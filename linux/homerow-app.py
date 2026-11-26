#!/usr/bin/python3

import argparse
import filecmp
import glob
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk

APP_ID = "io.github.fuwaflow.HomeRow"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "homerow"
CONFIG_PATH = CONFIG_DIR / "config.json"
LIVE_STATE_PATH = Path("/tmp/homerow-state.json")
APP_DIR = Path(__file__).resolve().parent
BLP_PATH = APP_DIR / "window.blp"
UI_PATH = APP_DIR / "window.ui"

MOD_CHOICES = [("Off", "Off"), ("Super", "Super"), ("Alt", "Alt"), ("Ctrl", "Ctrl"), ("Shift", "Shift")]
MOD_SHORT = dict(MOD_CHOICES)
LEGACY_MODS = {"Control ⌃": "Super", "Option ⌥": "Alt", "Command ⌘": "Ctrl", "Shift ⇧": "Shift"}

LEFT_SLOTS = [("0", "A", "A", False), ("1", "S", "R", False), ("2", "D", "S", False), ("3", "F", "T", True)]
RIGHT_SLOTS = [("38", "J", "N", True), ("40", "K", "E", False), ("37", "L", "I", False), ("41", ";", "O", False)]
EV_TO_SLOT = {30: "0", 31: "1", 32: "2", 33: "3", 36: "38", 37: "40", 38: "37", 39: "41"}

NAV_ROWS = [
    [(22, "U", "L", "Home"), (24, "O", "Y", "End")],
    [(35, "H", "M", "PgUp"), (36, "J", "N", "←"), (37, "K", "E", "↓"), (38, "L", "I", "↑"), (39, ";", "O", "→")],
    [(49, "N", "K", "PgDn"), (50, "M", "H", "Back"), (51, ",", ",", "Fwd")],
]

DEFAULT_CONFIG = {
    "isEnabled": True,
    "isCalibrating": False,
    "homeRowModsEnabled": True,
    "capsLockToBackspace": True,
    "navLayerEnabled": False,
    "oppositeHandOnly": True,
    "xkbCtrlSuperSwapped": False,
    "swapIsoKeys": True,
    "pinkyRingGrace": True,
    "bothShiftsToggle": True,
    "tappingTermMs": 200,
    "priorIdleMs": 250,
    "quickTapMs": 175,
    "displayColemak": True,
    "keyMods": {"0": "Super", "1": "Alt", "2": "Ctrl", "3": "Shift", "38": "Shift", "40": "Ctrl", "37": "Alt", "41": "Super"},
}

ICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#ff6b8b"/><stop offset="100%" stop-color="#e0457b"/></linearGradient>
    <filter id="sh" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="2.5" stdDeviation="2.5" flood-color="#000" flood-opacity="0.28"/></filter>
  </defs>
  <rect x="12" y="12" width="104" height="104" rx="23" fill="url(#bg)" filter="url(#sh)"/>
  <rect x="12.8" y="12.8" width="102.4" height="102.4" rx="22.2" fill="none" stroke="#fff" stroke-opacity="0.22" stroke-width="1.6"/>
  <rect x="24.5" y="51.5" width="23" height="29" rx="5" fill="#e0e0e0" fill-opacity="0.48"/>
  <rect x="24.5" y="49.5" width="23" height="29" rx="5" fill="#fff" fill-opacity="0.90"/>
  <rect x="52.5" y="51.5" width="23" height="29" rx="5" fill="#e0e0e0" fill-opacity="0.48"/>
  <rect x="52.5" y="49.5" width="23" height="29" rx="5" fill="#fff" fill-opacity="0.98"/>
  <rect x="58.7" y="69.5" width="10.6" height="3.2" rx="1.6" fill="#e0457b" fill-opacity="0.75"/>
  <rect x="80.5" y="51.5" width="23" height="29" rx="5" fill="#e0e0e0" fill-opacity="0.48"/>
  <rect x="80.5" y="49.5" width="23" height="29" rx="5" fill="#fff" fill-opacity="0.90"/>
