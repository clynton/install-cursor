#!/usr/bin/env bash
set -euo pipefail

# =====================================================================================================================================
# Cursor install/update (AppImage) for Linux - ARM / x64 !
# This script handles the complete user-level install/update process for cursor. i.e. won't install as root just because sudo given
#
# Usage:
#       # asks for sudo permission to install missing system dependencies (curl, FUSE libs, etc.)
#       # useful if all dependencies are already installed
#   ./install.sh
#
# Also works:
#       # useful when run for the first time to install dependencies
#   sudo ./install.sh
#
# Optional
#       # install a cursor version you downloaded
#   sudo ./install.sh /path/to/Cursor-*.AppImage
#
# Default behavior:
#   - does ldd-based dependency fix/verify
#   - then does an interactive runtime test: launches Cursor briefly and kills it (~10s)
#
# Headless behavior (add to skip GUI launch):
#   --headless   -> skips runtime launch test; keeps ldd-only verify
#
# It will:
#   - Detect your system architecture (x64 or ARM) and download the latest stable Linux AppImage automatically
#   - Pin the AppImage to: ~/Applications/Cursor/Cursor.AppImage
#   - Create ~/.local/bin/cursor (runs with sandbox first, falls back to --no-sandbox; if FUSE missing, extract+run)
#   - Create or update the launcher entry with a fixed icon so it appears in the app panel
#   - Clean up any stray squashfs-root folders left by AppImage extraction
#
# Key Behavior:
#   - If run with sudo, system packages are installed as root, but Cursor + desktop entry + icon are installed
#     into the invoking user's home so the launcher appears for that user.
#   - If run without sudo, the script will use sudo for system packages when needed (prompts to auth as sudo at that point).
#   - Attempts to detect missing shared libraries and installs the mapped apt packages
# =====================================================================================================================================

unset APPIMAGE_EXTRACT_AND_RUN
unset APPIMAGE_SILENT_INSTALL
export APPIMAGE_SILENT_INSTALL=1

log(){ echo "$@" >&2; }
die(){ log "ERROR: $*"; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

HEADLESS=0
APPIMAGE_INPUT=""

# -----------------------------
# Args
# -----------------------------
for arg in "$@"; do
  case "$arg" in
    --headless) HEADLESS=1 ;;
    --help|-h)
      cat >&2 <<EOF
Usage:
  sudo ./install.sh [--headless] [/path/to/Cursor.AppImage]

--headless  Skip GUI runtime test; do ldd-only verification.
EOF
      exit 0
      ;;
    *)
      if [[ -z "$APPIMAGE_INPUT" && -f "$arg" ]]; then
        APPIMAGE_INPUT="$arg"
      else
        die "Unknown arg or file not found: $arg"
      fi
      ;;
  esac
done

EUID_NUM="${EUID:-$(id -u)}"

# -----------------------------
# Target user/home
# -----------------------------
if [[ "$EUID_NUM" -eq 0 ]]; then
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] || die "Run via sudo from the target user session."
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$(id -un)"
fi

if have_cmd getent; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
else
  TARGET_HOME=""
fi
if [[ -z "${TARGET_HOME:-}" ]]; then
  TARGET_HOME="$(eval echo "~${TARGET_USER}")"
fi
[[ -d "$TARGET_HOME" ]] || die "Cannot resolve home for: $TARGET_USER"

# -----------------------------
# Paths (user-scoped)
# -----------------------------
BASE_DIR="$TARGET_HOME/Applications/Cursor"
STABLE_APPIMAGE="$BASE_DIR/Cursor.AppImage"
EXTRACT_DIR="$BASE_DIR/cursor-extracted"
APP_RUN="$EXTRACT_DIR/squashfs-root/AppRun"

BIN_DIR="$TARGET_HOME/.local/bin"
WRAPPER="$BIN_DIR/cursor"

DESKTOP_DIR="$TARGET_HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/cursor.desktop"

ICON_DIR="$TARGET_HOME/.local/share/icons"
ICON_FILE="$ICON_DIR/cursor.png"

