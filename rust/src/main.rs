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
    layout::{Alignment, Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, List, ListItem, ListState, Paragraph},
    Terminal,
};

// ============================================================
// Theme (borrowed style from the example)
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
    /// The multi-select checklist
    Checklist,
    /// Pre-flight summary
    Summary,
    /// Running install
    Running,
    /// Done
    Done,
}

/// One line in the checklist.
struct OptionItem {
    key: &'static str,
    label: &'static str,
    help: &'static str,
    default: bool,
    enabled: bool,
}

struct App {
    screen: Screen,
    options: Vec<OptionItem>,
    cursor: usize,
    plan: Plan,
    log: Vec<String>,
    summary_scroll: u16,
    run_index: usize,
    run_steps: Vec<String>,
    should_quit: bool,
}

impl App {
    fn new() -> Self {
        let options = vec![
            OptionItem {
                key: "gnome",
                label: "Install GNOME (gdm + gnome)",
                help: "Installs gdm, gnome and enables gdm.service",
                default: false,
                enabled: false,
            },
            OptionItem {
                key: "gnome_theme",
                label: "Configure GNOME (adw-gtk3-dark, prefer-dark)",
                help: "Adds adw-gtk-theme, gnome-tweaks, sound-recorder + gsettings",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "fonts",
                label: "Install emoji & CJK fonts",
                help: "ttf-dejavu, noto-fonts, noto-fonts-emoji, noto-fonts-cjk, ...",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "bluetooth",
                label: "Enable Bluetooth",
                help: "systemctl enable --now bluetooth",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "locale",
                label: "Set locale to ru_RU.UTF-8",
                help: "localectl set-locale ru_RU.UTF-8",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "boot",
                label: "Speed up boot (bootloader timeout = 1s)",
                help: "sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "devtools",
                label: "Install dev & utility tools",
                help: "git, base-devel, docker, java, binwalk, android-tools, ...",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "flatpak",
                label: "Install Flatpak apps",
                help: "ExtensionManager, PolyMC, Chromium, Zoom",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "firmware",
                label: "Install CPU/GPU firmware",
                help: "Auto-detects CPU (Intel/AMD) and GPU (NVIDIA/AMD)",
                default: true,
                enabled: true,
            },
            OptionItem {
                key: "vm",
                label: "Install a virtual machine",
                help: "VirtualBox or GNOME Boxes",
                default: false,
                enabled: false,
            },
        ];

        Self {
            screen: Screen::Checklist,
            options,
            cursor: 0,
            plan: Plan::default(),
            log: Vec::new(),
            summary_scroll: 0,
            run_index: 0,
            run_steps: Vec::new(),
            should_quit: false,
        }
    }

    fn toggle(&mut self) {
        if let Some(o) = self.options.get_mut(self.cursor) {
            o.enabled = !o.enabled;
        }
    }

    fn build_plan(&mut self) {
        let mut plan = Plan::default();
        let opts: Vec<(String, bool)> = self
            .options
            .iter()
            .map(|o| (o.key.to_string(), o.enabled))
            .collect();

        let mut gnome_installed = false;

        for (key, on) in &opts {
            if !*on {
                continue;
            }
            match key.as_str() {
                "gnome" => {
                    plan.add_pacman(&["gdm", "gnome"]);
                    plan.add_post("systemctl enable --now gdm");
                    gnome_installed = true;
                }
                "gnome_theme" => {
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
                        None => {}
                    }
                }
                "fonts" => plan.add_pacman(&[
                    "ttf-dejavu",
                    "ttf-liberation",
                    "ttf-arphic-ukai",
                    "ttf-arphic-uming",
                    "ttf-sazanami",
                    "noto-fonts",
                    "noto-fonts-emoji",
                    "noto-fonts-cjk",
                ]),
                "bluetooth" => plan.add_post("systemctl enable --now bluetooth"),
                "locale" => plan.add_post("localectl set-locale ru_RU.UTF-8"),
                "boot" => plan.add_post("sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf"),
                "devtools" => {
                    plan.add_pacman(&[
                        "pacman-contrib",
                        "btrfs-progs", "xfsprogs", "f2fs-tools", "exfatprogs", "udftools",
                        "ntfs-3g", "ntfsprogs", "dosfstools", "e2fsprogs", "cryptsetup",
                        "binwalk", "squashfs-tools", "mtd-utils", "uboot-tools",
                        "udisks2", "usbutils",
                        "gvfs", "fuse2", "fuse3",
                        "openssl", "nss",
                        "android-tools", "scrcpy",
                        "jhead", "pixman",
                        "jdk8-openjdk", "jre8-openjdk", "jre8-openjdk-headless",
                        "jdk-openjdk", "xorg-xrandr",
                        "git", "base-devel", "devtools", "fakeroot", "meson", "ninja",
                        "pkgconfig", "glib2", "libusb", "systemd-libs",
                        "gdk-pixbuf2", "cairo", "gcc",
                        "docker", "docker-compose",
                    ]);
                    plan.add_post("systemctl enable --now docker");
                }
                "flatpak" => {
                    if !command_exists("flatpak") {
                        plan.add_pacman(&["flatpak"]);
                    }
                    plan.add_post("flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo");
                    plan.add_flatpak(&[
                        "com.mattjakeman.ExtensionManager",
                        "org.polymc.PolyMC",
                        "org.chromium.Chromium",
                        "us.zoom.Zoom",
                    ]);
                }
                "firmware" => {
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
                "vm" => {
                    // Both options are always added; user can install one.
                    plan.add_pacman(&["virtualbox", "virtualbox-host-modules-arch", "gnome-boxes"]);
                    plan.add_post("groupadd -f vboxusers");
                    plan.add_post("modprobe vboxdrv");
                }
                _ => {}
            }
        }

        // If GNOME install is off but GNOME theme is on, we still add theme bits.
        // If GNOME install is on, the theme bits are already added above.
        let _ = gnome_installed;

        plan.dedup();
        self.plan = plan;

        // Build step list for the run screen
        let mut steps: Vec<String> = Vec::new();
        if !self.plan.pacman.is_empty() {
            steps.push(format!("pacman -S --noconfirm --needed {}", self.plan.pacman.join(" ")));
        }
        if !self.plan.flatpak.is_empty() {
            steps.push(format!("flatpak install --system -y flathub {}", self.plan.flatpak.join(" ")));
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
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(3)].as_ref())
        .split(f.size());

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

