#!/bin/sh
set -eu

# These are passed as environment variables by the devcontainer CLI
CLAUDE_CODE_VERSION="${CLAUDECODEVERSION:-"latest"}"
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

# Install C++ runtime libraries on Alpine (required for Claude Code binary)
if [ "${ADJUSTED_ID}" = "alpine" ]; then
    ensure_packages libstdc++ libgcc
fi

# Track whether curl was already installed (for cleanup later)
HAS_CURL=false
if command -v curl >/dev/null 2>&1; then
    HAS_CURL=true
else
    ensure_packages curl
fi

# Ensure bash is installed for the Claude Code install script
HAS_BASH=false
if command -v bash >/dev/null 2>&1; then
    HAS_BASH=true
else
    ensure_packages bash
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

# Create Claude Code installation script
CLAUDE_TMPDIR=$(mktemp -d) || {
    echo "Failed to create temporary directory"
    exit 1
}
chmod 755 "${CLAUDE_TMPDIR}"
CLAUDE_INSTALL_SCRIPT="${CLAUDE_TMPDIR}/install_claude.sh"
CLAUDE_CHECKSUM="363382bed8849f78692bd2f15167a1020e1f23e7da1476ab8808903b6bebae05"

cat > "${CLAUDE_INSTALL_SCRIPT}" <<'BASE_EOF'
#!/bin/sh
set -eu

# Check if HOME is valid and writable
if [ -z "${HOME}" ] || [ "${HOME}" = "/" ] || [ "${HOME}" = "/nonexistent" ] || ! [ -d "${HOME}" ] || ! [ -w "${HOME}" ]; then
    echo "ERROR: Invalid or non-writable HOME directory: ${HOME}"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
BINARY_PATH="${TMP_DIR}/install.sh"

curl -fsSL https://claude.ai/install.sh -o "${BINARY_PATH}"
BASE_EOF

cat >> "${CLAUDE_INSTALL_SCRIPT}" <<EOF

if command -v shasum >/dev/null 2>&1; then
    actual=\$(shasum -a 256 "\${BINARY_PATH}" | cut -d' ' -f1)
elif command -v sha256sum >/dev/null 2>&1; then
    actual=\$(sha256sum "\${BINARY_PATH}" | cut -d' ' -f1)
else
    echo "ERROR: Neither shasum nor sha256sum command found!"
    exit 1
fi

if [ "\${actual}" != "${CLAUDE_CHECKSUM}" ]; then
    echo "ERROR: Claude Code installer checksum verification failed!"
    echo "Expected: ${CLAUDE_CHECKSUM}"
    echo "Got: \${actual}"
    exit 1
fi

bash "\${TMP_DIR}/install.sh" "${CLAUDE_CODE_VERSION}"
rm -rf "\${TMP_DIR}"

# Add Claude Code to PATH in shell configuration files
# The default installation directory is ~/.local/bin
CLAUDE_BIN_DIR="\${HOME}/.local/bin"

# # Add to user's shell RC files
# if [ -f "\${HOME}/.bashrc" ] || [ ! -f "\${HOME}/.zshrc" ]; then
#     echo "export PATH=\"\${CLAUDE_BIN_DIR}:\\\$PATH\"" >> "\${HOME}/.bashrc"
# fi
# if [ -f "\${HOME}/.zshrc" ]; then
#     echo "export PATH=\"\${CLAUDE_BIN_DIR}:\\\$PATH\"" >> "\${HOME}/.zshrc"
# fi

# Also add to system-wide profile for non-interactive shells
# Use a conditional PATH addition to avoid duplicates
cat >> "\${HOME}/.profile" <<'PROFILE_EOF'
# Claude Code CLI
case ":\${PATH}:" in
    *:\${HOME}/.local/bin:*)
        ;;
    *)
        export PATH="\${HOME}/.local/bin:\${PATH}"
        ;;
esac
PROFILE_EOF
EOF

chmod 755 "${CLAUDE_INSTALL_SCRIPT}"

# Execute the installation script as the target user
if command -v runuser > /dev/null 2>&1; then
    runuser -u "${USERNAME}" bash "${CLAUDE_INSTALL_SCRIPT}"
else
    su -s /bin/bash "${USERNAME}" "${CLAUDE_INSTALL_SCRIPT}"
fi

# Clean up temporary directory and script
if [ -n "${CLAUDE_TMPDIR}" ] && [ -d "${CLAUDE_TMPDIR}" ]; then
    rm -rf "${CLAUDE_TMPDIR}"
fi

# Clean up temporary packages
PACKAGES_TO_REMOVE=""
if [ "${HAS_CURL}" = "false" ]; then
    PACKAGES_TO_REMOVE="curl"
fi
if [ "${HAS_BASH}" = "false" ]; then
    PACKAGES_TO_REMOVE="${PACKAGES_TO_REMOVE} bash"
fi
if [ -n "${PACKAGES_TO_REMOVE}" ]; then
    prune_package ${PACKAGES_TO_REMOVE}
fi