</svg>"""

APP_CSS = """
.homerow-keycap { min-width: 56px; min-height: 62px; padding: 6px; border-radius: 10px; border: 1px solid alpha(@window_fg_color, 0.16); background-color: alpha(@card_bg_color, 0.95); box-shadow: 0 1px 2px alpha(#000000, 0.08); transition: all 90ms ease; }
.homerow-keycap.active-mod { background-color: alpha(@accent_bg_color, 0.14); border-color: alpha(@accent_bg_color, 0.55); }
.homerow-keycap.keycap-tapped { background-color: alpha(@window_fg_color, 0.14); border-color: alpha(@window_fg_color, 0.55); }
.homerow-keycap.keycap-pending { background-color: alpha(@accent_bg_color, 0.25); border-color: alpha(@accent_bg_color, 0.75); }
.homerow-keycap.keycap-promoted { background-color: @accent_bg_color; border-color: @accent_bg_color; color: @accent_fg_color; }
.homerow-keycap.keycap-promoted .homerow-keycap-mod { color: @accent_fg_color; }
.homerow-keycap-static { min-width: 38px; min-height: 62px; padding: 6px 4px; border-radius: 10px; border: 1px solid alpha(@window_fg_color, 0.10); background-color: alpha(@card_bg_color, 0.55); color: alpha(@window_fg_color, 0.45); }
.homerow-keycap-letter { font-size: 15px; font-weight: 700; }
.homerow-keycap-mod { font-size: 12px; font-weight: 600; color: @accent_color; }
.homerow-keycap-mod.off { color: alpha(@window_fg_color, 0.45); }
.homerow-bump { min-width: 12px; min-height: 2.5px; border-radius: 2px; background-color: alpha(@window_fg_color, 0.35); }
.homerow-navcap { min-width: 56px; min-height: 50px; padding: 4px 6px; border-radius: 9px; border: 1px solid alpha(@window_fg_color, 0.14); background-color: alpha(@card_bg_color, 0.85); transition: all 90ms ease; }
.homerow-navcap.nav-layer-active { background-color: alpha(@accent_bg_color, 0.16); border-color: alpha(@accent_bg_color, 0.55); }
.homerow-navcap.nav-key-pressed { background-color: @accent_bg_color; border-color: @accent_bg_color; color: @accent_fg_color; }
.homerow-navcap.nav-key-pressed .homerow-navcap-action { color: @accent_fg_color; }
.homerow-navcap-action { font-size: 11px; font-weight: 600; color: @accent_color; }
.homerow-hero-icon { padding: 10px; border-radius: 12px; background-color: alpha(@accent_bg_color, 0.15); color: @accent_color; }
"""


def ensure_ui_compiled():
    if UI_PATH.exists() and (not BLP_PATH.exists() or UI_PATH.stat().st_mtime >= BLP_PATH.stat().st_mtime):
        return
    if not BLP_PATH.exists():
        return
    if subprocess.run(["which", "blueprint-compiler"], capture_output=True).returncode == 0:
        subprocess.run(["blueprint-compiler", "compile", str(BLP_PATH), "--output", str(UI_PATH)], check=True)
        return
    mods = glob.glob("/var/lib/flatpak/runtime/org.gnome.Platform/*/active/files/lib/python*/site-packages")
    for m in mods:
        if (Path(m) / "blueprintcompiler").is_dir():
            env = dict(os.environ, PYTHONPATH=m)
            subprocess.run([sys.executable, "-c", 'from blueprintcompiler import main; main.main("0.20.4", "/usr/lib64", "/usr/share")',
                            "compile", str(BLP_PATH), "--output", str(UI_PATH)], env=env, check=True)
            return


def detect_xkb_swap():
    for cmd in (["dconf", "read", "/org/gnome/desktop/input-sources/xkb-options"],
                ["gsettings", "get", "org.gnome.desktop.input-sources", "xkb-options"]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=1)
            if r.returncode == 0 and r.stdout.strip():
                return "ctrl:swap_lwin_lctl" in r.stdout
        except Exception:
            pass
    return False


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    dirty = False
    if CONFIG_PATH.exists():
        try:
            for k, v in json.loads(CONFIG_PATH.read_text()).items():
                if k == "keyMods" and isinstance(v, dict):
                    for kk, vv in v.items():
                        nv = LEGACY_MODS.get(str(vv), str(vv) if str(vv) in MOD_SHORT else "Off")
                        if nv != vv:
                            dirty = True
                        cfg["keyMods"][str(kk)] = nv
                elif k in cfg:
                    cfg[k] = v
                else:
                    dirty = True
        except Exception:
            pass
    swap = detect_xkb_swap()
    if cfg.get("xkbCtrlSuperSwapped") != swap:
        cfg["xkbCtrlSuperSwapped"] = swap
        dirty = True
    if cfg.get("isCalibrating"):
        cfg["isCalibrating"] = False
        dirty = True
    if dirty:
        try:
            save_config(cfg)
        except Exception:
            pass
    return cfg


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".cfg-", suffix=".json", dir=str(CONFIG_DIR))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)


def daemon_pid():
    r = subprocess.run(["pgrep", "-x", "homerow-daemon"], capture_output=True, text=True)
    return r.stdout.strip().splitlines()[0] if r.returncode == 0 and r.stdout.strip() else None


def daemon_needs_update():
    ubin, sbin = Path.home() / ".local/bin/homerow-daemon", Path("/usr/local/bin/homerow-daemon")
    upan, span = Path.home() / ".local/share/homerow/libhomerow.so", Path("/usr/lib64/wingpanel-9/libhomerow.so")
    if not ubin.exists():
        return False
    if not sbin.exists():
        return True
    try:
        if not filecmp.cmp(str(ubin), str(sbin), shallow=False):
            return True
        if upan.exists() and (not span.exists() or not filecmp.cmp(str(upan), str(span), shallow=False)):
            return True
        pid = daemon_pid()
        return bool(pid and sbin.stat().st_mtime > Path(f"/proc/{pid}").stat().st_mtime)
    except OSError:
        return True


def find_installer():
    for p in (APP_DIR / "install.sh", Path.home() / ".local/share/homerow/install.sh"):
        if p.exists():
            return str(p)
    return None


class HomeRowController:
    def __init__(self, app):
        ensure_ui_compiled()
        self.cfg = load_config()
        self._suppress = False
        self.is_calibrating = False
        self.calib_downs, self.calib_taps, self.calib_gaps = {}, [], []
        self.calib_last_up = self._last_hw_ts = 0.0
        self._last_txt_len = 0
        self.rec_tap = self.rec_idle = None
        self._tap_seq = self._tog_seq = 0
        self._flash_until = {}
        self._local_pressed = set()
        self._live_seen = False

        self.b = Gtk.Builder.new_from_file(str(UI_PATH))
        self.win = self.b.get_object("win")
        self.win.set_application(app)
        self.win.connect("close-request", lambda _w: self._finish_calib(False) if self.is_calibrating else False)

        self.g = self.b.get_object
        self.switches = {
            "isEnabled": self.g("sw_enabled"), "homeRowModsEnabled": self.g("sw_hrm"),
            "capsLockToBackspace": self.g("sw_caps"), "navLayerEnabled": self.g("sw_nav"),
            "swapIsoKeys": self.g("sw_iso"), "bothShiftsToggle": self.g("sw_shifts_toggle"),
            "oppositeHandOnly": self.g("sw_opposite"), "pinkyRingGrace": self.g("sw_pinky_grace"),
        }
        self._build_sidebar()
        self._build_keycaps()
        self._build_nav()
        self._connect()
        self._sync_ui()
        self._refresh_daemon()
        GLib.timeout_add_seconds(2, self._poll_daemon)
        GLib.timeout_add(45, self._poll_live)

    def _build_sidebar(self):
        pages = [("quick-setup", "Quick Setup", "applications-science-symbolic"),
                 ("keys", "Home-Row Keys", "input-keyboard-symbolic"),
                 ("timing", "Timing & Feel", "preferences-other-symbolic")]
        first = None
        for pid, title, icon in pages:
            row = Gtk.ListBoxRow()
            row.page_id, row.title_text = pid, title
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            for m in ("top", "bottom", "start", "end"):
                getattr(box, f"set_margin_{m}")(8)
            box.append(Gtk.Image.new_from_icon_name(icon))
            box.append(Gtk.Label(label=title, xalign=0))
            row.set_child(box)
            self.g("sidebar_list").append(row)
            if first is None:
                first = row
        self.g("sidebar_list").select_row(first)

    def _build_keycaps(self):
        self.keycaps = {}
        row_box = self.g("keycap_row_box")
        for title, slots in (("Left Hand", LEFT_SLOTS), ("Right Hand", RIGHT_SLOTS)):
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            keys = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            for code, qw, co, bump in slots:
                keys.append(self._make_keycap(code, qw, co, bump))
            lbl = Gtk.Label(label=title)
            lbl.add_css_class("caption"); lbl.add_css_class("dim-label")
            col.append(keys); col.append(lbl)
            if title == "Left Hand":
                row_box.append(col)
                mid = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
                mid.set_valign(Gtk.Align.START)
                self.static_g, self.static_h = self._make_static("G"), self._make_static("M")
                mid.append(self.static_g); mid.append(self.static_h)
                row_box.append(mid)
            else:
                row_box.append(col)

    def _make_keycap(self, code, qw, co, bump):
        btn = Gtk.MenuButton()
        btn.add_css_class("flat"); btn.add_css_class("homerow-keycap")
        btn.qwerty, btn.colemak = qw, co
        vb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        vb.set_halign(Gtk.Align.CENTER); vb.set_valign(Gtk.Align.CENTER)
        btn.letter_lbl = Gtk.Label(label=co); btn.letter_lbl.add_css_class("homerow-keycap-letter")
        btn.mod_lbl = Gtk.Label(label="Off"); btn.mod_lbl.add_css_class("homerow-keycap-mod")
        vb.append(btn.letter_lbl); vb.append(btn.mod_lbl)
        if bump:
            b = Gtk.Box(); b.add_css_class("homerow-bump"); b.set_halign(Gtk.Align.CENTER); vb.append(b)
        btn.set_child(vb)

        pop = Gtk.Popover()
        pb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for m in ("top", "bottom", "start", "end"):
            getattr(pb, f"set_margin_{m}")(6)
        btn.choices = {}
        for cname, _ in MOD_CHOICES:
            cb = Gtk.Button(); cb.add_css_class("flat")
            bx = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            cl = Gtk.Label(label=cname, xalign=0); cl.set_hexpand(True)
            ci = Gtk.Image.new_from_icon_name("object-select-symbolic")
            bx.append(cl); bx.append(ci); cb.set_child(bx); cb.check = ci
            cb.connect("clicked", self._on_keycap_pick, code, cname, pop)
            pb.append(cb); btn.choices[cname] = cb
        pop.set_child(pb); btn.set_popover(pop)
        self.keycaps[code] = btn
        return btn

    def _make_static(self, letter):
        bx = Gtk.Box(orientation=Gtk.Orientation.VERTICAL); bx.add_css_class("homerow-keycap-static")
        bx.set_halign(Gtk.Align.CENTER); bx.set_valign(Gtk.Align.CENTER)
        lbl = Gtk.Label(label=letter); lbl.add_css_class("homerow-keycap-letter")
        lbl.set_vexpand(True); lbl.set_valign(Gtk.Align.CENTER)
        bx.append(lbl); bx.lbl = lbl
        return bx

    def _build_nav(self):
        self.nav_caps = {}
        box = self.g("nav_diagram_box")
        for row in NAV_ROWS:
            hb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6); hb.set_halign(Gtk.Align.CENTER)
            for ev, qw, co, act in row:
                c = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2); c.add_css_class("homerow-navcap")
                c.set_halign(Gtk.Align.CENTER); c.set_valign(Gtk.Align.CENTER)
                c.qwerty, c.colemak = qw, co
                c.kl = Gtk.Label(label=co); c.kl.add_css_class("homerow-keycap-letter")
                al = Gtk.Label(label=act); al.add_css_class("homerow-navcap-action")
                c.append(c.kl); c.append(al)
                hb.append(c); self.nav_caps[ev] = c
            box.append(hb)
        hint = Gtk.Label(label="A / Z / X / C / V → Ctrl+A / Z / X / C / V · Any other key → Ctrl+<key>")
        hint.add_css_class("caption"); hint.add_css_class("dim-label"); box.append(hint)

    def _connect(self):
        self.g("sidebar_list").connect("row-selected", self._on_nav)
        self.g("banner").connect("button-clicked", self._on_install_clicked)
        self.g("start_calib_btn").connect("clicked", self._on_start_calib)
        self.g("calib_cancel_btn").connect("clicked", lambda _b: self._finish_calib(False))
        self.g("calib_save_btn").connect("clicked", lambda _b: self._finish_calib(True))

        kc = Gtk.EventControllerKey(); kc.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        kc.connect("key-pressed", self._on_calib_press); kc.connect("key-released", self._on_calib_release)
        self.g("calib_entry").add_controller(kc)
        self.g("calib_entry").connect("changed", self._on_calib_changed)

        wk = Gtk.EventControllerKey(); wk.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        wk.connect("key-pressed", self._on_win_press); wk.connect("key-released", self._on_win_release)
        self.win.add_controller(wk)

        for k, sw in self.switches.items():
            sw.connect("notify::active", self._on_switch, k)
        self.g("sw_login").connect("notify::active", self._on_login_toggle)
        self.g("btn_qwerty").connect("toggled", self._on_layout)
        self.g("btn_colemak").connect("toggled", self._on_layout)
        self.g("sl_tapping_scale").connect("value-changed", self._on_slider, "tappingTermMs", self.g("sl_tapping_lbl"))
        self.g("sl_idle_scale").connect("value-changed", self._on_slider, "priorIdleMs", self.g("sl_idle_lbl"))
        self.g("sl_quick_scale").connect("value-changed", self._on_slider, "quickTapMs", self.g("sl_quick_lbl"))
        self.g("reset_btn").connect("clicked", self._on_reset)

    def _on_nav(self, _lb, row):
        if row:
            self.g("content_stack").set_visible_child_name(row.page_id)
            self.g("detail_page").set_title(row.title_text)

    def _sync_ui(self):
        self._suppress = True
        try:
            for k, sw in self.switches.items():
                sw.set_active(bool(self.cfg.get(k, DEFAULT_CONFIG[k])))
            for k, sname, lname in (("tappingTermMs", "sl_tapping_scale", "sl_tapping_lbl"),
                                    ("priorIdleMs", "sl_idle_scale", "sl_idle_lbl"),
                                    ("quickTapMs", "sl_quick_scale", "sl_quick_lbl")):
                self.g(sname).set_value(float(self.cfg[k]))
                self.g(lname).set_text(f"{int(self.cfg[k])} ms")

            col = bool(self.cfg.get("displayColemak", True))
            tb = self.g("btn_colemak") if col else self.g("btn_qwerty")
            if not tb.get_active():
                tb.set_active(True)
            self.static_h.lbl.set_text("M" if col else "H")

            for code, btn in self.keycaps.items():
                btn.letter_lbl.set_text(btn.colemak if col else btn.qwerty)
                mod = self.cfg["keyMods"].get(code, "Off")
                btn.mod_lbl.set_text(MOD_SHORT.get(mod, "Off"))
                self._set_css(btn, "active-mod", mod != "Off")
                self._set_css(btn.mod_lbl, "off", mod == "Off")
                for cname, cb in btn.choices.items():
                    cb.check.set_opacity(1.0 if cname == mod else 0.0)
            for cap in self.nav_caps.values():
                cap.kl.set_text(cap.colemak if col else cap.qwerty)

            t = int(self.cfg["tappingTermMs"])
            feel = "Snappy" if t <= 185 else ("Relaxed" if t >= 235 else "Balanced")
            self.g("calib_idle_row").set_subtitle(f"Current feel: {feel} ({t} ms)")
        finally:
            self._suppress = False

    def _on_switch(self, row, _ps, k):
        if not self._suppress:
            self.cfg[k] = row.get_active(); save_config(self.cfg)

    def _on_slider(self, sc, k, lbl):
        v = round(sc.get_value() / 5.0) * 5
        lbl.set_text(f"{int(v)} ms")
        if not self._suppress:
            self.cfg[k] = int(v); save_config(self.cfg)
            t = int(self.cfg["tappingTermMs"])
            feel = "Snappy" if t <= 185 else ("Relaxed" if t >= 235 else "Balanced")
            self.g("calib_idle_row").set_subtitle(f"Current feel: {feel} ({t} ms)")

    def _on_layout(self, btn):
        if not self._suppress and btn.get_active():
            self.cfg["displayColemak"] = btn is self.g("btn_colemak")
            save_config(self.cfg); self._sync_ui()

    def _on_keycap_pick(self, _b, code, cname, pop):
        pop.popdown(); self.cfg["keyMods"][code] = cname; save_config(self.cfg); self._sync_ui()

    def _on_reset(self, _b):
        self.cfg = json.loads(json.dumps(DEFAULT_CONFIG))
        self.cfg["xkbCtrlSuperSwapped"] = detect_xkb_swap()
        save_config(self.cfg); self._sync_ui()

    def _on_win_press(self, _c, _kv, kc, _st):
        if self.g("content_stack").get_visible_child_name() == "keys" and not self._live_seen:
            slot = EV_TO_SLOT.get(kc - 8)
            if slot:
                self._local_pressed.add(slot)
        return False

    def _on_win_release(self, _c, _kv, kc, _st):
        if self.g("content_stack").get_visible_child_name() == "keys" and not self._live_seen:
            slot = EV_TO_SLOT.get(kc - 8)
            if slot in self._local_pressed:
                self._local_pressed.discard(slot)
                self._flash_until[slot] = time.monotonic() + 0.16
        return False

    def _poll_live(self):
        now = time.monotonic()
        pend, prom, nav_down, nav_key = set(), set(), False, 0
        if LIVE_STATE_PATH.exists():
            try:
                st = json.loads(LIVE_STATE_PATH.read_text())
                self._live_seen = True
                pend, prom = set(st.get("pending", [])), set(st.get("promoted", []))
                nav_down, nav_key = bool(st.get("navDown")), int(st.get("navKey", 0))
                ts = int(st.get("tapSeq", 0))
                if ts != self._tap_seq:
                    if self._tap_seq and str(st.get("tapSlot", "")) in self.keycaps:
                        self._flash_until[str(st["tapSlot"])] = now + 0.16
                    self._tap_seq = ts
                gs = int(st.get("toggleSeq", 0))
                if gs != self._tog_seq:
                    if self._tog_seq and self.cfg.get("isEnabled") != bool(st.get("isEnabled", True)):
                        self.cfg["isEnabled"] = bool(st["isEnabled"]); save_config(self.cfg); self._sync_ui()
                    self._tog_seq = gs
            except Exception:
                pass
        else:
            self._live_seen = False
            pend = set(self._local_pressed)

        if self.g("content_stack").get_visible_child_name() == "keys":
            for code, btn in self.keycaps.items():
                pr, pe = code in prom, code in pend and code not in prom
                tp = self._flash_until.get(code, 0.0) > now and not pr and not pe
                self._set_css(btn, "keycap-promoted", pr)
                self._set_css(btn, "keycap-pending", pe)
                self._set_css(btn, "keycap-tapped", tp)
            for ev, cap in self.nav_caps.items():
                self._set_css(cap, "nav-layer-active", nav_down)
                self._set_css(cap, "nav-key-pressed", nav_down and nav_key == ev)

            lbl = self.g("live_feedback_lbl")
            if not self.cfg.get("isEnabled", True):
                lbl.set_text("HomeRow is paused (press Both Shifts to resume)")
            elif nav_down:
                lbl.set_text("Left Cmd Navigation Layer active")
            elif prom:
                lbl.set_text("Holding modifier: " + " + ".join(self.cfg["keyMods"].get(c, "") for c in prom))
            elif pend:
                lbl.set_text("Evaluating hold delay…")
            else:
                taps = [c for c, u in self._flash_until.items() if u > now]
                lbl.set_text(f"Tapped letter: {self.keycaps[taps[0]].letter_lbl.get_text()}" if taps else "Try tapping or holding a home-row key")
        return True

    @staticmethod
    def _set_css(w, cls, on):
        if on and not w.has_css_class(cls):
            w.add_css_class(cls)
        elif not on and w.has_css_class(cls):
            w.remove_css_class(cls)

    def _on_start_calib(self, _b):
        self.is_calibrating = True; self.cfg["isCalibrating"] = True; save_config(self.cfg)
        self.calib_downs.clear(); self.calib_taps.clear(); self.calib_gaps.clear()
        self.calib_last_up = self._last_hw_ts = 0.0; self._last_txt_len = 0
        self.rec_tap = self.rec_idle = None
        self.g("calib_entry").set_text("")
        self.g("calib_status_lbl").set_text("Keep typing… (0/8 keys)")
        self.g("calib_save_btn").set_sensitive(False)
        self.g("calib_idle_row").set_visible(False)
        self.g("calib_active_row").set_visible(True)
        self.g("calib_entry").grab_focus()

    def _finish_calib(self, apply):
        self.is_calibrating = False; self.cfg["isCalibrating"] = False
        if apply and self.rec_tap and self.rec_idle:
            self.cfg["tappingTermMs"], self.cfg["priorIdleMs"] = int(self.rec_tap), int(self.rec_idle)
            self.cfg["quickTapMs"] = max(120, min(220, int(self.rec_tap) - 25))
        save_config(self.cfg); self._sync_ui()
        self.g("calib_active_row").set_visible(False)
        self.g("calib_idle_row").set_visible(True)

    def _on_calib_press(self, _c, _kv, kc, _st, now=None):
        if not self.is_calibrating:
            return False
        now = time.monotonic() if now is None else now
        self._last_hw_ts = now
        if kc not in self.calib_downs:
            self.calib_downs[kc] = now
            if self.calib_last_up > 0 and 10 < (now - self.calib_last_up) * 1000 < 500:
                self.calib_gaps.append((now - self.calib_last_up) * 1000)
        return False

    def _on_calib_release(self, _c, _kv, kc, _st, now=None):
        if not self.is_calibrating:
            return
        now = time.monotonic() if now is None else now
        self._last_hw_ts = now
        down = self.calib_downs.pop(kc, None)
        if down and 20 < (now - down) * 1000 < 400:
            self.calib_taps.append((now - down) * 1000)
            self.calib_last_up = now
            self._update_calib()

    def _on_calib_changed(self, entry):
        if not self.is_calibrating:
            return
        n = len(entry.get_text())
        delta = n - self._last_txt_len; self._last_txt_len = n
        now = time.monotonic()
        if delta <= 0 or (now - self._last_hw_ts) < 0.08 or self.calib_downs:
            return
        if self.calib_last_up > 0 and 10 < (now - self.calib_last_up) * 1000 < 500:
            self.calib_gaps.append((now - self.calib_last_up) * 1000)
        self.calib_taps.append(90.0); self.calib_last_up = now; self._update_calib()

    def _update_calib(self):
        n = len(self.calib_taps)
        if n < 8:
            self.g("calib_status_lbl").set_text(f"Keep typing… ({n}/8 keys)")
            return
        st = sorted(self.calib_taps)
        self.rec_tap = round(min(300.0, max(150.0, st[min(n - 1, int(n * 0.95))] + 55.0)) / 5.0) * 5
        sg = sorted(self.calib_gaps)
        self.rec_idle = round(min(350.0, max(140.0, sg[min(len(sg) - 1, int(len(sg) * 0.85))] + 60.0)) / 5.0) * 5 if sg else 240
        self.g("calib_status_lbl").set_text(f"Ready! ({self.rec_tap} ms hold · {self.rec_idle} ms protection)")
        self.g("calib_save_btn").set_sensitive(True)

    def _refresh_daemon(self):
        bn = self.g("banner")
        if daemon_pid() is None:
            bn.set_title("HomeRow daemon is not running — enable system service to remap keys")
            bn.set_button_label("Enable & Start"); bn.set_revealed(True)
        elif daemon_needs_update():
            bn.set_title("HomeRow daemon was updated — restart service to apply changes")
            bn.set_button_label("Update & Restart"); bn.set_revealed(True)
        else:
            bn.set_revealed(False)
        self._suppress = True
        try:
            r = subprocess.run(["systemctl", "is-enabled", "homerow.service"], capture_output=True, text=True)
            self.g("sw_login").set_active(r.returncode == 0 and r.stdout.strip() == "enabled")
        finally:
            self._suppress = False

    def _poll_daemon(self):
        self._refresh_daemon()
        return True

    def _on_install_clicked(self, _b):
        inst = find_installer()
        if inst:
            self._run_pkexec(["pkexec", inst, "--system-install", os.environ.get("USER", ""), str(CONFIG_PATH)], True)

    def _on_login_toggle(self, row, _ps):
        if self._suppress:
            return
        inst = find_installer()
        if row.get_active() and not Path("/etc/systemd/system/homerow.service").exists() and inst:
            self._run_pkexec(["pkexec", inst, "--system-install", os.environ.get("USER", ""), str(CONFIG_PATH)], True)
        else:
            self._run_pkexec(["pkexec", "systemctl", "enable" if row.get_active() else "disable", "--now", "homerow.service"], False)

    def _run_pkexec(self, argv, reload_panel):
        try:
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE).wait_check_async(None, self._on_pkexec_done, reload_panel)
        except Exception:
            self._refresh_daemon()

    def _on_pkexec_done(self, proc, res, reload_panel):
        ok = False
        try:
            ok = proc.wait_check_finish(res)
        except Exception:
            pass
        if ok and reload_panel:
            subprocess.run(["pkill", "-f", "/usr/bin/io.elementary.wingpanel"], check=False)
            GLib.timeout_add(300, lambda: (subprocess.Popen(["io.elementary.wingpanel"], start_new_session=True) if subprocess.run(["pgrep", "-f", "/usr/bin/io.elementary.wingpanel"], capture_output=True).returncode != 0 else None) and False)
        self._refresh_daemon()


class HomeRowApp(Adw.Application):
    def __init__(self, check_only=False, test_calib=False):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.check_only, self.test_calib, self.ctrl = check_only, test_calib, None

    def do_startup(self):
        Adw.Application.do_startup(self)
        p = Gtk.CssProvider(); p.load_from_data(APP_CSS.encode())
        if d := Gdk.Display.get_default():
            Gtk.StyleContext.add_provider_for_display(d, p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def do_activate(self):
        if self.ctrl is None:
            self.ctrl = HomeRowController(self)
        if self.test_calib:
            c = self.ctrl; c._on_start_calib(None)
            for i in range(12):
                c._on_calib_press(None, 0, 30 + i, 0, now=10.0 + i * 0.2)
                c._on_calib_release(None, 0, 30 + i, 0, now=10.085 + i * 0.2)
            assert c.rec_tap and c.rec_idle and c.g("calib_save_btn").get_sensitive()
            c._finish_calib(False)
            print(f"PASS [calibration] tap={c.rec_tap}ms idle={c.rec_idle}ms")
            GLib.idle_add(self.quit); return
        if self.check_only:
            GLib.idle_add(self.quit); return
        self.ctrl.win.present()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--test-calibration", action="store_true")
    ap.add_argument("--toggle", action="store_true")
    ap.add_argument("--write-icon", metavar="PATH")
    args, rem = ap.parse_known_args()
    if args.write_icon:
        p = Path(args.write_icon); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(ICON_SVG); return 0
    if args.toggle:
        cfg = load_config(); cfg["isEnabled"] = not bool(cfg.get("isEnabled", True)); save_config(cfg); return 0
    if not CONFIG_PATH.exists():
        save_config(load_config())
    return HomeRowApp(args.check, args.test_calibration).run([sys.argv[0]] + rem)


if __name__ == "__main__":
    raise SystemExit(main())
