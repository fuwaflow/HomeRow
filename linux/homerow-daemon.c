#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_KBDS 8
#define MAX_SLOTS 8
#define MAX_BUF 64
#define MAX_SYNTH 128
#define MAX_NAV 32
#define BIT(a, b) (((a)[(b) / 8] >> ((b) % 8)) & 1)

typedef enum { MOD_NONE = 0, MOD_SUPER = 1, MOD_ALT = 2, MOD_CTRL = 4, MOD_SHIFT = 8 } ModMask;
typedef void (*EmitFn)(void *ctx, uint16_t code, int32_t val);

typedef struct {
    int id;
    uint16_t ev;
    bool left;
    bool outer;
    ModMask def;
} SlotDef;

static const SlotDef SLOTS[MAX_SLOTS] = {
    { 0,  KEY_A,         true,  true,  MOD_SUPER },
    { 1,  KEY_S,         true,  true,  MOD_ALT   },
    { 2,  KEY_D,         true,  false, MOD_CTRL  },
    { 3,  KEY_F,         true,  false, MOD_SHIFT },
    { 38, KEY_J,         false, false, MOD_SHIFT },
    { 40, KEY_K,         false, false, MOD_CTRL  },
    { 37, KEY_L,         false, true,  MOD_ALT   },
    { 41, KEY_SEMICOLON, false, true,  MOD_SUPER },
};

static const uint16_t LEFT_KEYS[] = {
    KEY_GRAVE, KEY_102ND, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5,
    KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_A, KEY_S, KEY_D, KEY_F, KEY_G,
    KEY_Z, KEY_X, KEY_C, KEY_V, KEY_B
};
static const uint16_t RIGHT_KEYS[] = {
    KEY_6, KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS, KEY_EQUAL,
    KEY_Y, KEY_U, KEY_I, KEY_O, KEY_P, KEY_LEFTBRACE, KEY_RIGHTBRACE, KEY_BACKSLASH,
    KEY_H, KEY_J, KEY_K, KEY_L, KEY_SEMICOLON, KEY_APOSTROPHE,
    KEY_N, KEY_M, KEY_COMMA, KEY_DOT, KEY_SLASH
};
static const uint16_t NEUTRAL_KEYS[] = {
    KEY_SPACE, KEY_ENTER, KEY_KPENTER, KEY_TAB, KEY_ESC, KEY_BACKSPACE,
    KEY_CAPSLOCK, KEY_DELETE, KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN,
    KEY_LEFT, KEY_RIGHT, KEY_DOWN, KEY_UP
};
static const struct { uint16_t src, dst; ModMask mods; } NAV_MAP[] = {
    { KEY_A,         KEY_A,        MOD_CTRL }, // A -> Ctrl+A
    { KEY_U,         KEY_HOME,     MOD_NONE }, // U -> Home
    { KEY_O,         KEY_END,      MOD_NONE }, // O -> End
    { KEY_H,         KEY_PAGEUP,   MOD_NONE }, // H -> Page Up
    { KEY_J,         KEY_LEFT,     MOD_NONE }, // J -> Left
    { KEY_K,         KEY_DOWN,     MOD_NONE }, // K -> Down
    { KEY_L,         KEY_UP,       MOD_NONE }, // L -> Up
    { KEY_SEMICOLON, KEY_RIGHT,    MOD_NONE }, // ; -> Right
    { KEY_N,         KEY_PAGEDOWN, MOD_NONE }, // N -> Page Down
    { KEY_Z,         KEY_Z,        MOD_CTRL }, // Z -> Ctrl+Z
    { KEY_X,         KEY_X,        MOD_CTRL }, // X -> Ctrl+X
    { KEY_C,         KEY_C,        MOD_CTRL }, // C -> Ctrl+C
    { KEY_V,         KEY_V,        MOD_CTRL }, // V -> Ctrl+V
    { KEY_M,         KEY_LEFT,     MOD_ALT  }, // M -> Alt+Left
    { KEY_COMMA,     KEY_RIGHT,    MOD_ALT  }, // , -> Alt+Right
};

typedef struct {
    bool is_enabled, is_calibrating, hrm_enabled, caps_bs, nav_layer;
    bool opp_only, xkb_swapped, swap_iso, pinky_grace, shifts_toggle;
    double tap_ms, idle_ms, quick_ms;
    ModMask mods[MAX_SLOTS];
} Config;

typedef struct {
    bool active, left, within_idle, promoted, fired;
    uint16_t code;
    double down_t;
    ModMask flag;
} Pending;

typedef struct { uint16_t src, dst; ModMask mods; } NavEntry;

typedef struct {
    Config cfg;
    Pending pend[MAX_SLOTS];
    ModMask active_mods, nav_mods;
    uint16_t buf[MAX_BUF], synth[MAX_SYNTH];
    int buf_n, synth_n, nav_n, last_tap_slot;
    double last_non_mod_t, last_rel_t[KEY_MAX + 1];
    bool p_lctrl, p_rctrl, p_lalt, p_ralt, p_lmeta, p_rmeta, p_lshift, p_rshift;
    bool swallow_up[MAX_SLOTS], caps_down, grave_down, iso102_down, shifts_used;
    bool out_ctrl, out_alt, out_meta, out_shift;
    NavEntry nav_down[MAX_NAV];
    uint32_t toggle_seq, tap_seq;
    uint16_t last_nav_key;
    EmitFn emit;
    void *ctx;
} Engine;

static volatile sig_atomic_t g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static bool in_list(uint16_t code, const uint16_t *arr, size_t n) {
    for (size_t i = 0; i < n; i++) if (arr[i] == code) return true;
    return false;
}

static int slot_by_ev(uint16_t c) {
    for (int i = 0; i < MAX_SLOTS; i++) if (SLOTS[i].ev == c) return i;
    return -1;
}

static int slot_by_id(int id) {
    for (int i = 0; i < MAX_SLOTS; i++) if (SLOTS[i].id == id) return i;
    return -1;
}

