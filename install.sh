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
FIX_GRUB_MENU=false
CONFIGURE_ZRAM=false

# GRUB theme
GRUB_THEME_DIR="/usr/share/grub/themes"
GRUB_THEME_SRC="/tmp/quickstartlinux/grub/themes"
INSTALL_GRUB_THEME=false
GRUB_THEME_SELECTED=""
GRUB_THEME_TITLE=""
GRUB_THEME_UNINSTALL=false

# quickstartlinux repo
QUICKSTART_REPO="https://github.com/NewTechDesign/quickstartlinux"
QUICKSTART_DIR="/tmp/quickstartlinux"

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

    if command_exists pkexec; then
        exec pkexec sh "$script_path" "$@"
    fi

    if command_exists sudo; then
        exec sudo sh "$script_path" "$@"
    fi

    echo -e "${RED}Error: neither pkexec nor sudo found. Please run as root.${NC}"
    exit 1
}

# Helper: ensure quickstartlinux is cloned (only once)
ensure_quickstartlinux_cloned() {
    if [[ -d "$QUICKSTART_DIR/.git" ]]; then
        return 0
    fi

    echo -e "${YELLOW}Cloning quickstartlinux...${NC}"
    rm -rf "$QUICKSTART_DIR"

    if git clone "$QUICKSTART_REPO" "$QUICKSTART_DIR"; then
        return 0
    fi

    echo -e "${RED}Clone failed: $QUICKSTART_REPO${NC}" >&2
    return 1
}

