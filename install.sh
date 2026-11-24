#!/usr/bin/env bash
set -euo pipefail

# ensure sudo rights
if [[ $EUID -ne 0 ]]; then
    echo "install.sh: must be run as root (sudo ./install.sh)" >&2
    exit 1
fi

# ── Settings ──────────────────────────────────────────────────────────────────────────────

# computed: folder of this script (Containerfile is copied from here)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# variable settings
HOST_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
SANDBOX_USER=claudeuser-pluto
PROJECTS_GROUP=pluto-projects
CONTAINERFILE=${1:-"Containerfile"}
# only change if you need to
PROJECTS_DIR=/srv/pluto-projects
INSTALL_PATH=/usr/local/bin/claude
# live inside sandbox_user's podman storage
IMAGE_NAME=claude-sandbox
HOME_VOLUME=claude-home
CONTAINER_HOME=/home/pluto
# command name; preflight may change it to claude-pluto
COMMAND_NAME=claude
# important, project tag
PLUTO_MARKER=pluto-sandbox


# ── Preflight checks (nothing is changed before step 0) ──────────────────────────────────

# check for nftables installation for network rules
# command makes -v silent
if ! command -v nft &>/dev/null; then 
    echo "install.sh: nft (nftables) is not installed, but the sandbox needs it for its network rules." >&2
    echo "Install it first (Ubuntu/Debian: sudo apt install nftables), then run install.sh again." >&2
    exit 1
fi

# check Containerfile existance
if [[ ! -f "$SCRIPT_DIR/$CONTAINERFILE" ]]; then
    echo "install.sh: Containerfile not found: $SCRIPT_DIR/$CONTAINERFILE" >&2
    exit 1
fi
if [[ "$CONTAINERFILE" != "Containerfile" ]]; then
    read -rp "install.sh: Should $CONTAINERFILE be used to build the image? [Y/n]: " use_containerfile_answer
    if [[ "$use_containerfile_answer" == @(n|N|no|No) ]]; then
        echo "install.sh: stopped" >&2
        exit 1
    fi
fi

# ask for $HOST_USER
echo "Press Enter to accept the default shown in brackets."
read -rp "Your own (existing) user, who will run claude [$HOST_USER]: " host_user_answer
# replace default values with answers
HOST_USER="${host_user_answer:-$HOST_USER}"

# $HOST_USER must exist and not be root
if ! id "$HOST_USER" &>/dev/null || [[ $HOST_USER == root ]]; then
    echo "install.sh: invalid host user" >&2
    exit 1
fi

# warn user of permission change of $PROJECTS_DIR
if [[ -d "$PROJECTS_DIR" ]]; then 
    read -rp "install.sh: folder $PROJECTS_DIR already exists, permissions will be changed! [y/N]: " override
    if [[ "$override" != @(y|Y|yes|Yes) ]]; then
        echo "install.sh: stopped" >&2
        exit 1
    fi
fi

# warn user about git permissions change
CHANGE_GIT_PERMISSIONS=false
if command -v git >/dev/null 2>&1; then
    read -rp "Make new git repos owner private (sets 2 values in your ~/.gitconfig)? [Y/n]: " change_git_answer
    if [[ "$change_git_answer" == @(n|N|no|No) ]]; then
        echo "install.sh: git will be unprotected when used in $PROJECTS_DIR" >&2
        # exit 1, maybe git permissions should be enforced
    else
        CHANGE_GIT_PERMISSIONS=true
    fi
fi

# search for foreign claude installations
mapfile -t found < <(sudo -u "$HOST_USER" -H bash -lc 'type -ap claude' | grep '^/')
foreign=()
for path in "${found[@]}"; do
    grep --quiet --no-messages "$PLUTO_MARKER" "$path" || foreign+=("$path")
done 

UNINSTALL_CLAUDE=false
HOST_USER_HOME="$(getent passwd "$HOST_USER" | cut -d: -f6)"