# Keep-file decisions for cleanup
KEEP_APPIMAGE_PRE=""   # resolved input AppImage path (if provided)
KEEP_APPIMAGE_POST=""  # pinned AppImage after install
KEEP_DESKTOP_POST="$DESKTOP_FILE"  # always keep installer-managed desktop

# -----------------------------
# Privilege helper
# -----------------------------
as_root(){
  if [[ "$EUID_NUM" -eq 0 ]]; then
    bash -lc "$*"
  else
    have_cmd sudo || die "sudo required for: $*"
    sudo bash -lc "$*"
  fi
}

# -----------------------------
# Setup helpers
# -----------------------------
ensure_dirs(){
  mkdir -p "$BASE_DIR" "$EXTRACT_DIR" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
  if [[ "$EUID_NUM" -eq 0 ]]; then
    chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.local" "$TARGET_HOME/Applications" 2>/dev/null || true
  fi
}

ensure_curl(){
  if have_cmd curl; then return 0; fi
  have_cmd apt-get || die "curl missing and apt-get not available."
  log "curl not found; installing curl..."
  # apt output must not go to stdout
  as_root "apt-get update -y 1>&2 && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates 1>&2"
  have_cmd curl || die "curl install failed."
}

detect_platform(){
  case "$(uname -m)" in
    x86_64) PLATFORM="linux-x64" ;;
    aarch64|arm64) PLATFORM="linux-arm64" ;;
    *) die "Unsupported architecture." ;;
  esac
}

