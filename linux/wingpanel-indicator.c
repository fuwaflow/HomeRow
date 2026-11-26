#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef unsigned long GType;
typedef void *gpointer;
typedef char gchar;
typedef int gint;
typedef unsigned int guint;
typedef int gboolean;
typedef unsigned long gulong;
typedef struct _GtkWidget GtkWidget;

extern GType wingpanel_indicator_get_type(void);
extern GtkWidget *wingpanel_popover_menu_item_new_with_text(const gchar *text);
extern GType g_type_register_static_simple(GType, const gchar *, guint, void (*)(gpointer, gpointer), guint, void (*)(gpointer, gpointer), guint);
extern gpointer g_type_class_peek_parent(gpointer);
extern gpointer g_object_new(GType, const gchar *, ...);
extern gpointer g_object_ref(gpointer);
extern gpointer g_object_ref_sink(gpointer);
extern void g_object_unref(gpointer);
extern gulong g_signal_connect_data(gpointer, const gchar *, gpointer, gpointer, gpointer, gint);
extern guint g_timeout_add(guint, gboolean (*)(gpointer), gpointer);
extern gboolean g_source_remove(guint);
extern const gchar *g_get_user_config_dir(void);
extern const gchar *g_get_home_dir(void);
extern gboolean g_spawn_command_line_async(const gchar *, gpointer *);

extern GtkWidget *gtk_image_new_from_icon_name(const gchar *);
extern void gtk_image_set_pixel_size(GtkWidget *, gint);
extern void gtk_widget_set_opacity(GtkWidget *, double);
extern void gtk_widget_set_tooltip_text(GtkWidget *, const gchar *);
extern GtkWidget *gtk_box_new(gint, gint);
extern void gtk_box_append(gpointer, GtkWidget *);
extern void gtk_widget_set_margin_top(GtkWidget *, gint);
extern void gtk_widget_set_margin_bottom(GtkWidget *, gint);
extern void gtk_widget_set_margin_start(GtkWidget *, gint);
extern void gtk_widget_set_margin_end(GtkWidget *, gint);
extern void gtk_widget_set_hexpand(GtkWidget *, gboolean);
extern void gtk_widget_set_valign(GtkWidget *, gint);
extern void gtk_widget_set_size_request(GtkWidget *, gint, gint);
extern void gtk_widget_add_css_class(GtkWidget *, const gchar *);
extern GtkWidget *gtk_label_new(const gchar *);
extern void gtk_label_set_text(gpointer, const gchar *);
extern void gtk_label_set_xalign(gpointer, float);
extern GtkWidget *gtk_switch_new(void);
extern gboolean gtk_switch_get_active(gpointer);
extern void gtk_switch_set_active(gpointer, gboolean);
extern GtkWidget *gtk_separator_new(gint);
extern GType gtk_popover_get_type(void);
extern GtkWidget *gtk_widget_get_ancestor(GtkWidget *, GType);
extern void gtk_popover_popdown(gpointer);

typedef struct {
    uint8_t base[32];
    GtkWidget *icon, *popover, *status, *sw[6];
    int syncing;
    guint timer;
    uint32_t tog_seq;
} HomeRowIndicator;

typedef struct { HomeRowIndicator *ind; const char *key; } SwBind;
static const char *SW_KEYS[] = {
    "isEnabled", "homeRowModsEnabled", "capsLockToBackspace",
    "navLayerEnabled", "swapIsoKeys", "bothShiftsToggle"
};
static gpointer parent_cls = NULL;

static void cfg_path(char *out, size_t n) {
    const char *c = g_get_user_config_dir();
    snprintf(out, n, (c && *c) ? "%s/homerow/config.json" : "%s/.config/homerow/config.json",
             (c && *c) ? c : g_get_home_dir());
}

static bool slurp(const char *p, char *buf, size_t n) {
    FILE *f = fopen(p, "rb");
    if (!f) return false;
    size_t r = fread(buf, 1, n - 1, f);
    fclose(f);
    buf[r] = '\0';
    return true;
}

static const char *jval(const char *j, const char *k) {
    char pat[96];
    snprintf(pat, sizeof(pat), "\"%s\"", k);
    const char *p = strstr(j, pat);
    if (!p) return NULL;
    p += strlen(pat);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != ':') return NULL;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

static bool jbool(const char *j, const char *k, bool *out) {
    const char *v = jval(j, k);
    if (!v) return false;
    if (!strncmp(v, "true", 4)) { *out = true; return true; }
    if (!strncmp(v, "false", 5)) { *out = false; return true; }
    return false;
}

