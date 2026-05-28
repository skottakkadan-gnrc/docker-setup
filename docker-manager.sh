#!/bin/bash

# Save the current directory
initial_dir=$(pwd)

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

CONTAINER_PREFIX="gateway-yocto-docker-image"
YOCTO_USER_HOME="/home/yoctouser"
GIT_META_DSE_BSP_BRANCH="0899/V1/Main"

# Set CORP_PROXY=true only when behind a TLS-intercepting corporate proxy.
# When false (default) we keep normal TLS verification and do NOT mark
# registries insecure. Override at call time, e.g.:  CORP_PROXY=true ./docker-manager.sh
CORP_PROXY="${CORP_PROXY:-false}"

# Resolve the host user's home directory for non-root path operations
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
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
LOCAL_REPO_BINARY="$HOST_WORK_DIR/.repo/repo/repo"

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_ENGINE=""
ENGINE_DISPLAY_NAME=""

# Rootless-Podman UID mapping args; populated by compute_userns_args().
PODMAN_USERNS_ARGS=()

# Logging functions
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

# Function to pick and setup the container engine
container_engine_setup() {
    if command -v podman &> /dev/null; then
        CONTAINER_ENGINE="podman"
        ENGINE_DISPLAY_NAME="Podman"
    elif command -v docker &> /dev/null; then
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
        mkdir -p ~/.config/containers
        if [ "$CORP_PROXY" = "true" ]; then
            # Behind a TLS-intercepting proxy: allow insecure registry access.
            cat > ~/.config/containers/registries.conf << 'EOF'
unqualified-search-registries = ["docker.io"]

[[registry]]
location = "docker.io"
insecure = true

[[registry]]
location = "registry-1.docker.io"
insecure = true
EOF
            log_info "Podman configured for insecure registry access (proxy bypass)."
        else
            # Normal network: keep TLS verification, just allow bare image names
            # like 'ubuntu:22.04' to resolve against Docker Hub.
            cat > ~/.config/containers/registries.conf << 'EOF'
unqualified-search-registries = ["docker.io"]
EOF
            log_info "Podman configured (docker.io search registry, TLS verification on)."
        fi
    fi

    if [ "$CONTAINER_ENGINE" = "docker" ]; then
        if ! command -v docker &> /dev/null; then
            log_error "Docker is not available after installation. Exiting."
            exit 1
        fi
        sudo apt install -y ca-certificates || exit 1
        sudo systemctl restart docker || exit 1
    fi
}

container_engine_setup

# Compute the user-namespace mapping for rootless Podman.
# Rootless Podman remaps container UIDs into subordinate host UIDs, so a bare
# bind mount ends up owned by a "stranger" UID and git complains about
# ownership. keep-id maps the container's yoctouser back to the host user.
compute_userns_args() {
    PODMAN_USERNS_ARGS=()
    [ "$CONTAINER_ENGINE" = "podman" ] || return 0

    # Podman 4.0+ supports the keep-id:uid=,gid= form, which maps the host
    # user onto container UID/GID 1000 (yoctouser) regardless of the host UID.
    local pmajor
    pmajor="$(podman version --format '{{.Client.Version}}' 2>/dev/null | cut -d. -f1)"
    if [ "${pmajor:-0}" -ge 4 ] 2>/dev/null; then
        PODMAN_USERNS_ARGS=(--userns=keep-id:uid=1000,gid=1000)
    else
        # Older Podman: plain keep-id. This is correct as long as the host
        # user's UID is 1000 (the default first user on Ubuntu/WSL, which
        # matches yoctouser in the Dockerfile).
        PODMAN_USERNS_ARGS=(--userns=keep-id)
    fi
}

compute_userns_args

# Wrapper function so existing docker commands use the chosen engine
docker() {
    if [ -z "$CONTAINER_ENGINE" ]; then
        log_error "Container engine is not initialized."
        exit 1
    fi
    command "$CONTAINER_ENGINE" "$@"
}

# Function to check if the Docker image exists
image_exists() {
    local image_name=$1
    IMAGE_ID=$(docker images -q $image_name)
    if [ -n "$IMAGE_ID" ]; then
        log_info "Image '$image_name' exists."
        return 0
    else
        log_yellow "Image '$image_name' is good to go."
        return 1
    fi
}

