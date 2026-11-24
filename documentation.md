# How pluto-sandbox works

What the setup consists of, where each piece lives and what it's for, and how to check it
when something doesn't work. For installation and daily use, see the [README](README.md).

Names below are the defaults from `install.sh`: sandbox user `claudeuser-pluto`, group
`pluto-projects`, folder `/srv/pluto-projects`, command `claude` (or `claude-pluto` if you
kept another Claude install). "Your user" is the account you named during the install.

## Overview

```
your user ── claude (wrapper, root-owned) ── sudo -u claudeuser-pluto ── podman run
                                                                            │
           rootless container "claude-sandbox" ◄────────────────────────────┘
             process: user pluto (= claudeuser-pluto's UID)
             sees:    the folder you started in, at the same path
                      /home/pluto  (volume claude-home: Claude binary, login, history)
             network: web (80/443) and DNS only, enforced on the host by nftables
```

Two layers protect your account:

1. **A separate host user.** The container runs as `claudeuser-pluto`, a locked user
   without sudo. Even after a container escape, an attacker only has that user's rights:
   `/srv/pluto-projects` and its own home folder.
2. **The container.** Inside, Claude sees only the folder you started it in and its own
   home volume, with no capabilities and fixed resource limits.

## Users and groups

| Name | What it's for |
|---|---|
| your user | Runs `claude`. Needs sudo (the wrapper calls `sudo`). Member of `pluto-projects`. |
| `claudeuser-pluto` | Owns and runs the container; rootless Podman runs as this user. No login shell, password locked, no sudo. Linger is enabled, because rootless Podman needs a systemd user session and this user never logs in. |
| `pluto-projects` | Shared group of your user and the sandbox user. Access to `/srv/pluto-projects` is granted through this group. |
| `pluto` (inside the image) | Same UID/GID as `claudeuser-pluto`, so files Claude writes belong to `claudeuser-pluto` on the host. |

**Names inside the container are misleading.** Rootless Podman only maps the sandbox user's
own IDs into the container; everything else shows up as `nobody` / `nogroup`. Files your
user created appear as `nobody`, and the group `pluto-projects` appears as `nogroup`.
Access still works, because the kernel checks the real IDs. Always check ownership on the
host.

## Files and what they're for

### On the host