static double slot_tap_s(const Engine *e, int idx) {
    double extra = (e->cfg.pinky_grace && idx >= 0 && SLOTS[idx].outer) ? 30.0 : 0.0;
    return (e->cfg.tap_ms + extra) / 1000.0;
}

static void cfg_defaults(Config *c) {
    *c = (Config){
        .is_enabled = true, .hrm_enabled = true, .caps_bs = true,
        .opp_only = true, .swap_iso = true, .pinky_grace = true, .shifts_toggle = true,
        .tap_ms = 200.0, .idle_ms = 250.0, .quick_ms = 175.0,
    };
    for (int i = 0; i < MAX_SLOTS; i++) c->mods[i] = SLOTS[i].def;
}

static const char *skip_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

static const char *json_val(const char *json, const char *key) {
    char pat[96];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return NULL;
    p = skip_ws(p + strlen(pat));
    return (*p == ':') ? skip_ws(p + 1) : NULL;
}

static void json_bool(const char *j, const char *k, bool *out) {
    const char *v = json_val(j, k);
    if (!v) return;
    if (!strncmp(v, "true", 4)) *out = true;
    else if (!strncmp(v, "false", 5)) *out = false;
}

static void json_dbl(const char *j, const char *k, double *out) {
    const char *v = json_val(j, k);
    if (!v) return;
    char *end = NULL;
    double x = strtod(v, &end);
    if (end != v) *out = x;
}

static ModMask parse_mod(const char *s) {
    if (!strcmp(s, "Ctrl") || strstr(s, "Command")) return MOD_CTRL;
    if (!strcmp(s, "Super") || strstr(s, "Control")) return MOD_SUPER;
    if (!strcmp(s, "Alt") || strstr(s, "Option")) return MOD_ALT;
    if (strstr(s, "Shift")) return MOD_SHIFT;
    return MOD_NONE;
}

static void json_keymods(const char *json, Config *c) {
    const char *p = json_val(json, "keyMods");
    const char *end = p ? strchr(p, '}') : NULL;
    if (!p || *p != '{' || !end) return;
    for (p++; p < end; ) {
        const char *q1 = strchr(p, '"'), *q2 = q1 ? strchr(q1 + 1, '"') : NULL;
        const char *col = q2 ? strchr(q2 + 1, ':') : NULL;
        const char *v1 = col ? strchr(col + 1, '"') : NULL;
        const char *v2 = v1 ? strchr(v1 + 1, '"') : NULL;
        if (!v2 || v2 >= end) break;
        char kb[16] = {0}, vb[48] = {0};
        size_t kl = (size_t)(q2 - q1 - 1), vl = (size_t)(v2 - v1 - 1);
        memcpy(kb, q1 + 1, kl < 15 ? kl : 15);
        memcpy(vb, v1 + 1, vl < 47 ? vl : 47);
        int idx = slot_by_id(atoi(kb));
        if (idx >= 0) c->mods[idx] = parse_mod(vb);
        p = v2 + 1;
    }
}

static bool cfg_load(const char *path, Config *c) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    char buf[16384];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    cfg_defaults(c);
    json_bool(buf, "isEnabled", &c->is_enabled);
    json_bool(buf, "isCalibrating", &c->is_calibrating);
    json_bool(buf, "homeRowModsEnabled", &c->hrm_enabled);
    json_bool(buf, "capsLockToBackspace", &c->caps_bs);
    json_bool(buf, "navLayerEnabled", &c->nav_layer);
    json_bool(buf, "oppositeHandOnly", &c->opp_only);
    json_bool(buf, "xkbCtrlSuperSwapped", &c->xkb_swapped);
    json_bool(buf, "swapIsoKeys", &c->swap_iso);
    json_bool(buf, "pinkyRingGrace", &c->pinky_grace);
    json_bool(buf, "bothShiftsToggle", &c->shifts_toggle);
    json_dbl(buf, "tappingTermMs", &c->tap_ms);
    json_dbl(buf, "priorIdleMs", &c->idle_ms);
    json_dbl(buf, "quickTapMs", &c->quick_ms);
    json_keymods(buf, c);
    if (c->tap_ms < 50) c->tap_ms = 50;
    if (c->tap_ms > 1000) c->tap_ms = 1000;
    if (c->idle_ms < 0) c->idle_ms = 0;
    if (c->quick_ms < 0) c->quick_ms = 0;
    return true;
}

static void emit_raw(Engine *e, uint16_t code, int32_t val) {
    if (e->emit) e->emit(e->ctx, code, val);
}

static void sync_mods(Engine *e) {
    bool p_ctrl = e->cfg.xkb_swapped ? (!e->cfg.nav_layer && e->p_lmeta) : e->p_lctrl;
    bool p_super = e->cfg.xkb_swapped ? e->p_lctrl : (!e->cfg.nav_layer && e->p_lmeta);
    bool w_ctrl  = (e->active_mods & MOD_CTRL)  || p_ctrl  || (e->nav_mods & MOD_CTRL);
    bool w_super = (e->active_mods & MOD_SUPER) || p_super || (e->nav_mods & MOD_SUPER);
    bool w_alt   = (e->active_mods & MOD_ALT)   || e->p_lalt   || (e->nav_mods & MOD_ALT);
    bool w_shift = (e->active_mods & MOD_SHIFT) || e->p_lshift || (e->nav_mods & MOD_SHIFT);

    bool ev_ctrl = e->cfg.xkb_swapped ? w_super : w_ctrl;
    bool ev_meta = e->cfg.xkb_swapped ? w_ctrl  : w_super;

    if (ev_ctrl != e->out_ctrl)   { e->out_ctrl = ev_ctrl;   emit_raw(e, KEY_LEFTCTRL, ev_ctrl); }
    if (w_alt   != e->out_alt)    { e->out_alt = w_alt;      emit_raw(e, KEY_LEFTALT, w_alt); }
    if (ev_meta != e->out_meta)   { e->out_meta = ev_meta;   emit_raw(e, KEY_LEFTMETA, ev_meta); }
    if (w_shift != e->out_shift)  { e->out_shift = w_shift;  emit_raw(e, KEY_LEFTSHIFT, w_shift); }
}

