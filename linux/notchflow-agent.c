// notchflow-agent — the Linux end of Dynamic Notch's Flow (one mouse/keyboard and one clipboard across Mac and Linux).
//
// Runs on the Linux desktop's X server, started by the Mac over SSH (`ssh <host> notchflow-agent`), and speaks a
// small framed protocol on stdin/stdout, so SSH does the authentication and encryption and no port is opened.
//   frame = type (1 byte) + length (uint32 LE) + payload
//   Mac -> agent: H hello            -> I (w, h int32)
//                 M x y (int32)      absolute pointer position
//                 B button down (u8 u8)   X buttons: 1 left 2 middle 3 right 8 back 9 forward
//                 W dy dx (int8 int8)     wheel clicks, dy > 0 up, dx > 0 right
//                 K keysym down (u32 u8)
//                 R                  release everything held
//                 C text / P png     the Mac's clipboard: we own CLIPBOARD with it
//   agent -> Mac: I w h, C text / P png (the Linux clipboard changed), D log text
//
// Build: gcc -O2 -o notchflow-agent notchflow-agent.c -lX11 -lXtst -lXfixes
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xfixes.h>
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

static Display *dpy;
static Window root, win;
static Atom A_CLIP, A_TARGETS, A_UTF8, A_TEXT, A_PLAIN, A_PLAINU, A_PNG, A_PROP, A_INCR, A_TS;
static int fixes_ev;

static unsigned char *clip; static size_t clip_len; static int clip_png;   // what we serve while we own CLIPBOARD
static Time clip_time;

// keys and buttons held down, to release them all when the pointer goes back to the Mac
static KeyCode held_keys[64]; static int n_held;
static int held_buttons[16];

// INCR transfer in progress (reading a big Linux clipboard)
static unsigned char *incr_buf; static size_t incr_len; static int incr_on; static Atom incr_type;

// ------------------------------------------------------------------ output to the Mac
static void send_frame(char type, const void *p, uint32_t n) {
    unsigned char h[5] = {(unsigned char)type, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255};
    fwrite(h, 1, 5, stdout);
    if (n) fwrite(p, 1, n, stdout);
    fflush(stdout);
}
static void logf_(const char *fmt, ...) {
    char b[512]; va_list a; va_start(a, fmt); int n = vsnprintf(b, sizeof b, fmt, a); va_end(a);
    send_frame('D', b, n < 0 ? 0 : (uint32_t)(n < (int)sizeof b ? n : (int)sizeof b - 1));
}

// ------------------------------------------------------------------ display
static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

static Display *open_display(void) {
    Display *d = XOpenDisplay(NULL);
    if (d) return d;
    // started over SSH: find the desktop's display and its X authority ourselves
    const char *auths[] = {getenv("XAUTHORITY"), NULL, NULL};
    char a1[256], a2[256];
    snprintf(a1, sizeof a1, "/run/user/%d/gdm/Xauthority", (int)getuid());
    snprintf(a2, sizeof a2, "%s/.Xauthority", getenv("HOME") ? getenv("HOME") : "");
    auths[1] = a1; auths[2] = a2;
    DIR *dir = opendir("/tmp/.X11-unix");
    if (!dir) return NULL;
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (e->d_name[0] != 'X') continue;
        char disp[32]; snprintf(disp, sizeof disp, ":%s", e->d_name + 1);
        for (int i = 0; i < 3; i++) {
            if (!auths[i] || access(auths[i], R_OK)) continue;
            setenv("XAUTHORITY", auths[i], 1);
            if ((d = XOpenDisplay(disp))) { setenv("DISPLAY", disp, 1); closedir(dir); return d; }
        }
    }
    closedir(dir);
    return NULL;
}

