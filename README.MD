# Cursor Installer for Linux 🐧

Installs the latest stable [Cursor](https://www.cursor.com) on Linux using the official AppImage.

## 🚀 Features

- Fetches the latest **stable** Cursor release using Cursor’s official API:
  - `https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable`
- Downloads the AppImage with `curl -L` (follows redirects)
- Pins the AppImage into the user’s home:
  - `~/Applications/Cursor/Cursor.AppImage`
- Extracts the AppImage into a **stable** directory and launches via `AppRun`:
  - `~/Applications/Cursor/cursor-extracted/squashfs-root/AppRun`
  - This avoids many FUSE/mount issues common with AppImages
- Attempts to fix Chromium sandbox issues by fixing `chrome-sandbox` permissions (best-effort):
  - `root:root` ownership + `4755` mode
- Creates:
  - Desktop launcher: `~/.local/share/applications/cursor.desktop`
  - Icon: `~/.local/share/icons/cursor.png`
  - CLI wrapper: `~/.local/bin/cursor` (adds PATH line to `~/.bashrc` if missing)
- Best-effort auto-install of missing shared library packages on Debian/Ubuntu (`apt-get`) by detecting loader errors.

## 📦 Install

Recommended (installs system deps cleanly, but installs Cursor into the invoking user’s home):

```bash
sudo ./installer.sh
