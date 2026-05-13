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
YOCTO_REPO_DIR="$HOME/yocto_workspace/gateway_repo"
GIT_META_gateway_BRANCH="main"
GIT_META_gateway_REMOTE="dse-gateway"

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Function to setup Docker
docker_setup() {
    if ! command -v docker &> /dev/null; then
        log_yellow "Installing Docker..."
        sudo apt update || exit 1
        sudo apt install -y docker.io ca-certificates || exit 1
        sudo systemctl start docker || exit 1
        sudo systemctl enable docker || exit 1
        sudo systemctl restart docker || exit 1
        sudo usermod -aG docker $USER || exit 1
        log_info "Docker installed successfully. You may need to log out and back in for group changes to take effect."
    else
        log_info "Docker is already installed."
        # Ensure ca-certificates are installed and Docker is restarted
        sudo apt install -y ca-certificates || exit 1
        sudo systemctl restart docker || exit 1
    fi
}

# Setup Docker if not installed
docker_setup

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
        log_yellow "Creating docker image '$IMAGE_NAME'..."
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
        # Create the bin directory in the home directory if it doesn't exist
        mkdir -p ~/bin

        # Download the latest repo script
        curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo || exit 1

        # Make the repo script executable
        chmod a+x ~/bin/repo || exit 1

        # Add ~/bin to the PATH environment variable if it's not already there
        if ! echo $PATH | grep -q "$HOME/bin"; then
            echo 'export PATH=~/bin:$PATH' >> ~/.bashrc
            export PATH=~/bin:$PATH  # Ensure the current session is updated
            source ~/.bashrc || exit 1
        else
            # Ensure ~/bin is at the beginning of the PATH
            sed -i 's|PATH=\(.*\)|PATH=~/bin:\1|' ~/.bashrc || exit 1
            export PATH=~/bin:$PATH  # Ensure the current session is updated
            source ~/.bashrc || exit 1
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

# Function to check if required files are present
check_required_files() {
    local missing_files=0

    if [ ! -d ~/.ssh ]; then
        log_error "Error: ~/.ssh directory is missing."
        missing_files=1
    fi

    if [ $missing_files -eq 1 ]; then
        log_error "One or more required files are missing. Exiting."
        exit 1
    fi
}

# Function to create a new container
create_container() {
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

        # Check if the gateway repository exists
        if [ ! -d "$YOCTO_REPO_DIR" ]; then
            # setup your system repo tool
            repo_setup

            mkdir -p "$HOME/yocto_workspace" || exit 1
            cd "$HOME/yocto_workspace" || exit 1

            mkdir "$YOCTO_REPO_DIR" || exit 1
            cd "$YOCTO_REPO_DIR" || exit 1
            repo init -u git@github.com:skottakkadan-gnrc/898-manifest.git -b main -m default.xml || exit 1
            repo sync || exit 1

            cd "$YOCTO_REPO_DIR/sources/meta-gateway" || exit 1
            cp "$YOCTO_REPO_DIR/sources/meta-gateway/setup-environment" "$YOCTO_REPO_DIR/setup-environment" || exit 1
            git checkout HEM-311_newHardware || exit 1
	    # git checkout main
            #cp "$YOCTO_REPO_DIR/sources/meta-gateway/gateway-setup-platform.sh" "$YOCTO_REPO_DIR/gateway-setup-platform.sh"
            chmod +x "$YOCTO_REPO_DIR/setup-environment" || exit 1

            if [ ! -d "$HOME/yocto_workspace/downloads" ]; then
                mkdir "$HOME/yocto_workspace/downloads" || exit 1
            fi

            if [ ! -d "$HOME/yocto_workspace/sstate-cache" ]; then
                mkdir "$HOME/yocto_workspace/sstate-cache" || exit 1
            fi

            log_info "default.xml Repository cloned and checked out successfully."
            # Return to the initial directory
            cd "$initial_dir"
        else
            update_meta_gateway
        fi

        # Increase inotify limit. Required for Yocto builds,
        # Reason: Observed 'ERROR: No space left on device or exceeds fs.inotify.max_user_watches?' during yocto bitbaking
        if [ "$(sysctl -n fs.inotify.max_user_watches)" -ne 524288 ]; then
            echo "Setting inotify limit to 524288"
            sudo sysctl -w fs.inotify.max_user_watches=524288 || exit 1
            sudo sysctl -p || exit 1
        fi

        if [ ! -d "$HOME/yocto_workspace/${container_name}_build/tmp" ]; then
            mkdir -p "$HOME/yocto_workspace/${container_name}_build/tmp" || exit 1
        fi

        cp -r ~/.ssh $HOME/yocto_workspace/ssh || exit 1

        log_yellow "Creating docker container '$container_name'..."
        
        cp "$YOCTO_REPO_DIR/sources/meta-gateway/setup-environment" "$YOCTO_REPO_DIR/setup-environment" || exit 1

        docker run -it --name $container_name \
            -v "$HOME/yocto_workspace/ssh:${YOCTO_USER_HOME}/.ssh" \
            -v "$YOCTO_REPO_DIR/setup-environment:${YOCTO_USER_HOME}/setup-environment" \
            -v "$YOCTO_REPO_DIR/sources:${YOCTO_USER_HOME}/sources" \
            -v "$HOME/yocto_workspace/downloads:${YOCTO_USER_HOME}/downloads" \
            -v "$YOCTO_REPO_DIR/.repo:${YOCTO_USER_HOME}/.repo" \
            -v "$HOME/yocto_workspace/${container_name}_build/tmp:${YOCTO_USER_HOME}/build_xwayland/tmp" \
            -v "$HOME/yocto_workspace/sstate-cache:${YOCTO_USER_HOME}/build_xwayland/sstate-cache" \
            -v "$HOME/.gitconfig:${YOCTO_USER_HOME}/.gitconfig" \
            $image_name
        if [ $? -eq 0 ]; then
            log_info "Container '$container_name' created and started successfully."
        else
            log_error "Failed to create and start the container."
        fi
    else
        log_error "Invalid choice."
    fi
}

