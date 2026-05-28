#!/bin/bash
set -euo pipefail

# WSL Ubuntu Yocto setup helper.
# This script runs directly on the host in WSL/Ubuntu and does not use Docker.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BLACK='\033[0;30m'
DARK_GRAY='\033[1;30m'
LIGHT_GRAY='\033[0;37m'
WHITE='\033[1;37m'
CYAN='\033[0;36m'
LIGHT_CYAN='\033[1;36m'
PURPLE='\033[0;35m'
LIGHT_PURPLE='\033[1;35m'
BROWN='\033[0;33m'
LIGHT_RED='\033[1;31m'
LIGHT_GREEN='\033[1;32m'
LIGHT_BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
RESET='\033[0m'

log_info() {
    echo -e "${GREEN}$1${RESET}"
}
log_warn() {
    echo -e "${YELLOW}$1${RESET}"
}
log_error() {
    echo -e "${RED}$1${RESET}" >&2
}
log_prompt() {
    echo -e "${LIGHT_CYAN}$1${RESET}"
}

HOST_USER="$(id -un)"
HOST_HOME="$(getent passwd "$HOST_USER" | cut -d: -f6 || true)"
HOST_HOME="${HOST_HOME:-/home/$HOST_USER}"
HOST_WORK_DIR="${HOST_HOME}/gateway_workdir"
HOST_SOURCES_DIR="${HOST_WORK_DIR}/sources"
HOST_SSTATE_DIR="${HOST_HOME}/sstate-cache"
HOST_DOWNLOADS_DIR="${HOST_WORK_DIR}/downloads"
HOST_BIN_DIR="${HOST_HOME}/bin"
HOST_GITCONFIG="${HOST_HOME}/.gitconfig"
HOST_SSH_DIR="${HOST_HOME}/.ssh"
LOCAL_REPO_BINARY="${HOST_BIN_DIR}/repo"
REPO_URL="https://gerrit.googlesource.com/git-repo"
MANIFEST_URL="https://github.com/skottakkadan-gnrc/898-manifest.git"
MANIFEST_BRANCH="main"
LOCAL_MANIFEST_REPO="${LOCAL_MANIFEST_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)/898-manifest}"
LOCAL_REPO_SRC_DIR="${LOCAL_REPO_SRC_DIR:-$HOST_WORK_DIR/.repo/repo}"
CORP_PROXY="${CORP_PROXY:-false}"

if [ "$CORP_PROXY" = "true" ]; then
    GIT_SSL_ENV="GIT_SSL_NO_VERIFY=1"
    CURL_INSECURE="-k"
else
    GIT_SSL_ENV=""
    CURL_INSECURE=""
fi

setup_locale() {
    log_info "Configuring en_US.UTF-8 locale"

    sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
    sudo locale-gen en_US.UTF-8
    sudo update-locale LANG=en_US.UTF-8

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    if ! grep -q 'export LANG=en_US.UTF-8' "$HOST_HOME/.bashrc"; then
        {
            echo ''
            echo '# Yocto locale requirement'
            echo 'export LANG=en_US.UTF-8'
            echo 'export LC_ALL=en_US.UTF-8'
        } >> "$HOST_HOME/.bashrc"
    fi
}

configure_git_protocol_rewrites() {
    log_info "Configuring Git protocol rewrites: git:// -> https://"

    git config --global url."https://git.kernel.org/".insteadOf "git://git.kernel.org/"
    git config --global url."https://sourceware.org/".insteadOf "git://sourceware.org/"
    git config --global url."https://git.yoctoproject.org/".insteadOf "git://git.yoctoproject.org/"
    git config --global url."https://git.openembedded.org/".insteadOf "git://git.openembedded.org/"
}

verify_host_tools() {
    log_info "Verifying Yocto host tools"

    local missing_tools=()

    for tool in lz4c pzstd unzstd zstd; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ "${#missing_tools[@]}" -ne 0 ]; then
        log_error "Missing required host tools: ${missing_tools[*]}"
        log_error "Install package names are: sudo apt install -y lz4 zstd"
        return 1
    fi

    log_info "Yocto compression host tools are available."
}

