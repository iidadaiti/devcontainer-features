#!/bin/sh
set -eu

# These are passed as environment variables by the devcontainer CLI
USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
PLUGINDIR="${PLUGINDIR:-"automatic"}"
PURE="${PURE:-""}"
ZSH_AUTOSUGGESTIONS="${ZSHAUTOSUGGESTIONS:-""}"
ZSH_SYNTAX_HIGHLIGHTING="${ZSHSYNTAXHIGHLIGHTING:-""}"

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

if ! command -v zsh >/dev/null 2>&1; then
    ensure_packages zsh
fi

# Track whether git was already installed (for cleanup later)
HAS_GIT=false
if command -v git >/dev/null 2>&1; then
    HAS_GIT=true
else
    ensure_packages git
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

# Determine plugin directory
if [ "${PLUGINDIR}" = "automatic" ]; then
    # Get the target user's home directory
    if [ "${USERNAME}" = "root" ]; then
        TARGET_HOME="/root"
    else
        TARGET_HOME=$(getent passwd "${USERNAME}" 2>/dev/null | cut -d: -f6 || echo "/home/${USERNAME}")
    fi
    PLUGIN_DIR="${TARGET_HOME}/.zsh/plugins"
else
    PLUGIN_DIR="${PLUGINDIR}"
fi

# Install shadow package on Alpine if needed (provides su, runuser, and chsh)
if [ "${ADJUSTED_ID}" = "alpine" ]; then
    if ! command -v runuser > /dev/null 2>&1 || ! command -v chsh > /dev/null 2>&1; then
        ensure_packages shadow
    fi
fi

# Create user configuration script
# This script will be executed as the target user
ZSH_TMPDIR=$(mktemp -d) || {
    echo "Failed to create temporary directory"
    exit 1
}
chmod 755 "${ZSH_TMPDIR}"
ZSH_CONFIGURE_SCRIPT="${ZSH_TMPDIR}/configure_zsh.sh"

cat > "${ZSH_CONFIGURE_SCRIPT}" <<BASE_EOF
#!/bin/sh
# Check if HOME is valid and writable
if [ -z "\${HOME}" ] || [ "\${HOME}" = "/" ] || [ "\${HOME}" = "/nonexistent" ] || ! [ -d "\${HOME}" ] || ! [ -w "\${HOME}" ]; then
    echo "Skipping zsh configuration (HOME directory not writable)"
    exit 0
fi

# Create .zshrc configuration
ZSHRC="\${HOME}/.zshrc"
cat <<"EOF" >> "\${ZSHRC}"
# zsh compile
function source {
  ensure_zcompiled \${1}
  builtin source \${1}
}
function ensure_zcompiled {
  local compiled="\${1}.zwc"
  if [[ ! -r "\$compiled" || "\${1}" -nt "\$compiled" ]]; then
    zcompile \${1}
  fi
}
ensure_zcompiled \${HOME}/.zshrc

# Enable color
export TERM=xterm-256color
export COLORTERM=truecolor
autoload -Uz colors; colors

# Enable command auto-completion
autoload -Uz compinit; compinit

# Set history options
setopt hist_ignore_all_dups
setopt hist_ignore_dups
setopt share_history
setopt append_history

EOF

# Use provided PLUGIN_DIR or default to ~/.zsh/plugins
if [ -z "${PLUGIN_DIR:-}" ]; then
    PLUGIN_DIR="${HOME}/.zsh/plugins"
fi
mkdir -p "${PLUGIN_DIR}"

# Install Pure theme if requested
if [ -n "${PURE}" ] && [ ! -d "${PLUGIN_DIR}/pure" ]; then
    PURE_DIR="${PLUGIN_DIR}/pure"
    if git clone --depth 1 https://github.com/sindresorhus/pure.git "\${PURE_DIR}"; then
        git -C "\${PURE_DIR}" fetch --depth 1 origin "${PURE}"
        git -C "\${PURE_DIR}" checkout FETCH_HEAD
        rm -rf "\${PURE_DIR}/.git"

        cat <<EOF >> "\${ZSHRC}"
# Pure theme setup
fpath+="\${PURE_DIR}"
autoload -U promptinit; promptinit
prompt pure

EOF
    fi
fi

