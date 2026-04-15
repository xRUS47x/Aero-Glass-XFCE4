#!/usr/bin/env bash
set -u

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "This script requires bash." >&2
  exit 1
fi

: "${TERM:=xterm-256color}"
export TERM

CSI=$'\033['
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_DIR/xfce-color-switching-tool.conf"

PANEL_XML_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
WHISKERMENU_PANEL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/panel"
PANEL_CSS_RELATIVE_PATH="gtk-3.0/widgets/xfce/debug/colors-appearance.css"
PICOM_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/picom.conf"
LAST_APPLY_MESSAGE=""
LAST_APPLY_PANEL_XML=""
LAST_APPLY_WHISKER_FILES=""
LAST_APPLY_WHISKER_XFCONF=""
LAST_APPLY_PANEL_CSS=""
LAST_APPLY_PICOM_CONF=""
LAST_APPLY_MENU_OPACITY=""
LAST_APPLY_PANEL_ALPHA=""
LAST_APPLY_FRAME_OPACITY=""
LAST_RESTART_MESSAGE=""
LAST_RESTART_PANEL_STATUS=""
LAST_RESTART_XFWM_STATUS=""
MANIFEST_NAME=".xpm_color_targets.json"
XFWM4_DIR_NAME="xfwm4"
ORIGINAL_THEME_TARGET="#b3cce6"
LAST_APPLY_THEME_ROOT=""
LAST_APPLY_THEME_COLOR=""
LAST_APPLY_MANIFEST=""
LAST_APPLY_COLOR_MESSAGE=""
LAST_APPLY_COLOR_FILES=""


# -----------------------------
# ANSI / Terminal helpers
# -----------------------------
hide_cursor() { printf '%s?25l' "$CSI"; }
show_cursor() { printf '%s?25h' "$CSI"; }
enter_alt() { printf '%s?1049h' "$CSI"; }
leave_alt() { printf '%s?1049l' "$CSI"; }
clear_screen() { printf '%s2J%sH' "$CSI" "$CSI"; }
move() { printf '%s%d;%dH' "$CSI" "$1" "$2"; }
reset_style() { printf '%s0m' "$CSI"; }
fg() { printf '%s38;5;%sm' "$CSI" "$1"; }
bg() { printf '%s48;5;%sm' "$CSI" "$1"; }

repeat() {
  local count="$1" ch="$2" i
  for ((i=0; i<count; i++)); do
    printf '%s' "$ch"
  done
}

read_term_size() {
  local size
  if size=$(stty size 2>/dev/null); then
    rows=${size%% *}
    cols=${size##* }
  else
    rows=$(tput lines 2>/dev/null || printf '24')
    cols=$(tput cols 2>/dev/null || printf '80')
  fi
}

write_at() {
  local row="$1" col="$2" bgc="$3" fgc="$4" text="$5"
  local available

  if [[ -n "${cols:-}" ]]; then
    (( col < 1 )) && col=1
    (( row < 1 )) && row=1
    if (( col > cols )); then
      return 0
    fi
    available=$((cols - col + 1))
    (( available <= 0 )) && return 0
    if (( ${#text} > available )); then
      text="${text:0:available}"
    fi
  fi

  move "$row" "$col"
  [[ -n "$bgc" ]] && bg "$bgc"
  [[ -n "$fgc" ]] && fg "$fgc"
  printf '%s' "$text"
  reset_style
}

paint_line() {
  local row="$1" col="$2" width="$3" bgc="$4"
  move "$row" "$col"
  bg "$bgc"
  printf '%*s' "$width" ''
  reset_style
}

fill_rect() {
  local row="$1" col="$2" width="$3" height="$4" bgc="$5" i
  for ((i=0; i<height; i++)); do
    paint_line $((row + i)) "$col" "$width" "$bgc"
  done
}

hline() {
  local row="$1" col="$2" width="$3" bgc="$4" fgc="$5" ch="$6"
  move "$row" "$col"
  bg "$bgc"
  fg "$fgc"
  repeat "$width" "$ch"
  reset_style
}

box() {
  local row="$1" col="$2" width="$3" height="$4" border_fg="$5" fill_bg="$6"
  local inner_w=$((width - 2))
  local i

  move "$row" "$col"
  bg "$fill_bg"; fg "$border_fg"
  printf '┌'; repeat "$inner_w" '─'; printf '┐'

  for ((i=1; i<height-1; i++)); do
    move $((row + i)) "$col"
    bg "$fill_bg"; fg "$border_fg"
    printf '│'
    bg "$fill_bg"; printf '%*s' "$inner_w" ''
    fg "$border_fg"; printf '│'
  done

  move $((row + height - 1)) "$col"
  bg "$fill_bg"; fg "$border_fg"
  printf '└'; repeat "$inner_w" '─'; printf '┘'
  reset_style
}

shadow_box() {
  local row="$1" col="$2" width="$3" height="$4"
  fill_rect $((row + 1)) $((col + 2)) "$width" "$height" 16
}

pad_right() {
  local width="$1" text="$2"
  if (( ${#text} >= width )); then
    printf '%s' "${text:0:width}"
  else
    printf '%-*s' "$width" "$text"
  fi
}

clamp_percent() {
  local value="$1"
  (( value < 0 )) && value=0
  (( value > 100 )) && value=100
  printf '%d' "$value"
}

clamp_hue() {
  local value="$1"
  (( value < 0 )) && value=0
  (( value > 360 )) && value=360
  printf '%d' "$value"
}

clamp_rgb() {
  local value="$1"
  (( value < 0 )) && value=0
  (( value > 255 )) && value=255
  printf '%d' "$value"
}

cleanup() {
  if [[ -n "${stty_state:-}" ]]; then
    stty "$stty_state" 2>/dev/null || true
  else
    stty sane 2>/dev/null || true
  fi
  reset_style
  show_cursor
  leave_alt
}

on_winch() {
  need_relayout=1
}

trap cleanup EXIT INT TERM
trap on_winch WINCH

# -----------------------------
# Localization / configuration
# -----------------------------
ui_lang="en"

palette_names_en=(
  "Sky" "Twilight" "Sea" "Leaf" "Lime" "Sun" "Pumpkin" "Ruby"
  "Fuchsia" "Blush" "Violet" "Lavender" "Taupe" "Chocolate" "Slate" "Frost"
)

palette_names_de=(
  "Himmel" "Zwielicht" "Meer" "Blatt" "Limone" "Sonne" "Kürbis" "Rubinrot"
  "Pink" "Rouge" "Violett" "Lavendel" "Taupe" "Schokoladenbraun" "Schiefer" "Frost"
)

tr_text() {
  local key="$1"
  case "$ui_lang:$key" in
    en:title) printf 'Window Color and Appearance' ;;
    de:title) printf 'Fensterfarbe und -darstellung' ;;

    en:desc) printf 'Change the color of your window borders, Start menu, and taskbar.' ;;
    de:desc) printf 'Ändern Sie die Farbe von Fensterrahmen, Startmenü und Taskleiste.' ;;

    en:current_color) printf 'Current color:' ;;
    de:current_color) printf 'Aktuelle Farbe:' ;;

    en:enable_transparency) printf 'Enable transparency' ;;
    de:enable_transparency) printf 'Transparenz aktivieren' ;;

    en:hide_color_mixer) printf 'Hide color mixer' ;;
    de:hide_color_mixer) printf 'Farbmischer ausblenden' ;;

    en:show_color_mixer) printf 'Show color mixer' ;;
    de:show_color_mixer) printf 'Farbmischer einblenden' ;;

    en:color_intensity) printf 'Color intensity:' ;;
    de:color_intensity) printf 'Farbintensität:' ;;

    en:hue) printf 'Hue:' ;;
    de:hue) printf 'Farbton:' ;;

    en:saturation) printf 'Saturation:' ;;
    de:saturation) printf 'Sättigung:' ;;

    en:brightness) printf 'Brightness:' ;;
    de:brightness) printf 'Helligkeit:' ;;

    en:save_changes) printf 'Save changes' ;;
    de:save_changes) printf 'Änderungen speichern' ;;

    en:cancel) printf 'Cancel' ;;
    de:cancel) printf 'Abbrechen' ;;

    en:footer) printf '← → ↑ ↓: Navigate   Space: Toggle/Apply   Enter: Confirm   H: Enter HTML color code   L: Switch Language   R: Adjust window display   Q/Esc: Quit' ;;
    de:footer) printf '← → ↑ ↓: Navigieren   Leertaste: Auswählen   Enter: Bestätigen   H: HTML-Farbcode eingeben   L: Sprachausgabe ändern   R: Fensterdarstellung anpassen   Q/Esc: Beenden' ;;

    en:auto_size) printf 'Auto size:' ;;
    de:auto_size) printf 'Auto-Größe:' ;;

    en:not_run_yet) printf 'Not run yet' ;;
    de:not_run_yet) printf 'Noch nicht ausgeführt' ;;

    en:not_supported) printf 'Not supported' ;;
    de:not_supported) printf 'Nicht unterstützt' ;;

    en:requested) printf 'requested' ;;
    de:requested) printf 'angefordert' ;;

    en:current) printf 'current' ;;
    de:current) printf 'aktuell' ;;

    en:via) printf 'via' ;;
    de:via) printf 'via' ;;

    en:terminal_too_small_1) printf 'Terminal too small. Minimum required:' ;;
    de:terminal_too_small_1) printf 'Terminal zu klein. Mindestens erforderlich:' ;;

    en:terminal_too_small_2) printf 'The script first tries to resize the active XFCE4 Terminal with xdotool and then falls back to a terminal escape sequence.' ;;
    de:terminal_too_small_2) printf 'Das Skript versucht zuerst, das aktive XFCE4-Terminal mit xdotool zu vergrößern, und nutzt danach eine Terminal-Escape-Sequenz als Fallback.' ;;

    en:saved_selection) printf 'Saved selection' ;;
    de:saved_selection) printf 'Gespeicherte Auswahl' ;;

    en:color) printf 'Color:' ;;
    de:color) printf 'Farbe:' ;;

    en:transparency) printf 'Transparency:' ;;
    de:transparency) printf 'Transparenz:' ;;

    en:enabled) printf 'Enabled' ;;
    de:enabled) printf 'Aktiviert' ;;

    en:disabled) printf 'Disabled' ;;
    de:disabled) printf 'Deaktiviert' ;;

    en:color_mixer) printf 'Color mixer:' ;;
    de:color_mixer) printf 'Farbmischer:' ;;

    en:visible) printf 'Visible' ;;
    de:visible) printf 'Sichtbar' ;;

    en:hidden) printf 'Hidden' ;;
    de:hidden) printf 'Ausgeblendet' ;;

    en:terminal_size) printf 'Terminal size:' ;;
    de:terminal_size) printf 'Terminalgröße:' ;;

    en:auto_resize) printf 'Auto resize:' ;;
    de:auto_resize) printf 'Auto-Größe:' ;;

    en:canceled) printf 'Canceled.' ;;
    de:canceled) printf 'Abgebrochen.' ;;

    en:language_english) printf 'English' ;;
    de:language_english) printf 'Englisch' ;;

    en:language_german) printf 'German' ;;
    de:language_german) printf 'Deutsch' ;;

    en:language_dialog_title) printf 'Language Selection' ;;
    de:language_dialog_title) printf 'Sprachauswahl' ;;

    en:language_dialog_desc) printf 'Select the display language.' ;;
    de:language_dialog_desc) printf 'Wählen Sie die Anzeigesprache aus.' ;;

    en:language_dialog_hint) printf 'The selected language is saved for the next start.' ;;
    de:language_dialog_hint) printf 'Die gewählte Sprache wird für den nächsten Start gespeichert.' ;;

    en:language_hotkey_footer) printf '← → ↑ ↓: Navigate   Space: Toggle/Apply   Enter: Confirm   H: Enter HTML color code   L: Switch Language   R: Adjust window display   Q/Esc: Quit' ;;
    de:language_hotkey_footer) printf '← → ↑ ↓: Navigieren   Leertaste: Auswählen   Enter: Bestätigen   H: HTML-Farbcode eingeben   L: Sprachausgabe ändern   R: Fensterdarstellung anpassen   Q/Esc: Beenden' ;;

    en:ok) printf 'OK' ;;
    de:ok) printf 'OK' ;;

    en:set_value) printf 'Set value' ;;
    de:set_value) printf 'Wert eingeben' ;;

    en:value_for) printf 'Value for:' ;;
    de:value_for) printf 'Wert für:' ;;

    en:value_hint_percent) printf 'Type a number from 0 to 100. Enter/Space = Apply, Esc = Cancel.' ;;
    de:value_hint_percent) printf 'Geben Sie eine Zahl von 0 bis 100 ein. Enter/Leertaste = Übernehmen, Esc = Abbrechen.' ;;

    en:value_hint_hue) printf 'Type a number from 0 to 360. Enter/Space = Apply, Esc = Cancel.' ;;
    de:value_hint_hue) printf 'Geben Sie eine Zahl von 0 bis 360 ein. Enter/Leertaste = Übernehmen, Esc = Abbrechen.' ;;

    en:custom) printf 'Custom' ;;
    de:custom) printf 'Benutzerdefiniert' ;;

    en:html_color) printf 'HTML color:' ;;
    de:html_color) printf 'HTML-Farbe:' ;;

    en:set_html_color) printf 'Set HTML color' ;;
    de:set_html_color) printf 'HTML-Farbe eingeben' ;;

    en:html_color_hint) printf 'Type #RRGGBB or RRGGBB. Enter/Space = Apply, Esc = Cancel.' ;;
    de:html_color_hint) printf 'Geben Sie #RRGGBB oder RRGGBB ein. Enter/Leertaste = Übernehmen, Esc = Abbrechen.' ;;

    en:status_custom_color_selected) printf 'Selected custom HTML color.' ;;
    de:status_custom_color_selected) printf 'Benutzerdefinierte HTML-Farbe wurde ausgewählt.' ;;

    en:status_palette_color_selected) printf 'Selected palette color.' ;;
    de:status_palette_color_selected) printf 'Palettenfarbe wurde ausgewählt.' ;;

    en:status_invalid_html_color) printf 'Invalid HTML color. Use #RRGGBB or RRGGBB.' ;;
    de:status_invalid_html_color) printf 'Ungültige HTML-Farbe. Verwenden Sie #RRGGBB oder RRGGBB.' ;;

    en:status_loaded_saved) printf 'Loaded the last saved settings.' ;;
    de:status_loaded_saved) printf 'Die zuletzt gespeicherten Einstellungen wurden geladen.' ;;

    en:status_saved) printf 'Settings applied and saved.' ;;
    de:status_saved) printf 'Einstellungen wurden übernommen und gespeichert.' ;;

    en:status_save_failed) printf 'The current settings could not be fully applied.' ;;
    de:status_save_failed) printf 'Die aktuellen Einstellungen konnten nicht vollständig übernommen werden.' ;;

    en:status_restored) printf 'Restored the last saved settings.' ;;
    de:status_restored) printf 'Die zuletzt gespeicherten Einstellungen wurden wiederhergestellt.' ;;

    en:status_restore_failed) printf 'The last saved settings could not be fully restored.' ;;
    de:status_restore_failed) printf 'Die zuletzt gespeicherten Einstellungen konnten nicht vollständig wiederhergestellt werden.' ;;

    *) printf '%s' "$key" ;;
  esac
}