static void emit_key(Engine *e, uint16_t code, int32_t val) {
    sync_mods(e);
    emit_raw(e, code, val);
}

static void clear_state(Engine *e) {
    memset(e->pend, 0, sizeof(e->pend));
    memset(e->swallow_up, 0, sizeof(e->swallow_up));
    e->active_mods = e->nav_mods = MOD_NONE;
    e->buf_n = 0;
    for (int i = 0; i < e->synth_n; i++) emit_raw(e, e->synth[i], 0);
    for (int i = 0; i < e->nav_n; i++) emit_raw(e, e->nav_down[i].dst, 0);
    e->synth_n = e->nav_n = 0;
    if (e->caps_down) { emit_raw(e, KEY_BACKSPACE, 0); e->caps_down = false; }
    sync_mods(e);
}

static void engine_init(Engine *e, EmitFn fn, void *ctx) {
    memset(e, 0, sizeof(*e));
    cfg_defaults(&e->cfg);
    e->last_tap_slot = -1;
    e->emit = fn;
    e->ctx = ctx;
}

static bool can_mod(const Engine *e, uint16_t target, bool left) {
    if (!e->cfg.opp_only || in_list(target, NEUTRAL_KEYS, sizeof(NEUTRAL_KEYS) / 2)) return true;
    return left ? in_list(target, RIGHT_KEYS, sizeof(RIGHT_KEYS) / 2)
                : in_list(target, LEFT_KEYS, sizeof(LEFT_KEYS) / 2);
}

static void recompute_mods(Engine *e) {
    ModMask m = MOD_NONE;
    for (int i = 0; i < MAX_SLOTS; i++) if (e->pend[i].active && e->pend[i].promoted) m |= e->pend[i].flag;
    e->active_mods = m;
    sync_mods(e);
}

static bool in_u16(const uint16_t *arr, int n, uint16_t c) {
    for (int i = 0; i < n; i++) if (arr[i] == c) return true;
    return false;
}

static void add_synth(Engine *e, uint16_t c) {
    if (!in_u16(e->synth, e->synth_n, c) && e->synth_n < MAX_SYNTH) e->synth[e->synth_n++] = c;
}

static bool pop_synth(Engine *e, uint16_t c) {
    for (int i = 0; i < e->synth_n; i++) {
        if (e->synth[i] == c) { e->synth[i] = e->synth[--e->synth_n]; return true; }
    }
    return false;
}

static void flush_taps(Engine *e, const int *idxs, int n, double now, bool flush_buf) {
    int ord[MAX_SLOTS], m = 0;
    for (int i = 0; i < n; i++) if (e->pend[idxs[i]].active) ord[m++] = idxs[i];
    for (int i = 0; i < m; i++)
        for (int j = i + 1; j < m; j++)
            if (e->pend[ord[j]].down_t < e->pend[ord[i]].down_t) { int t = ord[i]; ord[i] = ord[j]; ord[j] = t; }

    for (int i = 0; i < m; i++) {
        int id = ord[i];
        uint16_t pk = e->pend[id].code;
        e->pend[id].active = e->pend[id].promoted = e->pend[id].fired = false;
        e->swallow_up[id] = true;
        e->last_rel_t[pk] = e->last_non_mod_t = now;
        e->last_tap_slot = id;
        e->tap_seq++;
        emit_key(e, pk, 1);
        emit_key(e, pk, 0);
    }
    if (flush_buf && e->buf_n > 0) {
        for (int i = 0; i < e->buf_n; i++) {
            e->last_non_mod_t = now;
            add_synth(e, e->buf[i]);
            emit_key(e, e->buf[i], 1);
        }
        e->buf_n = 0;
    }
}

static void promote_slots(Engine *e, const int *idxs, int n, bool flush_buf) {
    bool chg = false;
    for (int i = 0; i < n; i++) {
        Pending *p = &e->pend[idxs[i]];
        if (p->active && !p->promoted) { p->fired = p->promoted = true; chg = true; }
    }
    if (chg) recompute_mods(e);
    if (flush_buf && e->buf_n > 0) {
        for (int i = 0; i < e->buf_n; i++) {
            add_synth(e, e->buf[i]);
            emit_key(e, e->buf[i], 1);
        }
        e->buf_n = 0;
    }
}

static void engine_tick(Engine *e, double now) {
    if (!e->cfg.is_enabled || e->cfg.is_calibrating || !e->cfg.hrm_enabled) return;
    for (int i = 0; i < MAX_SLOTS; i++) {
        Pending *p = &e->pend[i];
        if (!p->active || p->promoted || p->fired || now - p->down_t < slot_tap_s(e, i)) continue;
        p->fired = true;
        if (e->buf_n > 0) {
            int tp[MAX_SLOTS], tn = 0;
            for (int j = 0; j < MAX_SLOTS; j++)
                if (e->pend[j].active && !e->pend[j].promoted && can_mod(e, e->buf[0], e->pend[j].left))
                    tp[tn++] = j;
            if (tn > 0) { promote_slots(e, tp, tn, true); continue; }
        }
        if (!e->cfg.opp_only) promote_slots(e, &i, 1, true);
        else p->within_idle = false;
    }
}

static int next_timeout_ms(const Engine *e, double now) {
    if (!e->cfg.is_enabled || e->cfg.is_calibrating || !e->cfg.hrm_enabled) return -1;
    int best = -1;
    for (int i = 0; i < MAX_SLOTS; i++) {
        const Pending *p = &e->pend[i];
        if (!p->active || p->promoted || p->fired) continue;
        double rem = (p->down_t + slot_tap_s(e, i)) - now;
        int ms = rem <= 0 ? 0 : (int)(rem * 1000.0) + 1;
        if (best < 0 || ms < best) best = ms;
    }
    return best;
}

