// ============================================================
// Arch Linux Setup Wizard — single-file Rust TUI
// Linux only. English only.
// ============================================================

use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::Duration;

use crossterm::{
    event::{Event, KeyCode, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, List, ListItem, ListState, Paragraph},
    Terminal,
};

// ============================================================
// Theme (from the zapret-rust example)
// ============================================================

struct Theme;

impl Theme {
    fn selected_item() -> Style {
        Style::default()
            .fg(Color::Black)
            .bg(Color::LightYellow)
            .add_modifier(Modifier::BOLD)
    }

    fn selected_value() -> Style {
        Style::default()
            .fg(Color::Blue)
            .bg(Color::LightYellow)
            .add_modifier(Modifier::BOLD)
    }

    fn normal_item() -> Style {
        Style::default().fg(Color::White)
    }

    fn normal_value() -> Style {
        Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)
    }

    fn dim_item() -> Style {
        Style::default().fg(Color::DarkGray)
    }

    fn header_style() -> Style {
        Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD)
    }

    fn block_title() -> Style {
        Style::default().fg(Color::LightGreen)
    }

    fn good() -> Style {
        Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)
    }

    fn warn() -> Style {
        Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
    }
}

// ============================================================
// Auto privilege escalation (Linux-only)
// ============================================================

fn is_root() -> bool {
    Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim() == "0")
        .unwrap_or(false)
}

fn ensure_root() {
    if is_root() {
        return;
    }

    println!("Root privileges required. Re-launching...");

    let exe = std::env::current_exe().unwrap_or_default();
    let args: Vec<String> = std::env::args().skip(1).collect();

    // Try pkexec first (exec replaces the current process)
    let _err1 = Command::new("pkexec").arg(&exe).args(&args).exec();

    // Fallback to sudo
    let err2 = Command::new("sudo").arg(&exe).args(&args).exec();

    eprintln!("Failed to escalate privileges: {}", err2);
    std::process::exit(1);
}

// ============================================================
// Plan
// ============================================================

#[derive(Default)]
struct Plan {
    pacman: Vec<String>,
    flatpak: Vec<String>,
    post: Vec<String>,
}

impl Plan {
    fn add_pacman(&mut self, pkgs: &[&str]) {
        for p in pkgs {
            self.pacman.push((*p).to_string());
        }
    }

    fn add_flatpak(&mut self, pkgs: &[&str]) {
        for p in pkgs {
            self.flatpak.push((*p).to_string());
        }
    }

    fn add_post(&mut self, cmd: &str) {
        self.post.push(cmd.to_string());
    }

    fn dedup(&mut self) {
        let mut s = HashSet::new();
        self.pacman.retain(|p| s.insert(p.clone()));
        let mut s = HashSet::new();
        self.flatpak.retain(|p| s.insert(p.clone()));
        let mut s = HashSet::new();
        self.post.retain(|p| s.insert(p.clone()));
    }
}

// ============================================================
// Detection helpers
// ============================================================