setup_yocto_local_conf_overrides() {
    local machine="${1:-dse-gateway}"
    local builddir="$HOST_WORK_DIR/build-${machine}"
    local confdir="$builddir/conf"
    local local_conf="$confdir/local.conf"
    local dse_local_conf="$HOST_SOURCES_DIR/meta-dse-bsp/conf/buildconf/local.conf"

    mkdir -p "$confdir"

    # The DSE setup script creates local.conf as a symlink.
    # Convert it to a real file so WSL-specific changes do not modify the source layer.
    if [ -L "$local_conf" ]; then
        cp -L "$local_conf" "${local_conf}.tmp"
        rm "$local_conf"
        mv "${local_conf}.tmp" "$local_conf"
    elif [ ! -f "$local_conf" ] && [ -f "$dse_local_conf" ]; then
        cp "$dse_local_conf" "$local_conf"
    fi

    if [ -f "$local_conf" ]; then
        sed -i '/CONNECTIVITY_CHECK_URIS/d' "$local_conf"

        cat >> "$local_conf" <<'EOF'

# WSL/corporate proxy: disable only Yocto connectivity sanity check.
# Normal recipe fetch/network access is still allowed.
CONNECTIVITY_CHECK_URIS = ""
EOF
    fi
}

repo_init_env() {
    if [ "$CORP_PROXY" = "true" ]; then
        echo "GIT_SSL_NO_VERIFY=1 PYTHONHTTPSVERIFY=0 SSL_CERT_FILE=/dev/null"
    else
        echo ""
    fi
}

install_zscaler_ca_from_windows() {
    log_info "Checking for Zscaler corporate CA"

    if [ "$CORP_PROXY" != "true" ]; then
        log_info "CORP_PROXY is not true; skipping Zscaler CA import."
        return 0
    fi

    if ! command -v powershell.exe >/dev/null 2>&1; then
        log_warn "powershell.exe not available from WSL; skipping Zscaler CA import."
        return 0
    fi

    local win_profile
    local win_profile_wsl
    local cert_path

    win_profile="$(cmd.exe /c echo %USERPROFILE% | tr -d '\r')"
    win_profile_wsl="$(wslpath "$win_profile")"
    cert_path="$win_profile_wsl/zscaler-root-ca.crt"

    powershell.exe -NoProfile -Command '
$cert = Get-ChildItem Cert:\LocalMachine\Root,Cert:\CurrentUser\Root |
    Where-Object { $_.Subject -like "*Zscaler*" -or $_.Issuer -like "*Zscaler*" } |
    Select-Object -First 1

if (-not $cert) {
    Write-Error "No Zscaler certificate found in Windows Root stores"
    exit 2
}

$bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$pem = "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($bytes, [System.Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----"
Set-Content -Path "$env:USERPROFILE\zscaler-root-ca.crt" -Value $pem -Encoding ascii
' || {
        log_warn "Could not export Zscaler CA from Windows."
        return 0
    }

    if [ -f "$cert_path" ]; then
        sudo cp "$cert_path" /usr/local/share/ca-certificates/zscaler-root-ca.crt
        sudo update-ca-certificates
        log_info "Installed Zscaler CA into WSL trust store."
    else
        log_warn "Zscaler CA export file not found: $cert_path"
    fi
}

clone_repo_source() {
    if [ -d "$LOCAL_REPO_SRC_DIR" ]; then
        return 0
    fi
    mkdir -p "$LOCAL_REPO_SRC_DIR"
    log_info "Cloning git-repo source directly to $LOCAL_REPO_SRC_DIR"
    env GIT_SSL_NO_VERIFY=1 git clone --depth 1 "$REPO_URL" "$LOCAL_REPO_SRC_DIR"
}

ensure_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' is not installed."
        return 1
    fi
    return 0
}

install_packages() {
    sudo apt update
    sudo apt install -y \
        git curl ca-certificates locales \
        python3 python3-pip python3-venv \
        wget unzip build-essential gcc-multilib \
        chrpath cpio diffstat texinfo xz-utils \
        sudo vim screen net-tools \
        lz4 zstd \
        && sudo apt clean
}

