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
- **Git:** run Git yourself, on the host. Claude has no Git inside the sandbox.
  `git init` and `git clone` inside `/srv/pluto-projects` create a `.git` folder
  the sandbox can write to. Hooks or config planted there would run as **you** on
  your next `git` command, and Git does not warn about it. Close the folder right
  after creating it:
  ```bash
  chmod 700 .git
  ```

## How it works

- **Sandbox user:** the container runs as a separate user (`claudeuser`) with no
  password, no login shell and no sudo. Even if Claude breaks out of the
  container, it can only reach what that user can reach.
- **Shared folder:** `/srv/pluto-projects` belongs to the group `projects`.
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
- `chmod 700 .git` is not complete protection: the sandbox can still rename
  `.git` and put another folder in its place. `claude` does not check `.git`
  yet; an automatic check at launch is planned.

## License

MIT, see [LICENSE](LICENSE).
