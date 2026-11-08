// Scripted input for testing without the real mouse and keyboard.
//
// PPC_SCRIPT="t:cmd;t:cmd;..." with t seconds after start and cmd one of
//   click x y [mods]    a click at window-local x, y of the front window
//   wclick Title x y [mods]  a click at content-local x, y of the window titled Title... (_ for spaces)
//   down x y / move x y / up    a press, drag and release (down and move also take a
//                       window title first, as wclick does)
//   key c [mods]        a key (c a character, or a name: return tab esc left right up down del)
//   type text           keys for each character of text (underscores for spaces)
//   shot file [Title]   the front window's (or the titled window's) pixels as a PNG
//   menu id item        a menu choice
//   windows             log every window
//   dump addr len       log len bytes of guest memory from hex addr
//   quit
// mods: any of cmd shift opt ctrl, joined with +
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "menu.h"
#include "win.h"

typedef struct { double t; char cmd[256]; } Step;
static Step *steps;
static int nsteps, next_step, loaded;
static double t_start;
static int fake, fake_down;
static QPoint fake_pos;

static void load(void)
{
	loaded = 1;
	const char *s = getenv("PPC_SCRIPT");
	if (!s)
		return;
	t_start = CFAbsoluteTimeGetCurrent();
	char *dup = strdup(s), *save = NULL;
	for (char *tok = strtok_r(dup, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
		char *colon = strchr(tok, ':');
		if (!colon)
			continue;
		steps = realloc(steps, sizeof(Step) * (nsteps + 1));
		steps[nsteps].t = atof(tok);
		snprintf(steps[nsteps].cmd, sizeof steps[nsteps].cmd, "%s", colon + 1);
		nsteps++;
	}
	free(dup);
}

int script_mouse(QPoint *p)
{
	if (!fake)
		return 0;
	*p = fake_pos;
	return 1;
}
int script_button(int *down)
{
	if (!fake)
		return 0;
	*down = fake_down;
	return 1;
}

static uint16_t mods_of(const char *s)
{
	uint16_t m = 0;
	if (!s)
		return 0;
	if (strstr(s, "cmd")) m |= 0x100;
	if (strstr(s, "shift")) m |= 0x200;
	if (strstr(s, "opt")) m |= 0x800;
	if (strstr(s, "ctrl")) m |= 0x1000;
	return m;
}

// the frontmost window that isn't floating
static Win *front(void)
{
	Win *w = WIN(SHIM_CALL("FrontNonFloatingWindow"));
	return w ? w : win_front(1);
}

// the window whose title starts with t (underscores for spaces), or the front window if t is empty
static Win *titled(const char *t)
{
	if (!t || !*t)
		return front();
	char b[200];
	snprintf(b, sizeof b, "%s", t);
	for (char *q = b; *q; q++)
		if (*q == '_')
			*q = ' ';
	size_t n = strlen(b);
	for (Win *w = win_list(); w; w = w->next)
		if (w->title[0] >= n && !memcmp(w->title + 1, b, n))
			return w;
	return NULL;
}

static QPoint global_of(int x, int y)
{
	Win *w = front();
	QPoint o = w ? win_origin(w) : (QPoint){0, 0};
	int l = w ? w->port->portRect.left : 0, t = w ? w->port->portRect.top : 0;
	return (QPoint){(int16_t)(o.v + y - t), (int16_t)(o.h + x - l)};
}

// "op Title x y": content-local x, y of the window whose title starts with Title
static QPoint titled_pos(const char *cmd)
{
	char t[200];
	int x = 0, y = 0;
	sscanf(cmd, "%*s %199s %d %d", t, &x, &y);
	for (char *q = t; *q; q++)
		if (*q == '_')
			*q = ' ';
	Win *w = titled(t);
	QPoint o = w ? win_origin(w) : (QPoint){0, 0};
	return (QPoint){(int16_t)(o.v + y), (int16_t)(o.h + x)};
}

static void mouse(int what, QPoint g, uint16_t mods)
{
	Ev e = {0};
	e.what = (uint16_t)what;
	e.where = g;
	e.modifiers = mods | (what == 2 ? 0x80 : 0);
	e.win = win_at(g.h, g.v);
	ev_post(e);
}

static void shot(const char *file, const char *title)
{
	Win *w = titled(title);
	if (!w || !w->port || !w->port->pix)
		return;
	Port *p = w->port;
	int wd = p->bounds.right - p->bounds.left, ht = p->bounds.bottom - p->bounds.top;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, G(p->pix), (size_t)p->rowBytes * ht, NULL);
	CGImageRef img = CGImageCreate(wd, ht, 8, 32, p->rowBytes, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big, dp, NULL,
		false, kCGRenderingIntentDefault);
	if (w->skirt && w->skirt_pix) {
		// with the custom frame drawn below the content
		CGContextRef bc = CGBitmapContextCreate(NULL, wd, ht + w->skirt, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGContextRef sc = CGBitmapContextCreate(w->skirt_pix, wd, w->skirt, 8, (size_t)wd * 4, cs,
			kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef si = CGBitmapContextCreateImage(sc);
		CGContextDrawImage(bc, CGRectMake(0, w->skirt, wd, ht), img);
		CGContextDrawImage(bc, CGRectMake(0, 0, wd, w->skirt), si);
		CGImageRelease(img);
		CGImageRelease(si);
		CGContextRelease(sc);
		img = CGBitmapContextCreateImage(bc);
		CGContextRelease(bc);
	}
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)file, (CFIndex)strlen(file), false);
	CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	CGImageDestinationAddImage(d, img, NULL);
	CGImageDestinationFinalize(d);
	CFRelease(d);
	CFRelease(url);
	CGImageRelease(img);
	CGDataProviderRelease(dp);
	CGColorSpaceRelease(cs);
	ppc_log("script: shot %s (%s)", file, w->title + 1);
}