static void handle_key(Engine *e, uint16_t code, int32_t val, double now) {
    if (val < 0 || val > 2) return;
    engine_tick(e, now);

    if (!e->cfg.is_calibrating && e->cfg.shifts_toggle && (code == KEY_LEFTSHIFT || code == KEY_RIGHTSHIFT)) {
        if (code == KEY_LEFTSHIFT) e->p_lshift = val != 0;
        else e->p_rshift = val != 0;
        if (val == 1 && e->p_lshift && e->p_rshift && !e->shifts_used) {
            e->shifts_used = true;
            e->cfg.is_enabled = !e->cfg.is_enabled;
            e->toggle_seq++;
            if (!e->cfg.is_enabled) clear_state(e);
        } else if (!e->p_lshift && !e->p_rshift) {
            e->shifts_used = false;
        }
        if (!e->cfg.is_enabled) { emit_raw(e, code, val); return; }
        if (code == KEY_LEFTSHIFT) sync_mods(e); else emit_raw(e, code, val);
        return;
    }

    if (!e->cfg.is_enabled || e->cfg.is_calibrating) { emit_raw(e, code, val); return; }

    if (code == KEY_CAPSLOCK && (e->cfg.caps_bs || (e->caps_down && val == 0))) {
        e->caps_down = e->cfg.caps_bs && val != 0;
        code = KEY_BACKSPACE;
    }
    if (code == KEY_GRAVE && (e->cfg.swap_iso || (e->grave_down && val == 0))) {
        e->grave_down = val != 0; code = KEY_102ND;
    } else if (code == KEY_102ND && (e->cfg.swap_iso || (e->iso102_down && val == 0))) {
        e->iso102_down = val != 0; code = KEY_GRAVE;
    }

    if (code == KEY_LEFTMETA) {
        e->p_lmeta = val != 0;
        if (e->cfg.nav_layer) {
            if (val == 0) {
                e->last_nav_key = 0;
                if (e->nav_n == 0 && e->nav_mods) { e->nav_mods = MOD_NONE; sync_mods(e); }
            }
            return;
        }
        sync_mods(e);
        return;
    }
    if (code == KEY_LEFTCTRL)  { e->p_lctrl  = val != 0; sync_mods(e); return; }
    if (code == KEY_LEFTALT)   { e->p_lalt   = val != 0; sync_mods(e); return; }
    if (code == KEY_LEFTSHIFT) { e->p_lshift = val != 0; sync_mods(e); return; }
    if (code == KEY_RIGHTCTRL) { e->p_rctrl  = val != 0; emit_raw(e, code, val); return; }
    if (code == KEY_RIGHTALT)  { e->p_ralt   = val != 0; emit_raw(e, code, val); return; }
    if (code == KEY_RIGHTMETA) { e->p_rmeta  = val != 0; emit_raw(e, code, val); return; }
    if (code == KEY_RIGHTSHIFT){ e->p_rshift = val != 0; emit_raw(e, code, val); return; }

    if (val == 0) {
        for (int i = 0; i < e->nav_n; i++) {
            if (e->nav_down[i].src == code) {
                uint16_t dst = e->nav_down[i].dst;
                e->nav_down[i] = e->nav_down[--e->nav_n];
                emit_raw(e, dst, 0);
                e->nav_mods = MOD_NONE;
                for (int j = 0; j < e->nav_n; j++) e->nav_mods |= e->nav_down[j].mods;
                sync_mods(e);
                return;
            }
        }
    }

    if (e->cfg.nav_layer && e->p_lmeta) {
        uint16_t dst = code;
        ModMask mods = MOD_CTRL;
        for (size_t i = 0; i < sizeof(NAV_MAP) / sizeof(NAV_MAP[0]); i++) {
            if (NAV_MAP[i].src == code) { dst = NAV_MAP[i].dst; mods = NAV_MAP[i].mods; break; }
        }
        if (val > 0) {
            e->last_nav_key = code;
            e->nav_mods = mods;
            sync_mods(e);
            if (val == 1 && e->nav_n < MAX_NAV) e->nav_down[e->nav_n++] = (NavEntry){ code, dst, mods };
            emit_raw(e, dst, val);
        } else {
            e->last_nav_key = 0;
            e->nav_mods = MOD_NONE;
            emit_raw(e, dst, 0);
            sync_mods(e);
        }
        return;
    }

    if (!e->cfg.hrm_enabled) { emit_key(e, code, val); return; }

    int si = slot_by_ev(code);
    bool active_slot = si >= 0 && e->cfg.mods[si] != MOD_NONE;

    if (val == 0 && (!active_slot || !e->pend[si].active)) {
        if (si >= 0 && e->swallow_up[si]) { e->swallow_up[si] = false; return; }
        if (in_u16(e->buf, e->buf_n, code)) {
            int el[MAX_SLOTS], en = 0; bool prom = false;
            for (int i = 0; i < MAX_SLOTS; i++) {
                if (e->pend[i].active && !e->pend[i].promoted && can_mod(e, code, e->pend[i].left)) {
                    el[en++] = i;
                    if (!e->pend[i].within_idle || now - e->pend[i].down_t >= slot_tap_s(e, i)) prom = true;
                }
            }
            if (en > 0 && prom) promote_slots(e, el, en, true);
            else {
                int all[MAX_SLOTS], an = 0;
                for (int i = 0; i < MAX_SLOTS; i++) if (e->pend[i].active && !e->pend[i].promoted) all[an++] = i;
                flush_taps(e, all, an, now, true);
            }
        }
        pop_synth(e, code);
        emit_key(e, code, 0);
        return;
    }

    if (active_slot) {
        if (val > 0) {
            if (val == 2) {
                if (!e->pend[si].active && !in_u16(e->synth, e->synth_n, code) && !in_u16(e->buf, e->buf_n, code))
                    emit_key(e, code, 2);
                return;
            }
            e->swallow_up[si] = false;
            bool left = SLOTS[si].left, any_prom = false, same_prom = true;
            for (int i = 0; i < MAX_SLOTS; i++) {
                if (e->pend[i].active && e->pend[i].promoted) {
                    any_prom = true;
                    if (e->pend[i].left != left) same_prom = false;
                }
            }
            if (any_prom && same_prom) {
                e->pend[si] = (Pending){ true, left, false, true, true, code, now, e->cfg.mods[si] };
                recompute_mods(e);
                return;
            }
            int opp[MAX_SLOTS], on = 0; bool past = false;
            for (int i = 0; i < MAX_SLOTS; i++) {
                if (e->pend[i].active && !e->pend[i].promoted && e->pend[i].code != code && can_mod(e, code, e->pend[i].left)) {
                    opp[on++] = i;
                    if (now - e->pend[i].down_t >= slot_tap_s(e, i)) past = true;
                }
            }
            if (on > 0) {
                if (past) { promote_slots(e, opp, on, true); add_synth(e, code); emit_key(e, code, 1); }
                else if (e->buf_n < MAX_BUF) e->buf[e->buf_n++] = code;
                return;
            }
            if (e->active_mods != MOD_NONE) { add_synth(e, code); emit_key(e, code, 1); return; }
            if (e->p_lctrl || e->p_rctrl || e->p_lalt || e->p_ralt || e->p_lmeta || e->p_rmeta) {
                e->last_tap_slot = si; e->tap_seq++; emit_key(e, code, 1); return;
            }
            bool same_pend = false;
            for (int i = 0; i < MAX_SLOTS; i++)
                if (e->pend[i].active && !e->pend[i].promoted && e->pend[i].left == left) same_pend = true;
            if (!same_pend && e->last_rel_t[code] > 0 && now - e->last_rel_t[code] < e->cfg.quick_ms / 1000.0) {
                e->last_non_mod_t = now; e->last_tap_slot = si; e->tap_seq++; emit_key(e, code, 1); return;
            }
            bool idle = e->last_non_mod_t > 0 && (now - e->last_non_mod_t) < (e->cfg.idle_ms / 1000.0);
            e->pend[si] = (Pending){ true, left, idle, false, false, code, now, e->cfg.mods[si] };
            return;
        } else {
            Pending p = e->pend[si];
            double st = slot_tap_s(e, si);
            if (p.promoted) {
                e->pend[si].active = e->pend[si].promoted = false;
                recompute_mods(e);
            } else if (e->buf_n > 0 && now - p.down_t >= st && can_mod(e, e->buf[0], p.left)) {
                int tp[MAX_SLOTS], tn = 0;
                for (int i = 0; i < MAX_SLOTS; i++)
                    if (e->pend[i].active && !e->pend[i].promoted && can_mod(e, e->buf[0], e->pend[i].left))
                        tp[tn++] = i;
                promote_slots(e, tp, tn, true);
                e->pend[si].active = false;
                recompute_mods(e);
            } else if (now - p.down_t >= st && e->buf_n == 0) {
                e->pend[si].active = false;
            } else {
                int fl[MAX_SLOTS], fn = 0, rem = 0;
                for (int i = 0; i < MAX_SLOTS; i++) {
                    if (e->pend[i].active && !e->pend[i].promoted) {
                        if (e->pend[i].left == p.left && e->pend[i].down_t <= p.down_t) fl[fn++] = i;
                        else rem++;
                    }
                }
                flush_taps(e, fl, fn, now, rem == 0);
            }
            return;
        }
    }

    if (val == 1) {
        e->last_non_mod_t = now;
        int el[MAX_SLOTS], en = 0, inel[MAX_SLOTS], in = 0;
        for (int i = 0; i < MAX_SLOTS; i++) {
            if (!e->pend[i].active || e->pend[i].promoted) continue;
            bool ok = (code == KEY_BACKSPACE)
                ? (now - e->pend[i].down_t >= slot_tap_s(e, i) || !e->pend[i].within_idle)
                : can_mod(e, code, e->pend[i].left);
            if (ok) el[en++] = i; else inel[in++] = i;
        }
        bool flushed = false;
        if (in > 0) { flush_taps(e, inel, in, now, false); flushed = true; }
        if (en > 0) {
            bool past = false;
            for (int i = 0; i < en; i++)
                if (now - e->pend[el[i]].down_t >= slot_tap_s(e, el[i])) { past = true; break; }
            if (past) promote_slots(e, el, en, true);
            else { if (e->buf_n < MAX_BUF) e->buf[e->buf_n++] = code; return; }
        }
        if (flushed || e->active_mods != MOD_NONE) { add_synth(e, code); emit_key(e, code, 1); return; }
    } else if (val == 2 && in_u16(e->buf, e->buf_n, code)) {
        return;
    }
    emit_key(e, code, val);
}