fn capture(cmd: &str) -> String {
    Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
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

fn detect_active_user() -> Option<(String, u32)> {
    let out = capture("loginctl list-sessions --no-legend 2>/dev/null");
    let mut user: Option<String> = None;

    for line in out.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 3 && cols.iter().any(|c| *c == "seat0") {
            user = Some(cols[2].to_string());
            break;
        }
    }

    if user.is_none() {
        if let Some(first) = out.lines().next() {
            let cols: Vec<&str> = first.split_whitespace().collect();
            if cols.len() >= 3 {
                user = Some(cols[2].to_string());
            }
        }
    }

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
// Wizard state
// ============================================================

#[derive(Clone, Copy, PartialEq, Eq)]
enum Screen {
    /// The Y/N checklist
    Checklist,
    /// Pre-flight summary
    Summary,
    /// Running install
    Running,
    /// Done
    Done,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Choice {
    Yes,
    No,
}

impl Choice {
    fn flip(self) -> Self {
        match self {
            Choice::Yes => Choice::No,
            Choice::No => Choice::Yes,
        }
    }

    fn as_bool(self) -> bool {
        matches!(self, Choice::Yes)
    }
}

struct OptionItem {
    key: &'static str,
    label: &'static str,
    help: &'static str,
    choice: Choice,
    enabled: bool,
}

impl OptionItem {
    fn new(key: &'static str, label: &'static str, help: &'static str, default_yes: bool) -> Self {
        Self {
            key,
            label,
            help,
            choice: if default_yes { Choice::Yes } else { Choice::No },
            enabled: false,
        }
    }
}

/// The checklist cursor can be on any option OR on the Install/Exit buttons.
#[derive(Clone, Copy, PartialEq, Eq)]
enum CursorPos {
    Option(usize),
    Install,
    Exit,
}

struct App {
    screen: Screen,
    options: Vec<OptionItem>,
    cursor: CursorPos,
    plan: Plan,
    log: Vec<String>,
    summary_scroll: u16,
    run_index: usize,
    run_steps: Vec<String>,
    should_quit: bool,
}

impl App {
    fn new() -> Self {
        // Strictly ordered, following the source plan.
        let options = vec![
            OptionItem::new(
                "gnome",
                "Install GNOME?",
                "pacman -S gdm gnome + systemctl enable --now gdm",
                false, // default N
            ),
            OptionItem::new(
                "gnome_theme",
                "Are you using GNOME?",
                "adw-gtk-theme, gnome-tweaks, gnome-sound-recorder + gsettings (dark)",
                true, // default Y
            ),
            OptionItem::new(
                "fonts",
                "Install emoji & language fonts?",
                "ttf-dejavu, ttf-liberation, noto-fonts, noto-fonts-emoji, noto-fonts-cjk, ...",
                true,
            ),
            OptionItem::new(
                "bluetooth",
                "Enable Bluetooth?",
                "systemctl enable --now bluetooth",
                true,
            ),
            OptionItem::new(
                "locale",
                "Set locale to ru_RU.UTF-8?",
                "localectl set-locale ru_RU.UTF-8",
                true,
            ),
            OptionItem::new(
                "boot",
                "Speed up boot?",
                "sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf",
                true,
            ),
            OptionItem::new(
                "devtools",
                "Install all dev & utility tools?",
                "git, base-devel, docker, java, binwalk, android-tools, ...",
                true,
            ),
            OptionItem::new(
                "flatpak",
                "Install useful applications (Flatpak)?",
                "ExtensionManager, PolyMC, Chromium, Zoom",
                true,
            ),
            OptionItem::new(
                "firmware",
                "Install CPU/GPU firmware?",
                "Auto-detect CPU (Intel/AMD) and GPU (NVIDIA/AMD)",
                true,
            ),
            OptionItem::new(
                "vm",
                "Install a virtual machine?",
                "VirtualBox or GNOME Boxes",
                false, // default N
            ),
        ];

        Self {
            screen: Screen::Checklist,
            options,
            cursor: CursorPos::Option(0),
            plan: Plan::default(),
            log: Vec::new(),
            summary_scroll: 0,
            run_index: 0,
            run_steps: Vec::new(),
            should_quit: false,
        }
    }

    fn move_up(&mut self) {
        self.cursor = match self.cursor {
            CursorPos::Option(0) => CursorPos::Option(0),
            CursorPos::Option(i) => CursorPos::Option(i - 1),
            CursorPos::Install => CursorPos::Option(self.options.len() - 1),
            CursorPos::Exit => CursorPos::Install,
        };
    }

    fn move_down(&mut self) {
        self.cursor = match self.cursor {
            CursorPos::Option(i) if i + 1 < self.options.len() => CursorPos::Option(i + 1),
            CursorPos::Option(_) => CursorPos::Install,
            CursorPos::Install => CursorPos::Exit,
            CursorPos::Exit => CursorPos::Exit,
        };
    }

    fn flip_choice(&mut self) {
        if let CursorPos::Option(i) = self.cursor {
            self.options[i].choice = self.options[i].choice.flip();
        }
    }

    fn set_choice(&mut self, c: Choice) {
        if let CursorPos::Option(i) = self.cursor {
            self.options[i].choice = c;
        }
    }

    /// Mark all options per their current Y/N and build the install plan.
    fn build_plan(&mut self) {
        for o in &mut self.options {
            o.enabled = o.choice.as_bool();
        }

        let mut plan = Plan::default();

        let gnome_on = self.options.iter().find(|o| o.key == "gnome").map(|o| o.enabled).unwrap_or(false);
        let gnome_theme_on = self
            .options
            .iter()
            .find(|o| o.key == "gnome_theme")
            .map(|o| o.enabled)
            .unwrap_or(false);
        let fonts_on = self.options.iter().find(|o| o.key == "fonts").map(|o| o.enabled).unwrap_or(false);
        let bt_on = self.options.iter().find(|o| o.key == "bluetooth").map(|o| o.enabled).unwrap_or(false);
        let locale_on = self.options.iter().find(|o| o.key == "locale").map(|o| o.enabled).unwrap_or(false);
        let boot_on = self.options.iter().find(|o| o.key == "boot").map(|o| o.enabled).unwrap_or(false);
        let dev_on = self.options.iter().find(|o| o.key == "devtools").map(|o| o.enabled).unwrap_or(false);
        let flatpak_on = self.options.iter().find(|o| o.key == "flatpak").map(|o| o.enabled).unwrap_or(false);
        let fw_on = self.options.iter().find(|o| o.key == "firmware").map(|o| o.enabled).unwrap_or(false);
        let vm_on = self.options.iter().find(|o| o.key == "vm").map(|o| o.enabled).unwrap_or(false);

        // 1. GNOME install
        if gnome_on {
            plan.add_pacman(&["gdm", "gnome"]);
            plan.add_post("systemctl enable --now gdm");
        }

        // 2. GNOME theme
        if gnome_theme_on {
            plan.add_pacman(&["adw-gtk-theme", "gnome-tweaks", "gnome-sound-recorder"]);
            if let Some((user, uid)) = detect_active_user() {
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
        }

        // 3. Fonts
        if fonts_on {
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

        // 4. Bluetooth
        if bt_on {
            plan.add_post("systemctl enable --now bluetooth");
        }

        // 5. Locale
        if locale_on {
            plan.add_post("localectl set-locale ru_RU.UTF-8");
        }

        // 6. Boot
        if boot_on {
            plan.add_post("sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf");
        }

        // 7. Dev tools
        if dev_on {
            plan.add_pacman(&[
                // Group 1: pacman-contrib
                "pacman-contrib",
                // Group 2: filesystems
                "btrfs-progs", "xfsprogs", "f2fs-tools", "exfatprogs", "udftools",
                "ntfs-3g", "ntfsprogs", "dosfstools", "e2fsprogs", "cryptsetup",
                // Group 3: forensics
                "binwalk", "squashfs-tools", "mtd-utils", "uboot-tools",
                "udisks2", "usbutils",
                // Group 4: gvfs
                "gvfs", "fuse2", "fuse3",
                // Group 5: crypto
                "openssl", "nss",
                // Group 6: android
                "android-tools", "scrcpy",
                // Group 7: misc
                "jhead", "pixman",
                // Group 8: java / xorg
                "jdk8-openjdk", "jre8-openjdk", "jre8-openjdk-headless",
                "jdk-openjdk", "xorg-xrandr",
                // Group 9: build tools
                "git", "base-devel", "devtools", "fakeroot", "meson", "ninja",
                "pkgconfig", "glib2", "libusb", "systemd-libs",
                "gdk-pixbuf2", "cairo", "gcc",
                // Group 10: containers
                "docker", "docker-compose",
            ]);
            plan.add_post("systemctl enable --now docker");
        }

        // 8. Flatpak
        if flatpak_on {
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

        // 9. Firmware
        if fw_on {
            plan.add_pacman(&[
                "pipewire", "pipewire-alsa", "pipewire-pulse", "wireplumber",
                "alsa-utils", "sof-firmware", "alsa-ucm-conf",
                "v4l-utils", "bluez", "bluez-utils", "pciutils",
            ]);

            let cpu = detect_cpu_vendor();
            let gpu = detect_gpu_info();

            if cpu == "GenuineIntel" {
                plan.add_pacman(&[
                    "mesa", "mesa-utils", "libva-intel-driver", "intel-media-driver",
                    "vulkan-intel", "lib32-vulkan-intel", "lib32-mesa",
                ]);
            } else if cpu == "AuthenticAMD" {
                plan.add_pacman(&[
                    "mesa", "mesa-utils", "vulkan-radeon", "lib32-vulkan-radeon",
                    "libva-mesa-driver", "lib32-mesa",
                ]);
            }

            let gpu_lc = gpu.to_lowercase();
            if gpu_lc.contains("nvidia") {
                plan.add_pacman(&[
                    "nvidia", "nvidia-utils", "nvidia-settings", "lib32-nvidia-utils",
                    "vulkan-icd-loader", "lib32-vulkan-icd-loader",
                    "libvdpau", "lib32-libvdpau",
                    "opencl-nvidia", "lib32-opencl-nvidia",
                ]);
            }
            if gpu_lc.contains("amd") || gpu_lc.contains("ati") || gpu_lc.contains("radeon") {
                plan.add_pacman(&[
                    "mesa", "mesa-utils", "vulkan-radeon", "lib32-vulkan-radeon",
                    "libva-mesa-driver", "lib32-mesa",
                ]);
            }
        }

        // 10. VM
        if vm_on {
            plan.add_pacman(&[
                "virtualbox", "virtualbox-host-modules-arch",
                "gnome-boxes",
            ]);
            plan.add_post("groupadd -f vboxusers");
            plan.add_post("modprobe vboxdrv");
        }

        plan.dedup();
        self.plan = plan;

        // Build step list for the running screen
        let mut steps: Vec<String> = Vec::new();
        if !self.plan.pacman.is_empty() {
            steps.push(format!(
                "pacman -S --noconfirm --needed {}",
                self.plan.pacman.join(" ")
            ));
        }
        if !self.plan.flatpak.is_empty() {
            steps.push(format!(
                "flatpak install --system -y flathub {}",
                self.plan.flatpak.join(" ")
            ));
        }
        for c in &self.plan.post {
            steps.push(c.clone());
        }
        self.run_steps = steps;
        self.run_index = 0;
    }

    fn run_one_step(&mut self) -> Result<(), String> {
        if self.run_index >= self.run_steps.len() {
            return Ok(());
        }
        let cmd = self.run_steps[self.run_index].clone();
        self.log.push(format!(">>> {}", cmd));

        let status = Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .status()
            .map_err(|e| e.to_string())?;

        if !status.success() {
            return Err(format!("command exited with {}", status));
        }
        self.run_index += 1;
        Ok(())
    }
}

// ============================================================
// UI
// ============================================================

fn draw_checklist(f: &mut ratatui::Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(2)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(5),
        ])
        .split(f.size());

    // --- Title ---
    let title_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::Cyan));

    let title = Paragraph::new(Line::from(vec![Span::styled(
        "Arch Linux Setup Wizard",
        Theme::header_style(),
    )]))
    .alignment(Alignment::Center)
    .block(title_block);
    f.render_widget(title, chunks[0]);

    // --- Options + buttons ---
    let mut items: Vec<ListItem> = Vec::new();
    let mut selected_line: usize = 0;

    for (i, o) in app.options.iter().enumerate() {
        let is_sel = app.cursor == CursorPos::Option(i);
        if is_sel {
            selected_line = i;
        }

        let yes_style = if o.choice == Choice::Yes {
            if is_sel {
                Theme::selected_value()
            } else {
                Theme::good()
            }
        } else if is_sel {
            Theme::selected_item()
        } else {
            Theme::dim_item()
        };

        let no_style = if o.choice == Choice::No {
            if is_sel {
                Theme::selected_value()
            } else {
                Theme::good()
            }
        } else if is_sel {
            Theme::selected_item()
        } else {
            Theme::dim_item()
        };

        let label_style = if is_sel {
            Theme::selected_item()
        } else {
            Theme::normal_item()
        };

        let line = Line::from(vec![
            Span::styled(format!("  {}  ", o.label), label_style),
            Span::styled("[ Y ]", yes_style),
            Span::raw("  "),
            Span::styled("[ N ]", no_style),
        ]);
        items.push(ListItem::new(line));
    }

    // Install button
    let install_selected = app.cursor == CursorPos::Install;
    if install_selected {
        selected_line = app.options.len();
    }
    items.push(ListItem::new(Line::from(vec![Span::styled(
        "            ▶  INSTALL  ",
        if install_selected {
            Theme::selected_item()
        } else {
            Theme::good()
        },
    )])));

    // Exit button
    let exit_selected = app.cursor == CursorPos::Exit;
    if exit_selected {
        selected_line = app.options.len() + 1;
    }
    items.push(ListItem::new(Line::from(vec![Span::styled(
        "            ✖  EXIT  ",
        if exit_selected {
            Theme::selected_item()
        } else {
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
        },
    )])));

    let list_block = Block::default()
        .title(Span::styled(" Options ", Theme::block_title()))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let list = List::new(items).block(list_block);
    let mut st = ListState::default();
    st.select(Some(selected_line));
    f.render_stateful_widget(list, chunks[1], &mut st);

    // --- Help / status bar ---
    let (help_title, help_body) = match app.cursor {
        CursorPos::Option(i) => (" Help ", app.options[i].help.to_string()),
        CursorPos::Install => (" Action ", "Build the plan and start installing".to_string()),
        CursorPos::Exit => (" Action ", "Quit without making changes".to_string()),
    };

    let keys = "↑/↓ navigate  •  ←/→ or y/n toggle  •  Enter = activate  •  a = all Y  •  n = all N  •  q = quit";

    let help_block = Block::default()
        .title(Span::styled(help_title, Theme::block_title()))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let help_widget = Paragraph::new(vec![
        Line::from(Span::styled(help_body, Style::default().fg(Color::Gray))),
        Line::from(Span::styled(keys, Style::default().fg(Color::DarkGray))),
    ])
    .alignment(Alignment::Center)
    .block(help_block);
    f.render_widget(help_widget, chunks[2]);
}

fn draw_summary(f: &mut ratatui::Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(2)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(3),
        ])
        .split(f.size());

    let title_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::Cyan));

    let title = Paragraph::new(Line::from(vec![Span::styled(
        "Summary",
        Theme::header_style(),
    )]))
    .alignment(Alignment::Center)
    .block(title_block);
    f.render_widget(title, chunks[0]);

    let mut lines: Vec<Line> = Vec::new();

    lines.push(Line::from(Span::styled(
        format!("Pacman packages ({}):", app.plan.pacman.len()),
        Theme::warn(),
    )));
    for p in &app.plan.pacman {
        lines.push(Line::from(Span::styled(format!("   {}", p), Theme::dim_item())));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        format!("Flatpak packages ({}):", app.plan.flatpak.len()),
        Theme::warn(),
    )));
    for p in &app.plan.flatpak {
        lines.push(Line::from(Span::styled(format!("   {}", p), Theme::dim_item())));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        format!("Post-install commands ({}):", app.plan.post.len()),
        Theme::warn(),
    )));
    for c in &app.plan.post {
        let short = if c.len() > 100 { &c[..100] } else { c };
        lines.push(Line::from(Span::styled(format!("   {}", short), Theme::dim_item())));
    }

    let body_block = Block::default()
        .title(Span::styled(" Plan ", Theme::block_title()))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let body = Paragraph::new(lines)
        .block(body_block)
        .scroll((app.summary_scroll, 0));
    f.render_widget(body, chunks[1]);

    let help_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let help = Paragraph::new(Span::styled(
        "Enter = install  •  Esc = back  •  ↑/↓ scroll  •  q = quit",
        Style::default().fg(Color::Gray),
    ))
    .alignment(Alignment::Center)
    .block(help_block);
    f.render_widget(help, chunks[2]);
}

