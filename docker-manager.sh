#!/bin/bash
# Docker/Podman manager for the DSE gateway Yocto setup under WSL.
#
# This version includes the same fixes used by the WSL-native setup:
#   - en_US.UTF-8 locale setup
#   - correct lz4/zstd package names for lz4c, pzstd, unzstd, zstd
#   - CONNECTIVITY_CHECK_URIS = "" for corporate/WSL network sanity checks
#   - safer GitHub SSH/proxy handling
#   - Podman keep-id handling for mounted Yocto worktrees
#
# Usage:
#   ./docker-manager.sh auto
#   CORP_PROXY=true ./docker-manager.sh auto
#   ./docker-manager.sh

set -o pipefail

initial_dir="$(pwd)"

# Text colors
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
    echo
}

log_yellow() {
    echo -e "   ${YELLOW}$1${RESET}"
}

log_error() {
    echo
    echo -e "   ${RED}$1${RESET}"
    echo
}

log_prompt() {
    echo
    echo -e "   ${LIGHT_CYAN}$1${RESET}"
}

CONTAINER_PREFIX="gateway-yocto-docker-image"
YOCTO_USER_HOME="/home/yoctouser"
YOCTO_MACHINE="${YOCTO_MACHINE:-dse-gateway}"
GIT_META_DSE_BSP_BRANCH="0899/V1/Main"

# Set CORP_PROXY=true only when behind a TLS-intercepting corporate proxy.
CORP_PROXY="${CORP_PROXY:-false}"

# Resolve the host user's home directory for non-root path operations.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    HOST_USER="$SUDO_USER"
else
    HOST_USER="$(logname 2>/dev/null || id -un 2>/dev/null || true)"
    if [ -z "$HOST_USER" ] || [ "$HOST_USER" = "root" ]; then
        HOST_USER="$(id -un 2>/dev/null || true)"
    fi
fi

HOST_HOME="$(getent passwd "$HOST_USER" | cut -d: -f6)"
if [ -z "$HOST_HOME" ]; then
    HOST_HOME="/home/$HOST_USER"
fi

if [ -z "$HOST_HOME" ]; then
    log_error "Unable to determine the host user's home directory."
    exit 1
fi

HOST_BASE_DIR="$HOST_HOME"
HOST_BIN_DIR="$HOST_HOME/bin"
HOST_BASHRC="$HOST_HOME/.bashrc"
HOST_SSH_DIR="$HOST_HOME/.ssh"
HOST_GITCONFIG="$HOST_HOME/.gitconfig"
HOST_WORK_DIR="$HOST_BASE_DIR/gateway_workdir"
HOST_SOURCES_DIR="$HOST_WORK_DIR/sources"
HOST_CHECKOUT_DIR="$HOST_SOURCES_DIR"
HOST_SSTATE_DIR="$HOST_BASE_DIR/sstate-cache"
HOST_DOWNLOADS_DIR="$HOST_WORK_DIR/downloads"
HOST_CONTAINER_SSH_DIR="$HOST_WORK_DIR/ssh"
HOST_YOCTO_START_SCRIPT="$HOST_WORK_DIR/start-yocto.sh"
LOCAL_REPO_BINARY="$HOST_WORK_DIR/.repo/repo/repo"
REPO_URL="https://gerrit.googlesource.com/git-repo"
MANIFEST_HTTPS_URL="https://github.com/skottakkadan-gnrc/898-manifest.git"
MANIFEST_SSH_URL="git@github.com:skottakkadan-gnrc/898-manifest.git"
MANIFEST_BRANCH="main"
MANIFEST_FILE="default.xml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_ENGINE=""
ENGINE_DISPLAY_NAME=""
PODMAN_USERNS_ARGS=()

if [ "$CORP_PROXY" = "true" ]; then
    GIT_SSL_ENV="GIT_SSL_NO_VERIFY=1"
    CURL_INSECURE="-k"
else
    GIT_SSL_ENV=""
    CURL_INSECURE=""
fi