# Function to list images with the specified prefix
list_images() {
    docker images --filter "reference=${CONTAINER_PREFIX}*" --format "{{.Repository}}:{{.Tag}} ({{.ID}})"
}

# Function to list existing containers
list_containers() {
    docker ps -a --format "{{.Names}} ({{.Status}})"
}

# Function to create a new Docker image
create_image() {
    local image_suffix=$(date +%Y%m%d%H%M%S)
    IMAGE_NAME="gateway-yocto-docker-image_$image_suffix"
    if image_exists $IMAGE_NAME; then
        log_error "Error: Image with name '$IMAGE_NAME' already exists. Aborting image creation."
        return
    else
        log_yellow "Creating $ENGINE_DISPLAY_NAME image '$IMAGE_NAME'..."
        docker build -t $IMAGE_NAME "${SCRIPT_DIR}" || exit 1
        log_info "Image '$IMAGE_NAME' created successfully."
    fi
}

# Function to setup the repo tool
repo_setup() {
   # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        log_yellow "Installing curl..."
        sudo apt update || exit 1
        sudo apt install -y curl || exit 1
    else
        log_yellow "curl is already installed."
    fi

    # Check if repo is installed
    if ! command -v repo &> /dev/null; then
        log_yellow "Installing repo..."
        # Create the bin directory in the host user's home directory if it doesn't exist
        mkdir -p "$HOST_BIN_DIR"

        # Download the latest repo script
        curl -L $CURL_INSECURE https://storage.googleapis.com/git-repo-downloads/repo > "$HOST_BIN_DIR/repo" || exit 1

        # Make the repo script executable
        chmod a+x "$HOST_BIN_DIR/repo" || exit 1

        # Add the host user's bin directory to the PATH environment variable if it's not already there
        if ! echo "$PATH" | grep -q "$HOST_BIN_DIR"; then
            echo "export PATH=\"$HOST_BIN_DIR:\$PATH\"" >> "$HOST_BASHRC"
            export PATH="$HOST_BIN_DIR:$PATH"
            source "$HOST_BASHRC" || exit 1
        else
            # Ensure host bin is at the beginning of the PATH
            sed -i "s|PATH=\(.*\)|PATH=\"$HOST_BIN_DIR:\1\"|" "$HOST_BASHRC" || exit 1
            export PATH="$HOST_BIN_DIR:$PATH"
            source "$HOST_BASHRC" || exit 1
        fi

        # Verify the installation
        if ! command -v repo &> /dev/null; then
            log_error "Error: repo command not found after installation. Exiting."
            exit 1
        fi
    else
        log_info "repo is already installed."
    fi

    # Verify the installation
    which repo
    repo --version
}

# Configure SSL/TLS handling. REPO_URL is always set. TLS verification is only
# disabled when CORP_PROXY=true (i.e. a proxy is intercepting certificates).
configure_ssl_bypass() {
    export REPO_URL="https://gerrit.googlesource.com/git-repo"

    if [ "$CORP_PROXY" != "true" ]; then
        # No proxy: keep TLS verification on. Do not touch the global gitconfig.
        return 0
    fi

    export PYTHONHTTPSVERIFY=0
    export GIT_SSL_NO_VERIFY=1
    git config --global http.sslverify false
    git config --global http.sslCAInfo /dev/null
}

# Per-command SSL flags derived from CORP_PROXY (empty when no proxy).
if [ "$CORP_PROXY" = "true" ]; then
    GIT_SSL_ENV="GIT_SSL_NO_VERIFY=1"
    CURL_INSECURE="-k"
else
    GIT_SSL_ENV=""
    CURL_INSECURE=""
fi

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

