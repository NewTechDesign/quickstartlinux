#!/usr/bin/env bash

# Exit on error
set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Arrays for package installation
PACMAN_PACKAGES=()
FLATPAK_PACKAGES=()
POST_COMMANDS=()

# Helper: ask a yes/no question
# Usage: ask_question "Question text?" "default (Y or N)"
ask_question() {
    local prompt="$1"
    local default="$2"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" answer
        answer="${answer:-Y}"
    else
        read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer
        answer="${answer:-N}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

# Helper: check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Helper: check if package is installed (pacman)
is_installed() {
    pacman -Qi "$1" &>/dev/null
}

echo -e "${GREEN}=== Arch Linux Setup Script ===${NC}"
echo

# ============================================================
# 1. Install GNOME?
# ============================================================
INSTALL_GNOME=false
if ask_question "Install GNOME?" "N"; then
    INSTALL_GNOME=true
    PACMAN_PACKAGES+=(gdm gnome)
    POST_COMMANDS+=("systemctl enable --now gdm")
fi

# ============================================================
# 2. Are you using GNOME?
# ============================================================
USE_GNOME=false
if ask_question "Are you using GNOME?" "Y"; then
    USE_GNOME=true
    PACMAN_PACKAGES+=(adw-gtk-theme gnome-tweaks gnome-sound-recorder)

    # Determine the active user in the graphical session
    ACTIVE_USER=""
    ACTIVE_UID=""

    # Try loginctl first
    if command_exists loginctl; then
        ACTIVE_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 == "seat0" || $4 == "seat0" {print $3; exit}')
        # Fallback: get the user of the active session
        if [[ -z "$ACTIVE_USER" ]]; then
            ACTIVE_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | head -n1)
        fi
    fi

    # Fallback: who is logged in
    if [[ -z "$ACTIVE_USER" ]]; then
        ACTIVE_USER=$(who | awk '{print $1}' | head -n1)
    fi

    if [[ -n "$ACTIVE_USER" ]]; then
        ACTIVE_UID=$(id -u "$ACTIVE_USER" 2>/dev/null || echo "")

        if [[ -n "$ACTIVE_UID" ]]; then
            POST_COMMANDS+=("export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${ACTIVE_UID}/bus && su - ${ACTIVE_USER} -c \"gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' && gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' && gsettings set org.gnome.shell disable-extension-version-validation true\"")
        else
            echo -e "${RED}Warning: Could not determine UID for user '${ACTIVE_USER}'. Skipping gsettings.${NC}"
        fi
    else
        echo -e "${RED}Warning: Could not determine active user. Skipping gsettings.${NC}"
    fi
fi

# ============================================================
# 3. Install emoji & language fonts?
# ============================================================
if ask_question "Install emoji and language fonts?" "Y"; then
    PACMAN_PACKAGES+=(ttf-dejavu ttf-liberation ttf-arphic-ukai ttf-arphic-uming ttf-sazanami noto-fonts noto-fonts-emoji noto-fonts-cjk)
fi

# ============================================================
# 4. Enable Bluetooth?
# ============================================================
if ask_question "Enable Bluetooth?" "Y"; then
    POST_COMMANDS+=("systemctl enable --now bluetooth")
fi

# ============================================================
# 5. Set locale?
# ============================================================
if ask_question "Set locale to ru_RU.UTF-8?" "Y"; then
    POST_COMMANDS+=("localectl set-locale ru_RU.UTF-8")
fi

# ============================================================
# 6. Speed up boot?
# ============================================================
if ask_question "Speed up boot (set bootloader timeout to 1s)?" "Y"; then
    POST_COMMANDS+=("sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf")
fi

# ============================================================
# 7. Install dev & utility tools?
# ============================================================
if ask_question "Install all development and utility tools?" "Y"; then
    PACMAN_PACKAGES+=(
        # Base tools
        pacman-contrib

        # Filesystems
        btrfs-progs xfsprogs f2fs-tools exfatprogs udftools ntfs-3g ntfsprogs
        dosfstools e2fsprogs cryptsetup

        # Forensics / embedded
        binwalk squashfs-tools mtd-utils uboot-tools udisks2 usbutils

        # GVFS / FUSE
        gvfs fuse2 fuse3

        # Crypto / SSL
        openssl nss

        # Android
        android-tools scrcpy

        # Misc
        jhead pixman

        # Java / Xorg
        jdk8-openjdk jre8-openjdk jre8-openjdk-headless jdk-openjdk xorg-xrandr

        # Build tools
        git base-devel devtools fakeroot meson ninja pkgconfig glib2 libusb
        systemd-libs gdk-pixbuf2 cairo gcc

        # Containers
        docker docker-compose
    )

    # Enable docker
    POST_COMMANDS+=("systemctl enable --now docker")
fi

# ============================================================
# 8. Install useful apps (Flatpak)?
# ============================================================
INSTALL_FLATPAK=false
if ask_question "Install useful applications via Flatpak?" "Y"; then
    INSTALL_FLATPAK=true

    # Ensure flatpak is available
    if ! command_exists flatpak; then
        PACMAN_PACKAGES+=(flatpak)
    fi

    # Add flathub remote
    POST_COMMANDS+=("flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo")

    FLATPAK_PACKAGES+=(
        com.mattjakeman.ExtensionManager
        org.polymc.PolyMC
        org.chromium.Chromium
        us.zoom.Zoom
    )