container_engine_setup() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_ENGINE="podman"
        ENGINE_DISPLAY_NAME="Podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_ENGINE="docker"
        ENGINE_DISPLAY_NAME="Docker"
    else
        log_yellow "Installing Podman..."
        sudo apt update || exit 1
        sudo apt install -y podman ca-certificates || exit 1
        CONTAINER_ENGINE="podman"
        ENGINE_DISPLAY_NAME="Podman"
        log_info "Podman installed successfully."
    fi

    log_info "$ENGINE_DISPLAY_NAME will be used for container operations."

    if [ "$CONTAINER_ENGINE" = "podman" ]; then
        mkdir -p "$HOST_HOME/.config/containers"

        if [ "$CORP_PROXY" = "true" ]; then
            cat > "$HOST_HOME/.config/containers/registries.conf" <<'EOF'
unqualified-search-registries = ["docker.io"]

[[registry]]
location = "docker.io"
insecure = true

[[registry]]
location = "registry-1.docker.io"
insecure = true
EOF
            log_info "Podman configured for insecure registry access because CORP_PROXY=true."
        else
            cat > "$HOST_HOME/.config/containers/registries.conf" <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF
            log_info "Podman configured with docker.io search registry and normal TLS verification."
        fi
    fi

    if [ "$CONTAINER_ENGINE" = "docker" ]; then
        sudo apt install -y ca-certificates || exit 1
        if command -v systemctl >/dev/null 2>&1; then
            sudo systemctl restart docker 2>/dev/null || true
        fi
    fi
}

compute_userns_args() {
    PODMAN_USERNS_ARGS=()
    [ "$CONTAINER_ENGINE" = "podman" ] || return 0

    local pmajor
    pmajor="$(podman version --format '{{.Client.Version}}' 2>/dev/null | cut -d. -f1)"
    if [ "${pmajor:-0}" -ge 4 ] 2>/dev/null; then
        PODMAN_USERNS_ARGS=(--userns=keep-id:uid=1000,gid=1000)
    else
        PODMAN_USERNS_ARGS=(--userns=keep-id)
    fi
}

docker() {
    if [ -z "$CONTAINER_ENGINE" ]; then
        log_error "Container engine is not initialized."
        exit 1
    fi
    command "$CONTAINER_ENGINE" "$@"
}

install_host_dependencies() {
    log_yellow "Installing/verifying host dependencies required by the manager and Yocto cache handling..."
    sudo apt update || exit 1
    sudo apt install -y \
        git curl ca-certificates locales \
        python3 python3-pip python3-venv \
        wget unzip sudo vim screen net-tools \
        lz4 zstd \
        || exit 1
    sudo apt clean || true
}

setup_host_locale() {
    log_yellow "Configuring host en_US.UTF-8 locale..."
    sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
    sudo locale-gen en_US.UTF-8 || exit 1
    sudo update-locale LANG=en_US.UTF-8 || true

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    if ! grep -q 'export LANG=en_US.UTF-8' "$HOST_BASHRC" 2>/dev/null; then
        {
            echo ''
            echo '# Yocto locale requirement'
            echo 'export LANG=en_US.UTF-8'
            echo 'export LC_ALL=en_US.UTF-8'
        } >> "$HOST_BASHRC"
    fi
}

verify_host_tools() {
    log_yellow "Verifying host compression tools..."
    local missing_tools=()

    for tool in lz4c pzstd unzstd zstd; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ "${#missing_tools[@]}" -ne 0 ]; then
        log_error "Missing host tools: ${missing_tools[*]}"
        log_error "Install package names are: sudo apt install -y lz4 zstd"
        return 1
    fi
}

prepare_host_environment() {
    install_host_dependencies
    setup_host_locale
    verify_host_tools || exit 1

    mkdir -p "$HOST_WORK_DIR" "$HOST_SOURCES_DIR" "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" "$HOST_BIN_DIR"
}

image_exists() {
    local image_name="$1"
    local image_id
    image_id="$(docker images -q "$image_name")"

    if [ -n "$image_id" ]; then
        log_info "Image '$image_name' exists."
        return 0
    fi

    log_yellow "Image '$image_name' does not exist."
    return 1
}

list_images() {
    docker images --filter "reference=${CONTAINER_PREFIX}*" --format "{{.Repository}}:{{.Tag}} ({{.ID}})"
}