palette_name() {
  local idx="$1"
  if [[ "$ui_lang" == "de" ]]; then
    printf '%s' "${palette_names_de[idx]}"
  else
    printf '%s' "${palette_names_en[idx]}"
  fi
}

load_config() {
  local value
  [[ -f "$CONFIG_FILE" ]] || return 0

  while IFS='=' read -r key value; do
    value=${value//[$'\r\n\t ']/}
    case "$key" in
      UI_LANG)
        case "$value" in
          en|de) ui_lang="$value" ;;
        esac
        ;;
      HAS_SAVED_STATE)
        case "$value" in
          0|1) config_has_saved_state="$value" ;;
        esac
        ;;
      SAVED_SELECTED)
        [[ "$value" =~ ^-?[0-9]+$ ]] && last_saved_selected="$value" && config_has_saved_state=1
        ;;
      SAVED_TRANSPARENCY)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_transparency="$value" && config_has_saved_state=1
        ;;
      SAVED_SHOW_MIXER)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_show_mixer="$value" && config_has_saved_state=1
        ;;
      SAVED_INTENSITY)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_intensity="$value" && config_has_saved_state=1
        ;;
      SAVED_HUE)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_hue="$value" && config_has_saved_state=1
        ;;
      SAVED_SATURATION)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_saturation="$value" && config_has_saved_state=1
        ;;
      SAVED_BRIGHTNESS)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_brightness="$value" && config_has_saved_state=1
        ;;
      SAVED_CUSTOM_COLOR_ENABLED)
        [[ "$value" =~ ^[0-9]+$ ]] && last_saved_custom_color_enabled="$value" && config_has_saved_state=1
        ;;
      SAVED_CUSTOM_COLOR_HEX)
        [[ "$value" =~ ^#?[0-9a-fA-F]{6}$ ]] && last_saved_custom_color_hex="$value" && config_has_saved_state=1
        ;;
    esac
  done < "$CONFIG_FILE"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<CFG
UI_LANG=$ui_lang
HAS_SAVED_STATE=1
SAVED_SELECTED=$last_saved_selected
SAVED_TRANSPARENCY=$last_saved_transparency
SAVED_SHOW_MIXER=$last_saved_show_mixer
SAVED_INTENSITY=$last_saved_intensity
SAVED_HUE=$last_saved_hue
SAVED_SATURATION=$last_saved_saturation
SAVED_BRIGHTNESS=$last_saved_brightness
SAVED_CUSTOM_COLOR_ENABLED=$last_saved_custom_color_enabled
SAVED_CUSTOM_COLOR_HEX=$last_saved_custom_color_hex
CFG
}

clamp_palette_index() {
  local value="$1"
  [[ "$value" =~ ^-?[0-9]+$ ]] || value=14
  (( value < 0 || value >= ${#palette_names_en[@]} )) && value=14
  printf '%d' "$value"
}

find_matching_preset_index() {
  local match=-1
  local i
  for i in "${!preset_intensity_values[@]}"; do
    if (( intensity == preset_intensity_values[i] && hue == preset_hue_values[i] && saturation == preset_saturation_values[i] && brightness == preset_brightness_values[i] )); then
      match=$i
      break
    fi
  done
  printf '%d' "$match"
}

sync_palette_cursor_with_current() {
  local preset_match
  if (( custom_color_enabled )); then
    palette_cursor=$(clamp_palette_index "$selected")
    return 0
  fi

  preset_match=$(find_matching_preset_index)
  if (( preset_match >= 0 )); then
    palette_cursor="$preset_match"
  else
    palette_cursor=$(clamp_palette_index "$selected")
  fi
}

normalize_html_hex() {
  local value="${1:-}"
  value="${value//[$'\r\n\t ']/}"
  [[ -z "$value" ]] && return 1
  if [[ "$value" =~ ^#?[0-9a-fA-F]{6}$ ]]; then
    [[ "$value" == \#* ]] || value="#$value"
    printf '%s' "${value,,}"
    return 0
  fi
  return 1
}

html_hex_to_rgb() {
  local value=""
  value=$(normalize_html_hex "$1") || return 1
  printf '%d %d %d' "0x${value:1:2}" "0x${value:3:2}" "0x${value:5:2}"
}

disable_custom_color_mode() {
  custom_color_enabled=0
}

current_color_name() {
  local preset_match
  if (( custom_color_enabled )); then
    tr_text custom
    return 0
  fi
  preset_match=$(find_matching_preset_index)
  if (( preset_match >= 0 )); then
    palette_name "$preset_match"
  else
    tr_text custom
  fi
}

commit_saved_state_from_current() {
  last_saved_selected=$(clamp_palette_index "$selected")
  last_saved_transparency=$(clamp_percent "$transparency")
  last_saved_show_mixer=$(clamp_percent "$show_mixer")
  last_saved_intensity=$(clamp_percent "$intensity")
  last_saved_hue=$(clamp_hue "$hue")
  last_saved_saturation=$(clamp_percent "$saturation")
  last_saved_brightness=$(clamp_percent "$brightness")
  last_saved_custom_color_enabled=$(clamp_percent "$custom_color_enabled")
  last_saved_custom_color_hex=$(normalize_html_hex "$custom_color_hex" 2>/dev/null || printf '#%s' 'b3cce6')
  config_has_saved_state=1
}

restore_working_state_from_saved() {
  selected=$(clamp_palette_index "$last_saved_selected")
  transparency=$(clamp_percent "$last_saved_transparency")
  show_mixer=$(clamp_percent "$last_saved_show_mixer")
  intensity=$(clamp_percent "$last_saved_intensity")
  hue=$(clamp_hue "$last_saved_hue")
  saturation=$(clamp_percent "$last_saved_saturation")
  brightness=$(clamp_percent "$last_saved_brightness")
  custom_color_enabled=$(clamp_percent "$last_saved_custom_color_enabled")
  custom_color_hex=$(normalize_html_hex "$last_saved_custom_color_hex" 2>/dev/null || printf '#%s' 'b3cce6')
  sync_palette_cursor_with_current
}

initialize_saved_and_working_state() {
  if (( config_has_saved_state )); then
    last_saved_selected=$(clamp_palette_index "$last_saved_selected")
    last_saved_transparency=$(clamp_percent "$last_saved_transparency")
    last_saved_show_mixer=$(clamp_percent "$last_saved_show_mixer")
    last_saved_intensity=$(clamp_percent "$last_saved_intensity")
    last_saved_hue=$(clamp_hue "$last_saved_hue")
    last_saved_saturation=$(clamp_percent "$last_saved_saturation")
    last_saved_brightness=$(clamp_percent "$last_saved_brightness")
    last_saved_custom_color_enabled=$(clamp_percent "$last_saved_custom_color_enabled")
    last_saved_custom_color_hex=$(normalize_html_hex "$last_saved_custom_color_hex" 2>/dev/null || printf '#%s' 'b3cce6')
    restore_working_state_from_saved
    ACTION_STATUS_MESSAGE="$(tr_text status_loaded_saved)"
  else
    apply_preset_values "$selected"
    custom_color_enabled=0
    custom_color_hex="#b3cce6"
    sync_palette_cursor_with_current
    commit_saved_state_from_current
    ACTION_STATUS_MESSAGE=""
  fi
}

set_language_metrics() {
  if [[ "$ui_lang" == "de" ]]; then
    RECOMMENDED_ROWS=38
    RECOMMENDED_COLS=136
    MIN_ROWS=35
    MIN_COLS=128
    DIALOG_W=112
    LANG_DIALOG_W=78
  else
    RECOMMENDED_ROWS=38
    RECOMMENDED_COLS=114
    MIN_ROWS=35
    MIN_COLS=106
    DIALOG_W=98
    LANG_DIALOG_W=62
  fi
}

open_language_dialog() {
  language_dialog_open=1
  if [[ "$ui_lang" == "de" ]]; then
    language_selected=1
  else
    language_selected=0
  fi
  language_button_index=0
  language_focus=0
}

close_language_dialog() {
  language_dialog_open=0
}

apply_language_selection() {
  local new_lang="en"
  (( language_selected == 1 )) && new_lang="de"

  language_dialog_open=0

  if [[ "$new_lang" != "$ui_lang" ]]; then
    ui_lang="$new_lang"
    save_config
    set_language_metrics
    apply_auto_window_size "$RECOMMENDED_ROWS" "$RECOMMENDED_COLS" >/dev/null 2>&1 || true
    need_relayout=1
  fi

  if (( auto_resize_runs == 0 )); then
    auto_resize_message="$(tr_text not_run_yet)"
  fi
}

# -----------------------------
# Colors
# -----------------------------
CLR_SCREEN_BG=25
CLR_HEADER_CYAN=51
CLR_DIALOG_BG=252
CLR_DIALOG_BORDER=240
CLR_DIALOG_TITLE=110
CLR_TEXT=234
CLR_TEXT_DIM=244
CLR_SELECT_BG=24
CLR_SELECT_FG=255
CLR_BUTTON_ACTIVE_FG=226
CLR_TRACK_BG=238
CLR_TRACK_FG=250
CLR_TRACK_FILLED=246
CLR_VALUE_BOX_BG=250
CLR_VALUE_BOX_FG=234
CLR_SWATCH_BORDER=244
CLR_SWATCH_ACTIVE=110
CLR_SWATCH_EMPTY=252
CLR_SWATCH_SELECTED_BG=24
CLR_SWATCH_SELECTED_BORDER=252

# -----------------------------
# Preset color data
# -----------------------------
preset_intensity_values=(
  41 73 53 40 40 29 53 73
  40 44 56 29 40 73 53 29
)

preset_hue_values=(
  211 216 181 112 84 52 36 0
  325 305 271 293 44 0 0 0
)

preset_saturation_values=(
  53 100 75 100 74 94 100 92
  100 21 63 39 50 65 0 0
)

preset_brightness_values=(
  98 67 80 65 85 98 100 80
  100 98 63 58 59 30 33 98
)

palette_colors=()

component_to_cube_idx() {
  local value="$1"
  if (( value < 48 )); then
    printf '0'
  elif (( value < 115 )); then
    printf '1'
  elif (( value < 155 )); then
    printf '2'
  elif (( value < 195 )); then
    printf '3'
  elif (( value < 235 )); then
    printf '4'
  else
    printf '5'
  fi
}

cube_value_from_idx() {
  local idx="$1"
  case "$idx" in
    0) printf '0' ;;
    1) printf '95' ;;
    2) printf '135' ;;
    3) printf '175' ;;
    4) printf '215' ;;
    *) printf '255' ;;
  esac
}

rgb_to_xterm() {
  local r="$1" g="$2" b="$3"
  local ri gi bi cube_r cube_g cube_b cube_color cube_dist
  local avg gray_idx gray_level gray_color gray_dist
  local dr dg db

  ri=$(component_to_cube_idx "$r")
  gi=$(component_to_cube_idx "$g")
  bi=$(component_to_cube_idx "$b")

  cube_r=$(cube_value_from_idx "$ri")
  cube_g=$(cube_value_from_idx "$gi")
  cube_b=$(cube_value_from_idx "$bi")
  cube_color=$((16 + 36 * ri + 6 * gi + bi))

  dr=$((r - cube_r))
  dg=$((g - cube_g))
  db=$((b - cube_b))
  cube_dist=$((dr * dr + dg * dg + db * db))

  avg=$(((r + g + b) / 3))
  if (( avg <= 8 )); then
    gray_idx=0
  elif (( avg >= 238 )); then
    gray_idx=23
  else
    gray_idx=$(((avg - 8 + 5) / 10))
  fi
  gray_level=$((8 + gray_idx * 10))
  gray_color=$((232 + gray_idx))

  dr=$((r - gray_level))
  dg=$((g - gray_level))
  db=$((b - gray_level))
  gray_dist=$((dr * dr + dg * dg + db * db))

  if (( gray_dist < cube_dist )); then
    printf '%d' "$gray_color"
  else
    printf '%d' "$cube_color"
  fi
}

hsv_to_rgb() {
  local hue_value="$1" saturation_value="$2" brightness_value="$3"
  local h_scaled sector frac v s c x m
  local r g b

  (( hue_value < 0 )) && hue_value=0
  (( hue_value > 360 )) && hue_value=360

  if (( hue_value == 360 )); then
    hue_value=0
  fi

  v=$((brightness_value * 255 / 100))
  s=$((saturation_value * 255 / 100))

  if (( s <= 0 )); then
    printf '%d %d %d' "$v" "$v" "$v"
    return 0
  fi

  h_scaled=$((hue_value * 1536 / 360))
  sector=$((h_scaled / 256))
  frac=$((h_scaled % 256))
  c=$((v * s / 255))

  if (( sector % 2 == 0 )); then
    x=$((c * frac / 256))
  else
    x=$((c * (256 - frac) / 256))
  fi

  m=$((v - c))

  case "$sector" in
    0) r=$c; g=$x; b=0 ;;
    1) r=$x; g=$c; b=0 ;;
    2) r=0; g=$c; b=$x ;;
    3) r=0; g=$x; b=$c ;;
    4) r=$x; g=0; b=$c ;;
    *) r=$c; g=0; b=$x ;;
  esac

  r=$((r + m))
  g=$((g + m))
  b=$((b + m))

  printf '%d %d %d' "$r" "$g" "$b"
}