# foreign claude installations?
if (( ${#foreign[@]} > 0 )); then
    echo "install.sh: found other claude installations:"
    printf '  %s\n' "${foreign[@]}"
    read -rp "Do you want to replace them with the sandbox? [y/N]: " replace_claude
    if [[ "$replace_claude" == @(y|Y|yes|Yes) ]]; then
        UNINSTALL_CLAUDE=true
    else
        read -rp "Do you want to call the command claude-pluto instead? [Y/n]: " rename_command
        if [[ "$rename_command" == @(n|N|no|No) ]]; then
            echo "install.sh: stopped" >&2
            exit 1
        fi
        INSTALL_PATH=/usr/local/bin/claude-pluto
        COMMAND_NAME=claude-pluto
    fi

    # removal happens in step 3, right before the wrapper is installed
fi


# ── Step 0: host setup: users, shared group, projects folder, git defaults (run as root) ──

# create $SANDBOX_USER if it doesn't exist
if ! id "$SANDBOX_USER" &>/dev/null; then
    echo "Creating sandbox user: $SANDBOX_USER" 
    useradd --create-home --shell /usr/sbin/nologin "$SANDBOX_USER"
fi
passwd -l "$SANDBOX_USER"
loginctl enable-linger "$SANDBOX_USER"

# create $PROJECTS_GROUP if it doesn't exist
if ! getent group "$PROJECTS_GROUP" &>/dev/null; then
    echo "Creating group: $PROJECTS_GROUP"
    groupadd "$PROJECTS_GROUP"
fi
usermod -aG "$PROJECTS_GROUP" "$HOST_USER"
usermod -aG "$PROJECTS_GROUP" "$SANDBOX_USER"
# usermod -aG doesn't apply to already-open shells — log $HOST_USER out/in first.

echo "Creating shared projects folder: $PROJECTS_DIR"
mkdir -p "$PROJECTS_DIR"
chown "root:$PROJECTS_GROUP" "$PROJECTS_DIR"
chmod 2770 "$PROJECTS_DIR"

# changing git permissions
if [[ "$CHANGE_GIT_PERMISSIONS" == true ]]; then
    echo "Setting git permissions"
    sudo -u "$HOST_USER" -H git -C / config --global core.sharedRepository 0600
    sudo -u "$HOST_USER" -H git -C / config --global safe.bareRepository explicit
fi


# ── Step 1: network egress restriction (after step 0: nft resolves the user name at load) ─

echo "Installing network restriction files for container"

rules="$(sed 's/@SANDBOX_USER@/'"$SANDBOX_USER"'/' "$SCRIPT_DIR/pluto-netOutRules.nft")"

if ! nft -c -f /dev/stdin <<< "$rules"; then
    echo "install.sh: pluto-netOutRules.nft failed the nft syntax check (see error above)" >&2
    exit 1
fi

# install the table
rm -f /etc/pluto-sandbox/egress.nft
install -D -o "root" -g "root" -m 644 /dev/stdin "/etc/pluto-sandbox/egress.nft" <<< "$rules"
# install the service
install -o "root" -g "root" -m 644 "$SCRIPT_DIR/pluto-sandbox-firewall.service" "/etc/systemd/system/"

echo "Restarting and enabling services for network restriction"

# systemd caches unit files and would keep using old file (only warning "unit file changed") -> update the cache
systemctl daemon-reload

# enable -> puts link into .wants, systemd only follows which are inside .wants
systemctl enable pluto-sandbox-firewall.service
systemctl restart pluto-sandbox-firewall.service


# ── Step 2: build image, first-time interactive Claude Code login ─────────────────────────

# change dir for build permissions
# tempfolder will be deleted by trap
tempfolder="$(sudo -u "$SANDBOX_USER" mktemp -d)"
trap 'rm -rf "$tempfolder"' EXIT
install -o "$SANDBOX_USER" -g "$(id -g "$SANDBOX_USER")" -m 400 "$SCRIPT_DIR/$CONTAINERFILE" "$tempfolder/Containerfile"
cd "$tempfolder"

echo "Building podman image: $IMAGE_NAME"
sudo -u "$SANDBOX_USER" -H podman build \
    --build-arg HOST_UID="$(id -u "$SANDBOX_USER")" \
    --build-arg HOST_GID="$(id -g "$SANDBOX_USER")" \
    -t "$IMAGE_NAME" -f Containerfile .

echo Installing claude in the sandbox
sudo -u "$SANDBOX_USER" -H podman run -it --rm \
    --userns=keep-id --group-add keep-groups \
    --user "$(id -u "$SANDBOX_USER"):$(id -g "$SANDBOX_USER")" \
    -v "$HOME_VOLUME:$CONTAINER_HOME" \
    "$IMAGE_NAME" bash -c "curl -fsSL https://claude.ai/install.sh | bash"


# ── Step 3: install daily-use wrapper to /usr/local/bin/claude or claude-pluto ────────────

# old or foreign executables will be replaced here
rm -f "$INSTALL_PATH"
if [[ "$UNINSTALL_CLAUDE" == true ]]; then
    rm -f "${foreign[@]}"
    sudo -u "$HOST_USER" rm -rf "$HOST_USER_HOME/.local/share/claude"
fi

echo "Installing daily-use wrapper to $INSTALL_PATH"
install -o root -g root -m 755 /dev/stdin "$INSTALL_PATH" <<EOF
#!/usr/bin/env bash
# $PLUTO_MARKER
set -euo pipefail

host_cwd="\$(pwd -P)"

# check directory
if [[ "\$host_cwd" != "$PROJECTS_DIR" && "\$host_cwd" != "$PROJECTS_DIR"/* ]]; then
    echo "$COMMAND_NAME: must be run from inside $PROJECTS_DIR" >&2
    exit 1
fi
if [[ "\$host_cwd" == *:* ]]; then
        echo "$COMMAND_NAME: project path must not contain ':'" >&2
    exit 1
fi

# check network restriction
if ! sudo nft list table inet pluto_sandbox >/dev/null; then
    echo "$COMMAND_NAME: could not verify the network restriction (see error above), refusing to start." >&2
    echo "If the firewall table is missing: sudo systemctl restart pluto-sandbox-firewall.service" >&2
    exit 1
fi

exec sudo -u "$SANDBOX_USER" podman run -it --rm \
    --umask=0002 \
    --userns=keep-id --group-add keep-groups \
    --user "$(id -u "$SANDBOX_USER"):$(id -g "$SANDBOX_USER")" \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --memory=4g --cpus=2 --pids-limit=256 \
    -v "\${host_cwd}:\${host_cwd}:Z" \
    -w "\${host_cwd}" \
    -v "$HOME_VOLUME:$CONTAINER_HOME" \
    "$IMAGE_NAME" "$CONTAINER_HOME/.local/bin/claude" "\$@"
EOF


# ── Done ──────────────────────────────────────────────────────────────────────────────────

echo "Build complete. Log out/in once (for the $PROJECTS_GROUP group), then run '$COMMAND_NAME' from inside $PROJECTS_DIR."
  