static void write_cfg_bool(const char *key, bool val) {
    char path[512], buf[16384], out[16384], tmp[540];
    cfg_path(path, sizeof(path));
    if (!slurp(path, buf, sizeof(buf))) {
        snprintf(buf, sizeof(buf), "{\n  \"%s\": %s\n}\n", key, val ? "true" : "false");
    } else {
        const char *v = jval(buf, key);
        size_t vl = v ? (!strncmp(v, "true", 4) ? 4 : !strncmp(v, "false", 5) ? 5 : 0) : 0;
        if (vl) {
            snprintf(out, sizeof(out), "%.*s%s%s", (int)(v - buf), buf, val ? "true" : "false", v + vl);
            snprintf(buf, sizeof(buf), "%s", out);
        } else {
            const char *b = strchr(buf, '{');
            if (b) {
                snprintf(out, sizeof(out), "%.*s\n  \"%s\": %s,%s", (int)(b - buf + 1), buf, key, val ? "true" : "false", b + 1);
                snprintf(buf, sizeof(buf), "%s", out);
            }
        }
    }
    snprintf(tmp, sizeof(tmp), "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fputs(buf, f);
    fclose(f);
    rename(tmp, path);
}

static void sync_ui(HomeRowIndicator *s) {
    char path[512], buf[16384], st[2048];
    bool vals[6] = { true, true, true, false, true, true };
    cfg_path(path, sizeof(path));
    if (slurp(path, buf, sizeof(buf)))
        for (int i = 0; i < 6; i++) jbool(buf, SW_KEYS[i], &vals[i]);

    if (slurp("/tmp/homerow-state.json", st, sizeof(st))) {
        const char *tv = jval(st, "toggleSeq");
        uint32_t tseq = tv ? (uint32_t)strtoul(tv, NULL, 10) : 0;
        if (tseq != s->tog_seq) {
            bool live_en = vals[0];
            if (jbool(st, "isEnabled", &live_en) && s->tog_seq != 0 && live_en != vals[0]) {
                vals[0] = live_en;
                write_cfg_bool("isEnabled", live_en);
            }
            s->tog_seq = tseq;
        } else {
            jbool(st, "isEnabled", &vals[0]);
        }
    }

    s->syncing = 1;
    for (int i = 0; i < 6; i++) gtk_switch_set_active(s->sw[i], vals[i]);
    s->syncing = 0;
    gtk_label_set_text(s->status, vals[0] ? "Active" : "Paused");
    gtk_widget_set_opacity(s->icon, vals[0] ? 1.0 : 0.45);
    gtk_widget_set_tooltip_text(s->icon, vals[0] ? "HomeRow: Active" : "HomeRow: Paused");
}

static gboolean on_timer(gpointer d) { sync_ui(d); return 1; }

static void on_sw(gpointer sw, gpointer ps, gpointer d) {
    (void)ps;
    SwBind *b = d;
    if (b->ind->syncing) return;
    write_cfg_bool(b->key, gtk_switch_get_active(sw) != 0);
    sync_ui(b->ind);
}

static void on_open(GtkWidget *btn, gpointer d) {
    (void)btn;
    HomeRowIndicator *s = d;
    GtkWidget *pop = gtk_widget_get_ancestor(s->popover, gtk_popover_get_type());
    if (pop) gtk_popover_popdown(pop);
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "%s/.local/bin/homerow", g_get_home_dir());
    g_spawn_command_line_async(cmd, NULL);
}

static GtkWidget *add_row(HomeRowIndicator *s, const char *txt, int idx) {
    GtkWidget *r = gtk_box_new(0, 12), *l = gtk_label_new(txt), *sw = gtk_switch_new();
    gtk_widget_set_margin_start(r, 12); gtk_widget_set_margin_end(r, 12);
    gtk_widget_set_margin_top(r, 4); gtk_widget_set_margin_bottom(r, 4);
    gtk_label_set_xalign(l, 0.0f);
    gtk_widget_set_hexpand(l, 1);
    gtk_widget_set_valign(sw, 3);
    SwBind *b = malloc(sizeof(*b));
    b->ind = s; b->key = SW_KEYS[idx];
    g_signal_connect_data(sw, "notify::active", (gpointer)on_sw, b, free, 0);
    gtk_box_append(r, l); gtk_box_append(r, sw);
    s->sw[idx] = sw;
    return r;
}

