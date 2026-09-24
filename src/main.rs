use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::process::{Command, Stdio};

use console::style;
use dialoguer::{theme::ColorfulTheme, Confirm, Select};

// ============================================================
// Data structures
// ============================================================

#[derive(Default)]
struct SetupPlan {
    pacman_packages: Vec<String>,
    flatpak_packages: Vec<String>,
    post_commands: Vec<String>,
}

impl SetupPlan {
    fn add_pacman(&mut self, pkgs: &[&str]) {
        for p in pkgs {
            self.pacman_packages.push((*p).to_string());
        }
    }

    fn add_flatpak(&mut self, pkgs: &[&str]) {
        for p in pkgs {
            self.flatpak_packages.push((*p).to_string());
        }
    }

    fn add_post(&mut self, cmd: &str) {
        self.post_commands.push(cmd.to_string());
    }

    fn dedup(&mut self) {
        let mut seen = HashSet::new();
        self.pacman_packages.retain(|p| seen.insert(p.clone()));

        let mut seen = HashSet::new();
        self.flatpak_packages.retain(|p| seen.insert(p.clone()));
    }
}

// ============================================================
// Helpers
// ============================================================

fn ask(question: &str, default_yes: bool) -> bool {
    Confirm::with_theme(&ColorfulTheme::default())
        .with_prompt(question)
        .default(default_yes)
        .interact()
        .unwrap_or(false)
}