# Install zsh-autosuggestions if requested
if [ -n "${ZSH_AUTOSUGGESTIONS}" ] && [ ! -d "${PLUGIN_DIR}/zsh-autosuggestions" ]; then
    ZSH_AUTOSUGGESTIONS_DIR="${PLUGIN_DIR}/zsh-autosuggestions"
    if git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git "\${ZSH_AUTOSUGGESTIONS_DIR}"; then
        git -C "\${ZSH_AUTOSUGGESTIONS_DIR}" fetch --depth 1 origin "${ZSH_AUTOSUGGESTIONS}"
        git -C "\${ZSH_AUTOSUGGESTIONS_DIR}" checkout FETCH_HEAD
        rm -rf "\${ZSH_AUTOSUGGESTIONS_DIR}/.git"

        cat <<EOF >> "\${ZSHRC}"
# Setup zsh-autosuggestions
source "\${ZSH_AUTOSUGGESTIONS_DIR}/zsh-autosuggestions.zsh"

EOF
    fi
fi

# Install zsh-syntax-highlighting if requested
if [ -n "${ZSH_SYNTAX_HIGHLIGHTING}" ] && [ ! -d "${PLUGIN_DIR}/zsh-syntax-highlighting" ]; then
    ZSH_SYNTAX_HIGHLIGHTING_DIR="${PLUGIN_DIR}/zsh-syntax-highlighting"
    if git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git "\${ZSH_SYNTAX_HIGHLIGHTING_DIR}"; then
        git -C "\${ZSH_SYNTAX_HIGHLIGHTING_DIR}" fetch --depth 1 origin "${ZSH_SYNTAX_HIGHLIGHTING}"
        git -C "\${ZSH_SYNTAX_HIGHLIGHTING_DIR}" checkout FETCH_HEAD
        rm -rf "\${ZSH_SYNTAX_HIGHLIGHTING_DIR}/.git"

        cat <<EOF >> "\${ZSHRC}"
# Setup zsh-syntax-highlighting
source "\${ZSH_SYNTAX_HIGHLIGHTING_DIR}/zsh-syntax-highlighting.zsh"

EOF
    fi
fi

cat <<'EOF' >> "${ZSHRC}"
unfunction source

EOF
BASE_EOF

# Export environment variables for the configuration script
cat >> "${ZSH_CONFIGURE_SCRIPT}" <<EOF

# Environment variables for plugin installation
PURE="${PURE}"
ZSH_AUTOSUGGESTIONS="${ZSH_AUTOSUGGESTIONS}"
ZSH_SYNTAX_HIGHLIGHTING="${ZSH_SYNTAX_HIGHLIGHTING}"
PLUGIN_DIR="${PLUGIN_DIR}"
EOF

chmod 755 "${ZSH_CONFIGURE_SCRIPT}"

# Execute the configuration script as the target user
if command -v runuser > /dev/null 2>&1; then
    runuser -u "${USERNAME}" sh "${ZSH_CONFIGURE_SCRIPT}"
else
    su -s /bin/sh "${USERNAME}" "${ZSH_CONFIGURE_SCRIPT}"
fi

# Clean up temporary directory and script
if [ -n "${ZSH_TMPDIR}" ] && [ -d "${ZSH_TMPDIR}" ]; then
    rm -rf "${ZSH_TMPDIR}"
fi

# Fixing chsh always asking for a password on alpine linux
# ref: https://askubuntu.com/questions/812420/chsh-always-asking-a-password-and-get-pam-authentication-failure.
if [ ! -f "/etc/pam.d/chsh" ] || ! grep -Eq '^auth(.*)pam_rootok\.so$' /etc/pam.d/chsh; then
    mkdir -p /etc/pam.d
    echo "auth sufficient pam_rootok.so" >> /etc/pam.d/chsh
elif [ -n "$(awk '/^auth(.*)pam_rootok\.so$/ && !/^auth[[:blank:]]+sufficient[[:blank:]]+pam_rootok\.so$/' /etc/pam.d/chsh 2>/dev/null || true)" ]; then
    _chsh_tmp=$(mktemp) || {
        echo "Failed to create temporary file for chsh configuration"
        exit 1
    }
    awk '/^auth(.*)pam_rootok\.so$/ { $2 = "sufficient" } { print }' /etc/pam.d/chsh > "${_chsh_tmp}" && mv "${_chsh_tmp}" /etc/pam.d/chsh
fi

# Change default shell to zsh
_zsh_path=$(command -v zsh)
chsh -s "${_zsh_path}" "${USERNAME}"

# Remove git if it was installed by this script
if [ "${HAS_GIT}" = "false" ]; then
    prune_package git
fi