static void run(const char *cmd)
{
	char op[32] = {0}, a[200] = {0}, b[32] = {0}, m[64] = {0};
	sscanf(cmd, "%31s %199s %31s %63s", op, a, b, m);
	if (ppc_verbose)
		ppc_log("script: %s", cmd);
	if (!strcmp(op, "click") || !strcmp(op, "down") || !strcmp(op, "wclick")) {
		fake = 1;
		if (op[0] == 'd' && !(a[0] == '-' || (a[0] >= '0' && a[0] <= '9'))) {
			fake_pos = titled_pos(cmd);
			m[0] = 0;
		} else if (op[0] == 'w') {
			// wclick Title x y [mods]: content-local x, y of the window whose title starts with Title
			// (underscores for spaces)
			char t[200], m2[64] = "";
			int x = 0, y = 0;
			sscanf(cmd, "%*s %199s %d %d %63s", t, &x, &y, m2);
			for (char *q = t; *q; q++)
				if (*q == '_')
					*q = ' ';
			Win *w = titled(t);
			QPoint o = w ? win_origin(w) : (QPoint){0, 0};
			fake_pos = (QPoint){(int16_t)(o.v + y), (int16_t)(o.h + x)};
			snprintf(m, sizeof m, "%s", m2);
		} else
			fake_pos = global_of(atoi(a), atoi(b));
		fake_down = 1;
		mouse(1, fake_pos, mods_of(m));
		if (strcmp(op, "down")) {
			// released at the next step of the pump
			fake_down = 2;
		}
	} else if (!strcmp(op, "move")) {
		fake = 1;
		fake_pos = (a[0] == '-' || (a[0] >= '0' && a[0] <= '9')) ? global_of(atoi(a), atoi(b)) : titled_pos(cmd);
	} else if (!strcmp(op, "up")) {
		fake_down = 0;
		mouse(2, fake_pos, 0);
	} else if (!strcmp(op, "key")) {
		static const struct { const char *n; uint8_t c, code; } names[] = {
			{"return", 13, 36}, {"tab", 9, 48}, {"esc", 27, 53}, {"left", 28, 123}, {"right", 29, 124},
			{"up", 30, 126}, {"down", 31, 125}, {"del", 8, 51}, {"space", 32, 49},
		};
		uint8_t ch = (uint8_t)a[0], code = 0;
		for (size_t i = 0; i < sizeof names / sizeof *names; i++)
			if (!strcmp(a, names[i].n)) {
				ch = names[i].c;
				code = names[i].code;
			}
		uint16_t mods = mods_of(b);
		if (mods & 0x100) {
			int r = menu_key(ch, mods);
			if (r) {
				Ev e = {0};
				e.what = 1;
				e.where = (QPoint){5, 5};
				e.part = 1;
				e.data = (uint32_t)r;
				ev_post(e);
				return;
			}
		}
		Ev e = {0};
		e.what = 3;
		e.message = ch | (uint32_t)code << 8;
		e.modifiers = mods | 0x80;
		e.win = front();
		e.where = fake ? fake_pos : ev_mouse_global();
		ev_post(e);
	} else if (!strcmp(op, "type")) {
		for (const char *q = a; *q; q++) {
			Ev e = {0};
			e.what = 3;
			e.message = (uint8_t)(*q == '_' ? ' ' : *q);
			e.modifiers = 0x80;
			e.win = front();
			e.where = fake ? fake_pos : ev_mouse_global();
			ev_post(e);
		}
	} else if (!strcmp(op, "menu")) {
		// a choice the menu does not offer now (changed since it was listed, or disabled) cannot be made
		if (!menu_item_enabled(menu_get_handle((int16_t)atoi(a)), atoi(b))) {
			ppc_log("script: menu %s %s is not available (menu %08x, %d items)", a, b, menu_get_handle((int16_t)atoi(a)), menu_count(menu_get_handle((int16_t)atoi(a))));
			return;
		}
		Ev e = {0};
		e.what = 1;
		e.where = (QPoint){5, 5};
		e.part = 1;
		e.data = (uint32_t)(uint16_t)atoi(a) << 16 | (uint16_t)atoi(b);
		ev_post(e);
	} else if (!strcmp(op, "menus")) {
		extern void menu_dump(void);
		menu_dump();
	} else if (!strcmp(op, "windows")) {
		for (Win *w = win_list(); w; w = w->next)
			ppc_log("script: window %08x '%.*s' class %d visible %d frame %d,%d,%d,%d", w->tok, w->title[0], w->title + 1, w->wclass,
				w->visible, w->frame.top, w->frame.left, w->frame.bottom, w->frame.right);
	} else if (!strcmp(op, "dump")) {
		uint32_t at = (uint32_t)strtoul(a, NULL, 16);
		int n = atoi(b);
		for (int i = 0; i < n; i += 16) {
			char line[80] = {0};
			for (int k = 0; k < 16 && i + k < n; k++)
				sprintf(line + strlen(line), "%02x%s", LD8(at + i + k), k % 4 == 3 ? " " : "");
			ppc_log("script: %08x: %s", at + i, line);
		}
	} else if (!strcmp(op, "shot"))
		shot(a, b);
	else if (!strcmp(op, "quit"))
		exit(0);
}

void script_tick(void)
{
	if (!loaded)
		load();
	if (fake_down == 2)
		fake_down = 3;           // pressed for one pump
	else if (fake_down == 3) {
		fake_down = 0;
		mouse(2, fake_pos, 0);
	}
	if (next_step >= nsteps)
		return;
	double now = CFAbsoluteTimeGetCurrent() - t_start;
	while (next_step < nsteps && steps[next_step].t <= now)
		run(steps[next_step++].cmd);
}