# -----------------------------
# Cursor API + download
# -----------------------------
get_latest(){
  # stdout ONLY: url|version
  ensure_curl
  detect_platform

  local json url ver
  json="$(curl -fsSL "https://www.cursor.com/api/download?platform=${PLATFORM}&releaseTrack=stable")"

  url="$(printf '%s' "$json" \
    | sed -n 's/.*"downloadUrl":"\([^"]*\)".*/\1/p' \
    | head -n1 \
    | sed 's/\\u0026/\&/g; s#\\/#/#g' \
    | tr -d '\r')"

  ver="$(printf '%s' "$json" \
    | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' \
    | head -n1 \
    | tr -d '\r')"

  [[ -n "${url:-}" && -n "${ver:-}" ]] || die "API parse failed."
  printf '%s|%s\n' "$url" "$ver"
}

download_appimage(){
  local url="$1"
  local tmp out
  tmp="$(mktemp -d)"
  out="$tmp/Cursor.AppImage"

  log "Downloading AppImage..."
  curl -fL --globoff --retry 3 --retry-delay 1 -o "$out" "$url"
  [[ -s "$out" ]] || { rm -rf "$tmp"; die "Download failed (empty file)."; }
  printf '%s\n' "$out"
}

pin_appimage(){
  local src="$1"
  mv -f "$src" "$STABLE_APPIMAGE"
  chmod +x "$STABLE_APPIMAGE"
  if [[ "$EUID_NUM" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$STABLE_APPIMAGE" 2>/dev/null || true
  fi
  KEEP_APPIMAGE_POST="$STABLE_APPIMAGE"
}

extract_stable(){
  rm -rf "$EXTRACT_DIR" 2>/dev/null || true
  mkdir -p "$EXTRACT_DIR"
  ( cd "$EXTRACT_DIR" && "$STABLE_APPIMAGE" --appimage-extract >/dev/null )
  [[ -x "$APP_RUN" ]] || die "Extraction failed."
}

fix_sandbox(){
  log "Attempting Chrome sandbox permission fix (best-effort)..."
  local sb="$EXTRACT_DIR/squashfs-root/usr/share/cursor/chrome-sandbox"

  if [[ ! -f "$sb" ]]; then
    sb="$(find "$EXTRACT_DIR/squashfs-root" -name "chrome-sandbox" 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "${sb:-}" && -f "$sb" ]] || { log "Warning: chrome-sandbox not found."; return 0; }

  as_root "chown root:root '$sb' 2>/dev/null || true"
  as_root "chmod 4755 '$sb' 2>/dev/null || true"

  if [[ "$sb" == "$EXTRACT_DIR/squashfs-root/usr/share/cursor/chrome-sandbox" ]]; then
    log "Chrome sandbox permissions fixed (expected path)."
  else
    log "Chrome sandbox permissions fix attempted (alternate path)."
  fi
}

copy_icon(){
  local icon
  icon="$(find "$EXTRACT_DIR/squashfs-root" -path "*/icons/hicolor/256x256/apps/*" -name "cursor.png" 2>/dev/null | head -n1 || true)"
  if [[ -z "${icon:-}" ]]; then
    icon="$(find "$EXTRACT_DIR/squashfs-root" -name "cursor.png" 2>/dev/null | head -n1 || true)"
  fi
  if [[ -n "${icon:-}" && -f "$icon" ]]; then
    cp -f "$icon" "$ICON_FILE"
    if [[ "$EUID_NUM" -eq 0 ]]; then
      chown "$TARGET_USER":"$TARGET_USER" "$ICON_FILE" 2>/dev/null || true
    fi
  else
    log "Warning: cursor.png not found in extracted tree."
  fi
}

write_wrapper(){
  cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/Applications/Cursor/cursor-extracted/squashfs-root/AppRun" "$@"
EOF
  chmod +x "$WRAPPER"
  if [[ "$EUID_NUM" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$WRAPPER" 2>/dev/null || true
  fi
}

write_desktop(){
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Cursor
Comment=AI-first code editor
Exec=$WRAPPER %U
Icon=$ICON_FILE
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=Cursor
MimeType=text/plain;inode/directory;
EOF
  if [[ "$EUID_NUM" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$DESKTOP_FILE" 2>/dev/null || true
  fi
  if have_cmd update-desktop-database; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
  fi
}

ensure_path(){
  local bashrc="$TARGET_HOME/.bashrc"
  local line='export PATH="$HOME/.local/bin:$PATH"'
  if [[ -f "$bashrc" ]] && grep -Fxq "$line" "$bashrc"; then
    return 0
  fi
  echo "$line" >> "$bashrc"
  if [[ "$EUID_NUM" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$bashrc" 2>/dev/null || true
  fi
}

# -----------------------------
# Dependency fix/verify (ldd-based)
# -----------------------------
so_to_apt_pkg() {
  local so="$1"
  case "$so" in
    libfuse.so.2) echo "libfuse2" ;;
    libfuse.so.3) echo "libfuse3-3" ;;
    libgbm.so.1) echo "libgbm1" ;;
    libasound.so.2) echo "libasound2" ;;
    libatk-1.0.so.0) echo "libatk1.0-0" ;;
    libatk-bridge-2.0.so.0) echo "libatk-bridge2.0-0" ;;
    libcups.so.2) echo "libcups2" ;;
    libdrm.so.2) echo "libdrm2" ;;
    libnss3.so) echo "libnss3" ;;
    libnspr4.so) echo "libnspr4" ;;
    libxkbcommon.so.0) echo "libxkbcommon0" ;;
    libxss.so.1) echo "libxss1" ;;
    libxtst.so.6) echo "libxtst6" ;;
    libx11-xcb.so.1) echo "libx11-xcb1" ;;
    libxcb.so.1) echo "libxcb1" ;;
    libxcb-xinerama.so.0) echo "libxcb-xinerama0" ;;
    libxcb-dri3.so.0) echo "libxcb-dri3-0" ;;
    libgtk-3.so.0) echo "libgtk-3-0" ;;
    libnotify.so.4) echo "libnotify4" ;;
    libatspi.so.0) echo "libatspi2.0-0" ;;
    libdbus-1.so.3) echo "libdbus-1-3" ;;
    libexpat.so.1) echo "libexpat1" ;;
    libssl.so.1.1|libcrypto.so.1.1) echo "libssl1.1" ;;
    libssl.so.3|libcrypto.so.3) echo "libssl3" ;;
    *) echo "" ;;
  esac
}

apt_install_pkgs() {
  have_cmd apt-get || return 0
  local pkgs=("$@")
  ((${#pkgs[@]}==0)) && return 0
  as_root "apt-get update -y 1>&2 && DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]} 1>&2" || true
}

collect_missing_sos_from_ldd() {
  have_cmd ldd || return 0
  local -a bins=(
    "$EXTRACT_DIR/squashfs-root/usr/share/cursor/bin/cursor"
    "$EXTRACT_DIR/squashfs-root/usr/share/cursor/cursor"
    "$EXTRACT_DIR/squashfs-root/usr/share/cursor/chrome_crashpad_handler"
    "$EXTRACT_DIR/squashfs-root/usr/share/cursor/bin/code-tunnel"
  )

  for b in "${bins[@]}"; do
    [[ -x "$b" ]] || continue
    ldd "$b" 2>/dev/null | awk '/not found/{print $1}' || true
  done
}

auto_fix_missing_libs_from_ldd() {
  have_cmd apt-get || return 0
  have_cmd ldd || return 0

  local max_rounds="${1:-3}"
  local round=1

  while (( round <= max_rounds )); do
    local -a missing_sos=()
    local -a pkgs=()

    mapfile -t missing_sos < <(collect_missing_sos_from_ldd | awk 'NF{print}' | sort -u)
    ((${#missing_sos[@]}==0)) && return 0

    for so in "${missing_sos[@]}"; do
      pkg="$(so_to_apt_pkg "$so")"
      [[ -n "${pkg:-}" ]] && pkgs+=("$pkg")
    done
    mapfile -t pkgs < <(printf "%s\n" "${pkgs[@]}" | awk 'NF{print}' | sort -u)

    if ((${#pkgs[@]}==0)); then
      log "Missing libs detected but no known apt mapping:"
      printf ' - %s\n' "${missing_sos[@]}" >&2
      return 0
    fi

    log "Installing packages for missing libs (round $round/$max_rounds):"
    printf ' - %s\n' "${missing_sos[@]}" >&2
    apt_install_pkgs "${pkgs[@]}"

    mapfile -t missing_sos < <(collect_missing_sos_from_ldd | awk 'NF{print}' | sort -u)
    ((${#missing_sos[@]}==0)) && return 0

    round=$((round+1))
  done
}

verify_ldd() {
  log "Verifying dependencies via ldd..."
  have_cmd ldd || { log "ldd not available; skipping shared-lib verification."; return 0; }

  local -a missing_sos=()
  mapfile -t missing_sos < <(collect_missing_sos_from_ldd | awk 'NF{print}' | sort -u)
  if ((${#missing_sos[@]}==0)); then
    log "OK: dependency check passed (no missing libs via ldd)."
  else
    log "Warning: missing libs still present:"
    printf ' - %s\n' "${missing_sos[@]}" >&2
  fi
}

# -----------------------------
# Runtime test (interactive default)
# -----------------------------
runtime_test_background_kill() {
  log "Runtime test: launching Cursor briefly (10s) then killing it..."

  have_cmd setsid || { log "setsid not available; skipping runtime test."; return 0; }
  [[ -x "$APP_RUN" ]] || { log "AppRun missing; skipping runtime test."; return 0; }

  # Start in new session/process group
  setsid "$APP_RUN" >/dev/null 2>&1 &
  local pid=$!

  # Let it initialize
  sleep 10

  # Kill entire process group if still alive
  if kill -0 "$pid" 2>/dev/null; then
    log "Runtime test: Cursor stayed running; killing test instance..."
    kill -TERM "-$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "-$pid" 2>/dev/null || true
  else
    log "Runtime test: Cursor exited before 10s (check environment if launch issues persist)."
  fi

  wait "$pid" 2>/dev/null || true
  log "Runtime test complete."
}

# -----------------------------
# Duplicate scan + optional deletion (no version/time reliance)
# -----------------------------
scan_duplicates() {
  find "$TARGET_HOME" -maxdepth 4 -type f \( -iname "*cursor*.AppImage" -o -iname "*cursor*.desktop" \) 2>/dev/null || true
}

cleanup_duplicates_confirmed() {
  # Keep decision:
  # - If pinned AppImage exists, keep it (pre-scan and post-scan)
  # - Else if post is known, keep it
  # - Else if pre is known, keep it
  local keep_img=""
  if [[ -f "$STABLE_APPIMAGE" ]]; then
    keep_img="$STABLE_APPIMAGE"
  elif [[ -n "${KEEP_APPIMAGE_POST:-}" ]]; then
    keep_img="$KEEP_APPIMAGE_POST"
  elif [[ -n "${KEEP_APPIMAGE_PRE:-}" ]]; then
    keep_img="$KEEP_APPIMAGE_PRE"
  fi

  local found
  found="$(scan_duplicates)"
  [[ -n "${found:-}" ]] || { log "No Cursor AppImages/desktop files found under scan."; return 0; }

  # Build candidate list (exclude keep targets)
  local candidates=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue

    if [[ -n "${keep_img:-}" && "$f" == "$keep_img" ]]; then
      continue
    fi
    if [[ -n "${KEEP_DESKTOP_POST:-}" && "$f" == "$KEEP_DESKTOP_POST" ]]; then
      continue
    fi

    case "${f,,}" in
      *.appimage|*.desktop) candidates+="$f"$'\n' ;;
    esac
  done <<< "$found"

  [[ -n "${candidates:-}" ]] || { log "No duplicates to delete."; return 0; }

  log "Found Cursor-related files:"
  printf '%s\n' "$found" >&2
  log "Keep AppImage: ${keep_img:-"(none)"}"
  log "Keep desktop:  ${KEEP_DESKTOP_POST:-"(none)"}"
  log "Deletion candidates:"
  printf '%s' "$candidates" >&2

  [[ -t 0 ]] || { log "Non-interactive shell detected; skipping deletion."; return 0; }

  echo -n "Delete the candidates listed above? (y/N): " >&2
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) log "Skipping deletion."; return 0 ;;
  esac

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    log "Deleting: $f"
    rm -f -- "$f" 2>/dev/null || true
  done <<< "$candidates"
}

resolve_input_path_if_any() {
  [[ -n "${APPIMAGE_INPUT:-}" ]] || return 0
  [[ -f "$APPIMAGE_INPUT" ]] || die "File not found: $APPIMAGE_INPUT"

  if have_cmd realpath; then
    KEEP_APPIMAGE_PRE="$(realpath "$APPIMAGE_INPUT")"
  else
    KEEP_APPIMAGE_PRE="$APPIMAGE_INPUT"
  fi
}

# -----------------------------
# Main
# -----------------------------
main(){
  ensure_dirs
  resolve_input_path_if_any

  log "Pre-scan for existing Cursor instances (before install):"
  cleanup_duplicates_confirmed || true

  local app tmp=""
  if [[ -n "$APPIMAGE_INPUT" ]]; then
    app="$APPIMAGE_INPUT"
  else
    api="$(get_latest)"
    url="${api%%|*}"
    ver="${api##*|}"
    log "Latest Cursor version: $ver"
    app="$(download_appimage "$url")"
    tmp="$(dirname "$app")"
  fi

  pin_appimage "$app"
  [[ -n "$tmp" ]] && rm -rf "$tmp" 2>/dev/null || true

  extract_stable
  fix_sandbox
  copy_icon

  auto_fix_missing_libs_from_ldd 3 || true
  verify_ldd

  write_wrapper
  ensure_path
  write_desktop

  # Default: interactive runtime test (brief launch + kill).
  # Headless: skip runtime test entirely.
  if [[ "$HEADLESS" -eq 0 ]]; then
    runtime_test_background_kill || true
  else
    log "Headless mode: skipping runtime test."
  fi

  log "Post-scan for existing Cursor instances (after install):"
  cleanup_duplicates_confirmed || true

  log "Done."
  log "Target user:     $TARGET_USER"
  log "AppImage:        $STABLE_APPIMAGE"
  log "Extracted:       $EXTRACT_DIR"
  log "CLI command:     $WRAPPER"
  log "Desktop entry:   $DESKTOP_FILE"
}

main