list_containers() {
    docker ps -a --filter "name=${CONTAINER_PREFIX}" --format "{{.Names}} ({{.Status}})"
}

create_image() {
    local image_suffix
    image_suffix="$(date +%Y%m%d%H%M%S)"
    local image_name="${CONTAINER_PREFIX}_${image_suffix}"

    if image_exists "$image_name"; then
        log_error "Image with name '$image_name' already exists. Aborting image creation."
        return 1
    fi

    log_yellow "Creating $ENGINE_DISPLAY_NAME image '$image_name'..."
    docker build -t "$image_name" "$SCRIPT_DIR" || exit 1
    log_info "Image '$image_name' created successfully."
}

create_auto_image_if_missing() {
    local image_name="${CONTAINER_PREFIX}_auto"

    if ! image_exists "$image_name"; then
        log_yellow "Creating $ENGINE_DISPLAY_NAME image '$image_name'..."
        docker build -t "$image_name" "$SCRIPT_DIR" || exit 1
        log_info "Image '$image_name' created successfully."
    fi
}

repo_setup() {
    if ! command -v curl >/dev/null 2>&1; then
        sudo apt update || exit 1
        sudo apt install -y curl || exit 1
    fi

    mkdir -p "$HOST_BIN_DIR"

    if ! command -v repo >/dev/null 2>&1 && [ ! -x "$HOST_BIN_DIR/repo" ]; then
        log_yellow "Installing repo tool to $HOST_BIN_DIR/repo..."
        curl -L $CURL_INSECURE https://storage.googleapis.com/git-repo-downloads/repo > "$HOST_BIN_DIR/repo" || exit 1
        chmod a+x "$HOST_BIN_DIR/repo" || exit 1
    fi

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOST_BIN_DIR"; then
        echo "export PATH=\"$HOST_BIN_DIR:\$PATH\"" >> "$HOST_BASHRC"
        export PATH="$HOST_BIN_DIR:$PATH"
    fi

    if ! command -v repo >/dev/null 2>&1 && [ ! -x "$HOST_BIN_DIR/repo" ]; then
        log_error "repo command not found after installation."
        exit 1
    fi
}

repo_command() {
    if [ -x "$LOCAL_REPO_BINARY" ]; then
        echo "$LOCAL_REPO_BINARY"
    elif [ -x "$HOST_BIN_DIR/repo" ]; then
        echo "$HOST_BIN_DIR/repo"
    else
        command -v repo
    fi
}

configure_ssl_bypass() {
    export REPO_URL="https://gerrit.googlesource.com/git-repo"

    if [ "$CORP_PROXY" != "true" ]; then
        return 0
    fi

    export PYTHONHTTPSVERIFY=0
    export GIT_SSL_NO_VERIFY=1
    git config --global http.sslverify false
    git config --global http.sslCAInfo /dev/null
}

run_as_host_user() {
    if [ "$(id -u)" -eq 0 ] && [ "$HOST_USER" != "root" ]; then
        sudo -u "$HOST_USER" HOME="$HOST_HOME" PATH="$PATH" "$@"
    else
        "$@"
    fi
}

resolve_checkout_dir() {
    HOST_CHECKOUT_DIR="$HOST_SOURCES_DIR"
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

        log_yellow "Rewrote manifest remotes, preserving GitHub SSH access."
    fi
}

fix_source_permissions() {
    if [ ! -d "$HOST_SOURCES_DIR" ]; then
        return 0
    fi

    if id -u "$HOST_USER" >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            chown -R "$HOST_USER":"$HOST_USER" "$HOST_SOURCES_DIR" "$HOST_WORK_DIR/.repo" 2>/dev/null || true
        elif command -v sudo >/dev/null 2>&1; then
            sudo chown -R "$HOST_USER":"$HOST_USER" "$HOST_SOURCES_DIR" "$HOST_WORK_DIR/.repo" 2>/dev/null || true
        fi
    fi

    chmod -R u+rwX,go+rX "$HOST_SOURCES_DIR" "$HOST_WORK_DIR/.repo" 2>/dev/null || true
    chmod -R u+rwX,go+rX "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" 2>/dev/null || true
}