// ------------------------------------------------------------------ input
static KeyCode keycode_for(KeySym ks) {
    KeyCode kc = XKeysymToKeycode(dpy, ks);
    if (kc) return kc;
    // not on the keyboard map (rare): borrow an unused keycode, as xdotool does
    int lo, hi, per;
    XDisplayKeycodes(dpy, &lo, &hi);
    KeySym *map = XGetKeyboardMapping(dpy, lo, hi - lo + 1, &per);
    for (int k = hi; k >= lo; k--) {
        int empty = 1;
        for (int j = 0; j < per; j++) if (map[(k - lo) * per + j]) { empty = 0; break; }
        if (empty) {
            KeySym s[2] = {ks, ks};
            XChangeKeyboardMapping(dpy, k, 2, s, 1); XSync(dpy, False);
            XFree(map); return (KeyCode)k;
        }
    }
    XFree(map);
    return 0;
}

static void key(KeySym ks, int down) {
    KeyCode kc = keycode_for(ks);
    if (!kc) return;
    XTestFakeKeyEvent(dpy, kc, down, CurrentTime);
    if (down) { if (n_held < 64) held_keys[n_held++] = kc; }
    else for (int i = 0; i < n_held; i++) if (held_keys[i] == kc) { held_keys[i] = held_keys[--n_held]; break; }
}

static void button(int b, int down) {
    if (b < 1 || b > 15) return;
    XTestFakeButtonEvent(dpy, b, down, CurrentTime);
    held_buttons[b] = down;
}

static void release_all(void) {
    for (int i = 0; i < n_held; i++) XTestFakeKeyEvent(dpy, held_keys[i], False, CurrentTime);
    n_held = 0;
    for (int b = 1; b < 16; b++) if (held_buttons[b]) { XTestFakeButtonEvent(dpy, b, False, CurrentTime); held_buttons[b] = 0; }
}

static void wheel(int dy, int dx) {
    int b = dy > 0 ? 4 : 5, n = dy > 0 ? dy : -dy;
    for (int i = 0; i < n; i++) { XTestFakeButtonEvent(dpy, b, True, CurrentTime); XTestFakeButtonEvent(dpy, b, False, CurrentTime); }
    b = dx > 0 ? 7 : 6; n = dx > 0 ? dx : -dx;
    for (int i = 0; i < n; i++) { XTestFakeButtonEvent(dpy, b, True, CurrentTime); XTestFakeButtonEvent(dpy, b, False, CurrentTime); }
}

// ------------------------------------------------------------------ clipboard: serving the Mac's
static Time server_time(void) {
    // a zero-length append to our own window gives a PropertyNotify carrying the server time
    XChangeProperty(dpy, win, A_TS, A_TS, 8, PropModeAppend, NULL, 0);
    XEvent e;
    XWindowEvent(dpy, win, PropertyChangeMask, &e);
    return e.xproperty.time;
}

static void take_clipboard(const unsigned char *p, size_t n, int png) {
    free(clip);
    clip = malloc(n ? n : 1); memcpy(clip, p, n); clip_len = n; clip_png = png;
    clip_time = server_time();
    XSetSelectionOwner(dpy, A_CLIP, win, clip_time);
    if (XGetSelectionOwner(dpy, A_CLIP) != win) logf_("could not own CLIPBOARD");
}

static void serve(XSelectionRequestEvent *r) {
    XSelectionEvent ev = {.type = SelectionNotify, .display = r->display, .requestor = r->requestor,
                          .selection = r->selection, .target = r->target, .property = None, .time = r->time};
    Atom prop = r->property ? r->property : r->target;
    if (r->selection == A_CLIP && clip) {
        if (r->target == A_TARGETS) {
            Atom t[6]; int n = 0;
            t[n++] = A_TARGETS;
            if (clip_png) t[n++] = A_PNG;
            else { t[n++] = A_UTF8; t[n++] = XA_STRING; t[n++] = A_TEXT; t[n++] = A_PLAINU; }
            XChangeProperty(dpy, r->requestor, prop, XA_ATOM, 32, PropModeReplace, (unsigned char *)t, n);
            ev.property = prop;
        } else if (!clip_png && (r->target == A_UTF8 || r->target == XA_STRING || r->target == A_TEXT ||
                                 r->target == A_PLAIN || r->target == A_PLAINU)) {
            XChangeProperty(dpy, r->requestor, prop, r->target == A_TEXT ? A_UTF8 : r->target, 8, PropModeReplace,
                            clip, (int)clip_len);
            ev.property = prop;
        } else if (clip_png && r->target == A_PNG) {
            XChangeProperty(dpy, r->requestor, prop, A_PNG, 8, PropModeReplace, clip, (int)clip_len);
            ev.property = prop;
        }
    }
    XSendEvent(dpy, r->requestor, False, 0, (XEvent *)&ev);
}