# Helper: ask a yes/no question
ask_question() {
    local prompt="$1"
    local default="$2"
    local answer

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
detect_active_user() {
    ACTIVE_USER=""
    ACTIVE_UID=""
    ACTIVE_HOME=""

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

    if [[ -z "$ACTIVE_USER" ]]; then
        ACTIVE_USER=$(who | awk '{print $1}' | head -n1)
        if [[ -n "$ACTIVE_USER" ]]; then
            ACTIVE_UID=$(id -u "$ACTIVE_USER" 2>/dev/null || echo "")
        fi
    fi

    if [[ -n "$ACTIVE_USER" ]]; then
        ACTIVE_HOME=$(getent passwd "$ACTIVE_USER" | cut -d: -f6)
        if [[ -z "$ACTIVE_HOME" ]]; then
            ACTIVE_HOME="/home/${ACTIVE_USER}"
        fi
    fi
}

# Helper: detect the bootloader in use
detect_bootloader() {
    if [[ -f /etc/default/grub ]]; then
        echo "grub"
        return 0
    fi
    if find /boot -maxdepth 3 -name grub.cfg -print -quit 2>/dev/null | grep -q .; then
        echo "grub"
        return 0
    fi
    if [[ -f /boot/loader/loader.conf ]]; then
        echo "systemd-boot"
        return 0
    fi
    if command_exists bootctl; then
        if bootctl status 2>/dev/null | grep -qi 'systemd-boot'; then
            echo "systemd-boot"
            return 0
        fi
    fi
    echo "unknown"
}

# Helper: set or update a GRUB variable in /etc/default/grub
set_grub_var() {
    local var="$1"
    local value="$2"
    local file="/etc/default/grub"

    if [[ ! -f "$file" ]]; then
        echo -e "${RED}GRUB config not found: $file${NC}" >&2
        return 1
    fi

    local esc_value
    esc_value=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')

    if grep -qE "^[[:space:]]*#?[[:space:]]*${var}=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${var}=.*|${var}=${esc_value}|" "$file"
        echo -e "${GREEN}Updated: ${var}=${value}${NC}"
    else
        printf '%s=%s\n' "$var" "$value" >> "$file"
        echo -e "${GREEN}Added:   ${var}=${value}${NC}"
    fi
}

# Helper: tune GRUB (/etc/default/grub only, no grub-mkconfig)
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

    local current
    current=$(sed -nE 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/p' "$FILE" | head -n1)
    current="${current:-}"

    local new
    new=$(printf '%s\n' "$current" \
        | tr ' ' '\n' \
        | grep -vxE 'quiet|loglevel=[0-9]+' \
        | grep -v '^$' \
        | tr '\n' ' ' || true)
    new="${new}loglevel=3"
    new="${new% }"

    sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$FILE"

    set_grub_var "GRUB_DISABLE_BOOTNEXT"      "true"
    set_grub_var "GRUB_DISABLE_UEFI_FIRMWARE" "false"
    set_grub_var "GRUB_DISABLE_SUBMENU"       "y"
    set_grub_var "GRUB_DISABLE_OS_PROBER"     "false"
    set_grub_var "GRUB_GFXMODE"               "auto"
    set_grub_var "GRUB_TIMEOUT_STYLE"         "menu"

    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' "$FILE" \
       && grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"$' "$FILE" \
       && grep -q 'loglevel=3' "$FILE" \
       && ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=".*\bquiet\b.*"' "$FILE" \
       && grep -q '^GRUB_DISABLE_BOOTNEXT=true$' "$FILE" \
       && grep -q '^GRUB_DISABLE_UEFI_FIRMWARE=false$' "$FILE" \
       && grep -q '^GRUB_DISABLE_SUBMENU=y$' "$FILE" \
       && grep -q '^GRUB_DISABLE_OS_PROBER=false$' "$FILE" \
       && grep -q '^GRUB_GFXMODE=auto$' "$FILE" \
       && grep -q '^GRUB_TIMEOUT_STYLE=menu$' "$FILE"; then
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

    echo
    echo "Custom GRUB options:"
    grep -E '^(GRUB_DISABLE_BOOTNEXT|GRUB_DISABLE_UEFI_FIRMWARE|GRUB_DISABLE_SUBMENU|GRUB_DISABLE_OS_PROBER|GRUB_GFXMODE|GRUB_TIMEOUT_STYLE)=' "$FILE" || true

    if [[ "$DONE" -ne 1 ]]; then
        echo -e "${RED}GRUB tuning failed — skipping regeneration${NC}" >&2
        return 1
    fi

    DONE=1
    trap - INT TERM EXIT
    cleanup_grub
    return 0
}

# Helper: fix GRUB menu to look like 'Arch Linux' / 'Windows'
fix_grub_menu() {
    local GRUB_D=/etc/grub.d
    local BACKUP=/tmp/grub-backup
    mkdir -p "$BACKUP"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)

    echo -e "${GREEN}==> Step 1. Removing immutable attribute${NC}"
    for f in "$GRUB_D/10_linux" "$GRUB_D/30_os-prober" \
             "$GRUB_D/31_efi_bootnext" "$GRUB_D/30_uefi-firmware"; do
        if [ -e "$f" ]; then
            chattr -i "$f" 2>/dev/null
        fi
    done

    echo -e "${GREEN}==> Step 2. Backing up working scripts${NC}"
    if [ -f "$GRUB_D/10_linux" ]; then
        cp -a "$GRUB_D/10_linux" "$BACKUP/10_linux.$ts"
        echo "    backup: $BACKUP/10_linux.$ts"
    fi
    if [ -f "$GRUB_D/30_os-prober" ]; then
        cp -a "$GRUB_D/30_os-prober" "$BACKUP/30_os-prober.$ts"
        echo "    backup: $BACKUP/30_os-prober.$ts"
    fi

    echo -e "${GREEN}==> Step 3. Patching 10_linux${NC}"
    if [ -f "$GRUB_D/10_linux" ]; then
        if grep -q '^  linux_entry "${OS}" "${version}" advanced' "$GRUB_D/10_linux"; then
            awk '
                BEGIN { skip=0 }
                /^  if \[ "x\$is_top_level" = xtrue \] && \[ "x\$\{GRUB_DISABLE_SUBMENU\}" != xtrue \]; then$/ {
                    skip=1
                    print "  linux_entry \"${OS}\" \"${version}\" simple \\"
                    print "              \"${GRUB_CMDLINE_LINUX} ${GRUB_CMDLINE_LINUX_DEFAULT}\""
                    next
                }
                skip==1 && /^              "\$\{GRUB_CMDLINE_LINUX\} \$\{GRUB_CMDLINE_LINUX_DEFAULT\}"$/ {
                    skip=0
                    next
                }
                skip==1 { next }
                { print }
            ' "$GRUB_D/10_linux" > "$GRUB_D/10_linux.new"

            if grep -q '^  linux_entry "${OS}" "${version}" simple' "$GRUB_D/10_linux.new" \
               && ! grep -q '^  linux_entry "${OS}" "${version}" advanced' "$GRUB_D/10_linux.new"; then
                mv "$GRUB_D/10_linux.new" "$GRUB_D/10_linux"
                chmod +x "$GRUB_D/10_linux"
                echo "    ok: advanced removed, simple kept"
            else
                rm -f "$GRUB_D/10_linux.new"
                echo -e "${YELLOW}    SKIP: could not replace block, file untouched${NC}"
            fi
        else
            echo "    ok: 10_linux already patched, skipping"
        fi
    else
        echo -e "${YELLOW}    SKIP: 10_linux not found${NC}"
    fi

    echo -e "${GREEN}==> Step 4. Patching 30_os-prober${NC}"
    if [ -f "$GRUB_D/30_os-prober" ]; then
        if grep -q 'LONGNAME="Windows"' "$GRUB_D/30_os-prober"; then
            echo "    ok: already patched, skipping"
        else
            local LINE
            LINE=$(grep -n '^  LONGNAME="`echo ${OS} | cut -d' "$GRUB_D/30_os-prober" | head -n1 | cut -d: -f1)
            if [ -z "$LINE" ]; then
                echo -e "${YELLOW}    SKIP: LONGNAME=... line not found, file untouched${NC}"
            else
                echo "    found LONGNAME=... on line $LINE"
                head -n "$LINE" "$GRUB_D/30_os-prober" > "$GRUB_D/30_os-prober.new"
                cat >> "$GRUB_D/30_os-prober.new" <<'EOF'
  case "$LONGNAME" in
    *"Windows Boot Manager"*) LONGNAME="Windows" ;;
  esac
