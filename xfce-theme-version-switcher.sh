#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
PANEL_XML="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
IMPORT_LINE='@import url("widgets/xfce-4-20-patch.css");'

# You can override this if your Whisker plugin is not plugin-1:
# WHISKER_PLUGIN_ID=7 ./xfce-theme-version-switcher.sh
WHISKER_PLUGIN_ID="${WHISKER_PLUGIN_ID:-1}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
ASSET_DIR="${SCRIPT_DIR}/assets"
BLANK_PNG="${ASSET_DIR}/Blank.png"

ts() { date +"%Y%m%d-%H%M%S"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  local safe
  safe="$(printf '%s' "$f" | sed 's|/|__|g')"
  local out="${BACKUP_DIR}/${safe}.bak.$(ts)"
  cp -a -- "$f" "$out"
  echo "Backup created: $out"
}

create_blank_png() {
  mkdir -p "$ASSET_DIR"

  # 40x40 fully transparent PNG (base64)
  local b64='iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAHElEQVR4nO3BAQEAAACCIP+vbkhAAQAAAAAAfBoZKAABYJ0ZdgAAAABJRU5ErkJggg=='

  if command -v base64 >/dev/null 2>&1; then
    # GNU coreutils: base64 -d ; some systems also accept --decode
    printf '%s' "$b64" | base64 -d > "$BLANK_PNG" 2>/dev/null || \
    printf '%s' "$b64" | base64 --decode > "$BLANK_PNG"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import base64, pathlib
b64 = "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAHElEQVR4nO3BAQEAAACCIP+vbkhAAQAAAAAAfBoZKAABYJ0ZdgAAAABJRU5ErkJggg=="
out = pathlib.Path("'"$BLANK_PNG"'")
out.write_bytes(base64.b64decode(b64))
PY
  else
    echo "ERROR: Neither 'base64' nor 'python3' is available to create Blank.png."
    exit 1
  fi

  chmod 0644 "$BLANK_PNG"
  echo "Created transparent 40x40 placeholder icon: $BLANK_PNG"
}

detect_theme_name() {
  local t=""
  if have_cmd xfconf-query; then
    t="$(xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null || true)"
  fi
  if [[ -z "${t}" ]] && have_cmd gsettings; then
    t="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'" || true)"
  fi
  echo "$t"
}

find_theme_dir() {
  local theme_name="$1"
  local candidates=(
    "${HOME}/.themes/${theme_name}"
    "${HOME}/.local/share/themes/${theme_name}"
    "/usr/local/share/themes/${theme_name}"
    "/usr/share/themes/${theme_name}"
  )
  for d in "${candidates[@]}"; do
    [[ -d "$d/gtk-3.0" ]] && { echo "$d"; return 0; }
  done
  return 1
}

ensure_theme_dir() {
  local theme_name theme_dir
  theme_name="$(detect_theme_name)"

  if [[ -n "$theme_name" ]] && theme_dir="$(find_theme_dir "$theme_name" 2>/dev/null)"; then
    echo "$theme_dir"
    return 0
  fi

  echo "Could not automatically locate the active GTK theme directory."
  echo "Please enter the path to your theme folder (it must contain 'gtk-3.0/')."
  read -r -p "Theme path: " theme_dir
  if [[ ! -d "$theme_dir/gtk-3.0" ]]; then
    echo "ERROR: '$theme_dir' does not contain 'gtk-3.0/'. Aborting."
    exit 1
  fi
  echo "$theme_dir"
}

xfconf_set_string() {
  local key="$1"
  local value="$2"
  xfconf-query -c xfce4-panel -p "$key" -s "$value" 2>/dev/null || \
  xfconf-query -c xfce4-panel -p "$key" -t string -s "$value" --create 2>/dev/null || true
}

set_whisker_properties() {
  local mode="$1"  # "xfce420" or "xfce418"

  if ! have_cmd xfconf-query; then
    echo "ERROR: xfconf-query not found. This script requires xfconf-query for reliable operation."
    exit 1
  fi

  local title_key="/plugins/plugin-${WHISKER_PLUGIN_ID}/button-title"
  local icon_key="/plugins/plugin-${WHISKER_PLUGIN_ID}/button-icon"

  # Validate that the keys exist; if not, try to auto-detect a plugin id.
  if ! xfconf-query -c xfce4-panel -p "$title_key" >/dev/null 2>&1; then
    echo "WARNING: $title_key not found. Trying to auto-detect whisker plugin id..."
    local found
    found="$(xfconf-query -c xfce4-panel -l 2>/dev/null | grep -E '/plugins/plugin-[0-9]+/button-title$' | head -n1 || true)"
    if [[ -n "$found" ]]; then
      WHISKER_PLUGIN_ID="$(printf '%s' "$found" | sed -n 's|^/plugins/plugin-\([0-9]\+\)/button-title$|\1|p')"
      title_key="/plugins/plugin-${WHISKER_PLUGIN_ID}/button-title"
      icon_key="/plugins/plugin-${WHISKER_PLUGIN_ID}/button-icon"
      echo "Auto-detected plugin id: ${WHISKER_PLUGIN_ID}"
    else
      echo "ERROR: Could not find any /button-title keys in xfce4-panel."
      exit 1
    fi
  fi

  if [[ "$mode" == "xfce420" ]]; then
    create_blank_png

    # EXACTLY one space for the title
    xfconf_set_string "$title_key" "$(printf ' ')"

    # Set icon to an absolute path to Blank.png
    xfconf_set_string "$icon_key" "$BLANK_PNG"

    echo "xfconf: set:"
    echo "  $title_key = [ ] (one space)"
    echo "  $icon_key  = [$BLANK_PNG]"
  else
    # Restore 4.18-ish behavior: empty values
    xfconf_set_string "$title_key" ""
    xfconf_set_string "$icon_key"  ""

    echo "xfconf: restored:"
    echo "  $title_key = []"
    echo "  $icon_key  = []"
  fi
}