ensure_repo_tool() {
    mkdir -p "$HOST_BIN_DIR"
    if [ ! -x "$LOCAL_REPO_BINARY" ]; then
        log_info "Downloading repo tool to $LOCAL_REPO_BINARY"
        curl -L $CURL_INSECURE https://storage.googleapis.com/git-repo-downloads/repo -o "$LOCAL_REPO_BINARY"
        chmod a+x "$LOCAL_REPO_BINARY"
    fi
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOST_BIN_DIR"; then
        log_info "Adding $HOST_BIN_DIR to PATH in $HOST_HOME/.bashrc"
        echo "export PATH=\"$HOST_BIN_DIR:\$PATH\"" >> "$HOST_HOME/.bashrc"
        export PATH="$HOST_BIN_DIR:$PATH"
    fi
}

ensure_paths() {
    mkdir -p "$HOST_WORK_DIR"
    mkdir -p "$HOST_SOURCES_DIR"
    mkdir -p "$HOST_DOWNLOADS_DIR"
    mkdir -p "$HOST_SSTATE_DIR"
    mkdir -p "$HOST_BIN_DIR"
}

rewrite_manifest_remotes() {
    local remotes_file="$HOST_WORK_DIR/.repo/manifests/_remotes.xml"
    if [ -f "$remotes_file" ]; then
        sed -i \
            -e 's|git://git.yoctoproject.org|https://git.yoctoproject.org|g' \
            -e 's|git://git.openembedded.org|https://git.openembedded.org|g' \
            -e 's|git://git.ti.com|https://git.ti.com|g' \
            -e 's|https://github.com/ecobee|ssh://git@github.com/ecobee|g' \
            -e 's|https://github.com/|ssh://git@github.com/|g' \
            -e 's|https://github.com|ssh://git@github.com|g' \
            "$remotes_file"
        log_info "Rewrote manifest remotes to preserve SSH GitHub access."
    fi
}

fix_source_permissions() {
    if [ -d "$HOST_SOURCES_DIR" ]; then
        log_info "Fixing permissions under $HOST_SOURCES_DIR"
        chmod -R u+rwX,go+rX "$HOST_SOURCES_DIR" || true
        chown -R "$HOST_USER":"$HOST_USER" "$HOST_SOURCES_DIR" || true
    fi
    chmod -R u+rwX,go+rX "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" || true
    if [ -d "$HOST_WORK_DIR/.repo" ]; then
        chmod -R u+rwX,go+rX "$HOST_WORK_DIR/.repo" || true
    fi
}

cleanup_repo_projects() {
    log_warn "Cleaning local repo project worktrees to remove untracked files and reset checkouts."
    cd "$HOST_WORK_DIR"
    env $GIT_SSL_ENV "$LOCAL_REPO_BINARY" forall -c 'git reset --hard >/dev/null 2>&1 && git clean -fdx >/dev/null 2>&1' || true
}

init_repo() {
    ensure_paths
    ensure_repo_tool

    cd "$HOST_WORK_DIR"
    if [ -d .repo ] && [ -f .repo/manifest.xml ]; then
        log_info "Existing repo checkout detected in $HOST_WORK_DIR"
        return 0
    fi

    local manifest_source="$MANIFEST_URL"
    if [ -d "$LOCAL_MANIFEST_REPO/.git" ]; then
        log_info "Using local manifest repo at $LOCAL_MANIFEST_REPO"
        manifest_source="$LOCAL_MANIFEST_REPO"
    fi
    log_info "Initializing repo with manifest source $manifest_source"

    REPO_ENV="$(repo_init_env)"
    if ! env $REPO_ENV "$LOCAL_REPO_BINARY" init --config-name --no-repo-verify --repo-url "$REPO_URL" -u "$manifest_source" -b "$MANIFEST_BRANCH" -m default.xml; then
        log_warn "Initial repo init failed. Trying again with SSL bypass and SSH manifest URL."
        if ! env GIT_SSL_NO_VERIFY=1 PYTHONHTTPSVERIFY=0 SSL_CERT_FILE=/dev/null GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$LOCAL_REPO_BINARY" init --config-name --no-repo-verify --repo-url "$REPO_URL" -u "git@github.com:skottakkadan-gnrc/898-manifest.git" -b "$MANIFEST_BRANCH" -m default.xml; then
            log_warn "repo init still failed; attempting manual git cloning of the repo tool source."
            if ! clone_repo_source; then
                log_error "Error: Manual clone of git-repo source failed. Check your network or proxy settings."
                return 1
            fi
            log_info "Retrying repo init using locally cloned repo source and SSH manifest URL."
            if ! env GIT_SSL_NO_VERIFY=1 PYTHONHTTPSVERIFY=0 SSL_CERT_FILE=/dev/null GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$LOCAL_REPO_BINARY" init --config-name --no-repo-verify --repo-url "$LOCAL_REPO_SRC_DIR" -u "git@github.com:skottakkadan-gnrc/898-manifest.git" -b "$MANIFEST_BRANCH" -m default.xml; then
                log_error "Error: Failed to initialize repo even after manual git-repo clone."
                return 1
            fi
        fi
    fi
    rewrite_manifest_remotes
}