    let mut items: Vec<ListItem> = Vec::new();
    for (i, o) in app.options.iter().enumerate() {
        let mark = if o.enabled { "[x]" } else { "[ ]" };
        let label = format!(" {} {}", mark, o.label);
        let style = if i == app.cursor {
            Theme::selected_item()
        } else if o.enabled {
            Theme::normal_item()
        } else {
            Theme::dim_item()
        };
        items.push(ListItem::new(label).style(style));
    }

    let list_block = Block::default()
        .title(Span::styled(" Options ", Theme::block_title()))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let list = List::new(items).block(list_block);
    let mut st = ListState::default();
    st.select(Some(app.cursor));
    f.render_stateful_widget(list, chunks[1], &mut st);

    let help = app
        .options
        .get(app.cursor)
        .map(|o| o.help.to_string())
        .unwrap_or_default();

    let help_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());

    let help_widget = Paragraph::new(vec![
        Line::from(Span::styled(help, Style::default().fg(Color::Gray))),
        Line::from(Span::styled(
            "↑/↓ move  •  Space toggle  •  a = all on  •  n = all off  •  Enter = continue  •  q = quit",
            Style::default().fg(Color::DarkGray),
        )),
    ])
    .alignment(Alignment::Center)
    .block(help_block);
    f.render_widget(help_widget, chunks[2]);
}

fn draw_summary(f: &mut ratatui::Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(2)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(3)].as_ref())
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
        "Enter = install  •  Esc = back to options  •  ↑/↓ scroll  •  q = quit",
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
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(3)].as_ref())
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

fn draw_done(f: &mut ratatui::Frame, _app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(2)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(3)].as_ref())
        .split(f.size());

    let title_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::Green));

    let title = Paragraph::new(Line::from(vec![Span::styled(
        "Setup complete",
        Theme::good(),
    )]))
    .alignment(Alignment::Center)
    .block(title_block);
    f.render_widget(title, chunks[0]);

    let body = Paragraph::new(Line::from(Span::styled(
        "All requested steps have finished. Press Enter to exit.",
        Style::default().fg(Color::Gray),
    )))
    .alignment(Alignment::Center);
    f.render_widget(body, chunks[1]);

    let help_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Theme::dim_item());
    let help = Paragraph::new(Span::styled(
        "Enter = exit",
        Style::default().fg(Color::Gray),
    ))
    .alignment(Alignment::Center)
    .block(help_block);
    f.render_widget(help, chunks[2]);
}

fn draw(f: &mut ratatui::Frame, app: &App) {
    match app.screen {
        Screen::Checklist => draw_checklist(f, app),
        Screen::Summary => draw_summary(f, app),
        Screen::Running => draw_running(f, app),
        Screen::Done => draw_done(f, app),
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
                    KeyCode::Up | KeyCode::Char('k') => {
                        if app.cursor > 0 {
                            app.cursor -= 1;
                        }
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        if app.cursor + 1 < app.options.len() {
                            app.cursor += 1;
                        }
                    }
                    KeyCode::Char(' ') | KeyCode::Enter => {
                        if key.code == KeyCode::Enter {
                            app.build_plan();
                            app.screen = Screen::Summary;
                        } else {
                            app.toggle();
                        }
                    }
                    KeyCode::Char('a') => {
                        for o in &mut app.options {
                            o.enabled = true;
                        }
                    }
                    KeyCode::Char('n') => {
                        for o in &mut app.options {
                            o.enabled = false;
                        }
                    }
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
                    // Blocking run — handled after the draw
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
            // Temporarily leave the TUI so shell commands can print their own output
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
                        // continue with remaining steps
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

            // Drain any pending key events so a stray keypress doesn't
            // immediately dismiss the Done screen.
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