fn draw_running(f: &mut ratatui::Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(2)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(3),
        ])
        .split(f.size());

    let title_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::Cyan));

    let total = app.run_steps.len();
    let done = app.run_index.min(total);
    let title = Paragraph::new(Line::from(vec![Span::styled(
        format!("Running...  {}/{}", done, total),
        Theme::header_style(),
    )]))
    .alignment(Alignment::Center)
    .block(title_block);
    f.render_widget(title, chunks[0]);

    let mut lines: Vec<Line> = Vec::new();
    lines.push(Line::from(Span::styled(
        ">>> currently executing:",
        Theme::warn(),
    )));
    if done < total {
        lines.push(Line::from(Span::styled(
            format!("   {}", app.run_steps[done]),
            Theme::normal_value(),
        )));
    } else {
        lines.push(Line::from(Span::styled("   (done)", Theme::good())));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Log:", Theme::warn())));
    let start = app.log.len().saturating_sub(15);
    for l in &app.log[start..] {
        let short = if l.len() > 120 { &l[..120] } else { l };
        lines.push(Line::from(Span::styled(format!("   {}", short), Theme::dim_item())));
    }

    let body_block = Block::default()
        .title(Span::styled(" Progress ", Theme::block_title()))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let body = Paragraph::new(lines).block(body_block);
    f.render_widget(body, chunks[1]);

    let help_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let help = Paragraph::new(Span::styled(
        "Do not close this window.",
        Style::default().fg(Color::Gray),
    ))
    .alignment(Alignment::Center)
    .block(help_block);
    f.render_widget(help, chunks[2]);
}