repo_command() {
    if [ -x "$LOCAL_REPO_BINARY" ]; then
        echo "$LOCAL_REPO_BINARY"
    else
        command -v repo
    fi
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

# Function to initialize repo with better error handling
init_and_sync_repo() {
    log_yellow "Updating CA certificates..."
    sudo apt update && sudo apt install -y ca-certificates || log_yellow "Failed to update CA certificates, proceeding anyway..."
    log_yellow "Initializing repo..."
    export GIT_SSH_COMMAND="ssh -i $HOST_HOME/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if [ ! -d .repo/repo ]; then
        log_yellow "Downloading repo source manually..."
        mkdir -p .repo
        run_as_host_user env ${GIT_SSL_ENV} git clone https://gerrit.googlesource.com/git-repo .repo/repo || log_yellow "Failed to download repo source manually, proceeding..."
    fi
    local repo_tool
    repo_tool="$(repo_command)"
if ! run_as_host_user env ${GIT_SSL_ENV} "$repo_tool" init --config-name --no-repo-verify --repo-url "$REPO_URL" -u https://github.com/skottakkadan-gnrc/898-manifest.git -b main -m default.xml 2>&1; then
            log_yellow "HTTPS manifest failed, trying SSH manifest..."
            if ! run_as_host_user env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$repo_tool" init --config-name --no-repo-verify --repo-url "$REPO_URL" -u git@github.com:skottakkadan-gnrc/898-manifest.git -b main -m default.xml 2>&1; then
            log_error "Error: Failed to initialize repo with both HTTPS and SSH manifest URLs."
            return 1
        fi
    fi

    rewrite_manifest_remotes

    log_yellow "Syncing repo (this may take a while)..."
    if ! run_as_host_user env ${GIT_SSL_ENV} GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$repo_tool" sync --jobs=1 --verbose 2>&1; then
        log_error "Error: repo sync failed. Please check your network and authentication."
        log_yellow "You can try running '$repo_tool sync' manually in $HOST_WORK_DIR"
        return 1
    fi

    # Ensure the repo metadata is accessible to the container user
    log_yellow "Adjusting .repo permissions for container access..."
    # Make metadata and worktrees writable so container users can create
    # lockfiles (e.g. index.lock). With --userns=keep-id the container user
    # already maps to the host user, so this is mostly belt-and-braces.
    if chmod -R a+rwX "$HOST_WORK_DIR/.repo" "$HOST_SOURCES_DIR" 2>/dev/null; then
        log_yellow "Updated permissions to allow container write access."
    else
        log_yellow "Warning: failed to set permissive permissions; will attempt more conservative update."
        chmod -R u+rwX,go+rX "$HOST_WORK_DIR/.repo" || log_yellow "Warning: failed to update .repo permissions; container may still not have access."
    fi

    # Ensure downloads, sstate and work/build dirs are writable by the container
    mkdir -p "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR"
    if chmod -R a+rwX "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" "$HOST_WORK_DIR" 2>/dev/null; then
        log_yellow "Updated downloads, sstate and work directories to allow container write access."
    else
        log_yellow "Warning: failed to set permissive permissions on downloads/sstate/work dirs; attempting conservative update."
        chmod -R u+rwX,go+rX "$HOST_DOWNLOADS_DIR" "$HOST_SSTATE_DIR" || log_yellow "Warning: failed to update downloads/sstate permissions"
    fi
    # Make sure the metadata and working tree are owned by the host user so
    # the container user (mapped via keep-id) can operate on the checkout
    # without git complaining about dubious ownership.
    if id -u "$HOST_USER" >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            chown -R "$HOST_USER":"$HOST_USER" "$HOST_WORK_DIR/.repo" || log_yellow "Warning: failed to chown .repo to $HOST_USER"
            chown -R "$HOST_USER":"$HOST_USER" "$HOST_SOURCES_DIR" || log_yellow "Warning: failed to chown sources to $HOST_USER"
        else
            if command -v sudo >/dev/null 2>&1; then
                sudo chown -R "$HOST_USER":"$HOST_USER" "$HOST_WORK_DIR/.repo" || log_yellow "Warning: sudo chown .repo to $HOST_USER failed"
                sudo chown -R "$HOST_USER":"$HOST_USER" "$HOST_SOURCES_DIR" || log_yellow "Warning: sudo chown sources to $HOST_USER failed"
            else
                log_yellow "Cannot change ownership: not running as root and sudo is unavailable."
            fi
        fi
    else
        log_yellow "Host user $HOST_USER not found; skipping chown step."
    fi

    # Copy mete-lpp, since NO access for SAHEER
    resolve_checkout_dir

    if [ ! -d "$HOST_CHECKOUT_DIR/meta-lpp" ]; then
        cp /mnt/c/SAHEER/meta-lpp/meta-lpp "$HOST_CHECKOUT_DIR/" -r
    fi

    return 0
}

# Function to check if required files are present
check_required_files() {
    local missing_files=0

    if [ ! -d "$HOST_SSH_DIR" ]; then
        log_error "Error: $HOST_SSH_DIR directory is missing."
        missing_files=1
    fi

    if [ $missing_files -eq 1 ]; then
        log_error "One or more required files are missing. Exiting."
        exit 1
    fi
}

# Function to verify meta-dse-bsp is a valid git repository
is_meta_gateway_git_repo() {
    if [ -d "$HOST_SOURCES_DIR/meta-dse-bsp" ]; then
        git -C "$HOST_SOURCES_DIR/meta-dse-bsp" rev-parse --is-inside-work-tree >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Function to determine whether an existing repo directory can be safely initialized
can_initialize_repo_dir() {
    if [ ! -d "$HOST_SOURCES_DIR" ]; then
        return 0
    fi

    if [ -d "$HOST_SOURCES_DIR/sources/meta-dse-bsp" ]; then
        return 0
    fi

    if is_meta_gateway_git_repo; then
        return 1
    fi

    # Allow initialization if the directory is empty or contains only an incomplete sources tree
    if [ -z "$(find "$HOST_SOURCES_DIR" -mindepth 1 -maxdepth 1 -not -name 'sources' -print -quit)" ]; then
        if [ ! -d "$HOST_SOURCES_DIR" ]; then
            return 0
        fi
        if [ -z "$(find "$HOST_SOURCES_DIR" -mindepth 1 -type f -print -quit)" ]; then
            return 0
        fi
    fi

    return 1
}

# Function to create a new container
create_container() {
    if [ ! -d "$HOST_WORK_DIR" ]; then
        mkdir -p "$HOST_WORK_DIR" || exit 1
    fi
    check_required_files  # Check for required files before proceeding

    log_prompt "Available images in '$CONTAINER_PREFIX':"
    images=$(list_images)
    echo "$images" | nl

    read -p "$(log_prompt "Choose an image to use for the new container (1, 2, 3, ...): ")" image_choice
    image_name=$(echo "$images" | sed -n "${image_choice}p" | awk '{print $1}')
    if [ -n "$image_name" ]; then
        local container_name="${CONTAINER_PREFIX}_c_$(date +%Y%m%d%H%M%S)"
        if [ $(docker ps -a --filter "name=$container_name" --format "{{.Names}}") ]; then
            log_yellow "Container $container_name already exists. Removing it."
            docker rm $container_name
        fi

        # Check if the gateway repository exists and can be initialized or updated
        if [ ! -d "$HOST_SOURCES_DIR" ] || can_initialize_repo_dir; then
            # Configure SSL handling (sets REPO_URL; only disables TLS if CORP_PROXY=true)
            configure_ssl_bypass

            # setup your system repo tool
            repo_setup

            cd "$HOST_WORK_DIR" || exit 1

            mkdir -p "$HOST_SOURCES_DIR" || exit 1
            resolve_checkout_dir || exit 1
            init_and_sync_repo || exit 1

            # Verify the meta-dse-bsp directory was created
            resolve_checkout_dir

            if [ ! -d "$HOST_CHECKOUT_DIR/meta-dse-bsp" ]; then
                log_error "Error: meta-dse-bsp directory not found after repo sync. The manifest may be incorrect."
                exit 0 # TO DO
            fi

            if [ ! -d "$HOST_DOWNLOADS_DIR" ]; then
                mkdir -p "$HOST_DOWNLOADS_DIR" || exit 1
            fi

            if [ ! -d "$HOST_SSTATE_DIR" ]; then
                mkdir -p "$HOST_SSTATE_DIR" || exit 1
            fi

            log_info "Repository cloned and checked out successfully."
            cd "$initial_dir"
        else
            resolve_checkout_dir
            # Verify necessary subdirectories exist
            if [ ! -d "$HOST_CHECKOUT_DIR/meta-dse-bsp" ]; then
                log_error "Error: $HOST_SOURCES_DIR seems to contain an invalid or corrupted checkout."
                log_yellow "Please remove or rename it, then rerun this script."
                exit 1
            fi
            # update_meta_gateway part of manifest
        fi
    else
        resolve_checkout_dir
        # Verify necessary subdirectories exist
        if [ ! -d "$HOST_CHECKOUT_DIR/meta-dse-bsp" ]; then
            log_error "Error: meta-dse-bsp directory not found. Repository may be corrupted."
            exit 1
        fi
         # update_meta_gateway part of manifest
    fi

        # Increase inotify limit. Required for Yocto builds,
        # Reason: Observed 'ERROR: No space left on device or exceeds fs.inotify.max_user_watches?' during yocto bitbaking
        if [ "$(sysctl -n fs.inotify.max_user_watches)" -ne 524288 ]; then
            echo "Setting inotify limit to 524288"
            sudo sysctl -w fs.inotify.max_user_watches=524288 || exit 1
            sudo sysctl -p || exit 1
        fi

        if [ ! -d "$HOST_WORK_DIR/${container_name}_build/tmp" ]; then
            mkdir -p "$HOST_WORK_DIR/${container_name}_build/tmp" || exit 1
        fi

        if [ ! -d "$HOST_DOWNLOADS_DIR" ]; then
            mkdir -p "$HOST_DOWNLOADS_DIR" || exit 1
        fi

        # Shared sstate cache persists build artifacts across containers (much
        # faster rebuilds). Mounted into the build dir below.
        mkdir -p "$HOST_SSTATE_DIR" || exit 1

        cp -r "$HOST_SSH_DIR" "$HOST_WORK_DIR/ssh" || exit 1

        log_yellow "Creating $ENGINE_DISPLAY_NAME container '$container_name'..."

        # cp "$HOST_SOURCES_DIR/meta-dse-bsp/setup-environment" "$HOST_SOURCES_DIR/setup-environment" || exit 1

        # Start container detached so we can configure git safe.directory entries,
        # then attach interactively.
        docker run -d --network host --name $container_name \
            "${PODMAN_USERNS_ARGS[@]}" \
            -v "$HOST_WORK_DIR/ssh:${YOCTO_USER_HOME}/.ssh" \
            -v "$HOST_SOURCES_DIR:${YOCTO_USER_HOME}/sources" \
            -v "$HOST_DOWNLOADS_DIR:${YOCTO_USER_HOME}/downloads" \
            -v "$HOST_WORK_DIR/.repo:${YOCTO_USER_HOME}/.repo" \
            -v "$HOST_WORK_DIR/${container_name}_build/tmp:${YOCTO_USER_HOME}/build-dse-gateway/tmp" \
            -v "$HOST_SSTATE_DIR:${YOCTO_USER_HOME}/build-dse-gateway/sstate-cache" \
            -v "$HOST_GITCONFIG:${YOCTO_USER_HOME}/.gitconfig" \
            $image_name tail -f /dev/null || {
                log_error "Failed to start container $container_name"
                return 1
            }

        # Add system-level safe.directory entries for each project so git
        # inside the container won't complain about ownership.
        for proj in "$HOST_SOURCES_DIR"/*; do
            [ -d "$proj" ] || continue
            base=$(basename "$proj")
            docker exec -u 0 $container_name git config --system --add safe.directory "${YOCTO_USER_HOME}/sources/$base" || true
        done

        # Attach interactive shell
        docker exec -it $container_name /bin/bash

        if [ $? -eq 0 ]; then
            log_info "Container '$container_name' created and started successfully."
        else
            log_error "Failed to create and start the container."
        fi
}

update_meta_gateway() {
    local current_dir=$(pwd)
    resolve_checkout_dir
    if ! is_meta_gateway_git_repo; then
        log_error "Error: $HOST_CHECKOUT_DIR/meta-dse-bsp is not a valid git repository."
        exit 1
    fi

    cd "$HOST_CHECKOUT_DIR/meta-dse-bsp" || exit 1

    # Check for uncommitted changes
    if [ -n "$(git status --porcelain)" ]; then
        log_error "Uncommitted local changes detected in the '$HOST_CHECKOUT_DIR/meta-dse-bsp' repository."
        read -p "$(log_prompt "Do you want to proceed without pulling the latest changes from meta-dse-bsp repo? (yes/no): ")" proceed_without_pull
        if [[ "$proceed_without_pull" != "yes" ]]; then
            log_error "Please commit and push your changes before proceeding."
            exit 1
        else
            log_yellow "Proceeding without pulling the latest changes."
        fi
    else
        log_yellow "Pulling the latest changes from the meta-dse-bsp repo..."
        git pull $GIT_META_gateway_REMOTE $GIT_META_DSE_BSP_BRANCH || exit 1
    fi

    cd "$current_dir" || exit 1
}

# Function to start and attach to a container
start_and_attach_container() {
    local container_name=$1

    # update_meta_gateway part of manifest

    docker start $container_name

    # Wait until the container is running
    for i in {1..10}; do
        if [[ $(docker inspect -f '{{.State.Running}}' $container_name) == "true" ]]; then
            docker exec -it $container_name /bin/bash
            return
        fi
        sleep 1
    done

    log_error "Failed to start the container. Check the container logs for more details."
}

# Function to attach to a running container
attach_container() {
    local container_name=$1

    # update_meta_gateway part of manifest

    docker exec -it $container_name /bin/bash
}

# Function to open a new interactive session to a running container
exec_container() {
    local container_name=$1

    # update_meta_gateway part of manifest

    docker exec -it $container_name /bin/bash
}

# Function to delete a Docker image
delete_image() {
    read -p "$(log_error "Do you want to proceed? (yes/no): ")" proceed
    if [[ "$proceed" == "yes" || "$proceed" == "Yes"|| "$proceed" == "YES" ]]; then
        local image_name=$1
        docker rmi $image_name
        log_info "Image '$image_name' deleted successfully."
    fi
}

# Function to delete a container
delete_container() {
    read -p "$(log_error "Do you want to proceed Delete? (yes/no): ")" proceed
    if [[ "$proceed" == "yes" || "$proceed" == "Yes"|| "$proceed" == "YES" ]]; then
        local container_name=$1
        docker rm $container_name
        rm -rf "$HOST_WORK_DIR/${container_name}_build"  # Remove the specific build directory
        log_info "Container '$container_name' and its build directory deleted successfully."
    fi
}

# Function to stop a running container
stop_container() {
    local container_name=$1
    docker stop $container_name
    log_info "Container '$container_name' stopped successfully."
}

# Function to list and delete dangling images
delete_dangling_images() {
    dangling_images=$(docker images --filter "dangling=true" --format "{{.ID}} {{.Repository}} {{.Tag}} {{.CreatedSince}} {{.Size}}")
    if [ -n "$dangling_images" ]; then
        log_yellow "Found dangling images:"
        echo "$dangling_images"
        read -p "$(log_prompt "Do you want to delete these images? (yes/no): ")" proceed
        if [ "$proceed" == "yes" ]; then
            for image_id in $(echo "$dangling_images" | awk '{print $1}'); do
                log_yellow "Deleting image ID: $image_id"
                docker rmi -f $image_id
            done
            log_info "Dangling images deleted successfully."
        else
            log_error "Dangling image deletion aborted."
        fi
    fi
}

# Function to create a new image and start a container automatically
auto_create_and_start() {
    local image_suffix="auto"
    IMAGE_NAME="gateway-yocto-docker-image_$image_suffix"
    if ! image_exists $IMAGE_NAME; then
        log_yellow "Creating $ENGINE_DISPLAY_NAME image '$IMAGE_NAME'..."
        docker build -t $IMAGE_NAME "${SCRIPT_DIR}" || exit 1
        log_info "Image '$IMAGE_NAME' created successfully."
    fi

    check_required_files


    local container_name="${CONTAINER_PREFIX}_c_$(date +%Y%m%d%H%M%S)"
    if [ $(docker ps -a --filter "name=$container_name" --format "{{.Names}}") ]; then
        log_yellow "Container $container_name already exists. Removing it."
        docker rm $container_name
    fi

    if [ ! -d "$HOST_SOURCES_DIR" ] || can_initialize_repo_dir; then
        configure_ssl_bypass
        repo_setup
        mkdir -p "$HOST_WORK_DIR" || exit 1
        cd "$HOST_WORK_DIR" || exit 1
        mkdir -p "$HOST_SOURCES_DIR" || exit 1
        cd "$HOST_SOURCES_DIR" || exit 1

        init_and_sync_repo || exit 1

        # Verify the meta-dse-bsp directory was created
        resolve_checkout_dir
        if [ ! -d "$HOST_CHECKOUT_DIR/meta-dse-bsp" ]; then
            log_error "Error: meta-dse-bsp directory not found after repo sync. The manifest may be incorrect."
            exit 1
        fi

        if [ ! -d "$HOST_DOWNLOADS_DIR" ]; then
            mkdir -p "$HOST_DOWNLOADS_DIR" || exit 1
        fi

        if [ ! -d "$HOST_SSTATE_DIR" ]; then
            mkdir -p "$HOST_SSTATE_DIR" || exit 1
        fi

        log_info "default.xml Repository cloned and checked out successfully."
        cd "$initial_dir"
    else
        # Verify necessary subdirectories exist
        if [ ! -d "$HOST_CHECKOUT_DIR/meta-dse-bsp" ]; then
            log_error "Error: $HOST_SOURCES_DIR seems to contain an invalid or corrupted checkout."
            log_yellow "Please remove or rename it, then rerun this script."
            exit 1
        fi
        # update_meta_gateway part of manifest
    fi

    # Increase inotify limit. Required for Yocto builds, observed
    # Reason: Observed 'ERROR: No space left on device or exceeds fs.inotify.max_user_watches?' during yocto bitbaking
    if [ "$(sysctl -n fs.inotify.max_user_watches)" -ne 524288 ]; then
        echo "Setting inotify limit to 524288"
        sudo sysctl -w fs.inotify.max_user_watches=524288 || exit 1
        sudo sysctl -p || exit 1
    fi

    if [ ! -d "$HOST_WORK_DIR/${container_name}_build/tmp" ]; then
        mkdir -p "$HOST_WORK_DIR/${container_name}_build/tmp" || exit 1
    fi

    if [ ! -d "$HOST_DOWNLOADS_DIR" ]; then
        mkdir -p "$HOST_DOWNLOADS_DIR" || exit 1
    fi

    mkdir -p "$HOST_SSTATE_DIR" || exit 1

    cp -r "$HOST_SSH_DIR" "$HOST_WORK_DIR/ssh" || exit 1

    log_yellow "Creating $ENGINE_DISPLAY_NAME container '$container_name'..."

    # cp "$HOST_SOURCES_DIR/meta-dse-bsp/setup-environment" "$HOST_SOURCES_DIR/setup-environment" || exit 1

    docker run -it --network host --name $container_name \
        "${PODMAN_USERNS_ARGS[@]}" \
        -v "$HOST_WORK_DIR/ssh:${YOCTO_USER_HOME}/.ssh" \
        -v "$HOST_SOURCES_DIR:${YOCTO_USER_HOME}/sources" \
        -v "$HOST_DOWNLOADS_DIR:${YOCTO_USER_HOME}/downloads" \
        -v "$HOST_WORK_DIR/.repo:${YOCTO_USER_HOME}/.repo" \
        -v "$HOST_WORK_DIR/${container_name}_build/tmp:${YOCTO_USER_HOME}/build-dse-gateway/tmp" \
        -v "$HOST_SSTATE_DIR:${YOCTO_USER_HOME}/build-dse-gateway/sstate-cache" \
        -v "$HOST_GITCONFIG:${YOCTO_USER_HOME}/.gitconfig" \
        $IMAGE_NAME

    if [ $? -eq 0 ]; then
        log_info "Container '$container_name' created and started successfully."
    else
        log_error "Failed to create and start the container."
    fi

}

# Function to delete all containers with CONTAINER_PREFIX
clean_all_containers() {
    containers=$(docker ps -a --filter "name=$CONTAINER_PREFIX" --format "{{.Names}}")
    if [ -z "$containers" ]; then
        log_info "No containers found with prefix '$CONTAINER_PREFIX'."
        return
    fi

    log_yellow "The following containers will be deleted:"
    echo "$containers" | nl

    read -p "$(log_error "Do you want to proceed with deleting these containers? (yes/no): ")" proceed
    if [[ "$proceed" == "yes" || "$proceed" == "Yes" || "$proceed" == "YES" ]]; then
        for container in $containers; do
            docker rm $container
            rm -rf "$HOST_WORK_DIR/${container}_buildTmp"  # Remove the specific build directory
            log_info "Container '$container' and its build directory deleted successfully."
        done
    else
        log_error "Container deletion aborted."
    fi
}

# Function to display help/usage
show_help() {
    echo
    echo "Docker Manager: Utility to manage Docker images and containers for Yocto development"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help      Show this help message and exit"
    echo "  auto            Create a new image and start a container automatically"
    echo "  clean           Delete all containers with prefix '$CONTAINER_PREFIX'"
    echo
    echo "Environment:"
    echo "  CORP_PROXY=true Enable TLS-bypass / insecure-registry workarounds for"
    echo "                  TLS-intercepting corporate proxies (default: false)"
    echo

    log_yellow "Interactive options: Run the script without any arguments to use these options [ $0 ]"
    echo "  (S) Start an existing container"
    echo "  (E) Open a new interactive session to a running container"
    echo
    echo "  (C) Create a new container"
    echo "  (N) Create a new image"
    echo
    echo "  (P) Stop a running container"
    echo
    echo "  (D) Delete a container"
    echo "  (I) Delete an image"
    echo "  (X) Exit"
    echo
}

# Check for arguments.
if [ $# -gt 0 ]; then
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_help
        exit 0
    elif [ "$1" == "auto" ]; then
        auto_create_and_start
        exit 0
    elif [ "$1" == "clean" ]; then
        clean_all_containers
        exit 0
    else
        log_error "Invalid argument: $1"
        show_help
        exit 1
    fi
fi

# Check for dangling images and prompt for deletion
delete_dangling_images

# Check if any Docker image exists
if ! docker images | grep -q "$IMAGE_NAME"; then
    create_image
fi

while true; do
    images=$(list_images)
    if [ -n "$images" ]; then
        log_prompt "Available images in '$CONTAINER_PREFIX':"
        echo "$images" | nl
    fi
    containers=$(list_containers)
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
    read -p "$(log_prompt "Enter your choice(S, E, C, N, P, D, I, X ...): ")" user_choice
    case $user_choice in
        S)
            read -p "$(log_prompt "Choose a container to start and attach (1, 2, 3, ...): ")" container_choice
            if [ -z "$container_choice" ]; then
                log_error "Invalid choice."
                continue
            fi
            container_name=$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')
            if [ -n "$container_name" ]; then
                if [[ $(docker inspect -f '{{.State.Running}}' $container_name) == "true" ]]; then
                    attach_container $container_name
                else
                    start_and_attach_container $container_name
                fi
                exit 0
            else
                log_error "Invalid choice."
            fi
            ;;
        C)
            images=$(list_images)
            if [ -z "$images" ]; then
                log_error "No images available. Please create an image first using the 'N' option."
            else
                create_container
                exit 0
            fi
            ;;
        N)
            create_image
            ;;
        I)
            log_prompt "Available images in '$CONTAINER_PREFIX':"
            list_images | nl
            read -p "$(log_prompt "Enter the number of the image to delete: ")" image_choice
            if [ -z "$image_choice" ]; then
                log_error "Invalid choice."
                continue
            fi
            image_name=$(list_images | sed -n "${image_choice}p" | awk '{print $1}')
            if [ -n "$image_name" ]; then
                delete_image $image_name
            else
                log_error "Invalid choice."
            fi
            ;;
        D)
            containers=$(list_containers)
            log_prompt "Available containers:"
            echo "$containers" | nl

            read -p "$(log_prompt "Choose a container to delete (1, 2, 3, ...): ")" container_choice
            if [ -z "$container_choice" ]; then
                log_error "Invalid choice."
                continue
            fi
            container_name=$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')
            if [ -n "$container_name" ]; then
                if [[ $(docker inspect -f '{{.State.Running}}' $container_name) == "true" ]]; then
                    log_error "Container is running. Please stop it first."
                    read -p "$(log_error "Do you want to stop the container? (yes/no): ")" stop_d
                    if [ "$stop_d" == "yes" ]; then
                        stop_container $container_name
                    fi
                fi

                delete_container $container_name
            else
                log_error "Invalid choice."
            fi
            ;;
        P)
            read -p "$(log_prompt "Choose a container to stop (1, 2, 3, ...): ")" container_choice
            if [ -z "$container_choice" ]; then
                log_error "Invalid choice."
                continue
            fi
            container_name=$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')
            if [ -n "$container_name" ]; then
                if [[ $(docker inspect -f '{{.State.Running}}' $container_name) == "true" ]]; then
                    stop_container $container_name
                else
                    log_error "Container is not running."
                fi
            else
                log_error "Invalid choice."
            fi
            ;;
        E)
            read -p "$(log_prompt "Choose a container to open a new interactive session (1, 2, 3, ...): ")" container_choice
            if [ -z "$container_choice" ]; then
                log_error "Invalid choice."
                continue
            fi
            container_name=$(echo "$containers" | sed -n "${container_choice}p" | awk '{print $1}')
            if [ -n "$container_name" ]; then
                if [[ $(docker inspect -f '{{.State.Running}}' $container_name) == "true" ]]; then
                    exec_container $container_name
                    exit 0
                else
                    log_error "Container is not running."
                fi
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