| Path | Owner, mode | What it's for |
|---|---|---|
| `/usr/local/bin/claude` (or `claude-pluto`) | `root:root 755` | The wrapper: the command you run. Checks the start folder and the firewall, then starts the container. Neither you nor the sandbox user can change it. Line 2 holds the marker `# pluto-sandbox`. |
| `/srv/pluto-projects/` | `root:pluto-projects 2770` | The shared projects folder. Setgid (`2`): new files get the group `pluto-projects`. |
| `/etc/pluto-sandbox/egress.nft` | `root:root 644` | The firewall rules (`pluto-netOutRules.nft` with the sandbox user filled in). |
| `/etc/systemd/system/pluto-sandbox-firewall.service` | `root:root 644` | Loads the rules at boot and whenever nftables reloads. |
| nft table `inet pluto_sandbox` | kernel | The active rules, loaded from `egress.nft`. See [Network](#network). |
| image `claude-sandbox` | sandbox user's Podman | Debian bookworm-slim plus `curl`, `ca-certificates`, `git`, common tools (`python3`, `jq`, `dig`, `zip`, `unzip`, `less`, `ps`, `file`) and the user `pluto`. Built from `Containerfile`, see [Your own image](#your-own-image). |
| volume `claude-home` | sandbox user's Podman | Claude's home folder, see below. Survives restarts, rebuilds and re-installs; only `podman volume rm` deletes it. |

### Your own image

Claude has no root in the container, and everything outside its home and your project is
thrown away after each session, so Claude can't install system packages itself. If it
needs one (for example `chromium` for screenshots), add it to a copy of `Containerfile`
next to `install.sh`, e.g. `Containerfile.local`, and build from that copy:
`sudo ./install.sh Containerfile.local`. The argument is a file name in the script's
folder. The image only gets updates when you run `install.sh` again.

### Inside the container

| Path | What it's for |
|---|---|
| the folder you started in, e.g. `/srv/pluto-projects/my-project` | Your project, read-write, at the same path as on the host. Nothing else from `/srv/pluto-projects` is visible. |
| `/home/pluto/` | The `claude-home` volume: the Claude Code binary, your login, and Claude's settings, memory and history. Memory and history are kept per start folder. |
| everything else | From the image; thrown away after every session. |

## The wrapper

When you run `claude`, the wrapper:

1. Refuses to start outside `/srv/pluto-projects`.
2. Refuses a path containing `:`, because `podman -v` splits its argument at `:`.
3. Refuses to start if the firewall table is missing.
4. Replaces itself with `sudo -u claudeuser-pluto podman run …`, so signals and the exit
   status pass straight through.

The `podman run` options:

| Option | Why |
|---|---|
| `-it --rm` | Interactive terminal; the container is deleted after the session (state lives in the volume). |
| `--umask=0002` | Files Claude creates are group-writable, so your user can edit them. |
| `--userns=keep-id` | The container user keeps the sandbox user's UID, so file ownership on the host is correct. |
| `--group-add keep-groups` | Keeps the sandbox user's membership in `pluto-projects`, which grants access to the shared folder. |
| `--user UID:GID` | Runs as the sandbox user's IDs. |
| `--cap-drop=ALL` | No Linux capabilities. |
| `--security-opt=no-new-privileges` | setuid programs can't raise privileges. |
| `--memory=4g --cpus=2 --pids-limit=256` | Resource limits. |
| `-v "$cwd:$cwd:Z"` | Mounts only the start folder, at its own path. `:Z` is an SELinux label; on AppArmor systems (Ubuntu) it does nothing. |
| `-w "$cwd"` | Starts Claude in that folder. Claude keys its memory and history on this path. |
| `-v claude-home:/home/pluto` | Claude's persistent home. |

Starting in `/srv/pluto-projects` itself is allowed: that session sees all projects,
read-write. Starting in a subfolder mounts only that subfolder.

## Network

- Rootless Podman's network (pasta) opens connections **from the host, as the sandbox
  user**. The firewall therefore matches all sandbox traffic by user
  (`meta skuid claudeuser-pluto`).
- **Rules, top to bottom:** allow DNS to the local resolver (`127.0.0.53`, `127.0.0.54`,
  `127.0.0.1`, `127.0.1.1`) → drop loopback, private and link-local ranges (IPv4 and IPv6)
  → allow TCP 80, 443, 53 and UDP 53 → drop everything else. Blocked connections time out.
- **DNS path:** container → `169.254.1.1` (pasta) → host resolver, e.g. systemd-resolved
  → upstream. The resolver's own upstream query isn't made by the sandbox user, so the LAN
  block doesn't affect it.
- The rules live in their own table, so other firewall tools (ufw, your own rules) are not
  touched. Reloading replaces the table in one step, never leaving a moment without rules.
- `nft flush ruleset` or stopping nftables removes the table. The unit reloads it together
  with nftables, and the wrapper refuses to start while it's missing.

## Git

Git can run code from a repository without asking (hooks, some config keys). In the shared
folder the sandbox can write to anything your user creates, including `.git`. Two global
Git settings for your user close that (`install.sh` sets them if you agree):

- `core.sharedRepository 0600`: every new `.git` is private to its owner.
- `safe.bareRepository explicit`: Git ignores bare repositories it finds on its own
  (Git 2.38 or newer).

Each repo then belongs to whoever created it: yours are closed to Claude, and repos Claude
creates are refused by your Git (`dubious ownership`). Never add a repo to
`safe.directory`; that switches the protection off.

## Checking and debugging

Run these on the host unless noted.

**Setup**

```bash
type -a claude                                  # first hit must be the wrapper
sed -n 2p "$(command -v claude)"                # wrapper marker: # pluto-sandbox
id claudeuser-pluto                             # sandbox user and its groups
getent group pluto-projects                     # both users listed?
id -nG                                          # your session has pluto-projects? (else log out/in)
stat -c '%A %U:%G %n' /srv/pluto-projects       # drwxrws--- root:pluto-projects
loginctl show-user claudeuser-pluto -p Linger   # Linger=yes
```

**Firewall**

```bash
systemctl status pluto-sandbox-firewall         # "active (exited)" is correct here
sudo nft list table inet pluto_sandbox          # the rules, with packet counters
sudo systemctl restart pluto-sandbox-firewall   # reload the rules
```

**Podman (as the sandbox user)**

`sudo -u` keeps your current folder, and the sandbox user can't enter your home, so `cd`
somewhere neutral first:

```bash
cd /
sudo -u claudeuser-pluto -H podman images                  # image claude-sandbox
sudo -u claudeuser-pluto -H podman volume inspect claude-home
sudo -u claudeuser-pluto -H podman ps -a                   # running sessions
```

**A shell in the sandbox, without Claude** (same isolation as the wrapper; run from a
project folder):

```bash
cd /srv/pluto-projects/my-project
sudo -u claudeuser-pluto podman run -it --rm \
    --umask=0002 --userns=keep-id --group-add keep-groups \
    --user "$(id -u claudeuser-pluto):$(id -g claudeuser-pluto)" \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --memory=4g --cpus=2 --pids-limit=256 \
    -v "$(pwd -P):$(pwd -P):Z" -w "$(pwd -P)" \
    -v claude-home:/home/pluto \
    claude-sandbox bash
```

**Inside a session** (Claude can run these too):

```bash
id                                              # uid of claudeuser-pluto, user pluto
grep -E ' /(srv|home)' /proc/self/mountinfo     # only your project and /home/pluto
cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max
grep -E 'CapEff|NoNewPrivs' /proc/self/status   # CapEff all zeros, NoNewPrivs 1
umask                                           # 0002
curl -sI https://example.com                    # works
curl -m 5 http://portquiz.net:8080              # times out (port blocked)
```

### Common problems

| Symptom | Cause | Fix |
|---|---|---|
| `must be run from inside /srv/pluto-projects` | Started elsewhere. | `cd` into a project folder. |
| `could not verify the network restriction` | Firewall table missing, or `sudo` failed. | `sudo systemctl restart pluto-sandbox-firewall`. |
| `Permission denied` in `/srv/pluto-projects` right after installing | Your session doesn't have the new group yet. | Log out and back in; check with `id -nG`. |
| `WARN … no systemd user session available` | Linger is off for the sandbox user. | `sudo loginctl enable-linger claudeuser-pluto`. |
| DNS lookups fail inside the sandbox | Your resolver isn't local (e.g. `resolv.conf` points to the router). | Use a local resolver (systemd-resolved, dnsmasq). |
| `sudo: unable to change directory` | The sandbox user can't enter your current folder. | `cd /` (or into `/srv/pluto-projects`) first. |
| `claude` starts without the sandbox | A Claude installed after `install.sh` comes earlier in `PATH` (e.g. `~/.local/bin`). | `type -a claude`; remove it or re-run `install.sh`. |
| `dubious ownership` from your Git in a repo you created | The `.git` was replaced (by the sandbox). | Don't "fix" it with `safe.directory`; re-clone. |
| Files show as `nobody` inside the container | Normal: your user's UID isn't mapped. | Check ownership on the host. |
| Claude has no memory or history from before | Memory and history are kept per start folder. | Start in the same folder as before. |