rgb_to_hsv() {
  local red_value="$1" green_value="$2" blue_value="$3"

  awk -v r="$red_value" -v g="$green_value" -v b="$blue_value" '
    BEGIN {
      rf = r / 255.0
      gf = g / 255.0
      bf = b / 255.0

      max = rf
      if (gf > max) max = gf
      if (bf > max) max = bf

      min = rf
      if (gf < min) min = gf
      if (bf < min) min = bf

      delta = max - min
      hue = 0

      if (delta == 0) {
        hue = 0
      } else if (max == rf) {
        hue = 60.0 * ((gf - bf) / delta)
        if (hue < 0) hue += 360.0
      } else if (max == gf) {
        hue = 60.0 * (((bf - rf) / delta) + 2.0)
      } else {
        hue = 60.0 * (((rf - gf) / delta) + 4.0)
      }

      saturation = (max == 0 ? 0 : (delta / max) * 100.0)
      brightness = max * 100.0

      printf "%d %d %d\n", int(hue + 0.5), int(saturation + 0.5), int(brightness + 0.5)
    }
  '
}

calc_preview_rgb() {
  local intensity_value="$1" hue_value="$2" saturation_value="$3" brightness_value="$4"
  local r g b gray

  read -r r g b <<< "$(hsv_to_rgb "$hue_value" "$saturation_value" "$brightness_value")"
  gray=$((brightness_value * 255 / 100))

  r=$((gray + (r - gray) * intensity_value / 100))
  g=$((gray + (g - gray) * intensity_value / 100))
  b=$((gray + (b - gray) * intensity_value / 100))

  r=$(clamp_rgb "$r")
  g=$(clamp_rgb "$g")
  b=$(clamp_rgb "$b")

  printf '%d %d %d' "$r" "$g" "$b"
}

calc_preview_color_code() {
  local intensity_value="$1" hue_value="$2" saturation_value="$3" brightness_value="$4"
  local r g b

  read -r r g b <<< "$(calc_preview_rgb "$intensity_value" "$hue_value" "$saturation_value" "$brightness_value")"
  rgb_to_xterm "$r" "$g" "$b"
}

get_effective_preview_rgb() {
  if (( custom_color_enabled )); then
    html_hex_to_rgb "$custom_color_hex"
  else
    calc_preview_rgb "$intensity" "$hue" "$saturation" "$brightness"
  fi
}

get_effective_preview_color_code() {
  local r g b
  read -r r g b <<< "$(get_effective_preview_rgb)"
  rgb_to_xterm "$r" "$g" "$b"
}

update_palette_colors() {
  local i
  palette_colors=()
  for i in "${!palette_names_en[@]}"; do
    palette_colors[i]=$(calc_preview_color_code \
      "${preset_intensity_values[i]}" \
      "${preset_hue_values[i]}" \
      "${preset_saturation_values[i]}" \
      "${preset_brightness_values[i]}")
  done
}

apply_preset_values() {
  local idx="$1"
  selected="$idx"
  palette_cursor="$idx"
  intensity="${preset_intensity_values[idx]}"
  hue="${preset_hue_values[idx]}"
  saturation="${preset_saturation_values[idx]}"
  brightness="${preset_brightness_values[idx]}"
  disable_custom_color_mode
}

open_value_dialog_for_focus() {
  local target_focus="$1"

  value_dialog_max=100
  value_dialog_hint_key="value_hint_percent"

  case "$target_focus" in
    2)
      value_dialog_field="intensity"
      value_dialog_label="$(tr_text color_intensity)"
      value_dialog_input="$intensity"
      ;;
    4)
      value_dialog_field="hue"
      value_dialog_label="$(tr_text hue)"
      value_dialog_input="$hue"
      value_dialog_max=360
      value_dialog_hint_key="value_hint_hue"
      ;;
    5)
      value_dialog_field="saturation"
      value_dialog_label="$(tr_text saturation)"
      value_dialog_input="$saturation"
      ;;
    6)
      value_dialog_field="brightness"
      value_dialog_label="$(tr_text brightness)"
      value_dialog_input="$brightness"
      ;;
    *)
      return 1
      ;;
  esac

  value_dialog_label=${value_dialog_label%:}
  value_dialog_open=1
  value_dialog_select_all=1
  return 0
}

close_value_dialog() {
  value_dialog_open=0
  value_dialog_field=""
  value_dialog_label=""
  value_dialog_input=""
  value_dialog_max=100
  value_dialog_hint_key="value_hint_percent"
  value_dialog_select_all=0
}

open_html_color_dialog() {
  html_color_dialog_open=1
  html_color_dialog_input="$(get_selected_color_hex)"
  html_color_dialog_select_all=1
}

close_html_color_dialog() {
  html_color_dialog_open=0
  html_color_dialog_input=""
  html_color_dialog_select_all=0
}

apply_html_color_dialog_value() {
  local normalized="" red=0 green=0 blue=0 converted_hue=0 converted_saturation=0 converted_brightness=0
  normalized=$(normalize_html_hex "$html_color_dialog_input") || {
    ACTION_STATUS_MESSAGE="$(tr_text status_invalid_html_color)"
    return 1
  }

  read -r red green blue <<< "$(html_hex_to_rgb "$normalized")" || {
    ACTION_STATUS_MESSAGE="$(tr_text status_invalid_html_color)"
    return 1
  }

  read -r converted_hue converted_saturation converted_brightness <<< "$(rgb_to_hsv "$red" "$green" "$blue")"

  hue=$(clamp_hue "$converted_hue")
  saturation=$(clamp_percent "$converted_saturation")
  brightness=$(clamp_percent "$converted_brightness")
  intensity=100

  custom_color_enabled=1
  custom_color_hex="$normalized"
  ACTION_STATUS_MESSAGE="$(tr_text status_custom_color_selected)"
  return 0
}

apply_value_dialog_value() {
  local value="${value_dialog_input}"

  [[ -z "$value" ]] && value=0
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    value=0
  fi

  value=$((10#$value))

  case "$value_dialog_field" in
    intensity)
      value=$(clamp_percent "$value")
      intensity="$value"
      disable_custom_color_mode
      sync_palette_cursor_with_current
      ;;
    hue)
      value=$(clamp_hue "$value")
      hue="$value"
      disable_custom_color_mode
      sync_palette_cursor_with_current
      ;;
    saturation)
      value=$(clamp_percent "$value")
      saturation="$value"
      disable_custom_color_mode
      sync_palette_cursor_with_current
      ;;
    brightness)
      value=$(clamp_percent "$value")
      brightness="$value"
      disable_custom_color_mode
      sync_palette_cursor_with_current
      ;;
  esac
}

# -----------------------------
# State
# -----------------------------
selected=14          # Slate
palette_cursor=14
transparency=1
show_mixer=1
intensity=0
hue=0
saturation=0
brightness=0
custom_color_enabled=0
custom_color_hex="#b3cce6"
last_saved_selected=14
last_saved_transparency=1
last_saved_show_mixer=1
last_saved_intensity=0
last_saved_hue=0
last_saved_saturation=0
last_saved_brightness=0
last_saved_custom_color_enabled=0
last_saved_custom_color_hex="#b3cce6"
config_has_saved_state=0
ACTION_STATUS_MESSAGE=""
button_index=0       # 0 = Save, 1 = Cancel
focus=0
result="quit"
need_relayout=1
auto_resize_message=""
auto_resize_runs=0
auto_resize_method="-"
language_dialog_open=0
language_selected=0
language_button_index=0
language_focus=0
value_dialog_open=0
value_dialog_field=""
value_dialog_label=""
value_dialog_input=""
value_dialog_max=100
value_dialog_hint_key="value_hint_percent"
value_dialog_select_all=0
html_color_dialog_open=0
html_color_dialog_input=""
html_color_dialog_select_all=0

RECOMMENDED_ROWS=38
RECOMMENDED_COLS=114
MIN_ROWS=35
MIN_COLS=106
DIALOG_W=98
LANG_DIALOG_W=62

# -----------------------------
# XFCE4 terminal patch / auto sizing
# -----------------------------
find_ancestor_process() {
  local needle="$1" pid="$$" comm ppid
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $1}')
    if [[ "$comm" == "$needle" ]]; then
      printf '%s' "$pid"
      return 0
    fi
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" || "$ppid" == "$pid" ]] && break
    pid="$ppid"
  done
  return 1
}

