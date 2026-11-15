# Claude Code in a Podman sandbox

Run Claude Code isolated from your own user account, built on one assumption:
**the process running Claude Code is under an attacker's full control**, and the
setup minimizes what that gets them. Claude runs in a rootless Podman container,
owned by a separate, locked system user, and only sees the project you start it in.

## Requirements

- Linux (tested on Ubuntu 26.04)
- Podman (rootless)
- systemd and nftables (`sudo apt install nftables` if `nft` is missing)
- sudo rights

## Installation

```bash
git clone https://github.com/stariov/pluto-sandbox.git
cd pluto-sandbox
sudo ./install.sh
```

Running `install.sh` again is safe; use it to update the setup. If you request to delete Claude, `~/.claude` settings are kept.

Installed Git after `install.sh`, or answered "n" to the Git question? This will only affect new repos.
```bash
git config --global core.sharedRepository 0600
git config --global safe.bareRepository explicit
```

> **Important:** installing claude after our install will shadow our command
> and launch unsandboxed claude. Check with `type -a claude` and look for
> pluto-sandbox in file.

If this setup is useful to you, please ⭐ star the project. Would make me happy.

## Usage

> **Important:** whatever you run from `/srv/pluto-projects` (scripts, `make`,
> `npm install`, …) runs with **your** rights, or root's with `sudo`. No
> container or VM can prevent that. Review code before running it.

```bash
mkdir /srv/pluto-projects/my-project
cd /srv/pluto-projects/my-project
claude
```

- `claude` (or `claude-pluto`) only starts inside `/srv/pluto-projects`. Anywhere else it refuses.
- Inside the sandbox, the current project appears as `/projects`. Other projects
  are not visible.
- **Git:** a repo belongs to whoever creates it (`git init`/`git clone`). Yours are
  closed to Claude; Claude's are refused by your Git with `dubious ownership`.
  **Never** add a repo to `safe.directory`.
  - Repos from before the install: `chmod 700 .git` once, or re-clone if Claude
    ran in that project while `.git` was open.
  - Submodules or worktrees: let Claude own Git for that project.

## How it works

- **Sandbox user:** the container runs as a separate user (`claudeuser-pluto`) with no
  password, no login shell and no sudo. Even if Claude breaks out of the
  container, it can only reach what that user can reach. Linger is enabled for
  it, because rootless Podman needs a systemd user session and this user never
  logs in.
- **Shared folder:** `/srv/pluto-projects` belongs to the group `pluto-projects`.
  You and the sandbox user are both members, which lets you both work on the
  same files.
- **Container limits:** no capabilities, no privilege escalation, 4 GB memory,
  2 CPUs, 256 processes.
- **Claude's data** (binary, login, history) lives in the Podman volume
  `claude-home`. It survives restarts and re-installs.
- **Network:** a firewall rule on the host (nftables, loaded at boot) lets the
  sandbox user reach only web ports (80, 443) and DNS. Your local network and
  the host itself are blocked. `claude` refuses to start if the rule is missing.

## Limitations

- Network restrictions do not prevent data exfiltration: ports 80 and 443 are open.
  DNS only works through a local resolver (systemd-resolved, as on Ubuntu, or
  dnsmasq). If your DNS server is in your local network, lookups in the sandbox fail.
- Treat everything in `/srv/pluto-projects` as readable by Claude, and keep
  no secrets there.
- A container is not a VM: a kernel exploit could still escape it.
- Git in `/srv/pluto-projects` is the one way around the sandbox: hooks or config
  planted in a repo would run as **you** on your next `git` command. The two Git
  settings close that; without them Git there is unprotected, and nothing warns you.
- The sandbox can rename `.git` and put another folder in its place.
  Git's `dubious ownership` error in a repo you created means it was replaced: don't fix it, re-clone.

## License

MIT, see [LICENSE](LICENSE).