sync_repo() {
    ensure_paths
    if [ ! -d "$HOST_WORK_DIR/.repo" ]; then
        log_error "Repo is not initialized. Run './wsl-setup.sh init' first."
        return 1
    fi
    cd "$HOST_WORK_DIR"
    log_info "Syncing repo into $HOST_WORK_DIR"
    if ! env $GIT_SSL_ENV GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$LOCAL_REPO_BINARY" sync --jobs=1 --fail-fast --force-sync --verbose; then
        log_warn "Repo sync failed. Cleaning repo projects and retrying."
        cleanup_repo_projects
        if ! env $GIT_SSL_ENV GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$LOCAL_REPO_BINARY" sync --jobs=1 --fail-fast --force-sync --verbose; then
            log_error "Repo sync failed again. Please inspect $HOST_WORK_DIR and remove conflicting files or projects if necessary."
            return 1
        fi
    fi
    fix_source_permissions
}

verify_build_script() {
    local script_path="$HOST_SOURCES_DIR/meta-dse-bsp/scripts/setup.sh"
    if [ ! -x "$script_path" ] && [ -f "$script_path" ]; then
        chmod +x "$script_path" || true
    fi
    if [ ! -f "$script_path" ]; then
        log_error "Cannot find setup script at $script_path"
        exit 1
    fi
}

enter_build_environment() {
    verify_build_script
    setup_yocto_local_conf_overrides "dse-gateway"

    cd "$HOST_WORK_DIR"
    log_info "Entering bitbake shell for dse-gateway"

    export LANG="${LANG:-en_US.UTF-8}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
    export USE_HTTPS_FOR_GITHUB_ECOBEE="${USE_HTTPS_FOR_GITHUB_ECOBEE:-}"

    set +u
    . "$HOST_SOURCES_DIR/meta-dse-bsp/scripts/setup.sh" dse-gateway
}

build_target() {
    local target="${1:-lpp-default-image}"
    verify_build_script
    setup_yocto_local_conf_overrides "dse-gateway"

    cd "$HOST_WORK_DIR"
    log_info "Running build target: $target"

    export LANG="${LANG:-en_US.UTF-8}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
    export USE_HTTPS_FOR_GITHUB_ECOBEE="${USE_HTTPS_FOR_GITHUB_ECOBEE:-}"

    set +u
    . "$HOST_SOURCES_DIR/meta-dse-bsp/scripts/setup.sh" dse-gateway --build "$target"
}

show_help() {
    cat <<EOF
Usage: $0 <command>

Commands:
  init         Install deps, download repo tool, init manifest, and rewrite remotes.
  sync         Sync the manifest and fix host permissions.
  env          Enter the dse-gateway bitbake shell.
  build <tgt>  Build a target, e.g. 'lpp-default-image'.
  fix-perms    Fix host permissions on sources, downloads, and sstate cache.
  all          Run init, sync, fix-perms, then enter the shell.
  help         Show this help message.

Environment variables:
  CORP_PROXY=true     Disable TLS verification for proxy environments.
EOF
}

main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 0
    fi

    case "$1" in
        init)
            install_packages
            setup_locale
            install_zscaler_ca_from_windows
            configure_git_protocol_rewrites
            verify_host_tools
            init_repo
            ;;
        sync)
            sync_repo
            ;;
        env)
            enter_build_environment
            ;;
        build)
            shift
            build_target "$@"
            ;;
        fix-perms)
            fix_source_permissions
            ;;
        all)
            install_packages
            setup_locale
            install_zscaler_ca_from_windows
            configure_git_protocol_rewrites
            verify_host_tools
            init_repo
            sync_repo
            setup_yocto_local_conf_overrides "dse-gateway"
            enter_build_environment
            ;;
        help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