get_active_window_if_xfce_terminal() {
  local wid class
  command -v xdotool >/dev/null 2>&1 || return 1
  [[ -n "${DISPLAY:-}" ]] || return 1

  wid=$(xdotool getactivewindow 2>/dev/null || true)
  [[ -n "$wid" ]] || return 1

  class=$(xdotool getwindowclassname "$wid" 2>/dev/null || true)
  case "${class,,}" in
    *xfce4-terminal*)
      printf '%s' "$wid"
      return 0
      ;;
  esac
  return 1
}

get_xfce_terminal_window_id() {
  local wid pid

  if wid=$(get_active_window_if_xfce_terminal); then
    printf '%s' "$wid"
    return 0
  fi

  command -v xdotool >/dev/null 2>&1 || return 1
  [[ -n "${DISPLAY:-}" ]] || return 1

  if pid=$(find_ancestor_process "xfce4-terminal"); then
    wid=$(xdotool search --all --pid "$pid" 2>/dev/null | head -n1 || true)
    [[ -n "$wid" ]] || return 1
    printf '%s' "$wid"
    return 0
  fi

  return 1
}

resize_xfce4_terminal_window() {
  local target_rows="$1" target_cols="$2"
  local wid pixel_w pixel_h

  wid=$(get_xfce_terminal_window_id) || return 1

  # Practical values for XFCE4 Terminal with a typical monospace font.
  pixel_w=$((target_cols * 9 + 70))
  pixel_h=$((target_rows * 18 + 120))

  command -v xdotool >/dev/null 2>&1 || return 1
  xdotool windowsize "$wid" "$pixel_w" "$pixel_h" >/dev/null 2>&1 || return 1
  sleep 0.18
  return 0
}

apply_escape_resize() {
  local target_rows="$1" target_cols="$2"
  [[ -t 1 ]] || return 1
  printf '%s8;%d;%dt' "$CSI" "$target_rows" "$target_cols"
  sleep 0.12
  return 0
}

apply_auto_window_size() {
  local target_rows="${1:-$RECOMMENDED_ROWS}"
  local target_cols="${2:-$RECOMMENDED_COLS}"
  local method="none"

  ((auto_resize_runs++))

  if resize_xfce4_terminal_window "$target_rows" "$target_cols"; then
    method="xfce4-terminal+xdotool"
  elif apply_escape_resize "$target_rows" "$target_cols"; then
    method="terminal-sequence"
  else
    auto_resize_method="none"
    auto_resize_message="$(tr_text not_supported)"
    return 1
  fi

  read_term_size
  auto_resize_method="$method"

  if (( rows >= MIN_ROWS && cols >= MIN_COLS )); then
    auto_resize_message="${cols}x${rows} $(tr_text via) ${method}"
    return 0
  fi

  auto_resize_message="$(tr_text requested): ${target_cols}x${target_rows} $(tr_text via) ${method}, $(tr_text current) ${cols}x${rows}"
  return 1
}

# -----------------------------
# Layout
# -----------------------------
get_layout() {
  read_term_size

  if (( rows < MIN_ROWS || cols < MIN_COLS )); then
    apply_auto_window_size "$RECOMMENDED_ROWS" "$RECOMMENDED_COLS" >/dev/null 2>&1 || true
    read_term_size
  fi

  if (( rows < MIN_ROWS || cols < MIN_COLS )); then
    cleanup
    echo "$(tr_text terminal_too_small_1) ${MIN_COLS}x${MIN_ROWS} characters. Current: ${cols}x${rows}." >&2
    echo "$(tr_text terminal_too_small_2)" >&2
    exit 1
  fi

  dlg_w=$DIALOG_W
  dlg_h=28

  (( dlg_w > cols - 8 )) && dlg_w=$((cols - 8))
  (( dlg_h > rows - 6 )) && dlg_h=$((rows - 6))

  dlg_r=$(( (rows - dlg_h) / 2 ))
  dlg_c=$(( (cols - dlg_w) / 2 ))

  (( dlg_r < 4 )) && dlg_r=4
  (( dlg_c < 3 )) && dlg_c=3

  palette_r=$((dlg_r + 4))
  palette_c=$((dlg_c + 5))

  need_relayout=0
}

# -----------------------------
# Focus order
# -----------------------------
get_focus_order() {
  if (( show_mixer )); then
    printf '0 1 3 2 4 5 6 7'
  else
    printf '0 1 3 2 7'
  fi
}