EOF
                tail -n +$((LINE+1)) "$GRUB_D/30_os-prober" >> "$GRUB_D/30_os-prober.new"

                if grep -q 'LONGNAME="Windows"' "$GRUB_D/30_os-prober.new"; then
                    mv "$GRUB_D/30_os-prober.new" "$GRUB_D/30_os-prober"
                    chmod +x "$GRUB_D/30_os-prober"
                    echo "    ok: Windows renamed"
                else
                    rm -f "$GRUB_D/30_os-prober.new"
                    echo -e "${YELLOW}    SKIP: insertion failed, file untouched${NC}"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}    SKIP: 30_os-prober not found${NC}"
    fi

    echo -e "${GREEN}==> Step 5. Syntax check (sh -n)${NC}"
    [ -f "$GRUB_D/10_linux" ]     && sh -n "$GRUB_D/10_linux"     && echo "    10_linux: ok"
    [ -f "$GRUB_D/30_os-prober" ] && sh -n "$GRUB_D/30_os-prober" && echo "    30_os-prober: ok"

    echo -e "${GREEN}==> Step 6. Setting immutable attribute${NC}"
    [ -f "$GRUB_D/10_linux" ]     && chattr +i "$GRUB_D/10_linux"     && echo "    ok: 10_linux protected (chattr +i)"
    [ -f "$GRUB_D/30_os-prober" ] && chattr +i "$GRUB_D/30_os-prober" && echo "    ok: 30_os-prober protected (chattr +i)"

    echo
    echo -e "${GREEN}==> Files patched:${NC}"
    echo "    10_linux, 30_os-prober"
    echo "    Backups in: $BACKUP"
    echo "    (grub.cfg will be regenerated once, later)"
    return 0
}

# Helper: regenerate grub.cfg exactly once
regenerate_grub_cfg() {
    local GRUB_CFG
    GRUB_CFG="$(find /boot -name grub.cfg -print -quit 2>/dev/null || true)"
    if [[ -z "$GRUB_CFG" ]]; then
        GRUB_CFG=/boot/grub/grub.cfg
    fi

    echo
    echo -e "${GREEN}>>> Regenerating GRUB configuration (single run)...${NC}"

    if grub-mkconfig -o "$GRUB_CFG"; then
        echo -e "${GREEN}GRUB configuration regenerated: $GRUB_CFG${NC}"
    else
        echo -e "${RED}grub-mkconfig failed${NC}" >&2
        return 1
    fi

    echo
    echo -e "${GREEN}==> Menu entries:${NC}"
    grep -n '^menuentry\|^submenu' "$GRUB_CFG" || true
    return 0
}