// ------------------------------------------------------------------ clipboard: reading Linux's
static void finish_read(Atom type, unsigned char *p, size_t n) {
    if (!n) return;
    if (type == A_PNG) send_frame('P', p, (uint32_t)n);
    else send_frame('C', p, (uint32_t)n);
}

static void got_selection(XSelectionEvent *s) {
    if (s->property == None) {
        if (s->target == A_UTF8) XConvertSelection(dpy, A_CLIP, XA_STRING, A_PROP, win, CurrentTime);
        return;
    }
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    if (XGetWindowProperty(dpy, win, A_PROP, 0, 0x1fffffff, True, AnyPropertyType, &type, &fmt, &n, &after, &data) != Success)
        return;
    if (type == A_INCR) {                       // big: it comes in chunks as we delete the property
        free(incr_buf); incr_buf = NULL; incr_len = 0; incr_on = 1; incr_type = s->target;
        if (data) XFree(data);
        return;
    }
    if (s->target == A_TARGETS && type == XA_ATOM) {
        Atom *t = (Atom *)data; int text = 0, png = 0;
        for (unsigned long i = 0; i < n; i++) { if (t[i] == A_UTF8 || t[i] == XA_STRING) text = 1; if (t[i] == A_PNG) png = 1; }
        if (text) XConvertSelection(dpy, A_CLIP, A_UTF8, A_PROP, win, CurrentTime);
        else if (png) XConvertSelection(dpy, A_CLIP, A_PNG, A_PROP, win, CurrentTime);
    } else if (data) {
        finish_read(s->target == A_PNG ? A_PNG : A_UTF8, data, n * (fmt / 8));
    }
    if (data) XFree(data);
}

static void incr_chunk(XPropertyEvent *p) {
    if (!incr_on || p->atom != A_PROP || p->state != PropertyNewValue) return;
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    if (XGetWindowProperty(dpy, win, A_PROP, 0, 0x1fffffff, True, AnyPropertyType, &type, &fmt, &n, &after, &data) != Success)
        return;
    size_t len = n * (fmt / 8);
    if (len == 0) {                             // the end
        incr_on = 0;
        finish_read(incr_type == A_PNG ? A_PNG : A_UTF8, incr_buf, incr_len);
        free(incr_buf); incr_buf = NULL; incr_len = 0;
    } else if (incr_len + len < (64u << 20)) {
        incr_buf = realloc(incr_buf, incr_len + len);
        memcpy(incr_buf + incr_len, data, len); incr_len += len;
    }
    if (data) XFree(data);
}

// ------------------------------------------------------------------ input from the Mac
static unsigned char *inbuf; static size_t in_len, in_cap;

static int32_t i32(const unsigned char *p) { return (int32_t)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24); }

static void handle(char t, const unsigned char *p, uint32_t n) {
    switch (t) {
    case 'H': {
        Screen *s = DefaultScreenOfDisplay(dpy);
        int32_t wh[2] = {WidthOfScreen(s), HeightOfScreen(s)};
        send_frame('I', wh, 8);
        logf_("display %s %dx%d", DisplayString(dpy), wh[0], wh[1]);
        break;
    }
    case 'M': if (n >= 8) XTestFakeMotionEvent(dpy, -1, i32(p), i32(p + 4), CurrentTime); break;
    case 'B': if (n >= 2) button(p[0], p[1]); break;
    case 'W': if (n >= 2) wheel((int8_t)p[0], (int8_t)p[1]); break;
    case 'K': if (n >= 5) key((KeySym)(uint32_t)i32(p), p[4]); break;
    case 'R': release_all(); break;
    case 'C': take_clipboard(p, n, 0); break;
    case 'P': take_clipboard(p, n, 1); break;
    }
}