copy_meta_lpp_if_needed() {
    resolve_checkout_dir

    if [ -d "$HOST_CHECKOUT_DIR/meta-lpp" ]; then
        return 0
    fi

    if [ -d "/mnt/c/SAHEER/meta-lpp/meta-lpp" ]; then
        log_yellow "Copying local meta-lpp from /mnt/c/SAHEER/meta-lpp/meta-lpp..."
        cp -r /mnt/c/SAHEER/meta-lpp/meta-lpp "$HOST_CHECKOUT_DIR/" || exit 1
    else
        log_yellow "meta-lpp is missing and /mnt/c/SAHEER/meta-lpp/meta-lpp was not found."
        log_yellow "If this layer is private, copy it manually to: $HOST_CHECKOUT_DIR/meta-lpp"
    fi
}

init_and_sync_repo() {
    configure_ssl_bypass
    repo_setup

    mkdir -p "$HOST_WORK_DIR" "$HOST_SOURCES_DIR" "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR"
    cd "$HOST_WORK_DIR" || exit 1

    local repo_tool
    repo_tool="$(repo_command)"

    export GIT_SSH_COMMAND="ssh -i $HOST_HOME/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if [ ! -d "$HOST_WORK_DIR/.repo/repo" ]; then
        log_yellow "Cloning git-repo source manually..."
        mkdir -p "$HOST_WORK_DIR/.repo"
        run_as_host_user env ${GIT_SSL_ENV} git clone --depth 1 "$REPO_URL" "$HOST_WORK_DIR/.repo/repo" \
            || log_yellow "Manual git-repo clone failed; repo tool may still self-fetch."
    fi

    log_yellow "Initializing repo..."
    if ! run_as_host_user env ${GIT_SSL_ENV} "$repo_tool" init \
        --config-name \
        --no-repo-verify \
        --repo-url "$REPO_URL" \
        -u "$MANIFEST_HTTPS_URL" \
        -b "$MANIFEST_BRANCH" \
        -m "$MANIFEST_FILE"; then

        log_yellow "HTTPS manifest failed, trying SSH manifest..."
        if ! run_as_host_user env ${GIT_SSL_ENV} GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$repo_tool" init \
            --config-name \
            --no-repo-verify \
            --repo-url "$REPO_URL" \
            -u "$MANIFEST_SSH_URL" \
            -b "$MANIFEST_BRANCH" \
            -m "$MANIFEST_FILE"; then
            log_error "Failed to initialize repo with both HTTPS and SSH manifest URLs."
            return 1
        fi
    fi

    rewrite_manifest_remotes

    log_yellow "Syncing repo..."
    if ! run_as_host_user env ${GIT_SSL_ENV} GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$repo_tool" sync \
        --jobs=1 \
        --force-sync \
        --verbose; then
        log_error "repo sync failed. Try manually: cd $HOST_WORK_DIR && $repo_tool sync --jobs=1 --force-sync --verbose"
        return 1
    fi

    fix_source_permissions
    copy_meta_lpp_if_needed

    log_info "Repo sync completed successfully."
}

is_meta_gateway_git_repo() {
    if [ -d "$HOST_SOURCES_DIR/meta-dse-bsp" ]; then
        git -C "$HOST_SOURCES_DIR/meta-dse-bsp" rev-parse --is-inside-work-tree >/dev/null 2>&1
        return $?
    fi
    return 1
}

can_initialize_repo_dir() {
    if [ ! -d "$HOST_WORK_DIR/.repo" ]; then
        return 0
    fi

    if [ ! -d "$HOST_SOURCES_DIR/meta-dse-bsp" ]; then
        return 0
    fi

    return 1
}

ensure_repo_ready() {
    mkdir -p "$HOST_WORK_DIR" "$HOST_SOURCES_DIR" "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR"

    if [ ! -d "$HOST_SOURCES_DIR/meta-dse-bsp" ] || [ ! -d "$HOST_WORK_DIR/.repo" ]; then
        init_and_sync_repo || exit 1
    else
        log_info "Existing repo checkout detected at $HOST_WORK_DIR."
        copy_meta_lpp_if_needed
        fix_source_permissions
    fi

    if [ ! -d "$HOST_SOURCES_DIR/meta-dse-bsp" ]; then
        log_error "meta-dse-bsp directory not found after repo setup."
        exit 1
    fi
}