update_meta_gateway() {
    local current_dir=$(pwd)
    cd "$YOCTO_REPO_DIR/sources/meta-gateway" || exit 1

    # Check for uncommitted changes
    if [ -n "$(git status --porcelain)" ]; then
        log_error "Uncommitted local changes detected in the '$YOCTO_REPO_DIR/sources/meta-gateway' repository."
        read -p "$(log_prompt "Do you want to proceed without pulling the latest changes from meta-gateway repo? (yes/no): ")" proceed_without_pull
        if [[ "$proceed_without_pull" != "yes" ]]; then
            log_error "Please commit and push your changes before proceeding."
            exit 1
        else
            log_yellow "Proceeding without pulling the latest changes."
        fi
    else
        log_yellow "Pulling the latest changes from the meta-gateway repo..."
        git pull $GIT_META_gateway_REMOTE $GIT_META_gateway_BRANCH || exit 1
    fi

    cd "$current_dir" || exit 1
}

# Function to start and attach to a container
start_and_attach_container() {
    local container_name=$1

    update_meta_gateway

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

    update_meta_gateway

    docker exec -it $container_name /bin/bash
}

# Function to open a new interactive session to a running container
exec_container() {
    local container_name=$1

    update_meta_gateway

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
        rm -rf $HOME/yocto_workspace/${container_name}_build  # Remove the specific build directory
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
        log_yellow "Creating image '$IMAGE_NAME'..."
        docker build -t $IMAGE_NAME "${SCRIPT_DIR}" || exit 1
        log_info "Image '$IMAGE_NAME' created successfully."
    fi

    check_required_files
    

    local container_name="${CONTAINER_PREFIX}_c_$(date +%Y%m%d%H%M%S)"
    if [ $(docker ps -a --filter "name=$container_name" --format "{{.Names}}") ]; then
        log_yellow "Container $container_name already exists. Removing it."
        docker rm $container_name
    fi

    if [ ! -d "$YOCTO_REPO_DIR" ]; then
        repo_setup
        mkdir -p "$HOME/yocto_workspace" || exit 1
        cd "$HOME/yocto_workspace" || exit 1
        mkdir "$YOCTO_REPO_DIR" || exit 1
        cd "$YOCTO_REPO_DIR" || exit 1
        repo init -u git@github.com:skottakkadan-gnrc/898-manifest.git -b main -m default.xml || exit 1
        repo sync || exit 1
        cd "$YOCTO_REPO_DIR/sources/meta-gateway" || exit 1
        cp "$YOCTO_REPO_DIR/sources/meta-gateway/setup-environment" "$YOCTO_REPO_DIR/setup-environment" || exit 1
        #git checkout main || exit 1
        git checkout HEM-311_newHardware || exit 1
        chmod +x "$YOCTO_REPO_DIR/setup-environment" || exit 1

        if [ ! -d "$HOME/yocto_workspace/downloads" ]; then
            mkdir "$HOME/yocto_workspace/downloads" || exit 1
        fi

        if [ ! -d "$HOME/yocto_workspace/sstate-cache" ]; then
            mkdir "$HOME/yocto_workspace/sstate-cache" || exit 1
        fi

        log_info "default.xml Repository cloned and checked out successfully."
        cd "$initial_dir"
    else
        update_meta_gateway
    fi

    # Increase inotify limit. Required for Yocto builds, observed 
    # Reason: Observed 'ERROR: No space left on device or exceeds fs.inotify.max_user_watches?' during yocto bitbaking
    if [ "$(sysctl -n fs.inotify.max_user_watches)" -ne 524288 ]; then
        echo "Setting inotify limit to 524288"
        sudo sysctl -w fs.inotify.max_user_watches=524288 || exit 1
        sudo sysctl -p || exit 1
    fi

    if [ ! -d "$HOME/yocto_workspace/${container_name}_build/tmp" ]; then
        mkdir -p "$HOME/yocto_workspace/${container_name}_build/tmp" || exit 1
    fi

    cp -r ~/.ssh $HOME/yocto_workspace/ssh || exit 1

    log_yellow "Creating docker container '$container_name'..."
        
    cp "$YOCTO_REPO_DIR/sources/meta-gateway/setup-environment" "$YOCTO_REPO_DIR/setup-environment" || exit 1

    docker run -it --name $container_name \
        -v "$HOME/yocto_workspace/ssh:${YOCTO_USER_HOME}/.ssh" \
        -v "$YOCTO_REPO_DIR/setup-environment:${YOCTO_USER_HOME}/setup-environment" \
        -v "$YOCTO_REPO_DIR/sources:${YOCTO_USER_HOME}/sources" \
        -v "$HOME/yocto_workspace/downloads:${YOCTO_USER_HOME}/downloads" \
        -v "$YOCTO_REPO_DIR/.repo:${YOCTO_USER_HOME}/.repo" \
        -v "$HOME/yocto_workspace/${container_name}_build/tmp:${YOCTO_USER_HOME}/build_xwayland/tmp" \
        -v "$HOME/yocto_workspace/sstate-cache:${YOCTO_USER_HOME}/build_xwayland/sstate-cache" \
        -v "$HOME/.gitconfig:${YOCTO_USER_HOME}/.gitconfig" \
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
            rm -rf $HOME/yocto_workspace/${container}_buildTmp  # Remove the specific build directory
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