add_import_line() {
  local gtkcss="$1"
  backup_file "$gtkcss"

  if grep -Fqx "$IMPORT_LINE" "$gtkcss"; then
    echo "gtk.css: import line is already present."
    return 0
  fi

  if [[ -n "$(tail -c 1 "$gtkcss" 2>/dev/null || true)" ]]; then
    echo >> "$gtkcss"
  fi
  echo "$IMPORT_LINE" >> "$gtkcss"
  echo "gtk.css: added import: $IMPORT_LINE"
}

remove_import_line() {
  local gtkcss="$1"
  backup_file "$gtkcss"

  if ! grep -Fq "$IMPORT_LINE" "$gtkcss"; then
    echo "gtk.css: import line not present (nothing to remove)."
    return 0
  fi

  perl -i -ne 'print unless /^\s*\@import\s+url\("widgets\/xfce-4-20-patch\.css"\);\s*$/' "$gtkcss"
  echo "gtk.css: removed import: $IMPORT_LINE"
}

restart_panel() {
  if have_cmd xfce4-panel; then
    xfce4-panel -r >/dev/null 2>&1 || true
    echo "Panel restarted (xfce4-panel -r)."
  else
    echo "Note: xfce4-panel not found — please restart the panel manually."
  fi
}

status() {
  echo "----- STATUS -----"
  echo "Script dir:       $SCRIPT_DIR"
  echo "Backups folder:   $BACKUP_DIR"
  echo "Assets folder:    $ASSET_DIR"
  echo "Blank.png:        $BLANK_PNG"
  echo "Panel XML path:   $PANEL_XML"
  echo "Whisker plugin:   plugin-${WHISKER_PLUGIN_ID}"
  echo

  if have_cmd xfconf-query; then
    local title_key="/plugins/plugin-${WHISKER_PLUGIN_ID}/button-title"
    local icon_key="/plugins/plugin-${WHISKER_PLUGIN_ID}/button-icon"
    local v1 v2
    v1="$(xfconf-query -c xfce4-panel -p "$title_key" 2>/dev/null || true)"
    v2="$(xfconf-query -c xfce4-panel -p "$icon_key"  2>/dev/null || true)"
    printf '%s = [%s] (len=%d)\n' "$title_key" "$v1" "${#v1}"
    printf '%s = [%s] (len=%d)\n' "$icon_key"  "$v2" "${#v2}"
  else
    echo "xfconf-query not available."
  fi
  echo "------------------"
}

apply_xfce_420() {
  local theme_dir gtkcss
  theme_dir="$(ensure_theme_dir)"
  gtkcss="${theme_dir}/gtk-3.0/gtk.css"

  [[ -f "$gtkcss" ]] || { echo "ERROR: gtk.css not found: $gtkcss"; exit 1; }

  set_whisker_properties "xfce420"
  add_import_line "$gtkcss"

  echo "Done: XFCE 4.20 patch enabled."
  read -r -p "Restart panel now? (y/N): " yn
  case "${yn,,}" in
    y|yes) restart_panel ;;
    *) echo "OK — not restarting." ;;
  esac
}

apply_xfce_418() {
  local theme_dir gtkcss
  theme_dir="$(ensure_theme_dir)"
  gtkcss="${theme_dir}/gtk-3.0/gtk.css"

  [[ -f "$gtkcss" ]] || { echo "ERROR: gtk.css not found: $gtkcss"; exit 1; }

  set_whisker_properties "xfce418"
  remove_import_line "$gtkcss"

  echo "Done: XFCE 4.18 behavior restored."
  read -r -p "Restart panel now? (y/N): " yn
  case "${yn,,}" in
    y|yes) restart_panel ;;
    *) echo "OK — not restarting." ;;
  esac
}

main_menu() {
  while true; do
    echo
    echo "=============================="
    echo " XFCE Theme Switcher (4.18/4.20)"
    echo "=============================="
    echo "1) Upgrade / Enable: XFCE 4.20 patch"
    echo "2) Downgrade / Restore: XFCE 4.18 behavior"
    echo "3) Show status"
    echo "4) Exit"
    echo
    read -r -p "Select an option: " choice

    case "$choice" in
      1) apply_xfce_420 ;;
      2) apply_xfce_418 ;;
      3) status ;;
      4) exit 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done
}

main_menu