fn command_exists(cmd: &str) -> bool {
    Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {}", cmd))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run(cmd: &str) -> bool {
    println!("{} {}", style(">>>").green().bold(), cmd);
    Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn capture(cmd: &str) -> String {
    Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

// ============================================================
// Active user detection
// ============================================================

fn detect_active_user() -> Option<(String, u32)> {
    // Try loginctl
    let out = capture("loginctl list-sessions --no-legend 2>/dev/null");
    let mut user: Option<String> = None;

    for line in out.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 3 {
            // Look for seat0
            if cols.iter().any(|c| *c == "seat0") {
                user = Some(cols[2].to_string());
                break;
            }
        }
    }

    // Fallback: first session user
    if user.is_none() {
        if let Some(first) = out.lines().next() {
            let cols: Vec<&str> = first.split_whitespace().collect();
            if cols.len() >= 3 {
                user = Some(cols[2].to_string());
            }
        }
    }

    // Fallback: who
    if user.is_none() {
        let who = capture("who");
        if let Some(first) = who.lines().next() {
            if let Some(u) = first.split_whitespace().next() {
                user = Some(u.to_string());
            }
        }
    }

    let user = user?;
    let uid_str = capture(&format!("id -u {} 2>/dev/null", user));
    let uid: u32 = uid_str.trim().parse().ok()?;
    Some((user, uid))
}

// ============================================================
// CPU / GPU detection
// ============================================================

fn detect_cpu_vendor() -> String {
    let cpuinfo = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    for line in cpuinfo.lines() {
        if line.starts_with("vendor_id") {
            if let Some(v) = line.split(':').nth(1) {
                return v.trim().to_string();
            }
        }
    }
    String::new()
}

fn detect_gpu_info() -> String {
    capture("lspci 2>/dev/null | grep -Ei 'vga|3d|display'")
}

// ============================================================
// Main
// ============================================================

fn main() {
    println!("{}", style("=== Arch Linux Setup Script (Rust) ===").green().bold());
    println!();

    let mut plan = SetupPlan::default();

    // 1. GNOME?
    if ask("Install GNOME?", false) {
        plan.add_pacman(&["gdm", "gnome"]);
        plan.add_post("systemctl enable --now gdm");
    }

    // 2. Using GNOME?
    if ask("Are you using GNOME?", true) {
        plan.add_pacman(&["adw-gtk-theme", "gnome-tweaks", "gnome-sound-recorder"]);

        match detect_active_user() {
            Some((user, uid)) => {
                let cmd = format!(
                    "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus && \
                     su - {user} -c \"gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' && \
                     gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' && \
                     gsettings set org.gnome.shell disable-extension-version-validation true\"",
                    uid = uid,
                    user = user
                );
                plan.add_post(&cmd);
            }
            None => {
                eprintln!(
                    "{} Could not determine active user. Skipping gsettings.",
                    style("Warning:").red().bold()
                );
            }
        }
    }

    // 3. Fonts?
    if ask("Install emoji and language fonts?", true) {
        plan.add_pacman(&[
            "ttf-dejavu",
            "ttf-liberation",
            "ttf-arphic-ukai",
            "ttf-arphic-uming",
            "ttf-sazanami",
            "noto-fonts",
            "noto-fonts-emoji",
            "noto-fonts-cjk",
        ]);
    }

    // 4. Bluetooth?
    if ask("Enable Bluetooth?", true) {
        plan.add_post("systemctl enable --now bluetooth");
    }

    // 5. Locale?
    if ask("Set locale to ru_RU.UTF-8?", true) {
        plan.add_post("localectl set-locale ru_RU.UTF-8");
    }

    // 6. Speed up boot?
    if ask("Speed up boot (set bootloader timeout to 1s)?", true) {
        plan.add_post("sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf");
    }

    // 7. Dev tools?
    if ask("Install all development and utility tools?", true) {
        plan.add_pacman(&[
            "pacman-contrib",
            "btrfs-progs", "xfsprogs", "f2fs-tools", "exfatprogs", "udftools",
            "ntfs-3g", "ntfsprogs", "dosfstools", "e2fsprogs", "cryptsetup",
            "binwalk", "squashfs-tools", "mtd-utils", "uboot-tools", "udisks2", "usbutils",
            "gvfs", "fuse2", "fuse3",
            "openssl", "nss",
            "android-tools", "scrcpy",
            "jhead", "pixman",
            "jdk8-openjdk", "jre8-openjdk", "jre8-openjdk-headless", "jdk-openjdk",
            "xorg-xrandr",
            "git", "base-devel", "devtools", "fakeroot", "meson", "ninja",
            "pkgconfig", "glib2", "libusb", "systemd-libs", "gdk-pixbuf2",
            "cairo", "gcc",
            "docker", "docker-compose",
        ]);
        plan.add_post("systemctl enable --now docker");
    }

    // 8. Flatpak apps?
    if ask("Install useful applications via Flatpak?", true) {
        if !command_exists("flatpak") {
            plan.add_pacman(&["flatpak"]);
        }
        plan.add_post(
            "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo",
        );
        plan.add_flatpak(&[
            "com.mattjakeman.ExtensionManager",
            "org.polymc.PolyMC",
            "org.chromium.Chromium",
            "us.zoom.Zoom",
        ]);
    }

    // 9. Firmware?
    if ask("Install firmware for your CPU/GPU?", true) {
        plan.add_pacman(&[
            "pipewire", "pipewire-alsa", "pipewire-pulse", "wireplumber",
            "alsa-utils", "sof-firmware", "alsa-ucm-conf", "v4l-utils",
            "bluez", "bluez-utils", "pciutils",
        ]);

        let cpu = detect_cpu_vendor();
        let gpu = detect_gpu_info();

        if cpu == "GenuineIntel" {
            println!("{}", style("Intel CPU detected.").green());
            plan.add_pacman(&[
                "mesa", "mesa-utils", "libva-intel-driver", "intel-media-driver",
                "vulkan-intel", "lib32-vulkan-intel", "lib32-mesa",
            ]);
        } else if cpu == "AuthenticAMD" {
            println!("{}", style("AMD CPU detected.").green());
            plan.add_pacman(&[
                "mesa", "mesa-utils", "vulkan-radeon", "lib32-vulkan-radeon",
                "libva-mesa-driver", "lib32-mesa",
            ]);
        }

        let gpu_lower = gpu.to_lowercase();

        if gpu_lower.contains("nvidia") {
            println!("{}", style("NVIDIA GPU detected.").green());
            plan.add_pacman(&[
                "nvidia", "nvidia-utils", "nvidia-settings", "lib32-nvidia-utils",
                "vulkan-icd-loader", "lib32-vulkan-icd-loader", "libvdpau",
                "lib32-libvdpau", "opencl-nvidia", "lib32-opencl-nvidia",
            ]);
        }

        if gpu_lower.contains("amd") || gpu_lower.contains("ati") || gpu_lower.contains("radeon") {
            println!("{}", style("AMD GPU detected.").green());
            plan.add_pacman(&[
                "mesa", "mesa-utils", "vulkan-radeon", "lib32-vulkan-radeon",
                "libva-mesa-driver", "lib32-mesa",
            ]);
        }
    }

    // 10. Virtual machine?
    if ask("Do you want to install a virtual machine?", false) {
        let choices = &["VirtualBox", "GNOME Boxes"];
        let selection = Select::with_theme(&ColorfulTheme::default())
            .with_prompt("Choose VM type")
            .items(choices)
            .default(0)
            .interact()
            .unwrap_or(usize::MAX);

        match selection {
            0 => {
                println!("{}", style("Selected VirtualBox.").green());
                plan.add_pacman(&["virtualbox", "virtualbox-host-modules-arch"]);
                plan.add_post("groupadd -f vboxusers");
                plan.add_post("modprobe vboxdrv");
            }
            1 => {
                println!("{}", style("Selected GNOME Boxes.").green());
                plan.add_pacman(&["gnome-boxes"]);
            }
            _ => {
                eprintln!("{}", style("Invalid choice. Skipping VM.").red());
            }
        }
    }

    plan.dedup();

    // ============================================================
    // Summary
    // ============================================================
    println!();
    println!("{}", style("=== Summary ===").green().bold());
    println!();

    println!("{}", style("Pacman packages:").yellow().bold());
    if plan.pacman_packages.is_empty() {
        println!("  (none)");
    } else {
        for p in &plan.pacman_packages {
            println!("  {}", p);
        }
    }

    println!();
    println!("{}", style("Flatpak packages:").yellow().bold());
    if plan.flatpak_packages.is_empty() {
        println!("  (none)");
    } else {
        for p in &plan.flatpak_packages {
            println!("  {}", p);
        }
    }

    println!();
    println!("{}", style("Post-install commands:").yellow().bold());
    if plan.post_commands.is_empty() {
        println!("  (none)");
    } else {
        for c in &plan.post_commands {
            println!("  {}", c);
        }
    }

    println!();
    if !ask("Proceed with installation?", true) {
        println!("{}", style("Aborted by user.").red());
        return;
    }

    // ============================================================
    // Execute
    // ============================================================
    if !plan.pacman_packages.is_empty() {
        println!();
        println!("{}", style(">>> Installing pacman packages...").green().bold());
        let mut cmd = String::from("pacman -S --noconfirm --needed");
        for p in &plan.pacman_packages {
            cmd.push(' ');
            cmd.push_str(p);
        }
        if !run(&cmd) {
            eprintln!("{}", style("Warning: pacman install failed.").red());
        }
    }

    if !plan.flatpak_packages.is_empty() {
        println!();
        println!("{}", style(">>> Installing Flatpak packages...").green().bold());
        let mut cmd = String::from("flatpak install --system -y flathub");
        for p in &plan.flatpak_packages {
            cmd.push(' ');
            cmd.push_str(p);
        }
        if !run(&cmd) {
            eprintln!("{}", style("Warning: flatpak install failed.").red());
        }
    }

    if !plan.post_commands.is_empty() {
        println!();
        println!("{}", style(">>> Running post-install commands...").green().bold());
        for c in &plan.post_commands {
            if !run(c) {
                eprintln!(
                    "{} command failed: {}",
                    style("Warning:").red().bold(),
                    c
                );
            }
        }
    }

    println!();
    println!("{}", style("=== Done! ===").green().bold());

    // Keep terminal from closing abruptly
    print!("Press Enter to exit...");
    io::stdout().flush().ok();
    let mut buf = String::new();
    io::stdin().read_line(&mut buf).ok();
}