typedef struct { int ufd; bool need_syn; } Uinput;
typedef struct { int fd; char path[280]; } Kbd;

static void u_emit(void *ctx, uint16_t code, int32_t val) {
    Uinput *u = ctx;
    struct input_event ev = { .type = EV_KEY, .code = code, .value = val };
    if (write(u->ufd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) u->need_syn = true;
}

static void u_syn(Uinput *u) {
    if (!u->need_syn) return;
    struct input_event syn = { .type = EV_SYN, .code = SYN_REPORT };
    ssize_t unused = write(u->ufd, &syn, sizeof(syn));
    (void)unused;
    u->need_syn = false;
}

static bool is_kbd(int fd, const char *name) {
    if (strstr(name, "HomeRow")) return false;
    uint8_t ev[(EV_MAX + 7) / 8] = {0}, kb[(KEY_MAX + 7) / 8] = {0};
    return ioctl(fd, EVIOCGBIT(0, sizeof(ev)), ev) >= 0 && BIT(ev, EV_KEY) &&
           ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(kb)), kb) >= 0 &&
           BIT(kb, KEY_A) && BIT(kb, KEY_Z) && BIT(kb, KEY_SPACE) && BIT(kb, KEY_ENTER);
}

static int open_uinput(const Kbd *kbds, int n) {
    int ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) return -1;
    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    ioctl(ufd, UI_SET_EVBIT, EV_SYN);
    uint8_t merged[(KEY_MAX + 7) / 8] = {0};
    for (int i = 0; i < n; i++) {
        uint8_t kb[(KEY_MAX + 7) / 8] = {0};
        if (ioctl(kbds[i].fd, EVIOCGBIT(EV_KEY, sizeof(kb)), kb) >= 0)
            for (size_t b = 0; b < sizeof(merged); b++) merged[b] |= kb[b];
    }
    for (int k = 1; k < KEY_MAX; k++) if (BIT(merged, k)) ioctl(ufd, UI_SET_KEYBIT, k);
    const uint16_t extra[] = {
        KEY_LEFTCTRL, KEY_LEFTALT, KEY_LEFTMETA, KEY_LEFTSHIFT, KEY_BACKSPACE,
        KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_LEFT, KEY_DOWN,
        KEY_UP, KEY_RIGHT, KEY_TAB, KEY_GRAVE, KEY_102ND
    };
    for (size_t i = 0; i < sizeof(extra) / 2; i++) ioctl(ufd, UI_SET_KEYBIT, extra[i]);

    struct uinput_setup us = { .id = { BUS_VIRTUAL, 0x05ac, 0x0357, 1 } };
    snprintf(us.name, UINPUT_MAX_NAME_SIZE, "Apple MTP HomeRow Keyboard");
    if (ioctl(ufd, UI_DEV_SETUP, &us) < 0 || ioctl(ufd, UI_DEV_CREATE) < 0) { close(ufd); return -1; }
    usleep(100000);
    return ufd;
}