focus_next() {
  local arr i
  read -r -a arr <<< "$(get_focus_order)"
  for i in "${!arr[@]}"; do
    if (( arr[i] == focus )); then
      if (( i == ${#arr[@]} - 1 )); then
        focus=${arr[0]}
      else
        focus=${arr[i+1]}
      fi
      return
    fi
  done
}

focus_prev() {
  local arr i
  read -r -a arr <<< "$(get_focus_order)"
  for i in "${!arr[@]}"; do
    if (( arr[i] == focus )); then
      if (( i == 0 )); then
        focus=${arr[${#arr[@]}-1]}
      else
        focus=${arr[i-1]}
      fi
      return
    fi
  done
}

# -----------------------------
# Rendering
# -----------------------------
render_background() {
  local r
  for ((r=1; r<=rows; r++)); do
    paint_line "$r" 1 "$cols" "$CLR_SCREEN_BG"
  done

  write_at 1 2 "$CLR_SCREEN_BG" "$CLR_HEADER_CYAN" "XFCE Color Switching Tool"
  hline 2 1 "$cols" "$CLR_SCREEN_BG" "$CLR_HEADER_CYAN" '─'
}

render_dialog_shell() {
  local title="$(tr_text title)"
  local title_col=$((dlg_c + (dlg_w - ${#title}) / 2))

  shadow_box "$dlg_r" "$dlg_c" "$dlg_w" "$dlg_h"
  box "$dlg_r" "$dlg_c" "$dlg_w" "$dlg_h" "$CLR_DIALOG_BORDER" "$CLR_DIALOG_BG"

  write_at "$dlg_r" "$title_col" "$CLR_DIALOG_BG" "$CLR_DIALOG_TITLE" " $title "
  write_at $((dlg_r + 2)) $((dlg_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$(tr_text desc)"

  hline $((dlg_r + dlg_h - 4)) $((dlg_c + 1)) $((dlg_w - 2)) "$CLR_DIALOG_BG" "$CLR_DIALOG_BORDER" '─'
}

render_palette() {
  local sw_w=7 sw_h=3 gap=2
  local idx row col rr cc border_color fill_color box_bg inset_col inset_w
  local preview_color preset_match

  preview_color=$(get_effective_preview_color_code)
  preset_match=$(find_matching_preset_index)

  for row in 0 1; do
    for col in 0 1 2 3 4 5 6 7; do
      idx=$((row * 8 + col))
      rr=$((palette_r + row * 4))
      cc=$((palette_c + col * (sw_w + gap)))
      fill_color=${palette_colors[idx]}
      border_color=$CLR_SWATCH_BORDER
      box_bg=$CLR_DIALOG_BG
      inset_col=$((cc + 1))
      inset_w=$((sw_w - 2))

      if (( preset_match == idx )); then
        border_color=$CLR_SWATCH_SELECTED_BORDER
        box_bg=$CLR_SWATCH_SELECTED_BG
        inset_col=$((cc + 2))
        inset_w=$((sw_w - 4))
      fi

      if (( focus == 0 && palette_cursor == idx )); then
        border_color=$CLR_BUTTON_ACTIVE_FG
        if (( preset_match != idx )); then
          box_bg=$CLR_SELECT_BG
        fi
      fi

      box "$rr" "$cc" "$sw_w" "$sw_h" "$border_color" "$box_bg"
      fill_rect $((rr + 1)) "$inset_col" "$inset_w" 1 "$fill_color"
    done
  done

  write_at $((dlg_r + 12)) $((dlg_c + 4)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$(tr_text current_color) $(current_color_name)"

  box $((dlg_r + 11)) $((dlg_c + dlg_w - 12)) 8 3 "$CLR_SWATCH_BORDER" "$CLR_DIALOG_BG"
  fill_rect $((dlg_r + 12)) $((dlg_c + dlg_w - 11)) 6 1 "$preview_color"
}

render_checkbox() {
  local row="$1" label="$2" checked="$3" active="$4"
  local mark=' '
  (( checked )) && mark='X'

  if (( active )); then
    write_at "$row" $((dlg_c + 4)) "$CLR_SELECT_BG" "$CLR_SELECT_FG" "[$mark] $label"
  else
    write_at "$row" $((dlg_c + 4)) "$CLR_DIALOG_BG" "$CLR_TEXT" "[$mark] $label"
  fi
}

render_link_row() {
  local row="$1" label="$2" active="$3"
  local symbol='[+]'

  if (( show_mixer )); then
    symbol='[-]'
  fi

  if (( active )); then
    write_at "$row" $((dlg_c + 4)) "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$symbol $label"
  else
    write_at "$row" $((dlg_c + 4)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$symbol $label"
  fi
}

render_slider_row() {
  local row="$1" label="$2" value="$3" active="$4" max_value="${5:-100}"
  local label_col=$((dlg_c + 4))
  local bar_col=$((dlg_c + 22))
  local bar_w=34
  local value_col=$((dlg_c + 60))
  local knob_pos=$(( value * (bar_w - 1) / max_value ))
  local i

  if (( active )); then
    write_at "$row" "$label_col" "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$(pad_right 16 "$label")"
  else
    write_at "$row" "$label_col" "$CLR_DIALOG_BG" "$CLR_TEXT" "$(pad_right 16 "$label")"
  fi

  move "$row" "$bar_col"
  bg "$CLR_TRACK_BG"; fg "$CLR_TRACK_FG"
  for ((i=0; i<bar_w; i++)); do
    if (( i < knob_pos )); then
      fg "$CLR_TRACK_FILLED"
      printf '─'
      fg "$CLR_TRACK_FG"
    elif (( i == knob_pos )); then
      if (( active )); then
        fg "$CLR_BUTTON_ACTIVE_FG"
      else
        fg 255
      fi
      printf '◆'
      fg "$CLR_TRACK_FG"
    else
      printf '─'
    fi
  done
  reset_style

  if (( active )); then
    write_at "$row" "$value_col" "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$(printf '%3d' "$value")"
  else
    write_at "$row" "$value_col" "$CLR_DIALOG_BG" "$CLR_TEXT" "$(printf '%3d' "$value")"
  fi
}

render_mixer() {
  local mixer_label="$(tr_text hide_color_mixer)"
  (( show_mixer == 0 )) && mixer_label="$(tr_text show_color_mixer)"

  render_checkbox   $((dlg_r + 14)) "$(tr_text enable_transparency)" "$transparency" $(( focus == 1 ))
  render_link_row   $((dlg_r + 16)) "$mixer_label" $(( focus == 3 ))
  render_slider_row $((dlg_r + 18)) "$(tr_text color_intensity)" "$intensity" $(( focus == 2 )) 100

  if (( show_mixer )); then
    render_slider_row $((dlg_r + 20)) "$(tr_text hue)" "$hue" $(( focus == 4 )) 360
    render_slider_row $((dlg_r + 21)) "$(tr_text saturation)" "$saturation" $(( focus == 5 )) 100
    render_slider_row $((dlg_r + 22)) "$(tr_text brightness)" "$brightness" $(( focus == 6 )) 100
    paint_line $((dlg_r + 23)) $((dlg_c + 2)) $((dlg_w - 4)) "$CLR_DIALOG_BG"
  else
    paint_line $((dlg_r + 20)) $((dlg_c + 2)) $((dlg_w - 4)) "$CLR_DIALOG_BG"
    paint_line $((dlg_r + 21)) $((dlg_c + 2)) $((dlg_w - 4)) "$CLR_DIALOG_BG"
    paint_line $((dlg_r + 22)) $((dlg_c + 2)) $((dlg_w - 4)) "$CLR_DIALOG_BG"
    paint_line $((dlg_r + 23)) $((dlg_c + 2)) $((dlg_w - 4)) "$CLR_DIALOG_BG"
  fi
}

render_action_status() {
  local row=$((dlg_r + dlg_h - 3))
  local col=$((dlg_c + 3))
  local width=$((dlg_w - 6))
  local message="$ACTION_STATUS_MESSAGE"

  paint_line "$row" "$col" "$width" "$CLR_DIALOG_BG"
  [[ -z "$message" ]] && return 0

  if (( ${#message} > width )); then
    if (( width > 3 )); then
      message="${message:0:width-3}..."
    else
      message="${message:0:width}"
    fi
  fi

  write_at "$row" "$col" "$CLR_DIALOG_BG" "$CLR_TEXT_DIM" "$message"
}

render_buttons() {
  local row=$((dlg_r + dlg_h - 2))
  local save_label="[ $(tr_text save_changes) ]"
  local cancel_label="[ $(tr_text cancel) ]"
  local save_col=$((dlg_c + dlg_w / 2 - ${#save_label} - 3))
  local cancel_col=$((dlg_c + dlg_w / 2 + 4))

  if (( focus == 7 && button_index == 0 )); then
    write_at "$row" "$save_col" "$CLR_SELECT_BG" "$CLR_BUTTON_ACTIVE_FG" "$save_label"
  else
    write_at "$row" "$save_col" "$CLR_DIALOG_BG" "$CLR_TEXT" "$save_label"
  fi

  if (( focus == 7 && button_index == 1 )); then
    write_at "$row" "$cancel_col" "$CLR_SELECT_BG" "$CLR_BUTTON_ACTIVE_FG" "$cancel_label"
  else
    write_at "$row" "$cancel_col" "$CLR_DIALOG_BG" "$CLR_TEXT" "$cancel_label"
  fi
}

render_footer_hint() {
  local footer="$(tr_text language_hotkey_footer)"
  paint_line "$rows" 1 "$cols" "$CLR_SCREEN_BG"
  write_at "$rows" 2 "$CLR_SCREEN_BG" 255 "$footer"
}

render_status() {
  local status="$(tr_text auto_size) ${auto_resize_message}"
  local col=$((cols - ${#status} - 2))
  (( col < 2 )) && col=2
  write_at 1 "$col" "$CLR_SCREEN_BG" "$CLR_HEADER_CYAN" "$status"
}

render_language_dialog() {
  (( language_dialog_open )) || return 0

  local title="$(tr_text language_dialog_title)"
  local desc="$(tr_text language_dialog_desc)"
  local hint="$(tr_text language_dialog_hint)"
  local win_w=$LANG_DIALOG_W
  local min_w=$(( ${#title} + 8 ))
  (( ${#desc} + 6 > min_w )) && min_w=$(( ${#desc} + 6 ))
  (( ${#hint} + 6 > min_w )) && min_w=$(( ${#hint} + 6 ))
  (( win_w < min_w )) && win_w=$min_w
  local max_w=$((dlg_w - 6))
  (( max_w < 40 )) && max_w=40
  (( win_w > max_w )) && win_w=$max_w
  local win_h=13
  local win_r=$((dlg_r + 7))
  local win_c=$((dlg_c + (dlg_w - win_w) / 2))
  local list_r=$((win_r + 3))
  local list_c=$((win_c + 3))
  local list_w=$((win_w - 6))
  local opt0="1  English"
  local opt1="2  Deutsch"
  local btn_row=$((win_r + win_h - 2))
  local ok_label="[ $(tr_text ok) ]"
  local cancel_label="[ $(tr_text cancel) ]"
  local ok_col=$((win_c + win_w / 2 - ${#ok_label} - 3))
  local cancel_col=$((win_c + win_w / 2 + 4))

  shadow_box "$win_r" "$win_c" "$win_w" "$win_h"
  box "$win_r" "$win_c" "$win_w" "$win_h" "$CLR_DIALOG_BORDER" "$CLR_DIALOG_BG"
  write_at "$win_r" $((win_c + (win_w - ${#title} - 2) / 2)) "$CLR_DIALOG_BG" "$CLR_DIALOG_TITLE" " $title "
  write_at $((win_r + 2)) $((win_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$desc"

  box "$list_r" "$list_c" "$list_w" 4 "$CLR_DIALOG_BORDER" "$CLR_DIALOG_BG"

  if (( language_selected == 0 )); then
    write_at $((list_r + 1)) $((list_c + 1)) "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$(pad_right $((list_w - 2)) "$opt0")"
  else
    write_at $((list_r + 1)) $((list_c + 1)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$(pad_right $((list_w - 2)) "$opt0")"
  fi

  if (( language_selected == 1 )); then
    write_at $((list_r + 2)) $((list_c + 1)) "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$(pad_right $((list_w - 2)) "$opt1")"
  else
    write_at $((list_r + 2)) $((list_c + 1)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$(pad_right $((list_w - 2)) "$opt1")"
  fi

  write_at $((win_r + 8)) $((win_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT_DIM" "$hint"
  hline $((win_r + win_h - 3)) $((win_c + 1)) $((win_w - 2)) "$CLR_DIALOG_BG" "$CLR_DIALOG_BORDER" '─'

  if (( language_focus == 1 && language_button_index == 0 )); then
    write_at "$btn_row" "$ok_col" "$CLR_SELECT_BG" "$CLR_BUTTON_ACTIVE_FG" "$ok_label"
  else
    write_at "$btn_row" "$ok_col" "$CLR_DIALOG_BG" "$CLR_TEXT" "$ok_label"
  fi

  if (( language_focus == 1 && language_button_index == 1 )); then
    write_at "$btn_row" "$cancel_col" "$CLR_SELECT_BG" "$CLR_BUTTON_ACTIVE_FG" "$cancel_label"
  else
    write_at "$btn_row" "$cancel_col" "$CLR_DIALOG_BG" "$CLR_TEXT" "$cancel_label"
  fi
}

render_value_dialog() {
  (( value_dialog_open )) || return 0

  local title="$(tr_text set_value)"
  local value_for_line="$(tr_text value_for) $value_dialog_label"
  local hint="$(tr_text "$value_dialog_hint_key")"
  local win_w=62
  local min_w=$(( ${#title} + 8 ))
  (( ${#value_for_line} + 6 > min_w )) && min_w=$(( ${#value_for_line} + 6 ))
  (( ${#hint} + 6 > min_w )) && min_w=$(( ${#hint} + 6 ))
  (( win_w < min_w )) && win_w=$min_w
  local max_w=$((dlg_w - 6))
  (( max_w < 40 )) && max_w=40
  (( win_w > max_w )) && win_w=$max_w
  local win_h=9
  local win_r=$((dlg_r + 9))
  local win_c=$((dlg_c + (dlg_w - win_w) / 2))
  local input_row=$((win_r + 4))
  local input_col=$((win_c + 3))
  local input_w=$((win_w - 6))
  local display_value="$value_dialog_input"

  shadow_box "$win_r" "$win_c" "$win_w" "$win_h"
  box "$win_r" "$win_c" "$win_w" "$win_h" "$CLR_DIALOG_BORDER" "$CLR_DIALOG_BG"
  write_at "$win_r" $((win_c + (win_w - ${#title} - 2) / 2)) "$CLR_DIALOG_BG" "$CLR_DIALOG_TITLE" " $title "
  write_at $((win_r + 2)) $((win_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$value_for_line"

  box "$input_row" "$input_col" "$input_w" 3 "$CLR_DIALOG_BORDER" "$CLR_SELECT_BG"
  write_at $((input_row + 1)) $((input_col + 2)) "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$(pad_right $((input_w - 4)) "$display_value")"

  write_at $((win_r + 7)) $((win_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT_DIM" "$hint"
}

render_html_color_dialog() {
  (( html_color_dialog_open )) || return 0

  local title="$(tr_text set_html_color)"
  local label_line="$(tr_text html_color)"
  local hint="$(tr_text html_color_hint)"
  local win_w=62
  local min_w=$(( ${#title} + 8 ))
  (( ${#label_line} + 6 > min_w )) && min_w=$(( ${#label_line} + 6 ))
  (( ${#hint} + 6 > min_w )) && min_w=$(( ${#hint} + 6 ))
  (( win_w < min_w )) && win_w=$min_w
  local max_w=$((dlg_w - 6))
  (( max_w < 40 )) && max_w=40
  (( win_w > max_w )) && win_w=$max_w
  local win_h=9
  local win_r=$((dlg_r + 9))
  local win_c=$((dlg_c + (dlg_w - win_w) / 2))
  local input_row=$((win_r + 4))
  local input_col=$((win_c + 3))
  local input_w=$((win_w - 6))
  local display_value="$html_color_dialog_input"

  shadow_box "$win_r" "$win_c" "$win_w" "$win_h"
  box "$win_r" "$win_c" "$win_w" "$win_h" "$CLR_DIALOG_BORDER" "$CLR_DIALOG_BG"
  write_at "$win_r" $((win_c + (win_w - ${#title} - 2) / 2)) "$CLR_DIALOG_BG" "$CLR_DIALOG_TITLE" " $title "
  write_at $((win_r + 2)) $((win_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT" "$label_line"

  box "$input_row" "$input_col" "$input_w" 3 "$CLR_DIALOG_BORDER" "$CLR_SELECT_BG"
  write_at $((input_row + 1)) $((input_col + 2)) "$CLR_SELECT_BG" "$CLR_SELECT_FG" "$(pad_right $((input_w - 4)) "$display_value")"

  write_at $((win_r + 7)) $((win_c + 3)) "$CLR_DIALOG_BG" "$CLR_TEXT_DIM" "$hint"
}

render() {
  (( need_relayout )) && get_layout
  render_background
  render_dialog_shell
  render_palette
  render_mixer
  hline $((dlg_r + dlg_h - 4)) $((dlg_c + 1)) $((dlg_w - 2)) "$CLR_DIALOG_BG" "$CLR_DIALOG_BORDER" '─'
  render_buttons
  render_action_status
  render_footer_hint
  render_status
  render_language_dialog
  render_value_dialog
  render_html_color_dialog
}

# -----------------------------
# Input
# -----------------------------
read_key() {
  local k rest
  IFS= read -rsn1 k || return 1

  if [[ "$k" == $'\x1b' ]]; then
    IFS= read -rsn1 -t 0.01 rest || { printf 'ESC'; return 0; }
    if [[ "$rest" == '[' ]]; then
      IFS= read -rsn1 -t 0.01 rest || { printf 'ESC'; return 0; }
      case "$rest" in
        A) printf 'UP' ;;
        B) printf 'DOWN' ;;
        C) printf 'RIGHT' ;;
        D) printf 'LEFT' ;;
        Z) printf 'BACKTAB' ;;
        3)
          IFS= read -rsn1 -t 0.01 rest || { printf 'ESC'; return 0; }
          printf 'DELETE'
          ;;
        *) printf 'ESC' ;;
      esac
    else
      printf 'ESC'
    fi
  elif [[ "$k" == $'\t' ]]; then
    printf 'TAB'
  elif [[ "$k" == $'\x7f' || "$k" == $'\b' ]]; then
    printf 'BACKSPACE'
  elif [[ -z "$k" || "$k" == $'\n' || "$k" == $'\r' ]]; then
    printf 'ENTER'
  elif [[ "$k" == ' ' ]]; then
    printf 'SPACE'
  else
    printf '%s' "$k"
  fi
}

handle_language_dialog_input() {
  local key="$1"

  case "$key" in
    q|Q|ESC|l|L)
      close_language_dialog
      return 1
      ;;
    TAB|BACKTAB)
      language_focus=$((1 - language_focus))
      return 1
      ;;
  esac

  if (( language_focus == 0 )); then
    case "$key" in
      UP)
        (( language_selected > 0 )) && ((language_selected--))
        ;;
      DOWN)
        (( language_selected < 1 )) && ((language_selected++))
        ;;
      LEFT|RIGHT)
        :
        ;;
      SPACE|ENTER)
        language_focus=1
        language_button_index=0
        ;;
    esac
  else
    case "$key" in
      LEFT)
        language_button_index=0
        ;;
      RIGHT)
        language_button_index=1
        ;;
      UP)
        language_focus=0
        ;;
      DOWN)
        :
        ;;
      SPACE|ENTER)
        if (( language_button_index == 0 )); then
          apply_language_selection
        else
          close_language_dialog
        fi
        ;;
    esac
  fi

  return 1
}

handle_value_dialog_input() {
  local key="$1"

  case "$key" in
    q|Q|ESC)
      close_value_dialog
      return 1
      ;;
    ENTER|SPACE)
      apply_value_dialog_value
      close_value_dialog
      return 1
      ;;
    BACKSPACE|DELETE)
      if (( value_dialog_select_all )); then
        value_dialog_input=""
        value_dialog_select_all=0
      else
        value_dialog_input="${value_dialog_input%?}"
      fi
      return 1
      ;;
  esac

  if [[ "$key" =~ ^[0-9]$ ]]; then
    if (( value_dialog_select_all )); then
      value_dialog_input="$key"
      value_dialog_select_all=0
    elif (( ${#value_dialog_input} < ${#value_dialog_max} )); then
      value_dialog_input+="$key"
    fi
  fi

  return 1
}

handle_html_color_dialog_input() {
  local key="$1"

  case "$key" in
    q|Q|ESC)
      close_html_color_dialog
      return 1
      ;;
    ENTER|SPACE)
      if apply_html_color_dialog_value; then
        close_html_color_dialog
      fi
      return 1
      ;;
    BACKSPACE|DELETE)
      if (( html_color_dialog_select_all )); then
        html_color_dialog_input=""
        html_color_dialog_select_all=0
      else
        html_color_dialog_input="${html_color_dialog_input%?}"
      fi
      return 1
      ;;
  esac

  if [[ "$key" =~ ^[0-9a-fA-F]$ || "$key" == "#" ]]; then
    if (( html_color_dialog_select_all )); then
      html_color_dialog_input="$key"
      html_color_dialog_select_all=0
    elif (( ${#html_color_dialog_input} < 7 )); then
      if [[ "$key" == "#" && "$html_color_dialog_input" == *"#"* ]]; then
        :
      else
        html_color_dialog_input+="$key"
      fi
    fi
  fi

  return 1
}

apply_action() {
  local key="$1"

  if (( language_dialog_open )); then
    handle_language_dialog_input "$key"
    return 1
  fi

  if (( value_dialog_open )); then
    handle_value_dialog_input "$key"
    return 1
  fi

  if (( html_color_dialog_open )); then
    handle_html_color_dialog_input "$key"
    return 1
  fi

  case "$key" in
    q|Q|ESC)
      result="quit"
      return 0
      ;;
    r|R)
      apply_auto_window_size "$RECOMMENDED_ROWS" "$RECOMMENDED_COLS" >/dev/null 2>&1 || true
      need_relayout=1
      return 1
      ;;
    h|H)
      open_html_color_dialog
      return 1
      ;;
    l|L)
      open_language_dialog
      return 1
      ;;
    TAB)
      focus_next
      return 1
      ;;
    BACKTAB)
      focus_prev
      return 1
      ;;
  esac

  case "$focus" in
    0) # Palette
      case "$key" in
        LEFT)
          if (( palette_cursor % 8 > 0 )); then
            palette_cursor=$((palette_cursor - 1))
          fi
          ;;
        RIGHT)
          if (( palette_cursor % 8 < 7 )); then
            palette_cursor=$((palette_cursor + 1))
          fi
          ;;
        UP)
          if (( palette_cursor >= 8 )); then
            palette_cursor=$((palette_cursor - 8))
          fi
          ;;
        DOWN)
          if (( palette_cursor < 8 )); then
            palette_cursor=$((palette_cursor + 8))
          else
            focus_next
          fi
          ;;
        SPACE|ENTER)
          apply_preset_values "$palette_cursor"
          ACTION_STATUS_MESSAGE="$(tr_text status_palette_color_selected)"
          ;;
      esac
      ;;

    1) # Transparency
      case "$key" in
        SPACE|ENTER|LEFT|RIGHT) transparency=$((1 - transparency)) ;;
        UP) focus_prev ;;
        DOWN) focus_next ;;
      esac
      ;;

    2) # Intensity
      case "$key" in
        LEFT) intensity=$(clamp_percent $((intensity - 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        RIGHT) intensity=$(clamp_percent $((intensity + 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        SPACE|ENTER) open_value_dialog_for_focus 2 ;;
        UP) focus_prev ;;
        DOWN) focus_next ;;
      esac
      ;;

    3) # Mixer on/off
      case "$key" in
        SPACE|ENTER|LEFT|RIGHT)
          show_mixer=$((1 - show_mixer))
          if (( show_mixer == 0 && focus >= 4 && focus <= 6 )); then
            focus=3
          fi
          ;;
        UP) focus_prev ;;
        DOWN) focus_next ;;
      esac
      ;;

    4) # Hue
      case "$key" in
        LEFT) hue=$(clamp_hue $((hue - 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        RIGHT) hue=$(clamp_hue $((hue + 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        SPACE|ENTER) open_value_dialog_for_focus 4 ;;
        UP) focus_prev ;;
        DOWN) focus_next ;;
      esac
      ;;

    5) # Saturation
      case "$key" in
        LEFT) saturation=$(clamp_percent $((saturation - 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        RIGHT) saturation=$(clamp_percent $((saturation + 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        SPACE|ENTER) open_value_dialog_for_focus 5 ;;
        UP) focus_prev ;;
        DOWN) focus_next ;;
      esac
      ;;

    6) # Brightness
      case "$key" in
        LEFT) brightness=$(clamp_percent $((brightness - 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        RIGHT) brightness=$(clamp_percent $((brightness + 1))); disable_custom_color_mode; sync_palette_cursor_with_current ;;
        SPACE|ENTER) open_value_dialog_for_focus 6 ;;
        UP) focus_prev ;;
        DOWN) focus_next ;;
      esac
      ;;

    7) # Buttons
      case "$key" in
        LEFT) button_index=0 ;;
        RIGHT) button_index=1 ;;
        UP) focus_prev ;;
        DOWN) : ;;
        SPACE|ENTER)
          if (( button_index == 0 )); then
            run_save_action
          else
            run_cancel_action
          fi
          return 1
          ;;
      esac
      ;;
  esac

  return 1
}


# -----------------------------
# Theme / transparency patching
# -----------------------------
format_opacity_decimal() {
  local value="$1"
  value=$(clamp_percent "$value")
  printf '%d.%02d' $((value / 100)) $((value % 100))
}

get_selected_color_hex() {
  local red green blue
  if (( custom_color_enabled )); then
    normalize_html_hex "$custom_color_hex"
    return 0
  fi
  read -r red green blue <<< "$(calc_preview_rgb "$intensity" "$hue" "$saturation" "$brightness")"
  printf '#%02x%02x%02x' "$red" "$green" "$blue"
}

resolve_theme_root() {
  local css_file=""
  local suffix="/$PANEL_CSS_RELATIVE_PATH"
  local theme_root=""

  css_file=$(resolve_theme_css_file) || return 1

  case "$css_file" in
    *"$suffix")
      theme_root="${css_file%"$suffix"}"
      ;;
    *)
      return 1
      ;;
  esac

  [[ -d "$theme_root/$XFWM4_DIR_NAME" ]] || return 1
  [[ -f "$theme_root/$PANEL_CSS_RELATIVE_PATH" ]] || return 1

  printf '%s' "$theme_root"
}

apply_theme_color_files() {
  local theme_root=""
  local new_color=""
  local tmp_stdout=""
  local tmp_stderr=""
  local py_rc=0

  LAST_APPLY_THEME_ROOT=""
  LAST_APPLY_THEME_COLOR=""
  LAST_APPLY_MANIFEST=""
  LAST_APPLY_COLOR_MESSAGE=""
  LAST_APPLY_COLOR_FILES=""

  command -v python3 >/dev/null 2>&1 || {
    LAST_APPLY_COLOR_MESSAGE="python3 not found in PATH."
    return 1
  }

  theme_root=$(resolve_theme_root) || {
    LAST_APPLY_COLOR_MESSAGE="Theme root not found. Expected xfwm4/ and $PANEL_CSS_RELATIVE_PATH below the selected theme."
    return 1
  }

  new_color=$(get_selected_color_hex)
  LAST_APPLY_THEME_ROOT="$theme_root"
  LAST_APPLY_THEME_COLOR="$new_color"
  LAST_APPLY_MANIFEST="$theme_root/$MANIFEST_NAME"

  tmp_stdout=$(mktemp) || {
    LAST_APPLY_COLOR_MESSAGE="Could not allocate temporary file for color patch output."
    return 1
  }
  tmp_stderr=$(mktemp) || {
    rm -f "$tmp_stdout"
    LAST_APPLY_COLOR_MESSAGE="Could not allocate temporary file for color patch errors."
    return 1
  }

  python3 - "$theme_root" "$new_color" "$ORIGINAL_THEME_TARGET" "$MANIFEST_NAME" "$PANEL_CSS_RELATIVE_PATH" "$XFWM4_DIR_NAME" >"$tmp_stdout" 2>"$tmp_stderr" <<'PY'
from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path


HEX_RE = re.compile(r"^#?[0-9a-fA-F]{6}$")
QUOTED_LINE_RE = re.compile(r'^(?P<prefix>\s*")(?P<content>(?:[^"\\]|\\.)*)(?P<suffix>".*)$')
COLOR_VALUE_RE = re.compile(r'(\bc\s+)(\S+)', re.IGNORECASE)
CSS_COLOR_BASE_RE = re.compile(
    r'(^\s*@define-color\s+color_base\s+)(#[0-9a-fA-F]{6})(\s*;)',
    re.IGNORECASE | re.MULTILINE,
)


class ThemeError(Exception):
    pass


def normalize_hex(value: str) -> str:
    value = value.strip()
    if not HEX_RE.fullmatch(value):
        raise ThemeError(f"Invalid color: {value!r}. Expected #cc4429 or cc4429.")
    if not value.startswith("#"):
        value = f"#{value}"
    return value.lower()


def backup_file(path: Path) -> None:
    backup = path.with_suffix(path.suffix + ".bak")
    if not backup.exists():
        shutil.copy2(path, backup)


def extract_xpm_table(lines: list[str]) -> tuple[int, int, list[int], list[str]]:
    quoted_indexes: list[int] = []
    quoted_contents: list[str] = []

    for index, line in enumerate(lines):
        match = QUOTED_LINE_RE.match(line.rstrip("\n"))
        if match:
            quoted_indexes.append(index)
            quoted_contents.append(match.group("content"))

    if not quoted_contents:
        raise ThemeError("No XPM data lines found.")

    header_parts = quoted_contents[0].split()
    if len(header_parts) < 4:
        raise ThemeError(f"Invalid XPM header: {quoted_contents[0]!r}")

    try:
        _width = int(header_parts[0])
        height = int(header_parts[1])
        colors = int(header_parts[2])
        cpp = int(header_parts[3])
    except ValueError as exc:
        raise ThemeError(f"Non-numeric XPM header: {quoted_contents[0]!r}") from exc

    expected_minimum = 1 + colors + height
    if len(quoted_contents) < expected_minimum:
        raise ThemeError(
            f"Incomplete XPM file: expected at least {expected_minimum} data lines, found {len(quoted_contents)}."
        )

    return colors, cpp, quoted_indexes, quoted_contents


def parse_color_definitions(contents: list[str], colors: int, cpp: int) -> dict[str, tuple[int, str, str]]:
    definitions: dict[str, tuple[int, str, str]] = {}

    for offset in range(1, colors + 1):
        entry = contents[offset]
        if len(entry) < cpp:
            raise ThemeError(f"Invalid color definition: {entry!r}")
        symbol = entry[:cpp]
        rest = entry[cpp:]
        color_match = COLOR_VALUE_RE.search(rest)
        color_value = color_match.group(2).lower() if color_match else ""
        definitions[symbol] = (offset, rest, color_value)

    return definitions


def rewrite_quoted_line(original_line: str, new_content: str) -> str:
    line_ending = "\n" if original_line.endswith("\n") else ""
    stripped = original_line.rstrip("\n")
    match = QUOTED_LINE_RE.match(stripped)
    if not match:
        raise ThemeError(f"Could not rewrite line: {original_line!r}")
    return f"{match.group('prefix')}{new_content}{match.group('suffix')}{line_ending}"


def update_xpm_file(path: Path, target_symbols: list[str], new_color: str) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    colors, cpp, quoted_indexes, quoted_contents = extract_xpm_table(lines)
    definitions = parse_color_definitions(quoted_contents, colors, cpp)
    changed = False

    for symbol in target_symbols:
        if symbol not in definitions:
            raise ThemeError(f"In {path.name}, remembered symbol {symbol!r} is missing.")

        entry_offset, rest, _current_value = definitions[symbol]
        updated_rest, replacements = COLOR_VALUE_RE.subn(rf'\1{new_color}', rest, count=1)
        if replacements == 0:
            raise ThemeError(f"In {path.name}, no 'c <color>' entry could be replaced for symbol {symbol!r}.")

        new_entry = f"{symbol}{updated_rest}"
        line_index = quoted_indexes[entry_offset]
        current_line = lines[line_index]
        current_content = quoted_contents[entry_offset]
        if current_content != new_entry:
            lines[line_index] = rewrite_quoted_line(current_line, new_entry)
            quoted_contents[entry_offset] = new_entry
            changed = True

    if changed:
        backup_file(path)
        path.write_text("".join(lines), encoding="utf-8")

    return changed


def load_or_bootstrap_manifest(theme_root: Path, xpm_files: list[Path], original_target: str, manifest_name: str, css_relative_path: str) -> dict:
    manifest_path = theme_root / manifest_name
    if manifest_path.exists():
        with manifest_path.open("r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        manifest.setdefault("original_target", original_target)
        manifest.setdefault("xpm_symbols", {})
        manifest.setdefault("css_relative_path", css_relative_path)
        return manifest

    manifest = {
        "original_target": original_target,
        "xpm_symbols": {},
        "css_relative_path": css_relative_path,
    }

    for xpm_path in xpm_files:
        lines = xpm_path.read_text(encoding="utf-8").splitlines(keepends=True)
        colors, cpp, _quoted_indexes, quoted_contents = extract_xpm_table(lines)
        definitions = parse_color_definitions(quoted_contents, colors, cpp)
        matching_symbols = [
            symbol
            for symbol, (_offset, _rest, color_value) in definitions.items()
            if color_value == original_target
        ]
        if matching_symbols:
            manifest["xpm_symbols"][str(xpm_path.relative_to(theme_root))] = matching_symbols

    if not manifest["xpm_symbols"]:
        raise ThemeError(
            f"No XPM color areas with original color {original_target} found. "
            "Create the manifest from an unmodified theme first."
        )

    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return manifest


def update_css_file(css_path: Path, new_color: str, original_target: str) -> bool:
    content = css_path.read_text(encoding="utf-8")
    new_content, replacements = CSS_COLOR_BASE_RE.subn(rf'\1{new_color}\3', content, count=1)

    if replacements == 0:
        fallback = re.compile(re.escape(original_target), re.IGNORECASE)
        new_content, replacements = fallback.subn(new_color, content, count=1)

    if replacements == 0:
        raise ThemeError(
            f"Neither '@define-color color_base ...' nor the original color {original_target} was found in the CSS file."
        )

    if new_content != content:
        backup_file(css_path)
        css_path.write_text(new_content, encoding="utf-8")
        return True
    return False


def main() -> int:
    if len(sys.argv) != 7:
        raise SystemExit("Unexpected arguments.")

    theme_root = Path(sys.argv[1]).resolve()
    new_color = normalize_hex(sys.argv[2])
    original_target = normalize_hex(sys.argv[3])
    manifest_name = sys.argv[4]
    css_relative_path = Path(sys.argv[5])
    xfwm4_dir_name = sys.argv[6]

    css_path = theme_root / css_relative_path
    xpm_dir = theme_root / xfwm4_dir_name
    xpm_files = sorted(xpm_dir.glob("*.xpm"))

    if not css_path.is_file():
        raise ThemeError(f"CSS file not found: {css_path}")
    if not xpm_dir.is_dir():
        raise ThemeError(f"xfwm4 directory not found: {xpm_dir}")
    if not xpm_files:
        raise ThemeError(f"No XPM files found under: {xpm_dir}")

    manifest = load_or_bootstrap_manifest(theme_root, xpm_files, original_target, manifest_name, str(css_relative_path))
    changed_files: list[str] = []

    for relative_path, symbols in sorted(manifest.get("xpm_symbols", {}).items()):
        xpm_path = theme_root / relative_path
        if update_xpm_file(xpm_path, list(symbols), new_color):
            changed_files.append(relative_path)

    if update_css_file(css_path, new_color, original_target):
        changed_files.append(str(css_path.relative_to(theme_root)))

    print(f"MANIFEST={theme_root / manifest_name}")
    print(f"COLOR={new_color}")
    print(f"THEME_ROOT={theme_root}")
    print("FILES=" + "|".join(changed_files))
    if changed_files:
        print(f"MESSAGE=Applied theme color {new_color} to {len(changed_files)} file(s).")
    else:
        print(f"MESSAGE=No color changes needed. Theme already uses {new_color}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ThemeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
PY
  py_rc=$?

  if (( py_rc != 0 )); then
    LAST_APPLY_COLOR_MESSAGE=$(tr '\n' ' ' < "$tmp_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    [[ -n "$LAST_APPLY_COLOR_MESSAGE" ]] || LAST_APPLY_COLOR_MESSAGE="Failed to apply theme color."
    rm -f "$tmp_stdout" "$tmp_stderr"
    return 1
  fi

  LAST_APPLY_MANIFEST=$(sed -n 's/^MANIFEST=//p' "$tmp_stdout" | tail -n1)
  LAST_APPLY_THEME_COLOR=$(sed -n 's/^COLOR=//p' "$tmp_stdout" | tail -n1)
  LAST_APPLY_THEME_ROOT=$(sed -n 's/^THEME_ROOT=//p' "$tmp_stdout" | tail -n1)
  LAST_APPLY_COLOR_FILES=$(sed -n 's/^FILES=//p' "$tmp_stdout" | tail -n1)
  LAST_APPLY_COLOR_MESSAGE=$(sed -n 's/^MESSAGE=//p' "$tmp_stdout" | tail -n1)

  rm -f "$tmp_stdout" "$tmp_stderr"
  return 0
}

get_panel_opacity_percent() {
  local transparency_value="${1:-$transparency}"
  local intensity_value="${2:-$intensity}"
  local opacity=100

  if (( ! transparency_value )); then
    printf '100'
    return 0
  fi

  intensity_value=$(clamp_percent "$intensity_value")

  if (( intensity_value <= 51 )); then
    opacity=$((25 + ((52 - 25) * intensity_value + 25) / 51))
  else
    opacity=$((52 + ((75 - 52) * (intensity_value - 51) + 24) / 49))
  fi

  printf '%d' "$opacity"
}

create_backup_file() {
  local file_path="$1"
  local backup_path="${file_path}.bak"

  if [[ ! -f "$backup_path" ]]; then
    cp -p -- "$file_path" "$backup_path" || return 1
  fi

  return 0
}

get_current_gtk_theme_name() {
  local theme_name=""
  local xsettings_file="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"

  if command -v xfconf-query >/dev/null 2>&1; then
    theme_name=$(xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null || true)
  fi

  if [[ -z "$theme_name" && -f "$xsettings_file" ]]; then
    theme_name=$(sed -nE 's/.*<property name="ThemeName" type="string" value="([^"]+)".*/\1/p' "$xsettings_file" | head -n1)
  fi

  printf '%s' "$theme_name"
}

resolve_theme_css_file() {
  local css_path=""
  local theme_name=""
  local script_dir=""
  local search_root=""
  local -a matches=()

  if [[ -n "${THEME_FOLDER:-}" ]]; then
    css_path="$HOME/.themes/$THEME_FOLDER/$PANEL_CSS_RELATIVE_PATH"
    if [[ -f "$css_path" ]]; then
      printf '%s' "$css_path"
      return 0
    fi
  fi

  theme_name=$(get_current_gtk_theme_name)
  if [[ -n "$theme_name" ]]; then
    css_path="$HOME/.themes/$theme_name/$PANEL_CSS_RELATIVE_PATH"
    if [[ -f "$css_path" ]]; then
      printf '%s' "$css_path"
      return 0
    fi
  fi

  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
  search_root="$script_dir"
  while [[ -n "$search_root" && "$search_root" != "/" ]]; do
    css_path="$search_root/$PANEL_CSS_RELATIVE_PATH"
    if [[ -f "$css_path" ]]; then
      printf '%s' "$css_path"
      return 0
    fi
    search_root=$(dirname "$search_root")
  done

  while IFS= read -r css_path; do
    matches+=("$css_path")
  done < <(find "$HOME/.themes" -maxdepth 6 -type f -path "*/$PANEL_CSS_RELATIVE_PATH" 2>/dev/null | sort)

  if (( ${#matches[@]} == 1 )); then
    printf '%s' "${matches[0]}"
    return 0
  fi

  return 1
}

update_panel_xml_menu_opacity() {
  local xml_file="$1"
  local opacity_percent="$2"
  local temp_file

  [[ -f "$xml_file" ]] || return 1
  create_backup_file "$xml_file" || return 1

  temp_file=$(mktemp) || return 1
  if sed -E "0,/(<property name=\"menu-opacity\" type=\"int\" value=\")[0-9]+(\"\\/>)/s//\\1${opacity_percent}\\2/" "$xml_file" > "$temp_file"; then
    if cmp -s "$xml_file" "$temp_file"; then
      if ! grep -q '<property name="menu-opacity" type="int" value="' "$xml_file"; then
        rm -f "$temp_file"
        return 1
      fi
    fi
    mv "$temp_file" "$xml_file"
    return 0
  fi

  rm -f "$temp_file"
  return 1
}

update_panel_css_opacity() {
  local css_file="$1"
  local opacity_decimal="$2"
  local temp_file

  [[ -f "$css_file" ]] || return 1
  create_backup_file "$css_file" || return 1

  temp_file=$(mktemp) || return 1
  if awk -v opacity="$opacity_decimal" '
    BEGIN {
      in_block = 0
      changed = 0
    }
    /^[[:space:]]*\.xfce4-panel\.background[[:space:]]*\{/ {
      in_block = 1
    }
    {
      if (in_block) {
        if ($0 ~ /alpha\(@panel_edge_dark,[[:space:]]*[0-9.]+\)/) {
          gsub(/alpha\(@panel_edge_dark,[[:space:]]*[0-9.]+\)/, "alpha(@panel_edge_dark, " opacity ")")
          changed = 1
        }
        if ($0 ~ /alpha\(@panel_edge_light,[[:space:]]*[0-9.]+\)/) {
          gsub(/alpha\(@panel_edge_light,[[:space:]]*[0-9.]+\)/, "alpha(@panel_edge_light, " opacity ")")
          changed = 1
        }
        if ($0 ~ /alpha\(@color_base,[[:space:]]*[0-9.]+\)/) {
          gsub(/alpha\(@color_base,[[:space:]]*[0-9.]+\)/, "alpha(@color_base, " opacity ")")
          changed = 1
        }
        if ($0 ~ /^[[:space:]]*\}/) {
          in_block = 0
        }
      }
      print
    }
    END {
      if (!changed) {
        exit 2
      }
    }
  ' "$css_file" > "$temp_file"; then
    mv "$temp_file" "$css_file"
    return 0
  fi

  rm -f "$temp_file"
  return 1
}

collect_whiskermenu_rc_files() {
  local panel_dir="${1:-$WHISKERMENU_PANEL_DIR}"
  local -a matches=()
  local file

  [[ -d "$panel_dir" ]] || return 1

  while IFS= read -r -d '' file; do
    matches+=("$file")
  done < <(find "$panel_dir" -maxdepth 1 -type f -name 'whiskermenu*.rc' -print0 2>/dev/null | sort -z)

  (( ${#matches[@]} > 0 )) || return 1
  printf '%s
' "${matches[@]}"
  return 0
}

update_whiskermenu_rc_menu_opacity() {
  local rc_file="$1"
  local opacity_percent="$2"
  local temp_file
  local matched=0

  [[ -f "$rc_file" ]] || return 1
  create_backup_file "$rc_file" || return 1

  temp_file=$(mktemp) || return 1
  if awk -v opacity="$opacity_percent" '
    BEGIN {
      updated = 0
    }
    {
      if ($0 ~ /^[[:space:]]*menu-opacity[[:space:]]*=/) {
        print "menu-opacity=" opacity
        updated = 1
      } else {
        print
      }
    }
    END {
      if (!updated) {
        print "menu-opacity=" opacity
      }
    }
  ' "$rc_file" > "$temp_file"; then
    mv "$temp_file" "$rc_file"
    return 0
  fi

  rm -f "$temp_file"
  return 1
}

collect_menu_opacity_xfconf_paths() {
  command -v xfconf-query >/dev/null 2>&1 || return 1

  local line
  local -a paths=()

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == /plugins/plugin-*/menu-opacity ]] || continue
    paths+=("$line")
  done < <(xfconf-query -c xfce4-panel -l 2>/dev/null || true)

  (( ${#paths[@]} > 0 )) || return 1
  printf '%s
' "${paths[@]}" | sort -u
  return 0
}

collect_whiskermenu_xfconf_plugin_ids() {
  command -v xfconf-query >/dev/null 2>&1 || return 1

  local line
  local path
  local plugin_id
  local -a ids=()

  while IFS= read -r line; do
    [[ "$line" == /plugins/plugin-* ]] || continue
    if printf '%s
' "$line" | grep -qi 'whiskermenu'; then
      path=$(printf '%s
' "$line" | awk '{print $1}')
      plugin_id="${path#/plugins/plugin-}"
      plugin_id="${plugin_id%%/*}"
      if [[ "$plugin_id" =~ ^[0-9]+$ ]]; then
        ids+=("$plugin_id")
      fi
    fi
  done < <(xfconf-query -c xfce4-panel -p /plugins -l -v 2>/dev/null || xfconf-query -c xfce4-panel -l -v 2>/dev/null || true)

  (( ${#ids[@]} > 0 )) || return 1
  printf '%s
' "${ids[@]}" | sort -u
  return 0
}

update_xfconf_menu_opacity_path() {
  local property="$1"
  local opacity_percent="$2"

  command -v xfconf-query >/dev/null 2>&1 || return 2

  xfconf-query -c xfce4-panel -p "$property" -t int -s "$opacity_percent" >/dev/null 2>&1 && return 0
  xfconf-query -c xfce4-panel -p "$property" -n -t int -s "$opacity_percent" >/dev/null 2>&1 && return 0
  return 1
}

update_whiskermenu_xfconf_menu_opacity() {
  local plugin_id="$1"
  local opacity_percent="$2"
  local property="/plugins/plugin-${plugin_id}/menu-opacity"

  update_xfconf_menu_opacity_path "$property" "$opacity_percent"
}

update_all_whiskermenu_xfconf_opacity() {
  local opacity_percent="$1"
  local property_path
  local plugin_id
  local -a updated_paths=()

  while IFS= read -r property_path; do
    [[ -n "$property_path" ]] || continue
    update_xfconf_menu_opacity_path "$property_path" "$opacity_percent" || return 1
    updated_paths+=("$property_path")
  done < <(collect_menu_opacity_xfconf_paths || true)

  if (( ${#updated_paths[@]} == 0 )); then
    while IFS= read -r plugin_id; do
      [[ -n "$plugin_id" ]] || continue
      update_whiskermenu_xfconf_menu_opacity "$plugin_id" "$opacity_percent" || return 1
      updated_paths+=("/plugins/plugin-${plugin_id}/menu-opacity")
    done < <(collect_whiskermenu_xfconf_plugin_ids || true)
  fi

  (( ${#updated_paths[@]} > 0 )) || return 1

  local joined=""
  local idx
  for idx in "${!updated_paths[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+="; "
    fi
    joined+="${updated_paths[idx]}"
  done
  LAST_APPLY_WHISKER_XFCONF="$joined"
  return 0
}

update_all_whiskermenu_rc_opacity() {
  local opacity_percent="$1"
  local file
  local -a updated_files=()

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    update_whiskermenu_rc_menu_opacity "$file" "$opacity_percent" || return 1
    updated_files+=("$file")
  done < <(collect_whiskermenu_rc_files)

  (( ${#updated_files[@]} > 0 )) || return 1

  local joined=""
  local idx
  for idx in "${!updated_files[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+="; "
    fi
    joined+="${updated_files[idx]}"
  done
  LAST_APPLY_WHISKER_FILES="$joined"
  return 0
}

update_picom_frame_opacity() {
  local picom_file="$1"
  local opacity_decimal="$2"
  local temp_file

  [[ -f "$picom_file" ]] || return 1
  create_backup_file "$picom_file" || return 1

  temp_file=$(mktemp) || return 1
  if sed -E "0,/^([[:space:]]*frame-opacity[[:space:]]*=[[:space:]]*)[0-9]+(\.[0-9]+)?([[:space:]]*;.*)$/s//\1${opacity_decimal}\3/" "$picom_file" > "$temp_file"; then
    if cmp -s "$picom_file" "$temp_file"; then
      if ! grep -Eq '^[[:space:]]*frame-opacity[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*;' "$picom_file"; then
        rm -f "$temp_file"
        return 1
      fi
    fi
    mv "$temp_file" "$picom_file"
    return 0
  fi

  rm -f "$temp_file"
  return 1
}

apply_transparency_files() {
  local css_file=""
  local opacity_percent=""
  local opacity_decimal=""
  local panel_xml_updated=0
  local whisker_rc_updated=0
  local whisker_xfconf_updated=0

  LAST_APPLY_MESSAGE=""
  LAST_APPLY_PANEL_XML="$PANEL_XML_FILE"
  LAST_APPLY_WHISKER_FILES=""
  LAST_APPLY_WHISKER_XFCONF=""
  LAST_APPLY_PANEL_CSS=""
  LAST_APPLY_PICOM_CONF="$PICOM_CONFIG_FILE"
  LAST_APPLY_MENU_OPACITY=""
  LAST_APPLY_PANEL_ALPHA=""
  LAST_APPLY_FRAME_OPACITY=""

  if [[ ! -f "$PICOM_CONFIG_FILE" ]]; then
    LAST_APPLY_MESSAGE="Picom config not found: $PICOM_CONFIG_FILE"
    return 1
  fi

  css_file=$(resolve_theme_css_file) || {
    LAST_APPLY_MESSAGE="colors-appearance.css not found below ~/.themes or the current script path."
    return 1
  }

  opacity_percent=$(get_panel_opacity_percent "$transparency" "$intensity")
  opacity_decimal=$(format_opacity_decimal "$opacity_percent")

  if [[ -f "$PANEL_XML_FILE" ]]; then
    if update_panel_xml_menu_opacity "$PANEL_XML_FILE" "$opacity_percent"; then
      panel_xml_updated=1
    fi
  fi

  if update_all_whiskermenu_xfconf_opacity "$opacity_percent"; then
    whisker_xfconf_updated=1
  fi

  if update_all_whiskermenu_rc_opacity "$opacity_percent"; then
    whisker_rc_updated=1
  fi

  if (( ! panel_xml_updated && ! whisker_xfconf_updated && ! whisker_rc_updated )); then
    LAST_APPLY_MESSAGE="Could not update Whisker menu opacity in xfconf, $PANEL_XML_FILE or under $WHISKERMENU_PANEL_DIR/whiskermenu*.rc"
    return 1
  fi

  update_panel_css_opacity "$css_file" "$opacity_decimal" || {
    LAST_APPLY_MESSAGE="Could not update panel alpha values in: $css_file"
    return 1
  }

  update_picom_frame_opacity "$PICOM_CONFIG_FILE" "$opacity_decimal" || {
    LAST_APPLY_MESSAGE="Could not update frame-opacity in: $PICOM_CONFIG_FILE"
    return 1
  }

  LAST_APPLY_PANEL_CSS="$css_file"
  LAST_APPLY_MENU_OPACITY="$opacity_percent"
  LAST_APPLY_PANEL_ALPHA="$opacity_decimal"
  LAST_APPLY_FRAME_OPACITY="$opacity_decimal"
  LAST_APPLY_MESSAGE="Applied menu-opacity=${opacity_percent} via xfconf property update, panel XML/Whisker rc sync, panel alpha=${opacity_decimal} and frame-opacity=${opacity_decimal}."

  return 0
}


restart_xfce4_panel() {
  command -v xfce4-panel >/dev/null 2>&1 || return 2

  if xfce4-panel -r >/dev/null 2>&1; then
    return 0
  fi

  pkill -x xfce4-panel >/dev/null 2>&1 || true
  sleep 0.35

  if command -v setsid >/dev/null 2>&1; then
    setsid xfce4-panel >/dev/null 2>&1 &
  else
    nohup xfce4-panel >/dev/null 2>&1 &
  fi

  sleep 0.35
  return 0
}

restart_xfwm4() {
  command -v xfwm4 >/dev/null 2>&1 || return 2

  if command -v setsid >/dev/null 2>&1; then
    setsid xfwm4 --replace >/dev/null 2>&1 &
  else
    nohup xfwm4 --replace >/dev/null 2>&1 &
  fi

  sleep 0.25
  return 0
}

restart_xfce_components() {
  local panel_rc=0
  local xfwm_rc=0

  LAST_RESTART_MESSAGE=""
  LAST_RESTART_PANEL_STATUS=""
  LAST_RESTART_XFWM_STATUS=""

  restart_xfce4_panel
  panel_rc=$?
  case "$panel_rc" in
    0) LAST_RESTART_PANEL_STATUS="restarted via xfce4-panel -r or full restart fallback" ;;
    1) LAST_RESTART_PANEL_STATUS="restart failed" ;;
    2) LAST_RESTART_PANEL_STATUS="xfce4-panel not found" ;;
    *) LAST_RESTART_PANEL_STATUS="unknown error (${panel_rc})" ;;
  esac

  restart_xfwm4
  xfwm_rc=$?
  case "$xfwm_rc" in
    0) LAST_RESTART_XFWM_STATUS="restarted via xfwm4 --replace" ;;
    1) LAST_RESTART_XFWM_STATUS="restart failed" ;;
    2) LAST_RESTART_XFWM_STATUS="xfwm4 not found" ;;
    *) LAST_RESTART_XFWM_STATUS="unknown error (${xfwm_rc})" ;;
  esac

  if (( panel_rc == 0 && xfwm_rc == 0 )); then
    LAST_RESTART_MESSAGE="Restarted xfce4-panel and xfwm4."
    return 0
  fi

  LAST_RESTART_MESSAGE="Restart warning: panel=${LAST_RESTART_PANEL_STATUS}; xfwm4=${LAST_RESTART_XFWM_STATUS}."
  return 1
}

run_save_action() {
  local color_apply_ok=0
  local transparency_apply_ok=0

  ACTION_STATUS_MESSAGE=""

  if apply_theme_color_files; then
    color_apply_ok=1
  fi

  if apply_transparency_files; then
    transparency_apply_ok=1
  fi

  if (( color_apply_ok || transparency_apply_ok )); then
    restart_xfce_components >/dev/null 2>&1 || true
  fi

  if (( color_apply_ok && transparency_apply_ok )); then
    commit_saved_state_from_current
    save_config
    ACTION_STATUS_MESSAGE="$(tr_text status_saved)"
    return 0
  fi

  ACTION_STATUS_MESSAGE="$(tr_text status_save_failed)"
  return 1
}

run_cancel_action() {
  local color_apply_ok=0
  local transparency_apply_ok=0

  restore_working_state_from_saved

  if apply_theme_color_files; then
    color_apply_ok=1
  fi

  if apply_transparency_files; then
    transparency_apply_ok=1
  fi

  if (( color_apply_ok || transparency_apply_ok )); then
    restart_xfce_components >/dev/null 2>&1 || true
  fi

  if (( color_apply_ok && transparency_apply_ok )); then
    ACTION_STATUS_MESSAGE="$(tr_text status_restored)"
    return 0
  fi

  ACTION_STATUS_MESSAGE="$(tr_text status_restore_failed)"
  return 1
}

# -----------------------------
# Main program
# -----------------------------
load_config
set_language_metrics
update_palette_colors
initialize_saved_and_working_state
auto_resize_message="$(tr_text not_run_yet)"

stty_state=$(stty -g 2>/dev/null || true)
apply_auto_window_size "$RECOMMENDED_ROWS" "$RECOMMENDED_COLS" >/dev/null 2>&1 || true

enter_alt
hide_cursor
stty -echo -icanon time 0 min 1
clear_screen

while true; do
  render
  key=$(read_key) || break
  apply_action "$key" && break
done

cleanup
trap - EXIT INT TERM WINCH
exit 0
