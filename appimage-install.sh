#!/usr/bin/env bash
# appimage-install: Install an AppImage into ~/.local with desktop entry + icon extraction.
# Requires: p7zip (7z) or bsdtar. Optional: appimage-run, update-desktop-database.
set -euo pipefail

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
APPDIR="${HOME}/.local/share/applications"
ICONDIR="${HOME}/.local/share/icons"
DESTDIR="${HOME}/AppImages"

# ---------------------------------------------------------------------------
# ANSI colors (disabled automatically for non-terminals)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

# SC2059: never put variables in printf format strings — pass them as %s args instead.
# Tags padded to [ERROR] width so all messages align on the same column.
log()     { printf '%s[*]   %s %s\n' "$CYAN"   "$RESET" "$1"; }
success() { printf '%s[OK]  %s %s\n' "$GREEN"  "$RESET" "$1"; }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1"; }
error()   { printf '%s[ERR] %s %s\n' "$RED"    "$RESET" "$1" >&2; }
info()    { printf '%s[INFO]%s %s\n' "$BOLD"   "$RESET" "$1"; }

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
TMPWORK=""
cleanup() {
  [[ -n "$TMPWORK" && -d "$TMPWORK" ]] && rm -rf "$TMPWORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" &>/dev/null; }

make_tmpdir() {
  if have_cmd mktemp; then
    mktemp -d
  else
    local d="${TMPDIR:-/tmp}/appimage-install.$$"
    mkdir -p "$d"
    printf '%s' "$d"
  fi
}

# Derive a clean display name from a raw filename stem.
# OnlySend_0.1.1_amd64     →  OnlySend
# Signal-Desktop-6.2.0     →  Signal Desktop
# balenaEtcher-1.18.11-x64 →  balenaEtcher
# AppFlowy-0.5.5-linux      →  AppFlowy
clean_display_name() {
  local name="$1"
  # Strip common arch/OS suffixes (longer patterns first to avoid partial matches)
  local suffixes=(
    _x86_64 -x86_64 _amd64  -amd64
    _arm64  -arm64  _aarch64 -aarch64
    _i386   -i386   _i686   -i686
    _x64    -x64    _x32    -x32
    _linux  -linux  _Linux  -Linux
    _AppImage -AppImage
  )
  for s in "${suffixes[@]}"; do
    name="${name//${s}/}"
  done
  # Strip version-like segments: _0.1.2  _v2.3  -1.0.0  -v3  _0  etc.
  name="$(printf '%s' "$name" | sed -E 's/[_-][vV]?[0-9][^_-]*//g')"
  # Replace remaining _ and - with space, collapse runs, trim edges
  name="$(printf '%s' "$name" | tr '_-' '  ' | sed -E 's/  +/ /g' | sed -E 's/^ +| +$//')"
  printf '%s' "$name"
}

sanitize_id() {
  # Lowercase, replace non-alnum with '-', collapse runs, trim edges.
  # Input must be plain text — never pass colored strings here.
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Return a usable icon path, following symlinks. Empty if not found.
resolve_icon_path() {
  local p="$1" target
  [[ -n "$p" && ( -f "$p" || -L "$p" ) ]] || return 0
  target="$(readlink -f "$p" 2>/dev/null || true)"
  [[ -n "$target" && -f "$target" ]] || return 0
  case "${target,,}" in
    *.png|*.svg|*.xpm) printf '%s' "$target" ;;
  esac
}

# Icon= value from a root .desktop, then usr/share/applications/*.desktop.
desktop_icon_name() {
  local d="$1" desktop icon
  desktop="$(find "$d" -maxdepth 1 -name '*.desktop' \( -type f -o -type l \) 2>/dev/null \
    | sort | head -n1 || true)"
  if [[ -n "$desktop" ]]; then
    icon="$(grep -m1 '^Icon=' "$desktop" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    if [[ -n "$icon" && "$icon" != "application-x-executable" ]]; then
      printf '%s' "$icon"
      return
    fi
  fi
  desktop="$(find "$d" \( -path '*/usr/share/applications/*.desktop' -o -path '*/share/applications/*.desktop' \) \
    \( -type f -o -type l \) 2>/dev/null | sort | head -n1 || true)"
  if [[ -n "$desktop" ]]; then
    icon="$(grep -m1 '^Icon=' "$desktop" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    if [[ -n "$icon" && "$icon" != "application-x-executable" ]]; then
      printf '%s' "$icon"
    fi
  fi
}

