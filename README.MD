# Cursor Installer for Linux 🐧

This script automatically downloads and installs the latest version of
[Cursor](https://www.cursor.com), an AI-first code editor, on Linux systems.

## 🚀 Features

- Determines which install version to fetch based on your architecture
- Fetches the latest x64 or ARM version directly from Cursor's official API
- Auto-detects missing shared libraries via ldd and installs mapped apt packages
- Installs required dependencies (FUSE, libgtk, etc.)
- Extracts the AppImage for direct execution
- Enables unprivileged user namespaces via permanent kernel sysctl where not already active (kernel 6.2+)
- Always applies setuid permissions to chrome-sandbox — Electron may prefer the setuid path even when user namespaces are available, and having both configured prevents launch failures after updates
- Creates a desktop shortcut and optional terminal command (cursor)


## 📦 Quick Install

Run this one-liner in your terminal:

```bash
bash <(curl -sL https://raw.githubusercontent.com/clynton/install-cursor/main/install.sh)
```

> ⚠️ You might be prompted for your password during installation (used for
> `sudo`).

Optional: `./install.sh --headless` skips the GUI runtime test; `./install.sh /path/to/Cursor-*.AppImage` installs from a local file.

## 🛠 Requirements

- Ubuntu or Debian-based Linux distro
- Internet connection
- `curl` (automatically installed if missing)
- Various system libraries (automatically installed if missing):
  - FUSE and related packages (fuse, libfuse2, fuse3, libfuse3-3)
  - Graphics libraries (libglx-mesa0, libegl1, libgbm1, libdrm2)
  - X11 libraries (libxcb-xinerama0, libxkbcommon-x11-0, libxss1, libxtst6)
  - GTK and system libraries (libgtk-3-0, libnotify4, libnss3, libatspi2.0-0)
  - Other utilities (xdg-utils)

## 📁 What it does

- Downloads the latest `Cursor-*.AppImage` based on the your architecture: x64 or ARM
- Makes it executable and pins it to `~/Applications/Cursor/Cursor.AppImage`
- Extracts to `~/Applications/Cursor/cursor-extracted` to fix sandbox permissions
- Creates `~/.local/bin/cursor` (adds `~/.local/bin` to PATH in `~/.bashrc` if needed)
- Creates a `.desktop` file for launching from the app menu with:
  - File associations for text files and directories
  - Proper application categorization
  - High-resolution icon integration
- So you can launch with `cursor` from the terminal
- Performs a test run to verify the installation

## 🐛 Troubleshooting

If the app doesn't run properly:

1. Check and install FUSE:

   ```bash
   sudo apt-get install fuse libfuse2 fuse3 libfuse3-3
   ```

2. Try launching manually:

   ```bash
   ~/Applications/Cursor/cursor-extracted/squashfs-root/AppRun
   ```

3. Check terminal output:
   ```bash
   ~/.local/bin/cursor
   ```

## 🔍 Installation Verification

The installer includes an automatic test run that will:

1. Launch Cursor in the background
2. Monitor its execution for 10 seconds
3. Provide feedback if the application exits unexpectedly

If you encounter any issues during installation, the script will attempt
alternative methods including:

- Trying different FUSE mounting approaches
- Searching for alternative chrome-sandbox locations
- Installing alternative package versions when needed

## 🛠 Notes
Auto-install is apt-based (Debian/Ubuntu).
If a missing .so is printed during verification and there’s no package mapping, add it to the so_to_apt_pkg() table in install.sh. Use `--headless` to skip the GUI runtime test.

## 🛠 Cleanup Procedure
The script prompts to delete all found Cursor AppImages/desktop files except:

If an AppImage path was provided: keeps that file (and the pinned install)

If no AppImage was provided: keeps only the pinned install ~/Applications/Cursor/Cursor.AppImage

Always keeps the installer-managed desktop entry ~/.local/share/applications/cursor.desktop

If the script is running non-interactively (no TTY), it will not delete anything automatically.

Examples: 
    Cursor-2.1.31-x86_64.AppImage
    Cursor-2.2.32-x86_64.AppImage
    Cursor-2.3.33-x86_64.AppImage