check_required_files() {
    if [ ! -d "$HOST_SSH_DIR" ]; then
        log_error "$HOST_SSH_DIR directory is missing."
        exit 1
    fi
}

prepare_ssh_mount() {
    check_required_files

    rm -rf "$HOST_CONTAINER_SSH_DIR"
    mkdir -p "$HOST_CONTAINER_SSH_DIR"
    cp -a "$HOST_SSH_DIR"/. "$HOST_CONTAINER_SSH_DIR"/ || exit 1
    chmod 700 "$HOST_CONTAINER_SSH_DIR" || true
    chmod 600 "$HOST_CONTAINER_SSH_DIR"/* 2>/dev/null || true
}

setup_inotify_limit() {
    local current
    current="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"

    if [ "$current" -lt 524288 ]; then
        log_yellow "Setting fs.inotify.max_user_watches=524288..."
        sudo sysctl -w fs.inotify.max_user_watches=524288 || exit 1
    fi
}

prepare_yocto_start_script() {
    cat > "$HOST_YOCTO_START_SCRIPT" <<EOF
#!/bin/bash
set -o pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export BB_ENV_PASSTHROUGH_ADDITIONS="\${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
export USE_HTTPS_FOR_GITHUB_ECOBEE="\${USE_HTTPS_FOR_GITHUB_ECOBEE:-}"

cd "$YOCTO_USER_HOME"

if [ ! -f "$YOCTO_USER_HOME/sources/meta-dse-bsp/scripts/setup.sh" ]; then
    echo "Missing: $YOCTO_USER_HOME/sources/meta-dse-bsp/scripts/setup.sh"
    exit 1
fi

set +u
. "$YOCTO_USER_HOME/sources/meta-dse-bsp/scripts/setup.sh" "$YOCTO_MACHINE"
EOF

    chmod +x "$HOST_YOCTO_START_SCRIPT"
}

setup_yocto_local_conf_overrides() {
    local container_name="$1"
    local builddir="$HOST_WORK_DIR/${container_name}_build"
    local confdir="$builddir/conf"
    local local_conf="$confdir/local.conf"

    mkdir -p "$confdir" "$builddir/tmp"

    cat > "$local_conf" <<EOF
# Auto-generated by docker-manager.sh for WSL/container builds.
# Keep source-layer local.conf untouched, then apply local WSL/corporate overrides.

require $YOCTO_USER_HOME/sources/meta-dse-bsp/conf/buildconf/local.conf

# WSL/corporate proxy: disable only Yocto connectivity sanity check.
# This does not disable normal recipe fetch/network access.
CONNECTIVITY_CHECK_URIS = ""

# Shared caches mounted from the WSL host.
DL_DIR = "$YOCTO_USER_HOME/downloads"
SSTATE_DIR = "$YOCTO_USER_HOME/build-dse-gateway/sstate-cache"
EOF

    chmod -R u+rwX,go+rX "$builddir" || true
}

prepare_build_dirs() {
    local container_name="$1"

    mkdir -p "$HOST_WORK_DIR/${container_name}_build/tmp" || exit 1
    mkdir -p "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" || exit 1

    setup_yocto_local_conf_overrides "$container_name"

    chmod -R u+rwX,go+rX "$HOST_WORK_DIR/${container_name}_build" "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" 2>/dev/null || true
}

container_exists() {
    local container_name="$1"
    [ -n "$(docker ps -a --filter "name=^/${container_name}$" --format "{{.Names}}")" ]
}

add_git_safe_directories() {
    local container_name="$1"

    docker exec -u 0 "$container_name" git config --system --add safe.directory "$YOCTO_USER_HOME" || true
    docker exec -u 0 "$container_name" git config --system --add safe.directory "$YOCTO_USER_HOME/sources" || true
    docker exec -u 0 "$container_name" git config --system --add safe.directory "$YOCTO_USER_HOME/.repo" || true

    for proj in "$HOST_SOURCES_DIR"/*; do
        [ -d "$proj" ] || continue
        local base
        base="$(basename "$proj")"
        docker exec -u 0 "$container_name" git config --system --add safe.directory "$YOCTO_USER_HOME/sources/$base" || true
    done
}

ensure_container_yocto_prereqs() {
    local container_name="$1"

    log_yellow "Installing/verifying Yocto prerequisites inside container..."

    docker exec -u 0 "$container_name" bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y \
        ca-certificates locales \
        git curl wget unzip \
        python3 python3-pip python3-venv \
        build-essential gcc-multilib \
        chrpath cpio diffstat texinfo xz-utils \
        lz4 zstd \
        sudo vim screen net-tools
    apt-get clean
else
    echo "apt-get not found in container. Please install locales, lz4, and zstd in the image."
    exit 1
fi

sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen || true
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 || true

cat > /etc/profile.d/yocto-env.sh <<PROFILEEOF
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export BB_ENV_PASSTHROUGH_ADDITIONS="\${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
export USE_HTTPS_FOR_GITHUB_ECOBEE="\${USE_HTTPS_FOR_GITHUB_ECOBEE:-}"
PROFILEEOF

for tool in lz4c pzstd unzstd zstd; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing required Yocto host tool inside container: $tool"
        exit 1
    }
done

if id yoctouser >/dev/null 2>&1; then
    grep -q "Yocto locale requirement" /home/yoctouser/.bashrc 2>/dev/null || cat >> /home/yoctouser/.bashrc <<BASHRCEOF

# Yocto locale requirement
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export BB_ENV_PASSTHROUGH_ADDITIONS="\${BB_ENV_PASSTHROUGH_ADDITIONS:-}"
export USE_HTTPS_FOR_GITHUB_ECOBEE="\${USE_HTTPS_FOR_GITHUB_ECOBEE:-}"
BASHRCEOF
    chown yoctouser:yoctouser /home/yoctouser/.bashrc 2>/dev/null || true
fi
' || exit 1

    add_git_safe_directories "$container_name"
}

start_container_shell() {
    local container_name="$1"

    log_info "Opening container shell. For Yocto env, run: ~/start-yocto.sh"
    docker exec -it "$container_name" bash -lc "cd $YOCTO_USER_HOME && exec /bin/bash"
}

run_container() {
    local image_name="$1"
    local container_name="$2"

    if container_exists "$container_name"; then
        log_yellow "Container $container_name already exists. Removing it."
        docker rm -f "$container_name" || exit 1
    fi

    prepare_build_dirs "$container_name"
    prepare_ssh_mount
    prepare_yocto_start_script

    log_yellow "Creating $ENGINE_DISPLAY_NAME container '$container_name'..."

    docker run -d --network host --name "$container_name" \
        "${PODMAN_USERNS_ARGS[@]}" \
        -e LANG=en_US.UTF-8 \
        -e LC_ALL=en_US.UTF-8 \
        -e BB_ENV_PASSTHROUGH_ADDITIONS="" \
        -e USE_HTTPS_FOR_GITHUB_ECOBEE="" \
        -w "$YOCTO_USER_HOME" \
        -v "$HOST_CONTAINER_SSH_DIR:${YOCTO_USER_HOME}/.ssh" \
        -v "$HOST_SOURCES_DIR:${YOCTO_USER_HOME}/sources" \
        -v "$HOST_DOWNLOADS_DIR:${YOCTO_USER_HOME}/downloads" \
        -v "$HOST_WORK_DIR/.repo:${YOCTO_USER_HOME}/.repo" \
        -v "$HOST_WORK_DIR/${container_name}_build:${YOCTO_USER_HOME}/build-dse-gateway" \
        -v "$HOST_SSTATE_DIR:${YOCTO_USER_HOME}/build-dse-gateway/sstate-cache" \
        -v "$HOST_YOCTO_START_SCRIPT:${YOCTO_USER_HOME}/start-yocto.sh:ro" \
        -v "$HOST_GITCONFIG:${YOCTO_USER_HOME}/.gitconfig:ro" \
        "$image_name" tail -f /dev/null || {
            log_error "Failed to start container $container_name"
            return 1
        }

    ensure_container_yocto_prereqs "$container_name"

    log_info "Container '$container_name' created successfully."
    start_container_shell "$container_name"
}

create_container() {
    ensure_repo_ready
    setup_inotify_limit
    fix_source_permissions

    log_prompt "Available images in '$CONTAINER_PREFIX':"
    local images
    images="$(list_images)"
    echo "$images" | nl

    read -p "$(log_prompt "Choose an image to use for the new container (1, 2, 3, ...): ")" image_choice
    local image_name
    image_name="$(echo "$images" | sed -n "${image_choice}p" | awk '{print $1}')"

    if [ -z "$image_name" ]; then
        log_error "Invalid image choice."
        return 1
    fi

    local container_name="${CONTAINER_PREFIX}_c_$(date +%Y%m%d%H%M%S)"
    run_container "$image_name" "$container_name"
}

auto_create_and_start() {
    prepare_host_environment
    create_auto_image_if_missing
    ensure_repo_ready
    setup_inotify_limit
    fix_source_permissions

    local image_name="${CONTAINER_PREFIX}_auto"
    local container_name="${CONTAINER_PREFIX}_c_$(date +%Y%m%d%H%M%S)"

    run_container "$image_name" "$container_name"
}

start_and_attach_container() {
    local container_name="$1"

    docker start "$container_name" >/dev/null || exit 1

    for _ in {1..10}; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" = "true" ]; then
            ensure_container_yocto_prereqs "$container_name"
            start_container_shell "$container_name"
            return
        fi
        sleep 1
    done

    log_error "Failed to start the container."
}

attach_container() {
    local container_name="$1"
    start_container_shell "$container_name"
}

exec_container() {
    local container_name="$1"
    start_container_shell "$container_name"
}

delete_image() {
    local image_name="$1"

    read -p "$(log_error "Delete image '$image_name'? (yes/no): ")" proceed
    if [[ "$proceed" == "yes" || "$proceed" == "Yes" || "$proceed" == "YES" ]]; then
        docker rmi "$image_name" && log_info "Image '$image_name' deleted successfully."
    fi
}

delete_container() {
    local container_name="$1"

    read -p "$(log_error "Delete container '$container_name'? (yes/no): ")" proceed
    if [[ "$proceed" == "yes" || "$proceed" == "Yes" || "$proceed" == "YES" ]]; then
        docker rm -f "$container_name" || true
        rm -rf "$HOST_WORK_DIR/${container_name}_build"
        log_info "Container '$container_name' and its build directory deleted successfully."
    fi
}

stop_container() {
    local container_name="$1"
    docker stop "$container_name"
    log_info "Container '$container_name' stopped successfully."
}

delete_dangling_images() {
    local dangling_images
    dangling_images="$(docker images --filter "dangling=true" --format "{{.ID}} {{.Repository}} {{.Tag}} {{.CreatedSince}} {{.Size}}")"

    if [ -n "$dangling_images" ]; then
        log_yellow "Found dangling images:"
        echo "$dangling_images"

        read -p "$(log_prompt "Delete dangling images? (yes/no): ")" proceed
        if [ "$proceed" = "yes" ]; then
            echo "$dangling_images" | awk '{print $1}' | while read -r image_id; do
                [ -n "$image_id" ] && docker rmi -f "$image_id"
            done
        fi
    fi
}

clean_all_containers() {
    local containers
    containers="$(docker ps -a --filter "name=$CONTAINER_PREFIX" --format "{{.Names}}")"

    if [ -z "$containers" ]; then
        log_info "No containers found with prefix '$CONTAINER_PREFIX'."
        return
    fi

    log_yellow "The following containers will be deleted:"
    echo "$containers" | nl

    read -p "$(log_error "Proceed deleting these containers? (yes/no): ")" proceed
    if [[ "$proceed" == "yes" || "$proceed" == "Yes" || "$proceed" == "YES" ]]; then
        for container in $containers; do
            docker rm -f "$container" || true
            rm -rf "$HOST_WORK_DIR/${container}_build"
            log_info "Container '$container' and its build directory deleted successfully."
        done
    fi
}

show_help() {
    echo
    echo "Docker/Podman Manager: Yocto development container helper"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  auto            Create/update auto image, prepare repo, start a new container"
    echo "  clean           Delete all containers with prefix '$CONTAINER_PREFIX'"
    echo
    echo "Environment:"
    echo "  CORP_PROXY=true Enable TLS-bypass / insecure-registry workarounds for"
    echo "                  TLS-intercepting corporate proxies."
    echo "  YOCTO_MACHINE=  Machine name, default: dse-gateway"
    echo
    echo "Inside the container:"
    echo "  ~/start-yocto.sh"
    echo "  bitbake lpp-default-image"
    echo
    log_yellow "Interactive mode: run without arguments."
    echo "  (S) Start an existing container"
    echo "  (E) Open a new interactive session to a running container"
    echo "  (C) Create a new container"
    echo "  (N) Create a new image"
    echo "  (P) Stop a running container"
    echo "  (D) Delete a container"
    echo "  (I) Delete an image"
    echo "  (X) Exit"
    echo
}

main_menu() {
    delete_dangling_images

    if [ -z "$(list_images)" ]; then
        create_image
    fi

    while true; do
        local images
        local containers
        images="$(list_images)"
        containers="$(list_containers)"

        if [ -n "$images" ]; then
            log_prompt "Available images in '$CONTAINER_PREFIX':"
            echo "$images" | nl
        fi

        if [ -n "$containers" ]; then
            log_prompt "Available containers:"
            echo "$containers" | nl
        fi

        log_prompt "Choose an option:"
        log_yellow "(S) Start an existing container"
        log_yellow "(E) Open a new interactive session to a running container"
        echo
        log_yellow "(C) Create a new container"
        log_yellow "(N) Create a new image"
        echo
        log_yellow "(P) Stop a running container"
        echo
        log_yellow "(D) Delete a container"
        log_yellow "(I) Delete an image"
        log_yellow "(X) Exit"

        read -p "$(log_prompt "Enter your choice (S, E, C, N, P, D, I, X): ")" user_choice

        case "$user_choice" in
            S)
                read -p "$(log_prompt "Choose a container to start and attach (1, 2, 3, ...): ")" container_choice
                local container_name
                container_name="$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')"

                if [ -n "$container_name" ]; then
                    if [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" = "true" ]; then
                        attach_container "$container_name"
                    else
                        start_and_attach_container "$container_name"
                    fi
                    exit 0
                else
                    log_error "Invalid choice."
                fi
                ;;
            E)
                read -p "$(log_prompt "Choose a running container (1, 2, 3, ...): ")" container_choice
                local container_name
                container_name="$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')"

                if [ -n "$container_name" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" = "true" ]; then
                    exec_container "$container_name"
                    exit 0
                else
                    log_error "Invalid choice or container is not running."
                fi
                ;;
            C)
                if [ -z "$(list_images)" ]; then
                    log_error "No images available. Create an image first with option N."
                else
                    prepare_host_environment
                    create_container
                    exit 0
                fi
                ;;
            N)
                create_image
                ;;
            P)
                read -p "$(log_prompt "Choose a container to stop (1, 2, 3, ...): ")" container_choice
                local container_name
                container_name="$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')"

                if [ -n "$container_name" ]; then
                    stop_container "$container_name"
                else
                    log_error "Invalid choice."
                fi
                ;;
            D)
                read -p "$(log_prompt "Choose a container to delete (1, 2, 3, ...): ")" container_choice
                local container_name
                container_name="$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')"

                if [ -n "$container_name" ]; then
                    delete_container "$container_name"
                else
                    log_error "Invalid choice."
                fi
                ;;
            I)
                log_prompt "Available images in '$CONTAINER_PREFIX':"
                list_images | nl
                read -p "$(log_prompt "Enter the number of the image to delete: ")" image_choice
                local image_name
                image_name="$(list_images | sed -n "${image_choice}p" | awk '{print $1}')"

                if [ -n "$image_name" ]; then
                    delete_image "$image_name"
                else
                    log_error "Invalid choice."
                fi
                ;;
            X)
                log_yellow "Exiting."
                exit 0
                ;;
            *)
                log_error "Invalid option."
                ;;
        esac
    done
}

container_engine_setup
compute_userns_args

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    auto)
        auto_create_and_start
        exit 0
        ;;
    clean)
        clean_all_containers
        exit 0
        ;;
    "")
        main_menu
        ;;
    *)
        log_error "Invalid argument: $1"
        show_help
        exit 1
        ;;
esac
