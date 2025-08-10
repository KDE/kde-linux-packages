# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

FROM archlinux:latest

# Set environment variables
ARG PROJECT_DIR
ARG PARALLELL_DOWNLOADS=50
ARG BUILD_DATE

# Copy the .env file if needed
# COPY .env $PROJECT_DIR/.env

# Enable parallel downloads for more speed
RUN sed -i "s/ParallelDownloads = 5/ParallelDownloads = $PARALLELL_DOWNLOADS/" /etc/pacman.conf && \
    sed -i 's/NoProgressBar//' /etc/pacman.conf

RUN echo "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist

# Initialize pacman and install packages
RUN pacman-key --init && \
    pacman-key --populate && \
    pacman --sync --refresh --noconfirm \
        sudo base-devel git ninja rsync openssh \
        python-yaml python-setproctitle python-requests python-srcinfo

# Create builder user
RUN useradd -m -s /bin/bash builder && \
    echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder

# Clone the KDE Builder repository and pin to a specific commit
# because there are some issues with the latest version
RUN git clone https://invent.kde.org/sdk/kde-builder.git /kde-builder && \
    ln -s /kde-builder/kde-builder /usr/local/bin

# Set up project directory
RUN mkdir -p $PROJECT_DIR && \
    chown -R builder:builder $PROJECT_DIR

ENV PROJECT_DIR=$PROJECT_DIR

# Switch to builder user and run make-packages.sh
USER builder
WORKDIR $PROJECT_DIR

# Use our custom config file for it
COPY kde-builder.yaml $HOME/.config/kde-builder.yaml

RUN curl https://aur.archlinux.org/cgit/aur.git/snapshot/paru-bin.tar.gz | tar xz && \
    cd paru-bin && \
    makepkg --noconfirm --syncdeps --install

RUN paru -S --noconfirm --needed --skipreview aurutils

COPY make-packages.sh .
CMD ["./make-packages.sh"]