fn draw_done(f: &mut ratatui::Frame) {
    let area = centered_rect(60, 20, f.size());

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::Green));

    let body = Paragraph::new(vec![
        Line::from(Span::styled("Setup complete", Theme::good())),
        Line::from(""),
        Line::from(Span::styled(
            "All requested steps have finished.",
            Style::default().fg(Color::Gray),
        )),
        Line::from(Span::styled(
            "Press Enter to exit.",
            Style::default().fg(Color::Gray),
        )),
    ])
    .alignment(Alignment::Center)
    .block(block);
    f.render_widget(body, area);
}

fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(vertical[1])[1]
}

fn draw(f: &mut ratatui::Frame, app: &App) {
    match app.screen {
        Screen::Checklist => draw_checklist(f, app),
        Screen::Summary => draw_summary(f, app),
        Screen::Running => draw_running(f, app),
        Screen::Done => draw_done(f),
    }
}

// ============================================================
// Main loop
// ============================================================

fn main() {
    ensure_root();

    // TUI setup
    enable_raw_mode().expect("enable_raw_mode");
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen).expect("enter alt screen");
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend).expect("terminal");

    let mut app = App::new();

    while !app.should_quit {
        terminal.draw(|f| draw(f, &app)).expect("draw");

        if let Event::Key(key) = crossterm::event::read().expect("read") {
            if key.kind != KeyEventKind::Press {
                continue;
            }

            match app.screen {
                Screen::Checklist => match key.code {
                    KeyCode::Up | KeyCode::Char('k') => app.move_up(),
                    KeyCode::Down | KeyCode::Char('j') => app.move_down(),
                    KeyCode::Left => app.set_choice(Choice::Yes),
                    KeyCode::Right => app.set_choice(Choice::No),
                    KeyCode::Char('y') | KeyCode::Char('Y') => app.set_choice(Choice::Yes),
                    KeyCode::Char('n') | KeyCode::Char('N') => app.set_choice(Choice::No),
                    KeyCode::Char(' ') => app.flip_choice(),
                    KeyCode::Char('a') => {
                        for o in &mut app.options {
                            o.choice = Choice::Yes;
                        }
                    }
                    KeyCode::Char('d') => {
                        for o in &mut app.options {
                            o.choice = Choice::No;
                        }
                    }
                    KeyCode::Enter => match app.cursor {
                        CursorPos::Install => {
                            app.build_plan();
                            app.screen = Screen::Summary;
                        }
                        CursorPos::Exit => app.should_quit = true,
                        CursorPos::Option(_) => {
                            // Enter on an option flips it
                            app.flip_choice();
                        }
                    },
                    KeyCode::Char('q') | KeyCode::Esc => app.should_quit = true,
                    _ => {}
                },
                Screen::Summary => match key.code {
                    KeyCode::Enter => {
                        app.screen = Screen::Running;
                        app.log.clear();
                        app.run_index = 0;
                    }
                    KeyCode::Esc | KeyCode::Backspace => {
                        app.screen = Screen::Checklist;
                    }
                    KeyCode::Up | KeyCode::Char('k') => {
                        app.summary_scroll = app.summary_scroll.saturating_sub(1);
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        app.summary_scroll = app.summary_scroll.saturating_add(1);
                    }
                    KeyCode::Char('q') => app.should_quit = true,
                    _ => {}
                },
                Screen::Running => {
                    // Blocking run handled after the draw
                }
                Screen::Done => match key.code {
                    KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q') => {
                        app.should_quit = true;
                    }
                    _ => {}
                },
            }
        }

        if app.screen == Screen::Running {
            // Temporarily leave the TUI so shell commands print their own output
            let _ = disable_raw_mode();
            let _ = execute!(terminal.backend_mut(), LeaveAlternateScreen);
            let _ = terminal.show_cursor();

            loop {
                match app.run_one_step() {
                    Ok(()) => {
                        if app.run_index >= app.run_steps.len() {
                            app.screen = Screen::Done;
                            break;
                        }
                    }
                    Err(e) => {
                        eprintln!("Step failed: {}", e);
                        app.run_index += 1;
                        if app.run_index >= app.run_steps.len() {
                            app.screen = Screen::Done;
                            break;
                        }
                    }
                }
            }

            // Re-enter the TUI
            let _ = enable_raw_mode();
            let _ = execute!(terminal.backend_mut(), EnterAlternateScreen);
            let _ = terminal.clear();
            let _ = io::stdout().flush();

            // Drain stale key events
            while crossterm::event::poll(Duration::from_millis(0)).unwrap_or(false) {
                let _ = crossterm::event::read();
            }
        }
    }

    // Restore terminal
    let _ = disable_raw_mode();
    let _ = execute!(terminal.backend_mut(), LeaveAlternateScreen);
    let _ = terminal.show_cursor();
}