static void scan_kbds(Kbd *kbds, int *n) {
    DIR *d = opendir("/dev/input");
    if (!d) return;
    struct dirent *ent;
    while ((ent = readdir(d)) && *n < MAX_KBDS) {
        if (strncmp(ent->d_name, "event", 5)) continue;
        char path[280];
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        bool seen = false;
        for (int i = 0; i < *n; i++) if (!strcmp(kbds[i].path, path)) seen = true;
        if (seen) continue;
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        char name[256] = "Unknown";
        ioctl(fd, EVIOCGNAME(sizeof(name)), name);
        if (!is_kbd(fd, name)) { close(fd); continue; }
        usleep(150000);
        if (ioctl(fd, EVIOCGRAB, 1) < 0) { close(fd); continue; }
        Kbd *k = &kbds[(*n)++];
        k->fd = fd;
        snprintf(k->path, sizeof(k->path), "%s", path);
        fprintf(stderr, "HomeRow: attached %s (%s)\n", k->path, name);
    }
    closedir(d);
}

typedef struct { uint16_t c; int32_t v; double t; } InEv;
typedef struct { uint16_t c; int32_t v; } OutEv;
typedef struct { OutEv ev[128]; int n; } TestLog;
static void t_emit(void *ctx, uint16_t c, int32_t v) { TestLog *l = ctx; if (l->n < 128) l->ev[l->n++] = (OutEv){ c, v }; }

static int check_seq(const char *name, const Engine *e_in, const InEv *in, int nin, const OutEv *exp, int nexp) {
    Engine e = *e_in;
    TestLog l = { .n = 0 };
    e.emit = t_emit; e.ctx = &l;
    for (int i = 0; i < nin; i++) handle_key(&e, in[i].c, in[i].v, in[i].t);
    if (l.n != nexp) { fprintf(stderr, "FAIL [%s]: got %d expected %d\n", name, l.n, nexp); return 1; }
    for (int i = 0; i < nexp; i++) {
        if (l.ev[i].c != exp[i].c || l.ev[i].v != exp[i].v) {
            fprintf(stderr, "FAIL [%s] @%d: got (%u,%d) exp (%u,%d)\n", name, i, l.ev[i].c, l.ev[i].v, exp[i].c, exp[i].v);
            return 1;
        }
    }
    printf("PASS [%s]\n", name);
    return 0;
}

