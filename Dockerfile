# Use Ubuntu 22.04 as the base image
FROM ubuntu:22.04

# Install locales package and generate the en_US.UTF-8 locale
RUN apt-get update && apt-get install -y \
    locales \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install dependencies
RUN apt-get update && apt-get install -y \
    file \
    lz4 \
    zstd \
    gawk \
    wget \
    git \
    diffstat \
    unzip \
    texinfo \
    gcc-multilib \
    build-essential \
    chrpath \
    socat \
    cpio \
    python3 \
    python3-pip \
    python3-pexpect \
    python3-venv \
    xz-utils \
    debianutils \
    iputils-ping \
    libsdl1.2-dev \
    xterm \
    libyaml-dev \
    libssl-dev \
    sudo \
    curl \
    vim \
    screen \
    net-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install the repo tool
RUN mkdir -p /usr/local/bin && \
    curl https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && \
    chmod a+x /usr/local/bin/repo

# Create user and give sudo privileges
RUN useradd -ms /bin/bash yoctouser && \
    echo "yoctouser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set the working directory
WORKDIR /home/yoctouser

# Change ownership of the Yocto directory to yoctouser
RUN chown -R yoctouser:yoctouser /home/yoctouser

# Create directories and set ownership
RUN mkdir -p /home/yoctouser/build_xwayland/tmp \
    /home/yoctouser/downloads \
    /home/yoctouser/build_xwayland/sstate-cache && \
    chown -R yoctouser:yoctouser /home/yoctouser/build_xwayland \
    /home/yoctouser/downloads

# Install Python dependencies for Bitbake
RUN python3 -m venv /opt/yocto-env && \
    . /opt/yocto-env/bin/activate && \
    pip install --upgrade pip setuptools

# Switch to the user
USER yoctouser

# Set the default command to bash
CMD ["/bin/bash"]