static int read_stdin(void) {
    if (in_cap - in_len < 65536) { in_cap = in_cap * 2 + 65536; inbuf = realloc(inbuf, in_cap); }
    ssize_t r = read(0, inbuf + in_len, in_cap - in_len);
    if (r <= 0) return 0;
    in_len += (size_t)r;
    size_t off = 0;
    while (in_len - off >= 5) {
        uint32_t n = (uint32_t)i32(inbuf + off + 1);
        if (in_len - off < 5 + (size_t)n) break;
        handle((char)inbuf[off], inbuf + off + 5, n);
        off += 5 + n;
    }
    memmove(inbuf, inbuf + off, in_len - off); in_len -= off;
    XFlush(dpy);
    return 1;
}

int main(void) {
    dpy = open_display();
    if (!dpy) { fprintf(stderr, "notchflow-agent: no X display\n"); return 1; }
    XSetErrorHandler(ignore_errors);
    int ev, err, maj, min;
    if (!XTestQueryExtension(dpy, &ev, &err, &maj, &min)) { fprintf(stderr, "no XTEST\n"); return 1; }
    if (!XFixesQueryExtension(dpy, &fixes_ev, &err)) { fprintf(stderr, "no XFIXES\n"); return 1; }
    root = DefaultRootWindow(dpy);
    win = XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0);
    XSelectInput(dpy, win, PropertyChangeMask);
#define ATOM(n) XInternAtom(dpy, n, False)
    A_CLIP = ATOM("CLIPBOARD"); A_TARGETS = ATOM("TARGETS"); A_UTF8 = ATOM("UTF8_STRING"); A_TEXT = ATOM("TEXT");
    A_PLAIN = ATOM("text/plain"); A_PLAINU = ATOM("text/plain;charset=utf-8"); A_PNG = ATOM("image/png");
    A_PROP = ATOM("NOTCHFLOW_SEL"); A_INCR = ATOM("INCR"); A_TS = ATOM("NOTCHFLOW_TS");
    XFixesSelectSelectionInput(dpy, root, A_CLIP, XFixesSetSelectionOwnerNotifyMask);
    XFlush(dpy);

    int xfd = ConnectionNumber(dpy);
    for (;;) {
        while (XPending(dpy)) {
            XEvent e; XNextEvent(dpy, &e);
            if (e.type == fixes_ev + XFixesSelectionNotify) {
                XFixesSelectionNotifyEvent *f = (XFixesSelectionNotifyEvent *)&e;
                // someone else copied: fetch it for the Mac (our own ownership is the Mac's copy, skip it)
                if (f->owner != win && f->owner != None) XConvertSelection(dpy, A_CLIP, A_TARGETS, A_PROP, win, CurrentTime);
            } else if (e.type == SelectionRequest) serve(&e.xselectionrequest);
            else if (e.type == SelectionNotify) got_selection(&e.xselection);
            else if (e.type == PropertyNotify) incr_chunk(&e.xproperty);
            else if (e.type == SelectionClear) { free(clip); clip = NULL; clip_len = 0; }
        }
        fd_set fds; FD_ZERO(&fds); FD_SET(0, &fds); FD_SET(xfd, &fds);
        if (select(xfd + 1, &fds, NULL, NULL, NULL) < 0) { if (errno == EINTR) continue; break; }
        if (FD_ISSET(0, &fds) && !read_stdin()) break;      // the Mac went away
    }
    release_all(); XFlush(dpy);
    return 0;
}