static int run_tests(void) {
    int fail = 0;
    Engine e;

    engine_init(&e, NULL, NULL);
    fail += check_seq("simple_tap", &e, (InEv[]){{KEY_F,1,1.0},{KEY_F,0,1.08}}, 2, (OutEv[]){{KEY_F,1},{KEY_F,0}}, 2);
    fail += check_seq("opposite_hand_hold", &e, (InEv[]){{KEY_D,1,1.0},{KEY_I,1,1.25},{KEY_I,0,1.30},{KEY_D,0,1.35}}, 4,
                      (OutEv[]){{KEY_LEFTCTRL,1},{KEY_I,1},{KEY_I,0},{KEY_LEFTCTRL,0}}, 4);
    fail += check_seq("prior_idle_roll", &e, (InEv[]){{KEY_G,1,1.0},{KEY_G,0,1.05},{KEY_F,1,1.12},{KEY_J,1,1.17},{KEY_F,0,1.20},{KEY_J,0,1.25}}, 6,
                      (OutEv[]){{KEY_G,1},{KEY_G,0},{KEY_F,1},{KEY_F,0},{KEY_J,1},{KEY_J,0}}, 6);
    fail += check_seq("same_hand_roll", &e, (InEv[]){{KEY_D,1,1.0},{KEY_C,1,1.06},{KEY_D,0,1.11},{KEY_C,0,1.14}}, 4,
                      (OutEv[]){{KEY_D,1},{KEY_D,0},{KEY_C,1},{KEY_C,0}}, 4);
    fail += check_seq("quick_tap_repeat", &e, (InEv[]){{KEY_F,1,1.0},{KEY_F,0,1.06},{KEY_F,1,1.15},{KEY_F,2,1.4},{KEY_F,0,1.5}}, 5,
                      (OutEv[]){{KEY_F,1},{KEY_F,0},{KEY_F,1},{KEY_F,2},{KEY_F,0}}, 5);
    fail += check_seq("caps_to_backspace", &e, (InEv[]){{KEY_CAPSLOCK,1,1.0},{KEY_CAPSLOCK,2,1.3},{KEY_CAPSLOCK,0,1.35}}, 3,
                      (OutEv[]){{KEY_BACKSPACE,1},{KEY_BACKSPACE,2},{KEY_BACKSPACE,0}}, 3);

    engine_init(&e, NULL, NULL); e.cfg.nav_layer = true;
    fail += check_seq("nav_layer_arrows", &e, (InEv[]){{KEY_LEFTMETA,1,1.0},{KEY_J,1,1.05},{KEY_J,0,1.1},{KEY_LEFTMETA,0,1.15}}, 4,
                      (OutEv[]){{KEY_LEFT,1},{KEY_LEFT,0}}, 2);

    engine_init(&e, NULL, NULL);
    fail += check_seq("ctrl_tab_native", &e, (InEv[]){{KEY_D,1,1.0},{KEY_TAB,1,1.25},{KEY_TAB,0,1.3},{KEY_D,0,1.35}}, 4,
                      (OutEv[]){{KEY_LEFTCTRL,1},{KEY_TAB,1},{KEY_TAB,0},{KEY_LEFTCTRL,0}}, 4);

    engine_init(&e, NULL, NULL); e.cfg.xkb_swapped = true;
    fail += check_seq("xkb_ctrl_super_swap", &e, (InEv[]){{KEY_D,1,1.0},{KEY_I,1,1.25},{KEY_I,0,1.3},{KEY_D,0,1.35},{KEY_A,1,2.0},{KEY_I,1,2.25},{KEY_I,0,2.3},{KEY_A,0,2.35}}, 8,
                      (OutEv[]){{KEY_LEFTMETA,1},{KEY_I,1},{KEY_I,0},{KEY_LEFTMETA,0},{KEY_LEFTCTRL,1},{KEY_I,1},{KEY_I,0},{KEY_LEFTCTRL,0}}, 8);

    engine_init(&e, NULL, NULL); e.cfg.xkb_swapped = true; e.cfg.nav_layer = true;
    fail += check_seq("nav_layer_left_of_space_with_xkb_swap", &e, (InEv[]){{KEY_LEFTMETA,1,1.0},{KEY_J,1,1.05},{KEY_J,0,1.1},{KEY_LEFTMETA,0,1.15}}, 4,
                      (OutEv[]){{KEY_LEFT,1},{KEY_LEFT,0}}, 2);
    fail += check_seq("nav_layer_ctrl_tab_passthrough", &e, (InEv[]){{KEY_LEFTMETA,1,1.0},{KEY_TAB,1,1.05},{KEY_TAB,0,1.1},{KEY_J,1,1.15},{KEY_J,0,1.2},{KEY_LEFTMETA,0,1.25}}, 6,
                      (OutEv[]){{KEY_LEFTMETA,1},{KEY_TAB,1},{KEY_TAB,0},{KEY_LEFTMETA,0},{KEY_LEFT,1},{KEY_LEFT,0}}, 6);

    engine_init(&e, NULL, NULL); e.cfg.swap_iso = true;
    fail += check_seq("iso_grave_102nd_swap", &e, (InEv[]){{KEY_GRAVE,1,1.0},{KEY_GRAVE,0,1.05},{KEY_102ND,1,1.1},{KEY_102ND,0,1.15}}, 4,
                      (OutEv[]){{KEY_102ND,1},{KEY_102ND,0},{KEY_GRAVE,1},{KEY_GRAVE,0}}, 4);

    engine_init(&e, NULL, NULL); e.cfg.pinky_grace = true;
    fail += check_seq("pinky_ring_grace_timing", &e, (InEv[]){{KEY_G,1,0.9},{KEY_G,0,0.94},{KEY_A,1,1.0},{KEY_I,1,1.19},{KEY_I,0,1.21},{KEY_A,0,1.22},{KEY_D,1,1.3},{KEY_I,1,1.49},{KEY_I,0,1.51},{KEY_D,0,1.52}}, 10,
                      (OutEv[]){{KEY_G,1},{KEY_G,0},{KEY_A,1},{KEY_A,0},{KEY_I,1},{KEY_I,0},{KEY_LEFTCTRL,1},{KEY_I,1},{KEY_I,0},{KEY_LEFTCTRL,0}}, 10);

    engine_init(&e, NULL, NULL);
    handle_key(&e, KEY_LEFTSHIFT, 1, 1.0); handle_key(&e, KEY_RIGHTSHIFT, 1, 1.02);
    bool dis = !e.cfg.is_enabled;
    handle_key(&e, KEY_LEFTSHIFT, 0, 1.05); handle_key(&e, KEY_RIGHTSHIFT, 0, 1.06);
    handle_key(&e, KEY_LEFTSHIFT, 1, 1.2); handle_key(&e, KEY_RIGHTSHIFT, 1, 1.22);
    if (!dis || !e.cfg.is_enabled) { fprintf(stderr, "FAIL [both_shifts_pause_toggle]\n"); fail++; }
    else printf("PASS [both_shifts_pause_toggle]\n");
    return fail ? 1 : 0;
}

typedef struct {
    bool init, en, nav;
    uint8_t pend, prom;
    uint32_t tap_seq, tog_seq;
    uint16_t nav_key;
} LiveSnap;

