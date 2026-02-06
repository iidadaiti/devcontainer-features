#!/bin/sh
set -eu

# These are passed as environment variables by the devcontainer CLI
USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"

# Bring in ID, ID_LIKE, VERSION_ID, VERSION_CODENAME from os-release
. /etc/os-release
# Get an adjusted ID independent of distro variants
MAJOR_VERSION_ID=$(echo "${VERSION_ID}" | cut -d . -f 1)
if [ "${ID}" = "debian" ] || [ "${ID_LIKE-}" = "debian" ]; then
    ADJUSTED_ID="debian"
elif [ "${ID}" = "alpine" ]; then
    ADJUSTED_ID="alpine"
elif [ "${ID}" = "rhel" ] || [ "${ID}" = "fedora" ] || [ "${ID}" = "mariner" ] || echo "${ID_LIKE}" | grep -q "rhel" || echo "${ID_LIKE}" | grep -q "fedora" || echo "${ID_LIKE}" | grep -q "mariner"; then
    ADJUSTED_ID="rhel"
    if [ "${ID}" = "rhel" ] || echo "${ID}" | grep -q "alma" || echo "${ID}" | grep -q "rocky"; then
        VERSION_CODENAME="rhel${MAJOR_VERSION_ID}"
    else
        VERSION_CODENAME="${ID}${MAJOR_VERSION_ID}"
    fi
else
    echo "Linux distro ${ID} not supported."
    exit 1
fi