# AppDir root icon file for a logical Icon= name (no extension per XDG spec).
root_icon_by_name() {
  local d="$1" name="$2" ext resolved
  for ext in png svg xpm; do
    resolved="$(resolve_icon_path "${d}/${name}.${ext}")"
    [[ -n "$resolved" ]] && printf '%s' "$resolved" && return
  done
}

# AppImage / AppDir spec: .DirIcon, then root icon matching desktop Icon=.
find_appdir_icon() {
  local d="$1" resolved icon_name
  resolved="$(resolve_icon_path "${d}/.DirIcon")"
  [[ -n "$resolved" ]] && printf '%s' "$resolved" && return

  icon_name="$(desktop_icon_name "$d")"
  if [[ -n "$icon_name" ]]; then
    resolved="$(root_icon_by_name "$d" "$icon_name")"
    [[ -n "$resolved" ]] && printf '%s' "$resolved"
  fi
}

# Rank hicolor size dirs: scalable > NxN (by pixel area).
hicolor_size_rank() {
  local segment="$1"
  if [[ "$segment" == "scalable" ]]; then
    printf '1000000'
  elif [[ "$segment" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    printf '%d' $(( BASH_REMATCH[1] * BASH_REMATCH[2] ))
  else
    printf '0'
  fi
}

# Best matching icon under */share/icons/*/apps/ (largest resolution wins).
find_hicolor_icon() {
  local d="$1" icon_name="${2:-}" path best="" best_rank=0 rank size_dir
  if [[ -z "$icon_name" ]]; then
    icon_name="$(desktop_icon_name "$d")"
  fi
  [[ -n "$icon_name" ]] || return 0

  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    size_dir="$(printf '%s' "$path" | sed -n 's|.*/share/icons/[^/]*/\([^/]*\)/apps/.*|\1|p')"
    rank="$(hicolor_size_rank "$size_dir")"
    if (( rank > best_rank )); then
      best_rank=$rank
      best="$path"
    fi
  done < <(find "$d" -type f -path '*/share/icons/*/apps/*' \
    \( -iname "${icon_name}.png" -o -iname "${icon_name}.svg" -o -iname "${icon_name}.xpm" \) \
    2>/dev/null | sort)

  [[ -n "$best" ]] && printf '%s' "$best"
}

# Last resort: any png/svg in the tree (alphabetically first).
first_icon_in_dir() {
  local d="$1"
  # head closes the pipe after one line; with pipefail that SIGPIPEs sort/find on
  # large trees (500+ icons). Swallow the pipeline status — empty output means none.
  find "$d" -type f \( -iname '*.png' -o -iname '*.svg' \) 2>/dev/null \
    | sort \
    | head -n1 \
    || true
}

# Search order: AppDir spec → hicolor theme → any icon file.
find_icon_in_payload() {
  local d="$1" found icon_name
  found="$(find_appdir_icon "$d")"
  [[ -n "$found" ]] && printf '%s' "$found" && return

  icon_name="$(desktop_icon_name "$d")"
  found="$(find_hicolor_icon "$d" "$icon_name")"
  [[ -n "$found" ]] && printf '%s' "$found" && return

  first_icon_in_dir "$d"
}

extract_appimage_payload() {
  local appimage="$1" outdir="$2"
  if have_cmd 7z; then
    7z x "$appimage" "-o${outdir}" &>/dev/null || true
  elif have_cmd bsdtar; then
    bsdtar -xf "$appimage" -C "$outdir" &>/dev/null || true
  else
    warn "No extractor found (7z / bsdtar). Skipping icon extraction."
  fi
}

# prompt_yn "Question [y/N]" — returns 0 for yes, 1 for no
# Reads directly from /dev/tty to avoid any subshell stdout capture issues.
prompt_yn() {
  local answer
  printf '%s%-6s%s %s ' "$YELLOW" "[?]" "$RESET" "$1" >/dev/tty
  read -r answer </dev/tty
  case "${answer,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

# prompt_value varname "Message" "default"
# Stores result in varname — avoids subshell so read works correctly.
prompt_value() {
  local _pv_var="$1" _pv_msg="$2" _pv_default="$3" _pv_answer
  printf '%s%-6s%s %s [%s]: ' "$YELLOW" "[?]" "$RESET" "$_pv_msg" "$_pv_default" >/dev/tty
  read -r _pv_answer </dev/tty
  # Assign to the caller's variable by name (no subshell needed)
  printf -v "$_pv_var" '%s' "${_pv_answer:-$_pv_default}"
}

usage() {
  printf '\n%sUsage:%s\n' "$BOLD" "$RESET"
  printf '  appimage-install <path/to/App.AppImage>\n\n'
}

# ---------------------------------------------------------------------------
# OS detection for targeted install hints
# ---------------------------------------------------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    printf '%s' "${ID:-unknown}"
  elif have_cmd uname; then
    printf '%s' "$(uname -s | tr '[:upper:]' '[:lower:]')"
  else
    printf '%s' "unknown"
  fi
}

# install_hint "pkg-nixos" "pkg-arch" "pkg-debian" "pkg-fedora"
# Prints a ready-to-run install command based on the detected OS.
install_hint() {
  local nix_pkg="$1" arch_pkg="$2" deb_pkg="$3" fed_pkg="$4"
  local os
  os="$(detect_os)"
  case "$os" in
    nixos)
      printf '  $ nix profile install nixpkgs#%s\n' "$nix_pkg" ;;
    arch|manjaro|endeavouros|garuda)
      printf '  $ sudo pacman -S %s\n' "$arch_pkg" ;;
    ubuntu|debian|linuxmint|pop)
      printf '  $ sudo apt install %s\n' "$deb_pkg" ;;
    fedora|rhel|centos|rocky|alma)
      printf '  $ sudo dnf install %s\n' "$fed_pkg" ;;
    opensuse*|sles)
      printf '  $ sudo zypper install %s\n' "$deb_pkg" ;;
    *)
      # Show all options when OS is unknown
      printf '  NixOS:  nix profile install nixpkgs#%s\n' "$nix_pkg"
      printf '  Arch:   sudo pacman -S %s\n' "$arch_pkg"
      printf '  Debian: sudo apt install %s\n' "$deb_pkg"
      printf '  Fedora: sudo dnf install %s\n' "$fed_pkg"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency detection
