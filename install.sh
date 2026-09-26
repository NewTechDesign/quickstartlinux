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

# Flags
INSTALL_FIRMWARE=false
TUNE_GRUB=false

# Helper: check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Helper: ensure root privileges (auto-escalate via pkexec or sudo)
ensure_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi

    echo -e "${YELLOW}Root privileges required. Re-launching...${NC}"

    local script_path
    script_path="$(readlink -f "$0")"

    # Try pkexec (graphical prompt) first
    if command_exists pkexec; then
        exec pkexec sh "$script_path" "$@"
    fi

    # Fallback to sudo (terminal prompt)
    if command_exists sudo; then
        exec sudo sh "$script_path" "$@"
    fi

    echo -e "${RED}Error: neither pkexec nor sudo found. Please run as root.${NC}"
    exit 1
}

# Helper: ask a yes/no question
# Usage: ask_question "Question text?" "default (Y or N)"
ask_question() {
    local prompt="$1"
    local default="$2"
    local answer

    # If default mode is active, return the default answer
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        if [[ "$default" == "Y" ]]; then
            echo -e "${YELLOW}${prompt} [Y/n]: ${GREEN}Y (default)${NC}"
            return 0
        else
            echo -e "${YELLOW}${prompt} [y/N]: ${GREEN}N (default)${NC}"
            return 1
        fi
    fi

    if [[ "$default" == "Y" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" answer
        answer="${answer:-Y}"
    else
        read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer
        answer="${answer:-N}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

# Helper: check if package is installed (pacman)
is_installed() {
    pacman -Qi "$1" &>/dev/null
}

# Helper: detect the active graphical user (name, UID, home)
# Sets: ACTIVE_USER, ACTIVE_UID, ACTIVE_HOME
detect_active_user() {
    ACTIVE_USER=""
    ACTIVE_UID=""
    ACTIVE_HOME=""

    # Try loginctl first
    if command_exists loginctl; then
        local session_id
        session_id=$(loginctl list-sessions --no-legend 2>/dev/null \
            | awk '$3 == "seat0" || $4 == "seat0" {print $1; exit}')

        if [[ -z "$session_id" ]]; then
            session_id=$(loginctl list-sessions --no-legend 2>/dev/null \
                | awk '{print $1}' | head -n1)
        fi

        if [[ -n "$session_id" ]]; then
            ACTIVE_UID=$(loginctl show-session "$session_id" -p UID --value 2>/dev/null || echo "")
            if [[ -n "$ACTIVE_UID" ]]; then
                ACTIVE_USER=$(id -nu "$ACTIVE_UID" 2>/dev/null || echo "")
            fi
        fi
    fi

    # Fallback: who
    if [[ -z "$ACTIVE_USER" ]]; then
        ACTIVE_USER=$(who | awk '{print $1}' | head -n1)
        if [[ -n "$ACTIVE_USER" ]]; then
            ACTIVE_UID=$(id -u "$ACTIVE_USER" 2>/dev/null || echo "")
        fi
    fi

    # Resolve home directory
    if [[ -n "$ACTIVE_USER" ]]; then
        ACTIVE_HOME=$(getent passwd "$ACTIVE_USER" | cut -d: -f6)
        if [[ -z "$ACTIVE_HOME" ]]; then
            ACTIVE_HOME="/home/${ACTIVE_USER}"
        fi
    fi
}

# Helper: detect the bootloader in use
# Echoes one of: grub, systemd-boot, unknown
detect_bootloader() {
    # GRUB: /etc/default/grub exists and/or grub.cfg present under /boot
    if [[ -f /etc/default/grub ]]; then
        echo "grub"
        return 0
    fi
    if find /boot -maxdepth 3 -name grub.cfg -print -quit 2>/dev/null | grep -q .; then
        echo "grub"
        return 0
    fi

    # systemd-boot: /boot/loader/loader.conf exists
    if [[ -f /boot/loader/loader.conf ]]; then
        echo "systemd-boot"
        return 0
    fi

    # Fallback: check EFI entries
    if command_exists bootctl; then
        if bootctl status 2>/dev/null | grep -qi 'systemd-boot'; then
            echo "systemd-boot"
            return 0
        fi
    fi

    echo "unknown"
}

# Helper: tune GRUB (remove quiet, set loglevel=3, regenerate config)
tune_grub() {
    local FILE=/etc/default/grub

    if [[ ! -f "$FILE" ]]; then
        echo -e "${YELLOW}GRUB config not found ($FILE), skipping.${NC}"
        return 0
    fi

    local BAK
    BAK="$(mktemp /tmp/grub.bak.XXXXXX)" || {
        echo -e "${RED}Could not create backup in /tmp${NC}" >&2
        return 1
    }

    if ! cp -a "$FILE" "$BAK"; then
        echo -e "${RED}cp failed${NC}" >&2
        rm -f "$BAK"
        return 1
    fi
    echo -e "${GREEN}Backup: $BAK${NC}"

    # --- rollback / cleanup ---
    local DONE=0
    cleanup_grub() {
        if [[ "$DONE" -ne 1 && -f "$BAK" ]]; then
            echo -e "${YELLOW}Rolling back from $BAK${NC}" >&2
            cp -a "$BAK" "$FILE"
        fi
        rm -f "$BAK"
        echo -e "${YELLOW}Backup $BAK removed${NC}" >&2
    }
    trap cleanup_grub INT TERM EXIT

    # --- current value ---
    local current
    current=$(sed -nE 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/p' "$FILE" | head -n1)
    current="${current:-}"

    # --- new value ---
    local new
    new=$(printf '%s\n' "$current" \
        | tr ' ' '\n' \
        | grep -vxE 'quiet|loglevel=[0-9]+' \
        | grep -v '^$' \
        | tr '\n' ' ' || true)
    new="${new}loglevel=3"
    new="${new% }"

    # --- write ---
    sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$FILE"

    # --- verify ---
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' "$FILE" \
       && grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"$' "$FILE" \
       && grep -q 'loglevel=3' "$FILE" \
       && ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=".*\bquiet\b.*"' "$FILE"; then
        echo -e "${GREEN}GRUB cmdline OK${NC}"
        DONE=1
    else
        echo -e "${RED}Verification failed — restoring from backup${NC}" >&2
    fi

    echo
    echo -e "Before: ${YELLOW}$current${NC}"
    echo -e "After:  ${GREEN}$new${NC}"
    echo "Current line:"
    grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$FILE" || true

    # --- regenerate grub config only on success ---
    if [[ "$DONE" -eq 1 ]]; then
        echo
        echo -e "${GREEN}>>> Regenerating GRUB configuration...${NC}"

        local GRUB_CFG
        GRUB_CFG="$(find /boot -name grub.cfg -print -quit 2>/dev/null || true)"

        if [[ -z "$GRUB_CFG" ]]; then
            echo -e "${RED}Could not find grub.cfg under /boot — skipping grub-mkconfig${NC}" >&2
            return 1
        fi

        if grub-mkconfig -o "$GRUB_CFG"; then
            echo -e "${GREEN}GRUB configuration regenerated: $GRUB_CFG${NC}"
        else
            echo -e "${RED}grub-mkconfig failed${NC}" >&2
            return 1
        fi
    else
        echo -e "${RED}Skipping grub-mkconfig due to failed verification${NC}" >&2
        return 1
    fi

    # success — disable rollback
    DONE=1
    trap - INT TERM EXIT
    cleanup_grub
    return 0
}

echo -e "${GREEN}=== Arch Linux Setup Script ===${NC}"
echo

# ============================================================
# Ensure root privileges (auto-escalate)
# ============================================================
ensure_root "$@"

# ============================================================
# 0. Use all defaults?
# ============================================================
USE_DEFAULTS=false
if ask_question "Use all default settings?" "Y"; then
    USE_DEFAULTS=true
    echo -e "${GREEN}Using default settings.${NC}"
fi
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

    # Detect the active user once and reuse it
    detect_active_user

    if [[ -n "$ACTIVE_UID" ]]; then
        POST_COMMANDS+=("export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${ACTIVE_UID}/bus && su ${ACTIVE_UID} -c \"gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' && gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' && gsettings set org.gnome.shell disable-extension-version-validation true\"")
    else
        echo -e "${RED}Warning: Could not determine active user. Skipping gsettings.${NC}"
    fi
fi

# ============================================================
# 2b. Restore GNOME settings?
# ============================================================
if [[ "$INSTALL_GNOME" == "true" || "$USE_GNOME" == "true" ]]; then
    if ask_question "Restore GNOME settings from quickstartlinux?" "Y"; then

        # Reuse the detected user, or detect if not set yet
        if [[ -z "$ACTIVE_USER" || -z "$ACTIVE_UID" ]]; then
            detect_active_user
        fi

        if [[ -z "$ACTIVE_USER" || -z "$ACTIVE_UID" || -z "$ACTIVE_HOME" ]]; then
            echo -e "${RED}Warning: Could not determine active user. Skipping GNOME restore.${NC}"
        else
            echo -e "${GREEN}Restoring GNOME settings for user: ${ACTIVE_USER} (UID ${ACTIVE_UID})${NC}"

            # 1. Clone repo
            POST_COMMANDS+=("rm -rf /tmp/quickstartlinux && git clone https://github.com/NewTechDesign/quickstartlinux /tmp/quickstartlinux")

            # 2. Apply dconf settings as the active user (with DBus session)
            POST_COMMANDS+=("su - ${ACTIVE_USER} -c 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${ACTIVE_UID}/bus dconf load / < /tmp/quickstartlinux/gnome/restore/dconf-settings.ini'")

            # 3. Copy gtk-3.0 into user's ~/.config
            POST_COMMANDS+=("mkdir -p ${ACTIVE_HOME}/.config && cp -a /tmp/quickstartlinux/gnome/restore/.config/gtk-3.0 ${ACTIVE_HOME}/.config/ && chown -R ${ACTIVE_USER}:${ACTIVE_USER} ${ACTIVE_HOME}/.config/gtk-3.0")

            # 3b. Replace USER placeholder in gtk-3.0/bookmarks with the actual username
            POST_COMMANDS+=("if [[ -f ${ACTIVE_HOME}/.config/gtk-3.0/bookmarks ]]; then sed -i 's/USER/${ACTIVE_USER}/g' ${ACTIVE_HOME}/.config/gtk-3.0/bookmarks; fi")

            # 4. Copy .local into user's home
            POST_COMMANDS+=("cp -a /tmp/quickstartlinux/gnome/restore/.local ${ACTIVE_HOME}/ && chown -R ${ACTIVE_USER}:${ACTIVE_USER} ${ACTIVE_HOME}/.local")

            # NOTE: Cleanup is intentionally moved to section 2d, so that
            # the sudoers restore (2c) can reuse the same cloned repo.
        fi
    fi
fi

# ============================================================
# 2c. Restore sudoers settings?
# ============================================================
RESTORE_SUDOERS=false
if ask_question "Restore sudoers settings from quickstartlinux?" "Y"; then
    RESTORE_SUDOERS=true

    # Reuse the detected user, or detect if not set yet
    if [[ -z "$ACTIVE_USER" || -z "$ACTIVE_UID" ]]; then
        detect_active_user
    fi

    if [[ -z "$ACTIVE_USER" ]]; then
        echo -e "${RED}Warning: Could not determine active user. Skipping sudoers restore.${NC}"
    else
        # 1. Clone repo (if not already cloned by section 2b)
        POST_COMMANDS+=("if [[ ! -d /tmp/quickstartlinux ]]; then git clone https://github.com/NewTechDesign/quickstartlinux /tmp/quickstartlinux; fi")

        # 2. Replace USER placeholder with the actual username in the repo's sudoers file
        POST_COMMANDS+=("if [[ -f /tmp/quickstartlinux/gnome/restore/etc/sudoers ]]; then sed -i 's/USER/${ACTIVE_USER}/g' /tmp/quickstartlinux/gnome/restore/etc/sudoers; fi")

        # 3. Append sudoers content from the repo to /etc/sudoers,
        #    but only if it is not already present (avoid duplicates).
        POST_COMMANDS+=("if [[ -f /tmp/quickstartlinux/gnome/restore/etc/sudoers ]]; then if ! grep -qFf /tmp/quickstartlinux/gnome/restore/etc/sudoers /etc/sudoers; then printf '\n' >> /etc/sudoers && cat /tmp/quickstartlinux/gnome/restore/etc/sudoers >> /etc/sudoers; echo 'sudoers: added'; else echo 'sudoers: already present, skipping'; fi; fi")

        # 4. Validate sudoers syntax
        POST_COMMANDS+=("visudo -cf /etc/sudoers")
    fi
fi

# ============================================================
# 2d. Cleanup quickstartlinux (once, if anything used it)
# ============================================================
if [[ "$INSTALL_GNOME" == "true" || "$USE_GNOME" == "true" || "$RESTORE_SUDOERS" == "true" ]]; then
    POST_COMMANDS+=("rm -rf /tmp/quickstartlinux")
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
# 6. Speed up boot? (auto-detect bootloader: GRUB or systemd-boot)
# ============================================================
BOOTLOADER="$(detect_bootloader)"
echo -e "${GREEN}Detected bootloader: ${YELLOW}${BOOTLOADER}${NC}"
echo

case "$BOOTLOADER" in
    systemd-boot)
        if ask_question "Speed up boot (set systemd-boot timeout to 1s)?" "Y"; then
            POST_COMMANDS+=("sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf")
        fi
        ;;
    grub)
        if ask_question "Tune GRUB (remove 'quiet', set loglevel=3)?" "Y"; then
            TUNE_GRUB=true
        fi
        ;;
esac

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
    # POST_COMMANDS+=("systemctl enable --now docker")
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
#    Only ask the question here; detection happens later.
# ============================================================
if ask_question "Install firmware for your CPU/GPU?" "Y"; then
    INSTALL_FIRMWARE=true
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
            echo -e "${GREEN}Selected VirtualBox.${NC}"
            PACMAN_PACKAGES+=(virtualbox virtualbox-host-modules-arch)
            POST_COMMANDS+=("groupadd -f vboxusers")
            POST_COMMANDS+=("modprobe vboxdrv")
            ;;
        2)
            echo -e "${GREEN}Selected GNOME Boxes.${NC}"
            PACMAN_PACKAGES+=(gnome-boxes)
            ;;
        *)
            echo -e "${RED}Invalid choice. Skipping VM installation.${NC}"
            ;;
    esac
fi

# ============================================================
# 11. DETECT CPU & GPU (after all questions)
# ============================================================
if [[ "$INSTALL_FIRMWARE" == "true" ]]; then
    echo
    echo -e "${GREEN}>>> Detecting CPU and GPU...${NC}"

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
echo -e "${YELLOW}Bootloader detected:${NC} ${BOOTLOADER}"
if [[ "$TUNE_GRUB" == "true" ]]; then
    echo -e "${YELLOW}GRUB tuning:${NC} enabled (will run grub-mkconfig after install)"
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
# TUNE GRUB (after packages are installed)
# ============================================================
if [[ "$TUNE_GRUB" == "true" ]]; then
    echo
    echo -e "${GREEN}>>> Tuning GRUB...${NC}"
    tune_grub || echo -e "${RED}Warning: GRUB tuning failed.${NC}"
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

# ============================================================
# INSTALL FLATPAK PACKAGES
# ============================================================
if [[ ${#FLATPAK_PACKAGES[@]} -gt 0 ]]; then
    echo
    echo -e "${GREEN}>>> Installing Flatpak packages...${NC}"
    flatpak install --system -y flathub "${FLATPAK_PACKAGES[@]}"
fi

echo
echo -e "${GREEN}=== Done! ===${NC}"