static void write_live_state(const Engine *e, LiveSnap *prev) {
    LiveSnap s = { true, e->cfg.is_enabled, e->cfg.is_enabled && e->cfg.nav_layer && e->p_lmeta, 0, 0, e->tap_seq, e->toggle_seq, e->last_nav_key };
    for (int i = 0; i < MAX_SLOTS; i++) if (e->pend[i].active) {
        if (e->pend[i].promoted) s.prom |= 1u << i; else s.pend |= 1u << i;
    }
    if (prev->init && !memcmp(prev, &s, sizeof(s))) return;
    *prev = s;

    char tmp[96];
    snprintf(tmp, sizeof(tmp), "/tmp/.homerow-state.%d.json", (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "{\"isEnabled\":%s,\"navDown\":%s,\"pending\":[", s.en ? "true" : "false", s.nav ? "true" : "false");
    for (int i = 0, first = 1; i < MAX_SLOTS; i++) if (s.pend & (1u << i)) { fprintf(f, "%s\"%d\"", first ? "" : ",", SLOTS[i].id); first = 0; }
    fprintf(f, "],\"promoted\":[");
    for (int i = 0, first = 1; i < MAX_SLOTS; i++) if (s.prom & (1u << i)) { fprintf(f, "%s\"%d\"", first ? "" : ",", SLOTS[i].id); first = 0; }
    int tid = (e->last_tap_slot >= 0 && e->last_tap_slot < MAX_SLOTS) ? SLOTS[e->last_tap_slot].id : -1;
    fprintf(f, "],\"tapSlot\":\"%d\",\"tapSeq\":%u,\"toggleSeq\":%u,\"navKey\":%u}\n", tid, s.tap_seq, s.tog_seq, s.nav_key);
    fclose(f);
    chmod(tmp, 0644);
    rename(tmp, "/tmp/homerow-state.json");
}

int main(int argc, char **argv) {
    char cfg_path[512];
    const char *xdg = getenv("XDG_CONFIG_HOME"), *home = getenv("HOME");
    if (xdg && *xdg) snprintf(cfg_path, sizeof(cfg_path), "%s/homerow/config.json", xdg);
    else {
        if (!home || !*home) { struct passwd *pw = getpwuid(getuid()); home = pw ? pw->pw_dir : "/tmp"; }
        snprintf(cfg_path, sizeof(cfg_path), "%s/.config/homerow/config.json", home);
    }
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--test")) return run_tests();
        if (!strcmp(argv[i], "--config") && i + 1 < argc) snprintf(cfg_path, sizeof(cfg_path), "%s", argv[++i]);
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    Uinput u = { .ufd = -1 };
    Engine e;
    engine_init(&e, u_emit, &u);
    cfg_load(cfg_path, &e.cfg);
    bool file_enabled = e.cfg.is_enabled;
    LiveSnap snap = {0};

    Kbd kbds[MAX_KBDS];
    int nk = 0;
    scan_kbds(kbds, &nk);
    if (nk == 0 || (u.ufd = open_uinput(kbds, nk)) < 0) return 1;

    int ifd = inotify_init1(IN_NONBLOCK), cwd = -1, dwd = -1;
    char cdir[512];
    snprintf(cdir, sizeof(cdir), "%s", cfg_path);
    char *sl = strrchr(cdir, '/');
    const char *cbase = sl ? sl + 1 : cfg_path;
    if (sl) *sl = '\0'; else snprintf(cdir, sizeof(cdir), ".");
    if (ifd >= 0) {
        cwd = inotify_add_watch(ifd, cdir, IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE);
        dwd = inotify_add_watch(ifd, "/dev/input", IN_CREATE | IN_ATTRIB);
    }

    write_live_state(&e, &snap);
    while (g_run) {
        struct pollfd pfds[MAX_KBDS + 1];
        int nfds = 0, ipfd = -1;
        for (int i = 0; i < nk; i++) pfds[nfds++] = (struct pollfd){ kbds[i].fd, POLLIN, 0 };
        if (ifd >= 0) { ipfd = nfds; pfds[nfds++] = (struct pollfd){ ifd, POLLIN, 0 }; }

        int rc = poll(pfds, (nfds_t)nfds, next_timeout_ms(&e, now_s()));
        if (rc < 0) { if (errno == EINTR) continue; break; }

        engine_tick(&e, now_s());
        u_syn(&u);

        bool rescan = false;
        for (int i = 0; i < nk; i++) {
            if (pfds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                close(kbds[i].fd); kbds[i--] = kbds[--nk]; continue;
            }
            if (!(pfds[i].revents & POLLIN)) continue;
            struct input_event ev;
            while (read(kbds[i].fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type == EV_KEY) handle_key(&e, ev.code, ev.value, now_s());
                else if (ev.type == EV_SYN && ev.code == SYN_REPORT) u_syn(&u);
                else if (ev.type != EV_MSC && write(u.ufd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) u.need_syn = true;
            }
            u_syn(&u);
        }
        if (ipfd >= 0 && (pfds[ipfd].revents & POLLIN)) {
            char ib[4096];
            ssize_t len = read(ifd, ib, sizeof(ib));
            for (ssize_t off = 0; off < len; ) {
                struct inotify_event *ie = (struct inotify_event *)(ib + off);
                if (ie->wd == cwd && ie->len > 0 && !strcmp(ie->name, cbase)) {
                    Config nc;
                    if (cfg_load(cfg_path, &nc)) {
                        bool was_en = e.cfg.is_enabled, was_cal = e.cfg.is_calibrating, was_hrm = e.cfg.hrm_enabled;
                        bool keep_en = (nc.is_enabled == file_enabled) ? e.cfg.is_enabled : nc.is_enabled;
                        file_enabled = nc.is_enabled;
                        nc.is_enabled = keep_en;
                        e.cfg = nc;
                        if ((was_en && !nc.is_enabled) || (!was_cal && nc.is_calibrating) || (was_hrm && !nc.hrm_enabled)) {
                            clear_state(&e); u_syn(&u);
                        }
                    }
                } else if (ie->wd == dwd) rescan = true;
                off += (ssize_t)sizeof(*ie) + (ssize_t)ie->len;
            }
        }
        if (rescan) scan_kbds(kbds, &nk);
        write_live_state(&e, &snap);
    }

    clear_state(&e);
    u_syn(&u);
    unlink("/tmp/homerow-state.json");
    if (ifd >= 0) close(ifd);
    for (int i = 0; i < nk; i++) { ioctl(kbds[i].fd, EVIOCGRAB, 0); close(kbds[i].fd); }
    ioctl(u.ufd, UI_DEV_DESTROY);
    close(u.ufd);
    return 0;
}