if [ "${ADJUSTED_ID}" = "rhel" ] && [ "${VERSION_CODENAME-}" = "centos7" ]; then
    # As of 1 July 2024, mirrorlist.centos.org no longer exists.
    # Update the repo files to reference vault.centos.org.
    if [ -d /etc/yum.repos.d ]; then
        sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/*.repo 2>/dev/null || true
        sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/*.repo 2>/dev/null || true
        sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/*.repo 2>/dev/null || true
    fi
fi

if type apt-get > /dev/null 2>&1; then
    INSTALL_CMD=apt-get
elif type apk > /dev/null 2>&1; then
    INSTALL_CMD=apk
elif type microdnf > /dev/null 2>&1; then
    INSTALL_CMD=microdnf
elif type dnf > /dev/null 2>&1; then
    INSTALL_CMD=dnf
elif type yum > /dev/null 2>&1; then
    INSTALL_CMD=yum
else
    echo "(Error) Unable to find a supported package manager."
    exit 1
fi

# Clean package cache to reduce image size
clean_package_cache() {
    case "${ADJUSTED_ID}" in
        debian)
            rm -rf /var/lib/apt/lists/*
            ;;
        alpine)
            rm -rf /var/cache/apk/*
            ;;
        rhel)
            rm -rf /var/cache/dnf/*
            rm -rf /var/cache/yum/*
            ;;
    esac
}
clean_package_cache

pkg_mgr_update() {
    if [ "${INSTALL_CMD}" = "apt-get" ]; then
        if [ ! -d /var/lib/apt/lists ] || [ -z "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]; then
            echo "Running apt-get update..."
            "${INSTALL_CMD}" update -y
        fi
    elif [ "${INSTALL_CMD}" = "apk" ]; then
        if [ ! -d /var/cache/apk ] || [ -z "$(ls -A /var/cache/apk 2>/dev/null)" ]; then
            echo "Running apk update..."
            "${INSTALL_CMD}" update
        fi
    elif [ "${INSTALL_CMD}" = "dnf" ] || [ "${INSTALL_CMD}" = "yum" ]; then
        if [ ! -d "/var/cache/${INSTALL_CMD}" ] || [ -z "$(ls -A "/var/cache/${INSTALL_CMD}" 2>/dev/null)" ]; then
            echo "Running ${INSTALL_CMD} check-update ..."
            "${INSTALL_CMD}" check-update || true
        fi
    fi
}

# Ensures packages are installed (installs if missing)
ensure_packages() {
    if [ "${INSTALL_CMD}" = "apt-get" ]; then
        if ! dpkg -s "$@" > /dev/null 2>&1; then
            pkg_mgr_update
            "${INSTALL_CMD}" -y install --no-install-recommends "$@"
        fi
    elif [ "${INSTALL_CMD}" = "apk" ]; then
        "${INSTALL_CMD}" add \
            --no-cache \
            "$@"
    elif [ "${INSTALL_CMD}" = "dnf" ] || [ "${INSTALL_CMD}" = "yum" ]; then
        _pkg_count=$(echo "$@" | tr ' ' '\n' | wc -l)
        _pkg_installed=$("${INSTALL_CMD}" -C list installed "$@" 2>/dev/null | sed '1,/^Installed/d' | wc -l)
        if [ "${_pkg_count}" != "${_pkg_installed}" ]; then
            pkg_mgr_update
            "${INSTALL_CMD}" -y install "$@"
        fi
    elif [ "${INSTALL_CMD}" = "microdnf" ]; then
        "${INSTALL_CMD}" -y install \
            --refresh \
            --best \
            --nodocs \
            --noplugins \
            --setopt=install_weak_deps=0 \
            "$@"
    else
        echo "Linux distro ${ID} not supported."
        exit 1
    fi
}

prune_package() {
    if [ "${INSTALL_CMD}" = "apt-get" ]; then
        "${INSTALL_CMD}" purge -y --auto-remove "$@"
    elif [ "${INSTALL_CMD}" = "apk" ]; then
        "${INSTALL_CMD}" del "$@"
    elif [ "${INSTALL_CMD}" = "dnf" ] || [ "${INSTALL_CMD}" = "yum" ]; then
        "${INSTALL_CMD}" -y remove "$@"
    elif [ "${INSTALL_CMD}" = "microdnf" ]; then
        "${INSTALL_CMD}" -y remove "$@"
    else
        echo "Linux distro ${ID} not supported."
        exit 1
    fi
}

ensure_packages ca-certificates

if ! command -v tmux >/dev/null 2>&1; then
    ensure_packages tmux
fi

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS="vscode node codespace $(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd 2>/dev/null || true)"
    for CURRENT_USER in ${POSSIBLE_USERS}; do
        if id -u "${CURRENT_USER}" > /dev/null 2>&1; then
            USERNAME="${CURRENT_USER}"
            break
        fi
    done
    if [ -z "${USERNAME}" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u "${USERNAME}" > /dev/null 2>&1; then
    USERNAME=root
fi

# Install shadow package on Alpine if needed (provides su and runuser)
if [ "${ADJUSTED_ID}" = "alpine" ]; then
    if ! command -v runuser > /dev/null 2>&1; then
        ensure_packages shadow
    fi
fi

# Create user configuration script
# This script will be executed as the target user
TMUX_TMPDIR=$(mktemp -d) || {
    echo "Failed to create temporary directory"
    exit 1
}
chmod 755 "${TMUX_TMPDIR}"
TMUX_CONFIGURE_SCRIPT="${TMUX_TMPDIR}/configure_tmux.sh"
cat > "${TMUX_CONFIGURE_SCRIPT}" <<'BASE_EOF'
#!/bin/sh
# Check if HOME is valid and writable
if [ -z "${HOME}" ] || [ "${HOME}" = "/" ] || [ "${HOME}" = "/nonexistent" ] || ! [ -d "${HOME}" ] || ! [ -w "${HOME}" ]; then
    echo "Skipping tmux configuration (HOME directory not writable)"
    exit 0
fi

# Create .tmux.conf configuration
TMUX_CONF="${HOME}/.tmux.conf"
cat <<'EOF' > "${TMUX_CONF}"
# Window index
set-option -g base-index 1
set -g base-index 1
set-option -g renumber-windows on

# Mouse support
set-option -g mouse on

# Colors
set-option -g default-terminal screen-256color
set -g terminal-overrides 'xterm:colors=256'

# Status bar
setw -g status-style fg=colour255,bg=colour234
set -g status-left ""
set -g status-right ""
setw -g window-status-current-format '#[bg=colour2,fg=colour255] #I #W '
setw -g window-status-format '#[fg=colour242] #I #W '
setw -g window-status-current-format '#[bg=colour2,fg=colour255]#{?client_prefix,#[bg=colour3],} #I #W '

set -s escape-time 0

## Key Bindings

# Split
bind h split-window -h
bind v split-window -v

# Move
bind -n C-o select-pane -t :.+
bind -n C-h select-pane -L
bind -n C-j select-pane -D
bind -n C-k select-pane -U
bind -n C-l select-pane -R

# Resize
bind -n C-z resize-pane -Z # Toggle zoom for pane
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

EOF
BASE_EOF

chmod 755 "${TMUX_CONFIGURE_SCRIPT}"

# Execute the configuration script as the target user
if command -v runuser > /dev/null 2>&1; then
    runuser -u "${USERNAME}" sh "${TMUX_CONFIGURE_SCRIPT}"
else
    su -s /bin/sh "${USERNAME}" "${TMUX_CONFIGURE_SCRIPT}"
fi

# Clean up temporary directory and script
if [ -n "${TMUX_TMPDIR}" ] && [ -d "${TMUX_TMPDIR}" ]; then
    rm -rf "${TMUX_TMPDIR}"
fi