# ------------------------------------------------------------------
# GRUB theme helpers
# ------------------------------------------------------------------

# Helper: list all theme directories under $GRUB_THEME_SRC
list_grub_themes() {
    local src="$1"
    if [[ ! -d "$src" ]]; then
        return 1
    fi
    find "$src" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# Helper: is any theme currently installed?
is_grub_theme_installed() {
    local theme_line
    theme_line=$(grep -E '^GRUB_THEME=' /etc/default/grub 2>/dev/null || true)
    [[ -n "$theme_line" ]]
}

# Helper: get currently installed theme directory (or empty)
get_installed_grub_theme() {
    local theme_path
    theme_path=$(sed -nE 's/^GRUB_THEME="?([^"]+)"?$/\1/p' /etc/default/grub 2>/dev/null | head -n1)
    if [[ -n "$theme_path" && -f "$theme_path" ]]; then
        dirname "$theme_path"
    fi
}

# Helper: install a GRUB theme
install_grub_theme() {
    local src="$1"
    local title="$2"

    if [[ ! -d "$src" ]]; then
        echo -e "${RED}Theme source not found: $src${NC}" >&2
        return 1
    fi

    local theme_name
    theme_name=$(basename "$src")
    local dst="${GRUB_THEME_DIR}/${theme_name}"

    echo -e "${GREEN}>>> Installing GRUB theme: ${theme_name}${NC}"

    mkdir -p "$GRUB_THEME_DIR"

    if [[ -d "$dst" ]]; then
        rm -rf "$dst"
    fi
    mkdir -p "$dst"

    cp -a "$src/." "$dst/"

    local theme_txt
    theme_txt=$(find "$dst" -maxdepth 3 -name theme.txt -print -quit 2>/dev/null)

    if [[ -n "$theme_txt" && -f "$theme_txt" ]]; then
        local new_title="$title"
        if [[ -z "${new_title// /}" ]]; then
            new_title="Bootloader"
        fi

        local esc
        esc=$(printf '%s' "$new_title" | sed -e 's/[\/&]/\\&/g')

        if grep -qE '^[[:space:]]*text=' "$theme_txt"; then
            awk -v new="$esc" '
                BEGIN { done=0 }
                {
                    if (!done && $0 ~ /^[[:space:]]*text=/) {
                        sub(/text=.*/, "text=\"" new "\"")
                        done=1
                    }
                    print
                }
            ' "$theme_txt" > "${theme_txt}.new" && mv "${theme_txt}.new" "$theme_txt"
            echo -e "${GREEN}    theme.txt: title set to '${new_title}'${NC}"
        else
            echo -e "${YELLOW}    theme.txt: no text= line found, skipping title change${NC}"
        fi
    else
        echo -e "${RED}    theme.txt not found in ${dst} — theme may not work${NC}" >&2
    fi

    cp -an /etc/default/grub /etc/default/grub.bak 2>/dev/null || true

    if grep -q '^GRUB_THEME=' /etc/default/grub; then
        sed -i '/^GRUB_THEME=/d' /etc/default/grub
    fi

    if [[ -n "$theme_txt" && -f "$theme_txt" ]]; then
        echo "GRUB_THEME=\"${theme_txt}\"" >> /etc/default/grub
        echo -e "${GREEN}    GRUB_THEME set to ${theme_txt}${NC}"
    else
        echo -e "${RED}    Cannot set GRUB_THEME — theme.txt not found${NC}" >&2
        return 1
    fi

    return 0
}

# Helper: uninstall the current GRUB theme
uninstall_grub_theme() {
    echo -e "${GREEN}>>> Uninstalling GRUB theme...${NC}"

    local installed_dir
    installed_dir=$(get_installed_grub_theme)

    if [[ -n "$installed_dir" && -d "$installed_dir" ]]; then
        rm -rf "$installed_dir"
        echo -e "${GREEN}    removed: ${installed_dir}${NC}"
    else
        echo -e "${YELLOW}    no installed theme directory found, skipping removal${NC}"
    fi

    cp -an /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
    sed -i '/^GRUB_THEME=/d' /etc/default/grub
    echo -e "${GREEN}    GRUB_THEME removed from /etc/default/grub${NC}"
    return 0
}

# ============================================================
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

        if [[ -z "$ACTIVE_USER" || -z "$ACTIVE_UID" ]]; then
            detect_active_user
        fi

        if [[ -z "$ACTIVE_USER" || -z "$ACTIVE_UID" || -z "$ACTIVE_HOME" ]]; then
            echo -e "${RED}Warning: Could not determine active user. Skipping GNOME restore.${NC}"
        else
            echo -e "${GREEN}Restoring GNOME settings for user: ${ACTIVE_USER} (UID ${ACTIVE_UID})${NC}"

            # Ensure the repo is present BEFORE adding post-commands that rely on it
            if ensure_quickstartlinux_cloned; then
                POST_COMMANDS+=("su - ${ACTIVE_USER} -c 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${ACTIVE_UID}/bus dconf load / < ${QUICKSTART_DIR}/gnome/restore/dconf-settings.ini'")
                POST_COMMANDS+=("mkdir -p ${ACTIVE_HOME}/.config && cp -a ${QUICKSTART_DIR}/gnome/restore/.config/gtk-3.0 ${ACTIVE_HOME}/.config/ && chown -R ${ACTIVE_USER}:${ACTIVE_USER} ${ACTIVE_HOME}/.config/gtk-3.0")
                POST_COMMANDS+=("if [[ -f ${ACTIVE_HOME}/.config/gtk-3.0/bookmarks ]]; then sed -i 's/USER/${ACTIVE_USER}/g' ${ACTIVE_HOME}/.config/gtk-3.0/bookmarks; fi")
                POST_COMMANDS+=("cp -a ${QUICKSTART_DIR}/gnome/restore/.local ${ACTIVE_HOME}/ && chown -R ${ACTIVE_USER}:${ACTIVE_USER} ${ACTIVE_HOME}/.local")
            else
                echo -e "${RED}Warning: quickstartlinux clone failed. Skipping GNOME restore.${NC}"
            fi
        fi
    fi
fi

# ============================================================
# 2c. Restore sudoers settings?
# ============================================================
RESTORE_SUDOERS=false
if ask_question "Restore sudoers settings from quickstartlinux?" "Y"; then
    RESTORE_SUDOERS=true

    if [[ -z "$ACTIVE_USER" || -z "$ACTIVE_UID" ]]; then
        detect_active_user
    fi

    if [[ -z "$ACTIVE_USER" ]]; then
        echo -e "${RED}Warning: Could not determine active user. Skipping sudoers restore.${NC}"
    else
        if ensure_quickstartlinux_cloned; then
            if find /etc/sudoers.d -maxdepth 1 -name "${ACTIVE_USER}" -print -quit 2>/dev/null | grep -q .; then
                echo -e "${YELLOW}sudoers: found existing entry for '${ACTIVE_USER}' in /etc/sudoers.d/, skipping${NC}"
            else
                POST_COMMANDS+=("if [[ -f ${QUICKSTART_DIR}/gnome/restore/etc/sudoers ]]; then sed -i 's/USER/${ACTIVE_USER}/g' ${QUICKSTART_DIR}/gnome/restore/etc/sudoers; fi")
                POST_COMMANDS+=("if [[ -f ${QUICKSTART_DIR}/gnome/restore/etc/sudoers ]]; then if ! grep -qFf ${QUICKSTART_DIR}/gnome/restore/etc/sudoers /etc/sudoers; then printf '\n' >> /etc/sudoers && cat ${QUICKSTART_DIR}/gnome/restore/etc/sudoers >> /etc/sudoers; echo 'sudoers: added'; else echo 'sudoers: already present, skipping'; fi; fi")
                POST_COMMANDS+=("visudo -cf /etc/sudoers")
            fi
        else
            echo -e "${RED}Warning: quickstartlinux clone failed. Skipping sudoers restore.${NC}"
        fi
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
    PACMAN_PACKAGES+=(kbd)

    # 1. Uncomment ru_RU.UTF-8 (and en_US.UTF-8 as fallback) in /etc/locale.gen
    POST_COMMANDS+=("if [[ -f /etc/locale.gen ]]; then sed -i -E 's/^#\\s*(ru_RU\\.UTF-8\\s+UTF-8)/\\1/' /etc/locale.gen; sed -i -E 's/^#\\s*(en_US\\.UTF-8\\s+UTF-8)/\\1/' /etc/locale.gen; fi")

    # 2. Generate locales
    POST_COMMANDS+=("locale-gen")

    # 3. Set system locale
    POST_COMMANDS+=("localectl set-locale LANG=ru_RU.UTF-8")

    # 4. (optional) Show result
    POST_COMMANDS+=("localectl status || true")

    # 5. Cyrillic console font for TTY
    POST_COMMANDS+=("if grep -q '^FONT=' /etc/vconsole.conf 2>/dev/null; then sed -i 's|^FONT=.*|FONT=UniCyrExt_8x16|' /etc/vconsole.conf; else echo 'FONT=UniCyrExt_8x16' >> /etc/vconsole.conf; fi")
    POST_COMMANDS+=("setfont UniCyrExt_8x16 2>/dev/null || true")
    POST_COMMANDS+=("systemctl restart systemd-vconsole-setup || true")
fi

# ============================================================
# 6. Configure zram (compressed swap in RAM)?
# ============================================================
if ask_question "Configure zram (compressed swap in RAM)?" "Y"; then
    CONFIGURE_ZRAM=true
    PACMAN_PACKAGES+=(zram-generator)
    POST_COMMANDS+=("echo '[zram0]' > /etc/systemd/zram-generator.conf")
    POST_COMMANDS+=("systemctl daemon-reload")
    POST_COMMANDS+=("systemctl start systemd-zram-setup@zram0.service || true")
    POST_COMMANDS+=("swapon --show || true")
fi

# ============================================================
# 7. Speed up boot? (auto-detect bootloader)
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
        if ask_question "Tune GRUB (remove 'quiet', set loglevel=3, apply custom GRUB options)?" "Y"; then
            TUNE_GRUB=true
        fi
        if ask_question "Fix GRUB menu to look like 'Arch Linux' / 'Windows' (patch 10_linux and 30_os-prober)?" "Y"; then
            FIX_GRUB_MENU=true
        fi
        ;;
esac

# ============================================================
# 8. GRUB theme (only for GRUB)
# ============================================================
if [[ "$BOOTLOADER" == "grub" ]]; then

    if is_grub_theme_installed; then
        local_installed=$(get_installed_grub_theme)
        echo -e "${YELLOW}A GRUB theme appears to be already installed:${NC}"
        if [[ -n "$local_installed" ]]; then
            echo -e "  ${local_installed}"
        else
            echo -e "  (GRUB_THEME= is set, but directory not found)"
        fi
        if ask_question "Remove the installed GRUB theme?" "N"; then
            GRUB_THEME_UNINSTALL=true
        fi
    fi

    if [[ "$GRUB_THEME_UNINSTALL" != "true" ]]; then

        if [[ ! -d "$GRUB_THEME_SRC" ]]; then
            echo -e "${YELLOW}Cloning quickstartlinux to enumerate GRUB themes...${NC}"
            ensure_quickstartlinux_cloned || echo -e "${RED}Clone failed — skipping GRUB theme step.${NC}"
        fi

        if [[ -d "$GRUB_THEME_SRC" ]]; then
            mapfile -t AVAILABLE_THEMES < <(list_grub_themes "$GRUB_THEME_SRC" || true)

            if [[ ${#AVAILABLE_THEMES[@]} -eq 0 ]]; then
                echo -e "${YELLOW}No themes found in ${GRUB_THEME_SRC} — skipping.${NC}"
            else
                if ask_question "Install a GRUB theme?" "Y"; then
                    INSTALL_GRUB_THEME=true

                    echo
                    echo -e "${YELLOW}Available themes:${NC}"
                    for i in "${!AVAILABLE_THEMES[@]}"; do
                        printf '  %d) %s\n' "$((i+1))" "${AVAILABLE_THEMES[$i]}"
                    done
                    echo "  0) skip"
                    echo

                    if [[ "$USE_DEFAULTS" == "true" ]]; then
                        THEME_CHOICE=1
                        echo -e "${YELLOW}Choose theme [1-${#AVAILABLE_THEMES[@]}, default 1]: ${GREEN}1 (default)${NC}"
                    else
                        read -rp "$(echo -e "${YELLOW}Choose theme [1-${#AVAILABLE_THEMES[@]}, default 1]: ${NC}")" THEME_CHOICE
                        THEME_CHOICE="${THEME_CHOICE:-1}"
                    fi

                    if [[ "$THEME_CHOICE" =~ ^[0-9]+$ ]] \
                       && (( THEME_CHOICE >= 1 && THEME_CHOICE <= ${#AVAILABLE_THEMES[@]} )); then
                        GRUB_THEME_SELECTED="${AVAILABLE_THEMES[$((THEME_CHOICE-1))]}"
                        echo -e "${GREEN}Selected theme: ${GRUB_THEME_SELECTED}${NC}"

                        echo
                        echo -e "${YELLOW}Enter the title text for the GRUB menu:${NC}"
                        echo -e "  (empty or spaces = default 'Bootloader')"

                        if [[ "$USE_DEFAULTS" == "true" ]]; then
                            GRUB_THEME_TITLE="Bootloader"
                            echo -e "${YELLOW}Title: ${GREEN}Bootloader (default)${NC}"
                        else
                            read -rp "Title: " GRUB_THEME_TITLE
                            if [[ -z "${GRUB_THEME_TITLE// /}" ]]; then
                                GRUB_THEME_TITLE="Bootloader"
                            fi
                        fi
                        echo -e "${GREEN}Title: ${GRUB_THEME_TITLE}${NC}"
                    else
                        echo -e "${YELLOW}Skipping theme install.${NC}"
                        INSTALL_GRUB_THEME=false
                    fi
                fi
            fi
        fi
    fi
fi

# ============================================================
# 9. Install dev & utility tools?
# ============================================================
if ask_question "Install all development and utility tools?" "Y"; then
    PACMAN_PACKAGES+=(
        # Base tools
        pacman-contrib htop btop

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

        # Xorg
        xorg-xrandr # jdk8-openjdk jre8-openjdk jre8-openjdk-headless jdk-openjdk 

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
# 10. Install useful apps (Flatpak)?
# ============================================================
INSTALL_FLATPAK=false
if ask_question "Install useful applications via Flatpak?" "Y"; then
    INSTALL_FLATPAK=true

    if ! command_exists flatpak; then
        PACMAN_PACKAGES+=(flatpak)
    fi

    POST_COMMANDS+=("flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo")

    FLATPAK_PACKAGES+=(
        com.mattjakeman.ExtensionManager
        org.chromium.Chromium
        org.onlyoffice.desktopeditors
        org.localsend.localsend_app
        org.polymc.PolyMC
        us.zoom.Zoom
    )
fi

# ============================================================
# 11. Install firmware (auto-detect CPU & GPU)?
# ============================================================
if ask_question "Install firmware for your CPU/GPU?" "Y"; then
    INSTALL_FIRMWARE=true
fi

# ============================================================
# 12. Install a virtual machine?
# ============================================================
if ask_question "Do you want to install a virtual machine?" "N"; then
    echo -e "${YELLOW}Choose VM type:${NC}"
    echo "  1) VirtualBox"
    echo "  2) GNOME Boxes"

    if [[ "$USE_DEFAULTS" == "true" ]]; then
        VM_CHOICE=1
        echo -e "${YELLOW}Enter choice [1/2]: ${GREEN}1 (default)${NC}"
    else
        read -rp "Enter choice [1/2]: " VM_CHOICE
    fi

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
# 13. DETECT CPU & GPU
# ============================================================
if [[ "$INSTALL_FIRMWARE" == "true" ]]; then
    echo
    echo -e "${GREEN}>>> Detecting CPU and GPU...${NC}"

    PACMAN_PACKAGES+=(
        pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils
        sof-firmware alsa-ucm-conf v4l-utils bluez bluez-utils pciutils
    )

    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    GPU_INFO=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)

    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        echo -e "${GREEN}Intel CPU detected. Adding Intel packages...${NC}"
        PACMAN_PACKAGES+=(
            mesa mesa-utils libva-intel-driver intel-media-driver
            vulkan-intel
        )
    fi

    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        echo -e "${GREEN}AMD CPU detected. Adding AMD packages...${NC}"
        PACMAN_PACKAGES+=(
            mesa mesa-utils vulkan-radeon libva-mesa-driver
        )
    fi

    if echo "$GPU_INFO" | grep -qi nvidia; then
        echo -e "${GREEN}NVIDIA GPU detected. Adding NVIDIA packages...${NC}"
        PACMAN_PACKAGES+=(
            nvidia nvidia-utils nvidia-settings
            vulkan-icd-loader libvdpau opencl-nvidia
        )
    fi

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
    echo -e "${YELLOW}GRUB tuning:${NC} enabled"
    echo "  GRUB_DISABLE_BOOTNEXT=true"
    echo "  GRUB_DISABLE_UEFI_FIRMWARE=false"
    echo "  GRUB_DISABLE_SUBMENU=y"
    echo "  GRUB_DISABLE_OS_PROBER=false"
    echo "  GRUB_GFXMODE=auto"
    echo "  GRUB_TIMEOUT_STYLE=menu"
fi
if [[ "$FIX_GRUB_MENU" == "true" ]]; then
    echo -e "${YELLOW}GRUB menu fix:${NC} enabled (Arch Linux / Windows)"
fi
if [[ "$GRUB_THEME_UNINSTALL" == "true" ]]; then
    echo -e "${YELLOW}GRUB theme:${NC} will be REMOVED"
elif [[ "$INSTALL_GRUB_THEME" == "true" && -n "$GRUB_THEME_SELECTED" ]]; then
    echo -e "${YELLOW}GRUB theme:${NC} ${GRUB_THEME_SELECTED}"
    echo -e "  title: ${GRUB_THEME_TITLE}"
fi
if [[ "$TUNE_GRUB" == "true" || "$FIX_GRUB_MENU" == "true" || "$INSTALL_GRUB_THEME" == "true" || "$GRUB_THEME_UNINSTALL" == "true" ]]; then
    echo -e "${YELLOW}GRUB regeneration:${NC} single run after all GRUB changes"
fi
if [[ "$CONFIGURE_ZRAM" == "true" ]]; then
    echo -e "${YELLOW}zram:${NC} enabled (config: /etc/systemd/zram-generator.conf)"
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
    UNIQUE_PACMAN=($(printf '%s\n' "${PACMAN_PACKAGES[@]}" | awk '!seen[$0]++'))
    pacman -S --noconfirm --needed "${UNIQUE_PACMAN[@]}"
fi

# ============================================================
# TUNE GRUB (only edits /etc/default/grub)
# ============================================================
GRUB_CHANGED=false
if [[ "$TUNE_GRUB" == "true" ]]; then
    echo
    echo -e "${GREEN}>>> Tuning GRUB...${NC}"
    if tune_grub; then
        GRUB_CHANGED=true
    else
        echo -e "${RED}Warning: GRUB tuning failed.${NC}"
    fi
fi

# ============================================================
# FIX GRUB MENU (only patches /etc/grub.d/*)
# ============================================================
if [[ "$FIX_GRUB_MENU" == "true" ]]; then
    echo
    echo -e "${GREEN}>>> Fixing GRUB menu (Arch Linux / Windows)...${NC}"
    if fix_grub_menu; then
        GRUB_CHANGED=true
    else
        echo -e "${RED}Warning: GRUB menu fix failed.${NC}"
    fi
fi

# ============================================================
# INSTALL / UNINSTALL GRUB THEME
# ============================================================
if [[ "$GRUB_THEME_UNINSTALL" == "true" ]]; then
    if uninstall_grub_theme; then
        GRUB_CHANGED=true
    else
        echo -e "${RED}Warning: GRUB theme uninstall failed.${NC}"
    fi
elif [[ "$INSTALL_GRUB_THEME" == "true" && -n "$GRUB_THEME_SELECTED" ]]; then
    if install_grub_theme "${GRUB_THEME_SRC}/${GRUB_THEME_SELECTED}" "$GRUB_THEME_TITLE"; then
        GRUB_CHANGED=true
    else
        echo -e "${RED}Warning: GRUB theme install failed.${NC}"
    fi
fi

# ============================================================
# REGENERATE GRUB CONFIG (exactly once)
# ============================================================
if [[ "$GRUB_CHANGED" == "true" ]]; then
    regenerate_grub_cfg || echo -e "${RED}Warning: grub-mkconfig failed.${NC}"
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

# ============================================================
# CLEANUP
# ============================================================
if [[ -d "$QUICKSTART_DIR" ]]; then
    rm -rf "$QUICKSTART_DIR"
fi

echo
echo -e "${GREEN}=== Done! ===${NC}"