fi

# ============================================================
# 9. Install firmware (auto-detect CPU & GPU)?
# ============================================================
if ask_question "Install firmware for your CPU/GPU?" "Y"; then
    # Base audio/video/bluetooth firmware
    PACMAN_PACKAGES+=(
        pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils
        sof-firmware alsa-ucm-conf v4l-utils bluez bluez-utils pciutils
    )

    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    GPU_INFO=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)

    # Intel CPU
    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        echo -e "${GREEN}Intel CPU detected. Adding Intel packages...${NC}"
        PACMAN_PACKAGES+=(
            mesa mesa-utils libva-intel-driver intel-media-driver
            vulkan-intel
        )
    fi

    # AMD CPU
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        echo -e "${GREEN}AMD CPU detected. Adding AMD packages...${NC}"
        PACMAN_PACKAGES+=(
            mesa mesa-utils vulkan-radeon libva-mesa-driver
        )
    fi

    # NVIDIA GPU
    if echo "$GPU_INFO" | grep -qi nvidia; then
        echo -e "${GREEN}NVIDIA GPU detected. Adding NVIDIA packages...${NC}"
        PACMAN_PACKAGES+=(
            nvidia nvidia-utils nvidia-settings
            vulkan-icd-loader libvdpau opencl-nvidia
        )
    fi

    # AMD GPU
    if echo "$GPU_INFO" | grep -qiE 'amd|ati|radeon'; then
        echo -e "${GREEN}AMD GPU detected. Adding AMD GPU packages...${NC}"
        PACMAN_PACKAGES+=(
            mesa mesa-utils vulkan-radeon libva-mesa-driver
        )
    fi
fi

# ============================================================
# 10. Install a virtual machine?
# ============================================================
if ask_question "Do you want to install a virtual machine?" "N"; then
    echo -e "${YELLOW}Choose VM type:${NC}"
    echo "  1) VirtualBox"
    echo "  2) GNOME Boxes"
    read -rp "Enter choice [1/2]: " VM_CHOICE

    case "$VM_CHOICE" in
        1)
            echo -e "${GREEN}Selected GNOME Boxes.${NC}"
            PACMAN_PACKAGES+=(gnome-boxes)
            ;;
        2)
            echo -e "${GREEN}Selected VirtualBox.${NC}"
            PACMAN_PACKAGES+=(virtualbox virtualbox-host-modules-arch)
            POST_COMMANDS+=("groupadd -f vboxusers")
            POST_COMMANDS+=("modprobe vboxdrv")
            ;;
        *)
            echo -e "${RED}Invalid choice. Skipping VM installation.${NC}"
            ;;
    esac
fi

# ============================================================
# SUMMARY
# ============================================================
echo
echo -e "${GREEN}=== Summary ===${NC}"
echo
echo -e "${YELLOW}Pacman packages to install:${NC}"
if [[ ${#PACMAN_PACKAGES[@]} -gt 0 ]]; then
    printf '  %s\n' "${PACMAN_PACKAGES[@]}"
else
    echo "  (none)"
fi

echo
echo -e "${YELLOW}Flatpak packages to install:${NC}"
if [[ ${#FLATPAK_PACKAGES[@]} -gt 0 ]]; then
    printf '  %s\n' "${FLATPAK_PACKAGES[@]}"
else
    echo "  (none)"
fi

echo
echo -e "${YELLOW}Post-install commands:${NC}"
if [[ ${#POST_COMMANDS[@]} -gt 0 ]]; then
    printf '  %s\n' "${POST_COMMANDS[@]}"
else
    echo "  (none)"
fi

echo
read -rp "$(echo -e "${YELLOW}Proceed with installation? [Y/n]: ${NC}")" CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 0
fi

# ============================================================
# INSTALL PACMAN PACKAGES
# ============================================================
if [[ ${#PACMAN_PACKAGES[@]} -gt 0 ]]; then
    echo
    echo -e "${GREEN}>>> Installing pacman packages...${NC}"
    # Deduplicate
    UNIQUE_PACMAN=($(printf '%s\n' "${PACMAN_PACKAGES[@]}" | awk '!seen[$0]++'))
    pacman -S --noconfirm --needed "${UNIQUE_PACMAN[@]}"
fi

# ============================================================
# INSTALL FLATPAK PACKAGES
# ============================================================
if [[ ${#FLATPAK_PACKAGES[@]} -gt 0 ]]; then
    echo
    echo -e "${GREEN}>>> Installing Flatpak packages...${NC}"
    flatpak install --system -y flathub "${FLATPAK_PACKAGES[@]}"
fi

# ============================================================
# RUN POST-INSTALL COMMANDS
# ============================================================
if [[ ${#POST_COMMANDS[@]} -gt 0 ]]; then
    echo
    echo -e "${GREEN}>>> Running post-install commands...${NC}"
    for cmd in "${POST_COMMANDS[@]}"; do
        echo -e "${YELLOW}Running: ${cmd}${NC}"
        eval "$cmd" || echo -e "${RED}Warning: command failed: ${cmd}${NC}"
    done
fi

echo
echo -e "${GREEN}=== Done! ===${NC}"