# ---------------------------------------------------------------------------
detect_extractor() {
  if have_cmd 7z;     then printf '7z';     return; fi
  if have_cmd bsdtar; then printf 'bsdtar'; return; fi
  printf ''
}

# Detects whether appimage-run is needed on this system.
needs_appimage_run() {
  # Explicitly set to empty → user opted out
  if [[ "${APPIMAGE_EXEC:-UNSET}" == "" ]]; then
    return 1
  fi
  # Explicitly set to a value → honor it
  if [[ "${APPIMAGE_EXEC:-UNSET}" != "UNSET" ]]; then
    return 0
  fi
  # Auto-detect: NixOS
  if [[ -f /etc/os-release ]] && grep -qi 'nixos' /etc/os-release; then
    return 0
  fi
  # Auto-detect: missing dynamic linker (immutable/container systems)
  local ld
  ld=$(find /lib /lib64 -maxdepth 1 -name 'ld-linux*' 2>/dev/null | head -n1 || true)
  [[ -z "$ld" ]]
}

check_dependencies() {
  local missing_critical=() missing_optional=()

  # --- appimage-run (conditional) ---
  if needs_appimage_run; then
    APPIMAGE_EXEC="${APPIMAGE_EXEC:-appimage-run}"
    if ! have_cmd "$APPIMAGE_EXEC"; then
      missing_critical+=("appimage-run")
    fi
  else
    APPIMAGE_EXEC=""
  fi

  # --- extractor ---
  if [[ -z "$(detect_extractor)" ]]; then
    missing_optional+=("p7zip")
  fi

  # --- Critical: must have to continue ---
  if [[ ${#missing_critical[@]} -gt 0 ]]; then
    printf '\n'
    error "Missing required dependency: appimage-run"
    printf '\n'
    warn  "On this system, AppImages cannot run without appimage-run."
    warn  "Install it with:"
    printf '\n'
    install_hint "appimage-run" "appimage-run" "appimage-run" "appimage-run" | while IFS= read -r line; do
      info "$line"
    done
    printf '\n'
    if prompt_yn "Continue anyway and fix Exec= manually later? [y/N]"; then
      warn "Proceeding. Remember to fix Exec= in the generated .desktop file."
    else
      exit 1
    fi
  fi

  # --- Optional: warn but never block ---
  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    warn "p7zip not found — icon extraction will be skipped."
    warn "Install with:"
    install_hint "p7zip" "p7zip" "p7zip-full" "p7zip" | while IFS= read -r line; do
      warn "  ${line}"
    done
    printf '\n'
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ $# -lt 1 ]]; then
    error "No AppImage file provided."
    usage
    exit 1
  fi

  local appimage="$1"
  if [[ ! -f "$appimage" ]]; then
    error "File not found: ${appimage}"
    exit 1
  fi

  # Make path absolute
  appimage="$(cd "$(dirname "$appimage")" && pwd)/$(basename "$appimage")"

  printf '\n%sAppImage Installer%s\n' "$BOLD" "$RESET"
  printf '%s\n\n' "──────────────────"

  check_dependencies

  # --- Derive a clean default name from the filename ---
  local filename stem default_name display_name file_id
  filename="$(basename "$appimage")"
  stem="${filename%%.*}"                       # drop extension(s): foo.AppImage → foo
  default_name="$(clean_display_name "$stem")" # strip version/arch: FooBar_0.1_amd64 → FooBar

  # --- Prompt for display name — using prompt_value to avoid subshell issues ---
  prompt_value display_name "Application name (for system menus)" "$default_name"
  [[ -z "$display_name" ]] && display_name="$default_name"

  file_id="$(sanitize_id "$display_name")"
  [[ -z "$file_id" ]] && file_id="$(sanitize_id "$default_name")"

  local dest_appimage="${DESTDIR}/${file_id}.AppImage"
  local desktop_file="${APPDIR}/${file_id}.desktop"

  printf '\n'
  log "Name     : ${display_name}"
  log "ID       : ${file_id}"
  log "AppImage : ${dest_appimage}"
  log "Desktop  : ${desktop_file}"
  printf '\n'

  mkdir -p "$APPDIR" "$ICONDIR" "$DESTDIR"

  # --- Make executable ---
  if [[ ! -x "$appimage" ]]; then
    chmod +x "$appimage"
    success "Made executable: ${appimage}"
  fi

  # --- Move / rename ---
  if [[ "$appimage" != "$dest_appimage" ]]; then
    if [[ -f "$dest_appimage" ]]; then
      error "'${file_id}.AppImage' already exists in ${DESTDIR}."
      if prompt_yn "Overwrite? [y/N]"; then
        rm -f "$dest_appimage"
      else
        exit 1
      fi
    fi
    mv "$appimage" "$dest_appimage"
    success "Moved to: ${dest_appimage}"
  else
    success "AppImage already in the correct location."
  fi

  [[ ! -x "$dest_appimage" ]] && chmod +x "$dest_appimage"

  # --- Extract icon ---
  local icon_path="${file_id}"
  log "Extracting icon from AppImage..."
  TMPWORK="$(make_tmpdir)"
  extract_appimage_payload "$dest_appimage" "$TMPWORK"

  local found_icon
  found_icon="$(find_icon_in_payload "$TMPWORK")"

  if [[ -n "$found_icon" && -f "$found_icon" ]]; then
    local ext="${found_icon##*.}"
    cp "$found_icon" "${ICONDIR}/${file_id}.${ext}"
    icon_path="${ICONDIR}/${file_id}.${ext}"
    success "Icon saved: ${icon_path}"
  else
    warn "No icon found — using name as icon fallback."
  fi

  # --- Build Exec line ---
  local exec_line
  if [[ -n "$APPIMAGE_EXEC" ]]; then
    exec_line="${APPIMAGE_EXEC} \"${dest_appimage}\""
  else
    exec_line="\"${dest_appimage}\""
  fi

  # --- Write .desktop ---
  cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=${display_name}
Exec=${exec_line}
Icon=${icon_path}
Type=Application
Categories=Utility;
Terminal=false
StartupNotify=true
EOF
  success ".desktop created: ${desktop_file}"

  # --- Optionally edit .desktop ---
  printf '\n'
  if prompt_yn "Open the .desktop file in your editor? [y/N]"; then
    local editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
      for e in nano vim vi micro; do
        if have_cmd "$e"; then editor="$e"; break; fi
      done
    fi
    if [[ -n "$editor" ]] && have_cmd "$editor"; then
      "$editor" "$desktop_file" </dev/tty
    else
      warn "No suitable editor found. Set \$EDITOR to your preferred editor."
    fi
  fi

  # --- Update desktop database ---
  if have_cmd update-desktop-database; then
    update-desktop-database "$APPDIR" &>/dev/null || true
    log "Desktop database updated."
  fi

  printf '\n'
  success "${display_name} installed and integrated successfully."
}

main "$@"
