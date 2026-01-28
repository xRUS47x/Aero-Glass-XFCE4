#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Windows 7 Theme Color Tool for XFCE — centered Win7-like UI

This version fixes "missing XFWM4 assets recolored" by:
1) Recoloring XFWM4 button XPMS too (close/min/max/menu/shade/stick), BUT only for marker-family colors.
2) Optionally removing PNG duplicates so xfwm4 will use the recolored XPMs (important if xfwm prefers PNG).

XFWM4 "sentinel template" workflow:
- In your template folder, recolorable areas must use the marker color (default: #e2da9d)
- On apply, the tool copies the template folder into ./xfwm4
- Then it replaces only palette colors close to the marker with the selected color, preserving shading

Template folder names (inside theme root):
  xfwm4-template, xfwm4_template, xfwm4.template, xfwm4-tpl
"""

import colorsys
import json
import os
import re
import shutil
import subprocess
import time
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk


# ----------------------------
# XFWM4 sentinel configuration
# ----------------------------

XFWM4_MARKER_HEX = "#e2da9d"           # marker color used in your template
XFWM4_RGB_DISTANCE_THRESHOLD = 0.26    # "family" width around the marker (increase if your template uses more shades)

# If you still get wrong recolors in button glyphs, set this False and ensure only frames use marker.
XFWM4_TINT_BUTTONS_DEFAULT = True

# If xfwm seems to ignore recolored XPMs, enable this:
# It removes *.png duplicates in the generated ./xfwm4 so xfwm falls back to the recolored *.xpm files.
XFWM4_REMOVE_PNG_DUPLICATES_DEFAULT = False

XFWM4_BUTTON_PREFIXES = {"close", "hide", "maximize", "menu", "shade", "stick"}


# ----------------------------
# Utilities
# ----------------------------

def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))

def normalize_hex(s: str) -> str:
    s = (s or "").strip()
    if not s.startswith("#"):
        s = "#" + s
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", s):
        raise ValueError(f"Ungültige Farbe: {s} (erwarte #RRGGBB)")
    return s.lower()

def hex_to_rgb01(hex_color: str) -> Tuple[float, float, float]:
    hex_color = normalize_hex(hex_color)
    r = int(hex_color[1:3], 16) / 255.0
    g = int(hex_color[3:5], 16) / 255.0
    b = int(hex_color[5:7], 16) / 255.0
    return r, g, b

def rgb01_to_hex(rgb: Tuple[float, float, float]) -> str:
    r, g, b = rgb
    r8 = int(round(clamp(r, 0.0, 1.0) * 255))
    g8 = int(round(clamp(g, 0.0, 1.0) * 255))
    b8 = int(round(clamp(b, 0.0, 1.0) * 255))
    return "#{:02x}{:02x}{:02x}".format(r8, g8, b8).lower()

def rgb_distance(a: Tuple[float, float, float], b: Tuple[float, float, float]) -> float:
    return ((a[0]-b[0])**2 + (a[1]-b[1])**2 + (a[2]-b[2])**2) ** 0.5

def rgb01_to_hls(rgb: Tuple[float, float, float]) -> Tuple[float, float, float]:
    return colorsys.rgb_to_hls(rgb[0], rgb[1], rgb[2])

def hls_to_rgb01(hls: Tuple[float, float, float]) -> Tuple[float, float, float]:
    return colorsys.hls_to_rgb(hls[0], hls[1], hls[2])

def hue_delta_signed(h1: float, h2: float) -> float:
    d = (h1 - h2) % 1.0
    if d > 0.5:
        d -= 1.0
    return d

def mix_rgb01(a: Tuple[float, float, float], b: Tuple[float, float, float], t: float) -> Tuple[float, float, float]:
    t = clamp(t, 0.0, 1.0)
    return (
        (1.0 - t) * a[0] + t * b[0],
        (1.0 - t) * a[1] + t * b[1],
        (1.0 - t) * a[2] + t * b[2],
    )

def opacity_to_percent(opacity: float) -> int:
    return int(round(clamp(opacity, 0.0, 1.0) * 100))

def compute_final_color_and_opacity(base_hex: str, enable_transparency: bool, intensity_0_100: int) -> Tuple[str, float]:
    base_hex = normalize_hex(base_hex)
    t = clamp(intensity_0_100 / 100.0, 0.0, 1.0)

    white = (1.0, 1.0, 1.0)
    base_rgb = hex_to_rgb01(base_hex)

    if enable_transparency:
        # keep it visibly tinted, but still translucent
        tint_min = 0.10
        mix_t = tint_min + (1.0 - tint_min) * t
        opacity = 0.10 + 0.80 * t
    else:
        mix_t = t
        opacity = 1.00

    final_rgb = mix_rgb01(white, base_rgb, mix_t)
    return rgb01_to_hex(final_rgb), opacity

def run_cmd(args: List[str]) -> Tuple[int, str, str]:
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def get_real_home() -> Path:
    if os.geteuid() == 0 and os.environ.get("SUDO_USER"):
        try:
            import pwd
            user = os.environ["SUDO_USER"]
            return Path(pwd.getpwnam(user).pw_dir)
        except Exception:
            pass
    return Path.home()

def ensure_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    return p


# ----------------------------
# Settings persistence
# ----------------------------

def config_dir() -> Path:
    return ensure_dir(get_real_home() / ".config" / "aero-glass-xfce4" / "color-tool")

def settings_path() -> Path:
    return config_dir() / "settings.json"

def load_settings() -> Dict:
    p = settings_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}

def save_settings(data: Dict) -> None:
    p = settings_path()
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(p)


# ----------------------------
# Patch logic (Panel CSS / Whisker / XFWM opacity)
# ----------------------------

@dataclass
class AppConfig:
    theme_root: Path
    theme_name: str
    aero_css: Path
    xfwm4_dir: Path

def patch_aero_elements_css(css_path: Path, new_panel_base_hex: str, new_opacity: float) -> None:
    txt = css_path.read_text(encoding="utf-8", errors="replace")

    updated, n1 = re.subn(
        r"(@define-color\s+panel_base\s+)(#[0-9a-fA-F]{6})(\s*;)",
        rf"\g<1>{new_panel_base_hex}\g<3>",
        txt,
        count=1,
    )
    if n1 == 0:
        raise RuntimeError("Konnte '@define-color panel_base ...;' nicht finden/ersetzen.")

    op_str = f"{new_opacity:.2f}"
    updated, _ = re.subn(
        r"alpha\(@(edge_dark|edge_light|panel_base),\s*(0(?:\.\d+)?|1(?:\.0+)?)\)",
        rf"alpha(@\1, {op_str})",
        updated,
    )

    if updated != txt:
        css_path.write_text(updated, encoding="utf-8")

def set_xfwm_frame_opacity(percent: int) -> str:
    percent = int(clamp(percent, 0, 100))
    rc, out, err = run_cmd(["xfconf-query", "-c", "xfwm4", "-p", "/general/frame_opacity", "-s", str(percent)])
    if rc != 0:
        return f"XFWM4 frame_opacity failed: {err or out}".strip()
    return f"XFWM4 frame_opacity={percent}%"

def get_xfwm_frame_opacity() -> Optional[int]:
    rc, out, _ = run_cmd(["xfconf-query", "-c", "xfwm4", "-p", "/general/frame_opacity"])
    if rc != 0:
        return None
    try:
        return int(out.strip())
    except Exception:
        return None

def force_reload_xfwm_theme() -> str:
    rc, theme, err = run_cmd(["xfconf-query", "-c", "xfwm4", "-p", "/general/theme"])
    if rc != 0 or not theme:
        return f"xfwm4 theme reload: cannot read /general/theme ({err or theme})"
    rc2, out, err2 = run_cmd(["xfconf-query", "-c", "xfwm4", "-p", "/general/theme", "-s", theme.strip()])
    if rc2 != 0:
        return f"xfwm4 theme reload failed: {err2 or out}"
    return f"xfwm4 theme re-set: {theme.strip()}"

def find_whisker_plugin_ids_via_xfconf() -> List[int]:
    rc, props, _ = run_cmd(["xfconf-query", "-c", "xfce4-panel", "-l"])
    if rc != 0 or not props:
        return []
    ids: List[int] = []
    for line in props.splitlines():
        line = line.strip()
        m = re.fullmatch(r"/plugins/plugin-(\d+)", line)
        if not m:
            continue
        pid = int(m.group(1))
        rc2, val, _ = run_cmd(["xfconf-query", "-c", "xfce4-panel", "-p", line])
        if rc2 == 0 and val.strip().lower() == "whiskermenu":
            ids.append(pid)
    return sorted(set(ids))

def get_whisker_opacity_values() -> Dict[int, Optional[int]]:
    vals: Dict[int, Optional[int]] = {}
    ids = find_whisker_plugin_ids_via_xfconf()
    for pid in ids:
        key = f"/plugins/plugin-{pid}/menu-opacity"
        rc, out, _ = run_cmd(["xfconf-query", "-c", "xfce4-panel", "-p", key])
        if rc != 0:
            vals[pid] = None
        else:
            try:
                vals[pid] = int(out.strip())
            except Exception:
                vals[pid] = None
    return vals

def set_whisker_opacity_xfconf(percent: int) -> str:
    percent = int(clamp(percent, 0, 100))
    ids = find_whisker_plugin_ids_via_xfconf()
    if not ids:
        return "Whisker xfconf: no whiskermenu plugin IDs found"

    ok_all = True
    msgs: List[str] = []
    for pid in ids:
        key = f"/plugins/plugin-{pid}/menu-opacity"
        rc, out, err = run_cmd([
            "xfconf-query", "-c", "xfce4-panel", "-p", key,
            "--create", "-t", "int", "-s", str(int(percent))
        ])
        if rc != 0:
            ok_all = False
            msgs.append(f"plugin-{pid}: failed ({err or out})")
        else:
            msgs.append(f"plugin-{pid}: menu-opacity={percent}")

    prefix = "Whisker xfconf OK" if ok_all else "Whisker xfconf PARTIAL"
    return f"{prefix}: " + "; ".join(msgs)

def find_whisker_rc_files(home: Path) -> List[Path]:
    panel_dir = home / ".config" / "xfce4" / "panel"
    if not panel_dir.exists():
        return []
    files = set(panel_dir.glob("whiskermenu*.rc"))
    files |= set(panel_dir.glob("whiskermenu-*.rc"))
    return sorted([p for p in files if p.is_file()])

def set_whisker_opacity_rc(home: Path, percent: int) -> str:
    percent = int(clamp(percent, 0, 100))
    files = find_whisker_rc_files(home)
    if not files:
        return "Whisker rc: no files found"

    changed = 0
    for p in files:
        txt = p.read_text(encoding="utf-8", errors="replace")
        if re.search(r"^menu-opacity\s*=", txt, flags=re.M):
            new_txt = re.sub(r"^menu-opacity\s*=.*$", f"menu-opacity={percent}", txt, flags=re.M)
        else:
            sep = "" if txt.endswith("\n") else "\n"
            new_txt = txt + sep + f"menu-opacity={percent}\n"
        if new_txt != txt:
            p.write_text(new_txt, encoding="utf-8")
            changed += 1
    return f"Whisker rc: menu-opacity={percent} ({changed}/{len(files)} files)"

def restart_xfwm() -> None:
    subprocess.Popen(["xfwm4", "--replace"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def restart_panel() -> None:
    subprocess.Popen(["xfce4-panel", "-r"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ----------------------------
# XFWM4 generation (template -> xfwm4, recolor marker-family in XPMs)
# ----------------------------

def find_xfwm4_template(theme_root: Path) -> Optional[Path]:
    candidates = [
        theme_root / "xfwm4-template",
        theme_root / "xfwm4_template",
        theme_root / "xfwm4.template",
        theme_root / "xfwm4-tpl",
    ]
    for p in candidates:
        if p.exists() and p.is_dir():
            return p
    return None

def list_xpm_files(folder: Path) -> List[Path]:
    if not folder.exists():
        return []
    return sorted([p for p in folder.rglob("*.xpm") if p.is_file()])

def list_png_files(folder: Path) -> List[Path]:
    if not folder.exists():
        return []
    return sorted([p for p in folder.rglob("*.png") if p.is_file()])

def filename_prefix(p: Path) -> str:
    return re.sub(r"-.*$", "", p.name).lower()

def backup_xfwm4(theme_root: Path, xfwm4_dir: Path) -> Optional[Path]:
    if not xfwm4_dir.exists():
        return None
    backups_root = ensure_dir(theme_root / "xfwm4-backups")
    stamp = time.strftime("%Y-%m-%d_%H-%M-%S")
    dst = backups_root / f"xfwm4_{stamp}"
    shutil.copytree(xfwm4_dir, dst)
    return dst

def restore_from_template(template_dir: Path, xfwm4_dir: Path) -> None:
    if xfwm4_dir.exists():
        shutil.rmtree(xfwm4_dir)
    shutil.copytree(template_dir, xfwm4_dir)

HEX_RE = re.compile(r"\s+c\s+(#[0-9A-Fa-f]{6}|None)\s*")

def parse_palette_lines(text: str) -> List[Tuple[int, str]]:
    out = []
    for i, line in enumerate(text.splitlines()):
        m = HEX_RE.search(line)
        if not m:
            continue
        val = m.group(1)
        if val.lower() == "none":
            continue
        out.append((i, val.lower()))
    return out

def build_marker_family_colors(xpm_files: List[Path], tint_buttons: bool) -> List[str]:
    """
    Scan XPMS and return unique palette colors close to the marker.
    """
    marker_rgb = hex_to_rgb01(XFWM4_MARKER_HEX)
    family: Dict[str, float] = {}

    for p in xpm_files:
        pref = filename_prefix(p)
        if (not tint_buttons) and (pref in XFWM4_BUTTON_PREFIXES):
            continue

        txt = p.read_text(encoding="utf-8", errors="replace")
        for _, hx in parse_palette_lines(txt):
            if hx == XFWM4_MARKER_HEX:
                family[hx] = 0.0
                continue
            d = rgb_distance(hex_to_rgb01(hx), marker_rgb)
            if d <= XFWM4_RGB_DISTANCE_THRESHOLD:
                family[hx] = min(family.get(hx, 9.0), d)

    return [k for k, _ in sorted(family.items(), key=lambda kv: kv[1])]

def map_family_color(hx: str, target_hex: str) -> str:
    """
    Preserve relative hue/lightness/saturation offsets vs marker, then apply to target.
    """
    src_rgb = hex_to_rgb01(hx)
    base_rgb = hex_to_rgb01(XFWM4_MARKER_HEX)
    tgt_rgb = hex_to_rgb01(target_hex)

    src_h, src_l, src_s = rgb01_to_hls(src_rgb)
    base_h, base_l, base_s = rgb01_to_hls(base_rgb)
    tgt_h, tgt_l, tgt_s = rgb01_to_hls(tgt_rgb)

    if src_s > 0.05 and base_s > 0.05:
        dh = hue_delta_signed(src_h, base_h)
        new_h = (tgt_h + dh) % 1.0
    else:
        new_h = tgt_h

    new_l = clamp(tgt_l + (src_l - base_l), 0.0, 1.0)

    if base_s > 0.02:
        new_s = clamp(tgt_s * (src_s / base_s), 0.0, 1.0)
    else:
        new_s = clamp(src_s, 0.0, 1.0)

    return rgb01_to_hex(hls_to_rgb01((new_h, new_l, new_s))).lower()

def recolor_xpm_palette_with_mapping(xpm_path: Path, mapping: Dict[str, str]) -> int:
    """
    Recolors ONLY palette lines ("... c #RRGGBB ...") using the given mapping.
    """
    txt = xpm_path.read_text(encoding="utf-8", errors="replace")
    lines = txt.splitlines()
    changed = 0

    palette = parse_palette_lines(txt)
    for idx, hx in palette:
        if hx not in mapping:
            continue
        new_hex = mapping[hx]
        if new_hex == hx:
            continue

        line = lines[idx]
        pat = rf"(\s+c\s+){re.escape(hx)}(\s*)"
        new_line, n = re.subn(pat, rf"\1{new_hex}\2", line, count=1)
        if n == 0:
            new_line = line.replace(hx, new_hex, 1)

        if new_line != line:
            lines[idx] = new_line
            changed += 1

    if changed > 0:
        xpm_path.write_text("\n".join(lines) + ("\n" if txt.endswith("\n") else ""), encoding="utf-8")
    return changed

def remove_png_duplicates(folder: Path) -> int:
    """
    Remove *.png files that have a sibling *.xpm with the same stem.
    This forces xfwm4 to use recolored XPMs if it prefers PNG.
    """
    removed = 0
    pngs = list_png_files(folder)
    if not pngs:
        return 0
    xpm_stems = {p.stem for p in list_xpm_files(folder)}
    for p in pngs:
        if p.stem in xpm_stems:
            try:
                p.unlink()
                removed += 1
            except Exception:
                pass
    return removed

def generate_xfwm4_from_template_sentinel(
    theme_root: Path,
    xfwm4_dir: Path,
    target_hex: str,
    backup_each_apply: bool,
    tint_buttons: bool,
    drop_png_duplicates: bool,
) -> Tuple[str, int, int]:
    template_dir = find_xfwm4_template(theme_root)
    if not template_dir:
        return ("XFWM4: no template folder found (expected: xfwm4-template)", 0, 0)

    backup_msg = "backup -> OFF"
    if backup_each_apply and xfwm4_dir.exists():
        b = backup_xfwm4(theme_root, xfwm4_dir)
        backup_msg = f"backup -> {b.name}" if b else "backup -> skipped"

    restore_from_template(template_dir, xfwm4_dir)

    xpm_files = list_xpm_files(xfwm4_dir)
    if not xpm_files:
        return (f"XFWM4: template copied, but no XPM files found ({backup_msg})", 0, 0)

    family = build_marker_family_colors(xpm_files, tint_buttons=tint_buttons)
    if not family:
        return (f"XFWM4: marker family empty — no colors near {XFWM4_MARKER_HEX} found ({backup_msg})", 0, 0)

    mapping = {hx: map_family_color(hx, target_hex) for hx in family}

    files_modified = 0
    entries_modified = 0
    for p in xpm_files:
        pref = filename_prefix(p)
        if (not tint_buttons) and (pref in XFWM4_BUTTON_PREFIXES):
            continue
        n = recolor_xpm_palette_with_mapping(p, mapping)
        if n > 0:
            files_modified += 1
            entries_modified += n

    removed_png = remove_png_duplicates(xfwm4_dir) if drop_png_duplicates else 0

    msg = (
        f"XFWM4: template={template_dir.name}, {backup_msg}, "
        f"marker={XFWM4_MARKER_HEX} -> target={normalize_hex(target_hex)}, "
        f"family={len(family)} colors, modified {files_modified} files ({entries_modified} palette entries), "
        f"tint_buttons={'ON' if tint_buttons else 'OFF'}, removed_png={removed_png}"
    )
    return (msg, files_modified, entries_modified)


# ----------------------------
# UI
# ----------------------------

PRESETS: List[Tuple[str, str]] = [
    ("Sky", "#afcbe6"),
    ("Twilight", "#396cb6"),
    ("Sea", "#80d1d1"),
    ("Leaf", "#8bc483"),
    ("Lime", "#bed999"),
    ("Sun", "#e2da9d"),
    ("Pumpkin", "#ebb767"),
    ("Ruby", "#ce4444"),
    ("Fuchsia", "#e783bf"),
    ("Blush", "#e7d0e5"),
    ("Violet", "#9d80b8"),
    ("Lavender", "#c3b4c5"),
    ("Taupe", "#bfb7a1"),
    ("Chocolate", "#724c4c"),
    ("Slate", "#939393"),
    ("Frost", "#e3e3e3"),
]

def install_global_css():
    css = b"""
    button.color-swatch {
        padding: 0;
        margin: 0;
        border: 1px solid rgba(0,0,0,0.35);
        border-radius: 4px;
        background-clip: padding-box;
        background-repeat: no-repeat;
        background-image:
            radial-gradient(circle at 30% 28%,
                rgba(255,255,255,0.85) 0%,
                rgba(255,255,255,0.0) 62%),
            linear-gradient(to bottom,
                rgba(255,255,255,0.55) 0%,
                rgba(255,255,255,0.10) 35%,
                rgba(255,255,255,0.0) 60%);
        box-shadow:
            0 1px 0 rgba(255,255,255,0.08) inset,
            0 0 0 1px rgba(255,255,255,0.06) inset;
    }
    button.color-swatch:hover {
        border: 1px solid rgba(0,0,0,0.55);
    }
    button.color-swatch.selected {
        box-shadow:
            0 0 0 2px rgba(255,255,255,0.92),
            0 0 0 3px rgba(0,0,0,0.45),
            0 1px 0 rgba(255,255,255,0.08) inset,
            0 0 0 1px rgba(255,255,255,0.06) inset;
    }
    """
    provider = Gtk.CssProvider()
    provider.load_from_data(css)
    screen = Gdk.Screen.get_default()
    Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

class ColorSwatch(Gtk.Button):
    def __init__(self, name: str, hexv: str):
        super().__init__()
        self.name = name
        self.hexv = normalize_hex(hexv)
        self.set_size_request(64, 64)
        self.set_tooltip_text(f"{self.name} ({self.hexv})")
        self.set_relief(Gtk.ReliefStyle.NONE)

        ctx = self.get_style_context()
        ctx.add_class("color-swatch")

        provider = Gtk.CssProvider()
        provider.load_from_data(f"button {{ background-color: {self.hexv}; }}".encode("utf-8"))
        ctx.add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def set_selected(self, selected: bool):
        ctx = self.get_style_context()
        if selected:
            ctx.add_class("selected")
        else:
            ctx.remove_class("selected")


class Win7ColorTool(Gtk.Window):
    def __init__(self, cfg: AppConfig):
        super().__init__(title="Window Color and Appearance")
        self.cfg = cfg

        self.set_default_size(960, 760)
        self.set_border_width(14)
        install_global_css()

        # Dynamic Win7-like slider gradients (Hue/Saturation/Brightness tracks)
        self._slider_css_provider = Gtk.CssProvider()
        screen = Gdk.Screen.get_default()
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(
                screen, self._slider_css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        self._committed = False
        s = load_settings()

        self.selected_name = s.get("selected_name", PRESETS[0][0])
        self.base_hex = normalize_hex(s.get("base_hex", PRESETS[0][1]))
        self.enable_transparency = bool(s.get("enable_transparency", True))
        self.intensity = int(s.get("intensity", 75))

        r, g, b = hex_to_rgb01(self.base_hex)
        hh, ss, vv = colorsys.rgb_to_hsv(r, g, b)
        self.h = int(s.get("h", round(hh * 360)))
        self.sat = int(s.get("sat", round(ss * 100)))
        self.val = int(s.get("val", round(vv * 100)))

        self.auto_apply = bool(s.get("auto_apply", True))
        self.sync_whisker = bool(s.get("sync_whisker", True))
        self.sync_xfwm_opacity = bool(s.get("sync_xfwm_opacity", True))
        self.do_restart_xfwm = bool(s.get("do_restart_xfwm", True))
        self.do_restart_panel = bool(s.get("do_restart_panel", True))

        self.update_xfwm4 = bool(s.get("update_xfwm4", True))
        self.xfwm4_backup_each_apply = bool(s.get("xfwm4_backup_each_apply", True))
        self.force_xfwm_reload = bool(s.get("force_xfwm_reload", True))

        self.xfwm4_tint_buttons = bool(s.get("xfwm4_tint_buttons", XFWM4_TINT_BUTTONS_DEFAULT))
        self.xfwm4_drop_png = bool(s.get("xfwm4_drop_png", XFWM4_REMOVE_PNG_DUPLICATES_DEFAULT))

        self._session_backup: Dict = {}
        self._create_session_backup()

        self._apply_id = None
        self._restart_id = None
        self._xfwm_id = None

        self.connect("delete-event", self.on_delete_event)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(outer)

        header = Gtk.Label(label="Change the color of your window borders, Start menu, and taskbar")
        header.set_halign(Gtk.Align.CENTER)
        outer.pack_start(header, False, False, 0)

        center = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        center.set_halign(Gtk.Align.CENTER)
        outer.pack_start(center, True, True, 0)

        self.swatch_buttons: List[ColorSwatch] = []
        flow = Gtk.FlowBox()
        flow.set_selection_mode(Gtk.SelectionMode.NONE)
        flow.set_max_children_per_line(8)
        flow.set_min_children_per_line(8)
        flow.set_row_spacing(12)
        flow.set_column_spacing(12)
        flow.set_halign(Gtk.Align.CENTER)

        for name, hexv in PRESETS:
            btn = ColorSwatch(name, hexv)
            btn.connect("clicked", self.on_preset_clicked)
            self.swatch_buttons.append(btn)
            flow.add(btn)
        center.pack_start(flow, False, False, 0)

        self.lbl_current = Gtk.Label()
        self.lbl_current.set_xalign(0)
        self.lbl_current.set_halign(Gtk.Align.FILL)
        center.pack_start(self.lbl_current, False, False, 0)

        self.chk_transparency = Gtk.CheckButton(label="Enable transparency")
        self.chk_transparency.set_active(self.enable_transparency)
        self.chk_transparency.connect("toggled", self.on_controls_changed)
        center.pack_start(self.chk_transparency, False, False, 0)

        row_int = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        row_int.set_hexpand(True)
        lbl = Gtk.Label(label="Color intensity:")
        lbl.set_xalign(0)
        row_int.pack_start(lbl, False, False, 0)

        self.scale_intensity = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
        self.scale_intensity.set_value(self.intensity)
        self.scale_intensity.set_hexpand(True)
        self.scale_intensity.set_draw_value(True)
        self.scale_intensity.set_digits(0)
        self.scale_intensity.set_value_pos(Gtk.PositionType.TOP)
        self.scale_intensity.connect("value-changed", self.on_controls_changed)
        row_int.pack_start(self.scale_intensity, True, True, 0)
        center.pack_start(row_int, False, False, 0)

        exp_mixer = Gtk.Expander(label="Advanced color mixer")
        exp_mixer.set_expanded(True)
        exp_mixer.set_hexpand(True)
        center.pack_start(exp_mixer, False, False, 0)

        mixer_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        exp_mixer.add(mixer_box)

        self.preview = Gtk.DrawingArea()
        self.preview.set_size_request(720, 44)
        self.preview.connect("draw", self.on_preview_draw)
        mixer_box.pack_start(self.preview, False, False, 0)

        self.scale_h = self._make_slider(mixer_box, "Hue:", 0, 360, self.h, self.on_mixer_changed)
        self.scale_s = self._make_slider(mixer_box, "Saturation:", 0, 100, self.sat, self.on_mixer_changed)
        self.scale_v = self._make_slider(mixer_box, "Brightness:", 0, 100, self.val, self.on_mixer_changed)

        self._update_mixer_slider_gradients()

        exp_settings = Gtk.Expander(label="Settings")
        exp_settings.set_expanded(False)
        exp_settings.set_hexpand(True)
        center.pack_start(exp_settings, False, False, 0)

        settings_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        exp_settings.add(settings_box)

        self.chk_auto = Gtk.CheckButton(label="Apply automatically while dragging")
        self.chk_auto.set_active(self.auto_apply)
        self.chk_auto.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_auto, False, False, 0)

        self.chk_restart_xfwm = Gtk.CheckButton(label="Restart xfwm4 after applying")
        self.chk_restart_xfwm.set_active(self.do_restart_xfwm)
        self.chk_restart_xfwm.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_restart_xfwm, False, False, 0)

        self.chk_restart_panel = Gtk.CheckButton(label="Restart xfce4-panel after applying")
        self.chk_restart_panel.set_active(self.do_restart_panel)
        self.chk_restart_panel.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_restart_panel, False, False, 0)

        self.chk_sync_whisker = Gtk.CheckButton(label="Sync Whisker background opacity (menu-opacity)")
        self.chk_sync_whisker.set_active(self.sync_whisker)
        self.chk_sync_whisker.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_sync_whisker, False, False, 0)

        self.chk_sync_xfwm_opacity = Gtk.CheckButton(label="Sync XFWM4 frame opacity")
        self.chk_sync_xfwm_opacity.set_active(self.sync_xfwm_opacity)
        self.chk_sync_xfwm_opacity.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_sync_xfwm_opacity, False, False, 0)

        self.chk_update_xfwm4 = Gtk.CheckButton(label="Update XFWM4 decorations (template marker mode)")
        self.chk_update_xfwm4.set_active(self.update_xfwm4)
        self.chk_update_xfwm4.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_update_xfwm4, False, False, 0)

        self.chk_xfwm_backup = Gtk.CheckButton(label="Backup previous generated xfwm4 to xfwm4-backups (each apply)")
        self.chk_xfwm_backup.set_active(self.xfwm4_backup_each_apply)
        self.chk_xfwm_backup.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_xfwm_backup, False, False, 0)

        self.chk_force_reload = Gtk.CheckButton(label="Force xfwm4 theme reload (set theme again)")
        self.chk_force_reload.set_active(self.force_xfwm_reload)
        self.chk_force_reload.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_force_reload, False, False, 0)

        self.chk_tint_buttons = Gtk.CheckButton(label="Tint window buttons too (close/min/max/...)")
        self.chk_tint_buttons.set_active(self.xfwm4_tint_buttons)
        self.chk_tint_buttons.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_tint_buttons, False, False, 0)

        self.chk_drop_png = Gtk.CheckButton(label="Prefer recolored XPM (remove PNG duplicates)")
        self.chk_drop_png.set_active(self.xfwm4_drop_png)
        self.chk_drop_png.connect("toggled", self.on_settings_changed)
        settings_box.pack_start(self.chk_drop_png, False, False, 0)

        self.status = Gtk.Label(label="")
        self.status.set_xalign(0)
        self.status.set_line_wrap(True)
        settings_box.pack_start(self.status, False, False, 0)

        bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        bottom.set_halign(Gtk.Align.END)
        outer.pack_end(bottom, False, False, 0)

        btn_cancel = Gtk.Button(label="Cancel")
        btn_cancel.connect("clicked", self.on_cancel_clicked)
        bottom.pack_start(btn_cancel, False, False, 0)

        btn_apply = Gtk.Button(label="Apply")
        btn_apply.connect("clicked", self.on_apply_clicked)
        bottom.pack_start(btn_apply, False, False, 0)

        btn_save_settings = Gtk.Button(label="Save settings")
        btn_save_settings.connect("clicked", self.on_save_settings_clicked)
        bottom.pack_start(btn_save_settings, False, False, 0)

        btn_save = Gtk.Button(label="Save changes")
        btn_save.get_style_context().add_class("suggested-action")
        btn_save.connect("clicked", self.on_save_clicked)
        bottom.pack_start(btn_save, False, False, 0)

        self._sync_swatch_selection()
        self._refresh_labels()
        self.preview.queue_draw()

        self._schedule_apply()
        self._schedule_xfwm()

    def _session_backup_dir(self) -> Path:
        return ensure_dir(config_dir() / "session-backup")

    def _create_session_backup(self):
        b: Dict = {}
        try:
            b["aero_css_text"] = self.cfg.aero_css.read_text(encoding="utf-8", errors="replace")
        except Exception:
            b["aero_css_text"] = None

        b["whisker_opacity"] = {str(k): v for k, v in get_whisker_opacity_values().items()}
        b["xfwm_frame_opacity"] = get_xfwm_frame_opacity()

        try:
            src = self.cfg.xfwm4_dir
            if src.exists() and src.is_dir():
                dst = self._session_backup_dir() / "xfwm4"
                if dst.exists():
                    shutil.rmtree(dst)
                shutil.copytree(src, dst)
                b["xfwm4_backup_path"] = str(dst)
            else:
                b["xfwm4_backup_path"] = None
        except Exception:
            b["xfwm4_backup_path"] = None

        self._session_backup = b

    def _restore_session_backup(self):
        msgs: List[str] = []
        b = self._session_backup or {}

        try:
            if b.get("aero_css_text") is not None:
                self.cfg.aero_css.write_text(b["aero_css_text"], encoding="utf-8")
                msgs.append("Restored: aero-elements.css")
        except Exception as e:
            msgs.append(f"Restore CSS failed: {e}")

        try:
            whisk = b.get("whisker_opacity") or {}
            for k, v in whisk.items():
                try:
                    pid = int(k)
                except Exception:
                    continue
                if v is None:
                    continue
                key = f"/plugins/plugin-{pid}/menu-opacity"
                run_cmd(["xfconf-query", "-c", "xfce4-panel", "-p", key, "--create", "-t", "int", "-s", str(int(v))])
            if whisk:
                msgs.append("Restored: Whisker menu-opacity (xfconf)")
        except Exception as e:
            msgs.append(f"Restore Whisker failed: {e}")

        try:
            xo = b.get("xfwm_frame_opacity")
            if xo is not None:
                run_cmd(["xfconf-query", "-c", "xfwm4", "-p", "/general/frame_opacity", "-s", str(int(xo))])
                msgs.append(f"Restored: XFWM4 frame_opacity={xo}%")
        except Exception as e:
            msgs.append(f"Restore XFWM opacity failed: {e}")

        try:
            p = b.get("xfwm4_backup_path")
            if p:
                src = Path(p)
                dst = self.cfg.xfwm4_dir
                if src.exists() and src.is_dir():
                    if dst.exists():
                        shutil.rmtree(dst)
                    shutil.copytree(src, dst)
                    msgs.append("Restored: xfwm4 folder")
        except Exception as e:
            msgs.append(f"Restore xfwm4 folder failed: {e}")

        try:
            if self.do_restart_xfwm:
                restart_xfwm()
                msgs.append("xfwm4 restarted")
                if self.force_xfwm_reload:
                    msgs.append(force_reload_xfwm_theme())
            if self.do_restart_panel:
                restart_panel()
                msgs.append("xfce4-panel restarted")
        except Exception as e:
            msgs.append(f"Restart failed: {e}")

        self.status.set_text("Restored backup:\n- " + "\n- ".join(msgs))

    def on_delete_event(self, *_):
        if not self._committed:
            self._restore_session_backup()
        return False


    def _update_mixer_slider_gradients(self) -> None:
        """Update Hue/Saturation/Brightness slider tracks to look like Windows 7."""
        if not hasattr(self, "_slider_css_provider"):
            return

        try:
            h = float(self.scale_h.get_value()) / 360.0 if hasattr(self, "scale_h") else 0.0
            s = float(self.scale_s.get_value()) / 100.0 if hasattr(self, "scale_s") else 0.0
            v = float(self.scale_v.get_value()) / 100.0 if hasattr(self, "scale_v") else 0.0

            sat_left = colorsys.hsv_to_rgb(h, 0.0, v)
            sat_right = colorsys.hsv_to_rgb(h, 1.0, v)
            val_right = colorsys.hsv_to_rgb(h, s, 1.0)

            css = f"""
            /* Win7-like slider troughs (colored tracks) */
            scale.win7-hue trough,
            scale.win7-sat trough,
            scale.win7-val trough {{
                min-height: 8px;
                border-radius: 0;
                border: 1px solid rgba(0,0,0,0.45);
                box-shadow: 0 0 0 1px rgba(255,255,255,0.35) inset;
                background-repeat: no-repeat;
                background-size: 100% 100%;
            }}

            /* Hide the filled highlight so the full gradient stays visible */
            scale.win7-hue trough highlight,
            scale.win7-sat trough highlight,
            scale.win7-val trough highlight {{
                background-color: transparent;
                background-image: none;
                box-shadow: none;
            }}

            scale.win7-hue trough {{
                background-image: linear-gradient(to right,
                    #ff0000,
                    #ffff00,
                    #00ff00,
                    #00ffff,
                    #0000ff,
                    #ff00ff,
                    #ff0000);
            }}

            scale.win7-sat trough {{
                background-image: linear-gradient(to right, {rgb01_to_hex(sat_left)}, {rgb01_to_hex(sat_right)});
            }}

            scale.win7-val trough {{
                background-image: linear-gradient(to right, #000000, {rgb01_to_hex(val_right)});
            }}
            """
            self._slider_css_provider.load_from_data(css.encode("utf-8"))
        except Exception:
            # Never break the tool if the CSS backend doesn't support something
            return

    def _make_slider(self, parent: Gtk.Box, label: str, mn: int, mx: int, val: int, cb) -> Gtk.Scale:
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        row.set_hexpand(True)

        lab = Gtk.Label(label=label)
        lab.set_xalign(0)
        row.pack_start(lab, False, False, 0)

        sc = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, mn, mx, 1)
        sc.set_value(val)
        sc.set_hexpand(True)
        sc.set_draw_value(True)
        sc.set_digits(0)
        sc.set_value_pos(Gtk.PositionType.TOP)
        sc.connect("value-changed", cb)

        # Add Win7-like slider classes so we can style the trough with gradients
        ctx = sc.get_style_context()
        low = (label or "").strip().lower()
        if low.startswith("hue"):
            ctx.add_class("win7-hue")
        elif low.startswith("saturation"):
            ctx.add_class("win7-sat")
        elif low.startswith("brightness"):
            ctx.add_class("win7-val")

        row.pack_start(sc, True, True, 0)

        parent.pack_start(row, False, False, 0)
        return sc

    def _sync_swatch_selection(self):
        matched = False
        for b in self.swatch_buttons:
            sel = (normalize_hex(b.hexv) == normalize_hex(self.base_hex))
            b.set_selected(sel)
            matched = matched or sel
        if not matched:
            self.selected_name = "Custom"

    def _refresh_labels(self):
        applied_hex, _ = compute_final_color_and_opacity(self.base_hex, self.enable_transparency, self.intensity)
        self.lbl_current.set_text(f"Current color: {self.selected_name} ({applied_hex})")

    def _persist_settings(self):
        data = {
            "selected_name": self.selected_name,
            "base_hex": normalize_hex(self.base_hex),
            "enable_transparency": bool(self.enable_transparency),
            "intensity": int(self.intensity),
            "h": int(self.scale_h.get_value()),
            "sat": int(self.scale_s.get_value()),
            "val": int(self.scale_v.get_value()),
            "auto_apply": bool(self.auto_apply),
            "sync_whisker": bool(self.sync_whisker),
            "sync_xfwm_opacity": bool(self.sync_xfwm_opacity),
            "do_restart_xfwm": bool(self.do_restart_xfwm),
            "do_restart_panel": bool(self.do_restart_panel),
            "update_xfwm4": bool(self.update_xfwm4),
            "xfwm4_backup_each_apply": bool(self.xfwm4_backup_each_apply),
            "force_xfwm_reload": bool(self.force_xfwm_reload),
            "xfwm4_tint_buttons": bool(self.xfwm4_tint_buttons),
            "xfwm4_drop_png": bool(self.xfwm4_drop_png),
        }
        save_settings(data)

    def on_preset_clicked(self, btn: Gtk.Button):
        if not isinstance(btn, ColorSwatch):
            return
        self.selected_name = btn.name
        self.base_hex = btn.hexv

        r, g, b = hex_to_rgb01(self.base_hex)
        hh, ss, vv = colorsys.rgb_to_hsv(r, g, b)

        self.scale_h.handler_block_by_func(self.on_mixer_changed)
        self.scale_s.handler_block_by_func(self.on_mixer_changed)
        self.scale_v.handler_block_by_func(self.on_mixer_changed)
        try:
            self.scale_h.set_value(int(round(hh * 360)))
            self.scale_s.set_value(int(round(ss * 100)))
            self.scale_v.set_value(int(round(vv * 100)))
        finally:
            self.scale_h.handler_unblock_by_func(self.on_mixer_changed)
            self.scale_s.handler_unblock_by_func(self.on_mixer_changed)
            self.scale_v.handler_unblock_by_func(self.on_mixer_changed)

        self._update_mixer_slider_gradients()

        self._sync_swatch_selection()
        self._refresh_labels()
        self.preview.queue_draw()
        self._schedule_apply()
        self._schedule_xfwm()

    def on_controls_changed(self, *_):
        self.enable_transparency = self.chk_transparency.get_active()
        self.intensity = int(self.scale_intensity.get_value())
        self._refresh_labels()
        self.preview.queue_draw()
        self._schedule_apply()
        self._schedule_xfwm()

    def on_mixer_changed(self, *_):
        h = int(self.scale_h.get_value())
        s = int(self.scale_s.get_value())
        v = int(self.scale_v.get_value())
        r, g, b = colorsys.hsv_to_rgb(h / 360.0, s / 100.0, v / 100.0)

        self.base_hex = rgb01_to_hex((r, g, b))
        self.selected_name = "Custom"

        self._update_mixer_slider_gradients()

        self._sync_swatch_selection()
        self._refresh_labels()
        self.preview.queue_draw()
        self._schedule_apply()
        self._schedule_xfwm()

    def on_settings_changed(self, *_):
        self.auto_apply = self.chk_auto.get_active()
        self.do_restart_xfwm = self.chk_restart_xfwm.get_active()
        self.do_restart_panel = self.chk_restart_panel.get_active()
        self.sync_whisker = self.chk_sync_whisker.get_active()
        self.sync_xfwm_opacity = self.chk_sync_xfwm_opacity.get_active()

        self.update_xfwm4 = self.chk_update_xfwm4.get_active()
        self.xfwm4_backup_each_apply = self.chk_xfwm_backup.get_active()
        self.force_xfwm_reload = self.chk_force_reload.get_active()

        self.xfwm4_tint_buttons = self.chk_tint_buttons.get_active()
        self.xfwm4_drop_png = self.chk_drop_png.get_active()

        self._schedule_apply()
        self._schedule_xfwm()

    def on_cancel_clicked(self, *_):
        self._restore_session_backup()
        self.close()

    def on_apply_clicked(self, *_):
        self._apply_now(force_restarts=True, force_xfwm=True)

    def on_save_settings_clicked(self, *_):
        self._persist_settings()
        self.status.set_text("Settings saved.")

    def on_save_clicked(self, *_):
        self._apply_now(force_restarts=True, force_xfwm=True)
        self._persist_settings()
        self._committed = True
        self.close()

    def on_preview_draw(self, area, cr):
        applied_hex, _ = compute_final_color_and_opacity(self.base_hex, self.enable_transparency, self.intensity)
        rgba = Gdk.RGBA()
        rgba.parse(applied_hex)
        alloc = area.get_allocation()

        cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 1.0)
        cr.rectangle(0, 0, alloc.width, alloc.height)
        cr.fill()

        cr.set_source_rgba(1, 1, 1, 0.35)
        cr.rectangle(1, 1, alloc.width - 2, alloc.height - 2)
        cr.stroke()
        return False

    def _schedule_apply(self):
        if not self.auto_apply:
            return
        if self._apply_id is not None:
            GLib.source_remove(self._apply_id)
        self._apply_id = GLib.timeout_add(250, self._apply_debounced)

    def _apply_debounced(self):
        self._apply_id = None
        self._apply_now(force_restarts=False, force_xfwm=False)
        return False

    def _schedule_xfwm(self):
        if not self.auto_apply:
            return
        if not self.update_xfwm4:
            return
        if self._xfwm_id is not None:
            GLib.source_remove(self._xfwm_id)
        self._xfwm_id = GLib.timeout_add(900, self._xfwm_debounced)

    def _xfwm_debounced(self):
        self._xfwm_id = None
        try:
            msg = self._apply_xfwm4_generation()
            if msg:
                self.status.set_text(self.status.get_text() + "\n- " + msg)
        except Exception:
            self.status.set_text(self.status.get_text() + "\nXFWM4 error:\n" + traceback.format_exc())
        return False

    def _apply_now(self, force_restarts: bool, force_xfwm: bool):
        applied_hex, opacity = compute_final_color_and_opacity(self.base_hex, self.enable_transparency, self.intensity)
        percent = 100 if not self.enable_transparency else opacity_to_percent(opacity)

        msgs: List[str] = []
        try:
            patch_aero_elements_css(self.cfg.aero_css, applied_hex, opacity)
            msgs.append(f"GTK CSS: panel_base={applied_hex}, alpha={opacity:.2f}")

            if self.sync_whisker:
                msgs.append(set_whisker_opacity_xfconf(percent))
                msgs.append(set_whisker_opacity_rc(get_real_home(), percent))

            if self.sync_xfwm_opacity:
                msgs.append(set_xfwm_frame_opacity(percent))

        except Exception:
            self.status.set_text("Error:\n" + traceback.format_exc())
            return

        if force_xfwm and self.update_xfwm4:
            try:
                msgs.append(self._apply_xfwm4_generation())
            except Exception:
                msgs.append("XFWM4 generation error:\n" + traceback.format_exc())

        if force_restarts:
            self._do_restarts_now()
        else:
            if self._restart_id is not None:
                GLib.source_remove(self._restart_id)
            self._restart_id = GLib.timeout_add(900, lambda: self._do_restarts_now() or False)

        self.status.set_text("Applied:\n- " + "\n- ".join([m for m in msgs if m]))

    def _apply_xfwm4_generation(self) -> str:
        applied_hex, _ = compute_final_color_and_opacity(self.base_hex, self.enable_transparency, self.intensity)
        msg, _, _ = generate_xfwm4_from_template_sentinel(
            theme_root=self.cfg.theme_root,
            xfwm4_dir=self.cfg.xfwm4_dir,
            target_hex=applied_hex,
            backup_each_apply=self.xfwm4_backup_each_apply,
            tint_buttons=self.xfwm4_tint_buttons,
            drop_png_duplicates=self.xfwm4_drop_png,
        )
        if self._restart_id is not None:
            GLib.source_remove(self._restart_id)
        self._restart_id = GLib.timeout_add(350, lambda: self._do_restarts_now() or False)
        return msg

    def _do_restarts_now(self) -> bool:
        self._restart_id = None
        out: List[str] = []
        try:
            if self.do_restart_xfwm:
                restart_xfwm()
                out.append("xfwm4 restarted")
                if self.force_xfwm_reload:
                    out.append(force_reload_xfwm_theme())
            if self.do_restart_panel:
                restart_panel()
                out.append("xfce4-panel restarted")
        except Exception:
            self.status.set_text(self.status.get_text() + "\n\nRestart error:\n" + traceback.format_exc())
            return False

        if out:
            self.status.set_text(self.status.get_text() + "\n\nRestarts:\n- " + "\n- ".join(out))
        return False


# ----------------------------
# Startup
# ----------------------------

def detect_aero_elements_css(theme_root: Path) -> Path:
    candidates = [
        theme_root / "gtk-3.0" / "widgets" / "aero-elements.css",
        theme_root / "gtk-3.0" / "aero-elements.css",
    ]
    for p in candidates:
        if p.exists():
            return p
    raise FileNotFoundError(
        "Fehlt aero-elements.css. Erwartet z.B.:\n"
        f"- {candidates[0]}\n"
        f"- {candidates[1]}"
    )

def main():
    theme_root = Path(__file__).resolve().parent
    aero_css = detect_aero_elements_css(theme_root)
    xfwm4_dir = theme_root / "xfwm4"
    cfg = AppConfig(theme_root=theme_root, theme_name=theme_root.name, aero_css=aero_css, xfwm4_dir=xfwm4_dir)

    win = Win7ColorTool(cfg)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