static GtkWidget *get_display_widget(gpointer i) { return g_object_ref(((HomeRowIndicator *)i)->icon); }
static GtkWidget *get_widget(gpointer i) { sync_ui(i); return g_object_ref(((HomeRowIndicator *)i)->popover); }
static void opened(gpointer i) { sync_ui(i); }
static void closed(gpointer i) { (void)i; }

static void finalize(gpointer i) {
    HomeRowIndicator *s = i;
    if (s->timer) { g_source_remove(s->timer); s->timer = 0; }
    if (s->icon) g_object_unref(s->icon);
    if (s->popover) g_object_unref(s->popover);
    void (*pf)(gpointer) = *(void (**)(gpointer))((uint8_t *)parent_cls + 48);
    if (pf) pf(i);
}

static void cls_init(gpointer k, gpointer d) {
    (void)d;
    parent_cls = g_type_class_peek_parent(k);
    uint8_t *c = k;
    *(void (**)(gpointer))(c + 48) = finalize;
    *(GtkWidget *(**)(gpointer))(c + 136) = get_display_widget;
    *(GtkWidget *(**)(gpointer))(c + 144) = get_widget;
    *(void (**)(gpointer))(c + 152) = opened;
    *(void (**)(gpointer))(c + 160) = closed;
}

static void inst_init(gpointer inst, gpointer k) {
    (void)k;
    HomeRowIndicator *s = inst;
    s->icon = g_object_ref_sink(gtk_image_new_from_icon_name("input-keyboard-symbolic"));
    gtk_image_set_pixel_size(s->icon, 16);

    GtkWidget *root = g_object_ref_sink(gtk_box_new(1, 6));
    gtk_widget_set_size_request(root, 270, -1);
    gtk_widget_set_margin_top(root, 8); gtk_widget_set_margin_bottom(root, 8);
    s->popover = root;

    GtkWidget *hdr = gtk_box_new(0, 12), *tb = gtk_box_new(1, 2);
    gtk_widget_set_margin_start(hdr, 12); gtk_widget_set_margin_end(hdr, 12);
    gtk_widget_set_margin_top(hdr, 4); gtk_widget_set_margin_bottom(hdr, 4);
    gtk_widget_set_hexpand(tb, 1);

    GtkWidget *tl = gtk_label_new("HomeRow");
    gtk_label_set_xalign(tl, 0.0f); gtk_widget_add_css_class(tl, "heading");
    s->status = gtk_label_new("Active");
    gtk_label_set_xalign(s->status, 0.0f);
    gtk_widget_add_css_class(s->status, "dim-label");
    gtk_widget_add_css_class(s->status, "caption");
    gtk_box_append(tb, tl); gtk_box_append(tb, s->status);

    s->sw[0] = gtk_switch_new();
    gtk_widget_set_valign(s->sw[0], 3);
    SwBind *b = malloc(sizeof(*b)); b->ind = s; b->key = SW_KEYS[0];
    g_signal_connect_data(s->sw[0], "notify::active", (gpointer)on_sw, b, free, 0);
    gtk_box_append(hdr, tb); gtk_box_append(hdr, s->sw[0]);
    gtk_box_append(root, hdr);

    gtk_box_append(root, gtk_separator_new(0));
    const char *labels[] = { "", "Home Row Shortcuts", "Caps Lock → Backspace", "Left Cmd → Arrow Keys", "Fix Apple ISO ~ / § Keys", "Both Shifts → Pause" };
    for (int i = 1; i <= 5; i++) gtk_box_append(root, add_row(s, labels[i], i));

    gtk_box_append(root, gtk_separator_new(0));
    GtkWidget *btn = wingpanel_popover_menu_item_new_with_text("Open HomeRow Settings…");
    g_signal_connect_data(btn, "clicked", (gpointer)on_open, s, NULL, 0);
    gtk_box_append(root, btn);

    sync_ui(s);
    s->timer = g_timeout_add(800, on_timer, s);
}

static GType hr_ind_type(void) {
    static GType id = 0;
    if (!id) id = g_type_register_static_simple(wingpanel_indicator_get_type(), "HomeRowIndicator", 168, cls_init, sizeof(HomeRowIndicator), inst_init, 0);
    return id;
}

gpointer get_indicator(gpointer module, gint server_type) {
    (void)module;
    return server_type == 0 ? g_object_new(hr_ind_type(), "code-name", "homerow", "visible", 1, NULL) : NULL;
}
