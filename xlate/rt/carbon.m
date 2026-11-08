// More Carbon calls AppleWorks 6 makes at startup: event loop timers and the
// Time Manager (both fired from the event loop on the application thread),
// window positioning bounds, color tables, region queries, Process Manager
// comparisons, and calls with nothing to do here.
#import <AppKit/AppKit.h>
#include "win.h"
#include "rgn.h"
#include "hmap.h"

uint32_t cf_tok(CFTypeRef o);
CFTypeRef cf_obj(uint32_t t);
uint32_t res_get(uint32_t type, int16_t id, int one);
QRect qd_screen_rect(void);
void theme_font_metrics(int id, int *size, int *bold);

// ---- timers

typedef struct Timer {
	uint32_t tok;          // EventLoopTimerRef, or the TMTask address
	uint32_t proc, data;   // the UPP and its user data (Time Manager: the task itself)
	double fire, interval; // absolute time of the next firing; seconds between (0: once)
	int tm;                // a Time Manager task
	int armed;
	struct Timer *next;
} Timer;

static Timer *timers;
static uint32_t next_timer_tok = 0x7e000001;
static int running;

static Timer *timer_find(uint32_t tok)
{
	for (Timer *t = timers; t; t = t->next)
		if (t->tok == tok)
			return t;
	return NULL;
}

static void timer_remove(Timer *x)
{
	for (Timer **p = &timers; *p; p = &(*p)->next)
		if (*p == x) {
			*p = x->next;
			free(x);
			return;
		}
}

// fire whatever is due; called from the event loop
void timers_run(void)
{
	if (running || !timers)
		return;
	running = 1;
	double now = CFAbsoluteTimeGetCurrent();
	for (int pass = 0; pass < 64; pass++) {
		Timer *due = NULL;
		for (Timer *t = timers; t; t = t->next)
			if (t->armed && t->fire <= now && (!due || t->fire < due->fire))
				due = t;
		if (!due)
			break;
		uint32_t proc = due->proc, tok = due->tok, data = due->data;
		if (due->tm) {
			due->armed = 0;
			ppc_cb1(proc, tok);    // TimerProcPtr(TMTaskPtr)
		} else {
			if (due->interval > 0)
				due->fire = now + due->interval;
			else
				due->armed = 0;
			ppc_cb2(proc, tok, data);   // EventLoopTimerProcPtr(EventLoopTimerRef, void *)
		}
	}
	running = 0;
}

// InstallEventLoopTimer(loop, double fireDelay, double interval, upp, userData, EventLoopTimerRef *):
// the doubles come in f1 and f2 and take r4-r7, so upp is r8
static void sh_InstallEventLoopTimer(PPC *c)
{
	Timer *t = calloc(1, sizeof *t);
	t->tok = next_timer_tok++;
	t->proc = c->r[8];
	t->data = c->r[9];
	t->interval = c->f[2].d;
	t->fire = CFAbsoluteTimeGetCurrent() + c->f[1].d;
	t->armed = 1;
	t->next = timers;
	timers = t;
	if (c->r[10])
		ST32(c->r[10], t->tok);
	RET(0);
}

// SetEventLoopTimerNextFireTime(timer, double): the double in f1
static void sh_SetEventLoopTimerNextFireTime(PPC *c)
{
	Timer *t = timer_find(A(0));
	if (!t) {
		RET(-50);
		return;
	}
	double d = c->f[1].d;
	if (d > 1e9)       // kEventDurationForever
		t->armed = 0;
	else {
		t->fire = CFAbsoluteTimeGetCurrent() + d;
		t->armed = 1;
	}
	RET(0);
}

static void sh_RemoveEventLoopTimer(PPC *c)
{
	Timer *t = timer_find(A(0));
	if (t && !t->tm)
		timer_remove(t);
	RET(t ? 0 : -50);
}

// Time Manager: TMTask { qLink 0, qType 4, tmAddr 6, tmCount 10, tmWakeUp 14, tmReserved 18 }
static void sh_InsTime(PPC *c)
{
	uint32_t task = A(0);
	Timer *t = timer_find(task);
	if (!t) {
		t = calloc(1, sizeof *t);
		t->tok = task;
		t->tm = 1;
		t->next = timers;
		timers = t;
	}
	t->armed = 0;
	ST32(task + 10, 0);
}
// PrimeTime(task, count): count > 0 milliseconds, < 0 negated microseconds
static void sh_PrimeTime(PPC *c)
{
	uint32_t task = A(0);
	Timer *t = timer_find(task);
	if (!t)
		return;
	int32_t n = (int32_t)A(1);
	t->proc = LD32(task + 6);
	t->fire = CFAbsoluteTimeGetCurrent() + (n >= 0 ? n / 1000.0 : -n / 1e6);
	t->armed = 1;
}
// RmvTime(task): tmCount gets the time left, in negated microseconds
static void sh_RmvTime(PPC *c)
{
	uint32_t task = A(0);
	Timer *t = timer_find(task);
	if (!t)
		return;
	double left = t->armed ? t->fire - CFAbsoluteTimeGetCurrent() : 0;
	ST32(task + 10, left > 0 ? (uint32_t)-(int32_t)(left * 1e6) : 0);
	timer_remove(t);
}

static void sh_GetMainEventLoop(PPC *c) { RET(1); }
static void sh_AddEventTypesToHandler(PPC *c) { RET(0); }

// ---- QuickDraw

// GetQDGlobalsScreenBits(BitMap *): the main screen's bounds; no bits to draw into
static void sh_GetQDGlobalsScreenBits(PPC *c)
{
	uint32_t b = A(0);
	QRect r = qd_screen_rect();
	ST32(b, 0);
	ST16(b + 4, (uint16_t)(((r.right - r.left) + 15) / 16 * 2));
	ST16(b + 6, (uint16_t)r.top);
	ST16(b + 8, (uint16_t)r.left);
	ST16(b + 10, (uint16_t)r.bottom);
	ST16(b + 12, (uint16_t)r.right);
	RET(b);
}

// GetCTable(id): a 'clut' resource copy, or the standard gray/color ramp for id = depth (+32: gray)
static void sh_GetCTable(PPC *c)
{
	int16_t id = (int16_t)A(0);
	uint32_t h = res_get('clut', id, 0);
	if (h) {
		RET(NewHandleFrom(G(HP(h)), HSize(h)));
		return;
	}
	int depth = id & 31, gray = id & 32;
	if (depth != 1 && depth != 2 && depth != 4 && depth != 8) {
		RET(0);
		return;
	}
	int n = 1 << depth;
	uint32_t ct = NewHandleClearG(8 + 8 * n), p = HP(ct);
	ST32(p, (uint32_t)id);        // ctSeed
	ST16(p + 4, 0);               // ctFlags
	ST16(p + 6, (uint16_t)(n - 1));
	for (int i = 0; i < n; i++) {
		uint16_t v;
		uint16_t rgb[3];
		if (gray || depth <= 2) {
			v = (uint16_t)(0xffff - i * 0xffff / (n - 1));
			rgb[0] = rgb[1] = rgb[2] = v;
		} else if (depth == 4) {
			static const uint32_t c16[16] = {0xffffff, 0xfcf305, 0xff6402, 0xdd0806, 0xf20884, 0x4600a5, 0x0000d4, 0x02abea,
				0x1fb714, 0x006411, 0x562c05, 0x90713a, 0xc0c0c0, 0x808080, 0x404040, 0x000000};
			rgb[0] = (uint16_t)((c16[i] >> 16 & 0xff) * 0x101);
			rgb[1] = (uint16_t)((c16[i] >> 8 & 0xff) * 0x101);
			rgb[2] = (uint16_t)((c16[i] & 0xff) * 0x101);
		} else {
			// the 6x6x6 cube, then ramps of red, green, blue and gray
			if (i < 215) {
				int r = 5 - i / 36, g = 5 - i / 6 % 6, b = 5 - i % 6;
				rgb[0] = (uint16_t)(r * 0x3333), rgb[1] = (uint16_t)(g * 0x3333), rgb[2] = (uint16_t)(b * 0x3333);
			} else if (i == 255) {
				rgb[0] = rgb[1] = rgb[2] = 0;
			} else {
				int k = i - 215, ramp = k / 10, step = k % 10;
				static const uint8_t lv[10] = {0xee, 0xdd, 0xbb, 0xaa, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11};
				uint16_t l = (uint16_t)(lv[step] * 0x101);
				rgb[0] = ramp == 0 || ramp == 3 ? l : 0;
				rgb[1] = ramp == 1 || ramp == 3 ? l : 0;
				rgb[2] = ramp == 2 || ramp == 3 ? l : 0;
			}
		}
		ST16(p + 8 + 8 * i, (uint16_t)i);
		ST16(p + 10 + 8 * i, rgb[0]);
		ST16(p + 12 + 8 * i, rgb[1]);
		ST16(p + 14 + 8 * i, rgb[2]);
	}
	RET(ct);
}
static void sh_DisposeCTable(PPC *c) { if (is_handle(A(0))) SHIM_CALL("DisposeHandle", A(0)); }

static void sh_IsRegionRectangular(PPC *c)
{
	Rgn *g = RGN(A(0));
	RET(g && g->n <= 1);
}

// QDRegionToRects(rgn, dir, RegionToRectsUPP, refCon): each rectangle to the callback as
// (kQDRegionToRectsMsgParse, rgn, const Rect *, refCon), between Init and Terminate messages
static void sh_QDRegionToRects(PPC *c)
{
	Rgn *g = RGN(A(0));
	uint32_t rgn = A(0), proc = A(2), ref = A(3);
	if (!g) {
		RET(-50);
		return;
	}
	uint32_t r = gmalloc(8);
	uint32_t a[4] = {1, rgn, r, ref};   // kQDRegionToRectsMsgInit
	ppc_callback(proc, 4, a);
	int n = g->n;
	int rev = (int16_t)A(1) == 1 || (int16_t)A(1) == 3;   // kQDParseRegionFromBottom... reverse order
	for (int k = 0; k < n; k++) {
		QRect q = g->r[rev ? n - 1 - k : k];
		ST16(r, (uint16_t)q.top);
		ST16(r + 2, (uint16_t)q.left);
		ST16(r + 4, (uint16_t)q.bottom);
		ST16(r + 6, (uint16_t)q.right);
		a[0] = 2;   // kQDRegionToRectsMsgParse
		if (ppc_callback(proc, 4, a))
			break;
	}
	a[0] = 3;   // kQDRegionToRectsMsgTerminate
	ppc_callback(proc, 4, a);
	gfree(r);
	RET(0);
}

static void sh_QDIsPortBuffered(PPC *c) { RET(1); }

// CopyDeepMask(src, mask, dst, srcRect, maskRect, dstRect, mode, maskRgn): CopyMask's shape,
// then the transfer mode is the source copy
static void sh_CopyDeepMask(PPC *c)
{
	SHIM_CALL("CopyMask", A(0), A(1), A(2), A(3), A(4), A(5));
}

// ---- windows

// GetAvailableWindowPositioningBounds(GDHandle, Rect *): the screen less the menu bar and Dock
static void sh_GetAvailableWindowPositioningBounds(PPC *c)
{
	NSScreen *s = NSScreen.mainScreen;
	NSRect f = s.frame, v = s.visibleFrame;
	if (qd_guest_screen_is_virtual()) {
		QRect g = qd_screen_rect();
		g.top = 22;   // the menu bar's height
		PUTRECT(A(1), g);
		return;
	}
	int top = (int)(NSMaxY(f) - NSMaxY(v)), left = (int)(v.origin.x - f.origin.x);
	ST16(A(1), (uint16_t)top);
	ST16(A(1) + 2, (uint16_t)left);
	ST16(A(1) + 4, (uint16_t)(top + (int)v.size.height));
	ST16(A(1) + 6, (uint16_t)(left + (int)v.size.width));
	RET(0);
}
static void sh_ChangeWindowAttributes(PPC *c) { RET(0); }
static void sh_ReshapeCustomWindow(PPC *c) { RET(0); }
static void sh_SetThemeWindowBackground(PPC *c) { RET(0); }
static void sh_ShowHide(PPC *c) { SHIM_CALL((A(1) & 0xff) ? "ShowWindow" : "HideWindow", A(0)); }
// PaintOne(window, clobberedRgn): the window repaints on its update event
static void sh_PaintOne(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(1));
	if (w && g)
		// global coordinates, to the content's
		win_invalidate(w, rect_off(g->bbox, w->port->portRect.left - w->frame.left, w->port->portRect.top - w->frame.top));
}

// ---- controls, collections, Process Manager, Internet Config, and the rest

static void sh_SetControlProperty(PPC *c) { RET(0); }
static void sh_NewCollection(PPC *c) { RET(gcalloc(16)); }
static void sh_FindNextComponent(PPC *c) { RET(0); }
static void sh_ICStart(PPC *c) { if (A(0)) ST32(A(0), 0); RET(-108); }   // no Internet Config: memFullErr like a failed open
static void sh_AEInstallCoercionHandler(PPC *c) { RET(0); }
static void sh_InitDateCache(PPC *c) { RET(0); }
static void sh_LMGetApFontID(PPC *c) { RET(1); }   // applFont: Geneva
static void sh_LMGetKbdType(PPC *c) { RET(0x0b); }  // an Apple Extended keyboard
// LMGetCurApName: the application's name, a Pascal string
static void sh_LMGetCurApName(PPC *c)
{
	static uint32_t name;
	if (!name) {
		static const char n[] = "AppleWorks 6";
		name = gcalloc(32);
		*(uint8_t *)G(name) = (uint8_t)(sizeof n - 1);
		memcpy(G(name + 1), n, sizeof n - 1);
	}
	RET(name);
}
// the cursor is hidden only until the mouse moves (ObscureCursor); these balance nothing more
static void sh_HideCursor(PPC *c) { (void)c; }
static void sh_ShowCursor(PPC *c) { (void)c; }
static void sh_GetCaretTime(PPC *c) { RET(32); }
static void sh_CFStringCreateMutable(PPC *c) { RET(cf_tok(CFStringCreateMutable(NULL, (CFIndex)A(1)))); }
static void sh_CFBundleGetMainBundle(PPC *c) { RET(cf_tok(CFBundleGetMainBundle())); }
// GetFrontProcess(ProcessSerialNumber *): this one (kCurrentProcess is {0, 2})
static void sh_GetFrontProcess(PPC *c) { ST32(A(0), 0); ST32(A(0) + 4, 2); RET(0); }
static void sh_SameProcess(PPC *c)
{
	int same = LD32(A(0)) == LD32(A(1)) && LD32(A(0) + 4) == LD32(A(1) + 4);
	if (A(2))
		ST8(A(2), same);
	RET(0);
}

// Collections: GetTheme fills none, so every item lookup misses
static void sh_DisposeCollection(PPC *c) { if (A(0)) gfree(A(0)); }
static void sh_GetTheme(PPC *c) { RET(0); }
static void sh_GetCollectionItem(PPC *c) { RET(-5752); }   // collectionItemNotFoundErr

static void sh_RestoreDeviceClut(PPC *c) { (void)c; }   // the display needs no palette
static void sh_CFAllocatorGetDefault(PPC *c) { RET(cf_tok(CFAllocatorGetDefault())); }
static void sh_CFStringGetSystemEncoding(PPC *c) { RET(0); }   // kCFStringEncodingMacRoman
static void sh_CFStringAppendCString(PPC *c)
{
	CFTypeRef s = cf_obj(A(0));
	if (s && CFGetTypeID(s) == CFStringGetTypeID() && A(1))
		CFStringAppendCString((CFMutableStringRef)s, (const char *)G(A(1)), (CFStringEncoding)A(2));
}
static void sh_CFBundleCopyResourcesDirectoryURL(PPC *c)
{
	CFTypeRef b = cf_obj(A(0));
	CFURLRef u = b && CFGetTypeID(b) == CFBundleGetTypeID() ? CFBundleCopyResourcesDirectoryURL((CFBundleRef)b) : NULL;
	RET(u ? cf_tok(u) : 0);
}

// GetThemeTextDimensions(CFStringRef, ThemeFontID, state, wrapToWidth, Point *ioBounds, SInt16 *outBaseline)
static void sh_GetThemeTextDimensions(PPC *c)
{
	CFTypeRef s = cf_obj(A(0));
	NSString *str = s && CFGetTypeID(s) == CFStringGetTypeID() ? (__bridge NSString *)s : @"";
	int size, bold;
	theme_font_metrics((int16_t)A(1), &size, &bold);
	NSFont *f = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
	NSDictionary *at = @{NSFontAttributeName: f};
	NSSize sz;
	int wrap = (A(3) & 0xff) && A(4) && (int16_t)LD16(A(4) + 2) > 0;
	if (wrap) {
		NSRect r = [str boundingRectWithSize:NSMakeSize((int16_t)LD16(A(4) + 2), 1e6)
			options:NSStringDrawingUsesLineFragmentOrigin attributes:at];
		sz = r.size;
	} else
		sz = [str sizeWithAttributes:at];
	if (A(4)) {
		ST16(A(4), (uint16_t)(int16_t)ceil(sz.height));
		ST16(A(4) + 2, (uint16_t)(int16_t)ceil(sz.width));
	}
	if (A(5))
		ST16(A(5), (uint16_t)(int16_t)floor(f.descender));
	RET(0);
}

static void sh_IsPortColor(PPC *c) { RET(1); }
static void sh_WakeUpProcess(PPC *c) { RET(0); }

// InvokeXxxUPP(args..., upp): on PowerPC a UPP is the procedure's transition vector
static void invoke_upp(PPC *c, int n)
{
	uint32_t a[8];
	for (int i = 0; i < n; i++)
		a[i] = c->r[3 + i];
	RET(ppc_callback(c->r[3 + n], n, a));
}
static void sh_InvokeWindowDefUPP(PPC *c) { invoke_upp(c, 4); }   // (varCode, window, message, param)
static void sh_InvokeModalFilterUPP(PPC *c) { invoke_upp(c, 3); } // (dialog, event, itemHit)
static void sh_InvokeQDBitsUPP(PPC *c) { invoke_upp(c, 5); }      // (srcBits, srcRect, dstRect, mode, maskRgn)
static void sh_InvokeQDCommentUPP(PPC *c) { invoke_upp(c, 3); }   // (kind, dataSize, dataHandle)
static void sh_InvokeQDRgnUPP(PPC *c) { invoke_upp(c, 2); }       // (verb, rgn)
static void sh_InvokePMItemUPP(PPC *c) { invoke_upp(c, 2); }      // (dialog, item)
// (event, reply, mode, priority, timeout, idleProc, filterProc, refCon): the UPP is the ninth argument,
// past the eight argument registers, in the caller's parameter area at r1 + 24 + 32
static void sh_InvokeOSASendUPP(PPC *c)
{
	uint32_t a[8];
	for (int i = 0; i < 8; i++)
		a[i] = c->r[3 + i];
	RET(ppc_callback(LD32(c->r[1] + 56), 8, a));
}

// DeviceLoop(drawingRgn, DeviceLoopDrawingUPP, userData, flags): one 32-bit color screen, so the
// procedure runs once as (depth, deviceFlags, GDHandle, userData)
static void sh_DeviceLoop(PPC *c)
{
	uint32_t a[4] = {32, 1 << 0 /* gdDevType: color */, SHIM_CALL("GetMainDevice", 0), A(2)};
	ppc_callback(A(1), 4, a);
}

// ---- Fixed-point math (16.16)

static void sh_FixMul(PPC *c) { RET((uint32_t)(int32_t)(((int64_t)(int32_t)A(0) * (int32_t)A(1) + 0x8000) >> 16)); }
static void sh_FixDiv(PPC *c)
{
	int32_t a = (int32_t)A(0), b = (int32_t)A(1);
	if (!b) {
		RET(a < 0 ? 0x80000000u : 0x7fffffffu);
		return;
	}
	int64_t q = ((int64_t)a << 16) / b;
	RET((uint32_t)(int32_t)(q > INT32_MAX ? INT32_MAX : q < INT32_MIN ? INT32_MIN : q));
}
// Fix2X(Fixed) -> double in f1; X2Fix(double in f1) -> Fixed
static void sh_Fix2X(PPC *c) { c->f[1].d = (int32_t)A(0) / 65536.0; }
static void sh_X2Fix(PPC *c)
{
	double d = c->f[1].d * 65536.0;
	RET((uint32_t)(int32_t)(d >= 2147483647.0 ? INT32_MAX : d <= -2147483648.0 ? INT32_MIN : lround(d)));
}
static void sh_FixRound(PPC *c) { RET((uint32_t)(int32_t)(int16_t)(((int32_t)A(0) + 0x8000) >> 16)); }

// Microseconds(UnsignedWide *): since start-up
static void sh_Microseconds(PPC *c)
{
	uint64_t us = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1e6);
	ST32(A(0), (uint32_t)(us >> 32));
	ST32(A(0) + 4, (uint32_t)us);
}

// ---- Palette Manager: a direct-color screen has nothing to animate or reserve
// each window's palette, as NSetPalette / SetPalette gave it
static HMap palettes;
static void sh_NSetPalette(PPC *c) { hm_put(&palettes, A(0), (void *)(uintptr_t)A(1)); }
static void sh_GetPalette(PPC *c) { RET((uint32_t)(uintptr_t)hm_get(&palettes, A(0))); }
static void sh_palette_nop(PPC *c) { (void)c; }

// ---- Font Manager

static void sh_RealFont(PPC *c) { RET(1); }                  // outline fonts: every size exists
static void sh_GetOutlinePreferred(PPC *c) { RET(1); }
static void sh_LMGetFractEnable(PPC *c) { RET(0); }
static void sh_SpaceExtra(PPC *c) { if (qd_port) qd_port->spExtra = (int)A(0); }
static void sh_CharExtra(PPC *c) { (void)c; }                // not applied

// a classic WidthTable for the current port's font: Fixed widths of the 256 characters, then the
// font ID, size and style it is for
static uint32_t width_table(Port *p)
{
	static uint32_t h;
	if (!h)
		h = NewHandleClearG(1072);
	uint32_t t = HP(h);
	for (int ch = 0; ch < 256; ch++) {
		uint8_t b = (uint8_t)ch;
		ST32(t + 4 * (uint32_t)ch, (uint32_t)(int32_t)lround(qd_text_width(p, &b, 1) * 65536.0));
	}
	ST32(t + 1028, (uint32_t)p->spExtra);   // sExtra
	ST32(t + 1032, (uint32_t)p->txFace);    // style
	ST16(t + 1036, (uint16_t)p->txFont);    // fID
	ST16(t + 1038, (uint16_t)p->txSize);    // fSize
	ST16(t + 1040, (uint16_t)p->txFace);    // face
	ST32(t + 1044, 0x00010001);             // inNumer
	ST32(t + 1048, 0x00010001);             // inDenom
	ST16(t + 1052, (uint16_t)p->txFont);    // aFID
	ST16(t + 1064, 0x0100);                 // vFactor, hFactor: 1.0 in 8.8
	ST16(t + 1066, 0x0100);
	ST16(t + 1068, (uint16_t)p->txSize);    // aSize
	ST16(t + 1070, 1072);                   // tabSize
	return h;
}
static void sh_LMGetWidthTabHandle(PPC *c) { RET(qd_port ? width_table(qd_port) : 0); }

// FontMetrics(FMetricRec *): ascent, descent, leading, widMax (Fixed), wTabHandle
static void sh_FontMetrics(PPC *c)
{
	Port *p = qd_port;
	uint32_t m = A(0);
	memset(G(m), 0, 20);
	if (!p)
		return;
	int asc, desc, wid, lead;
	qd_font_info(p, &asc, &desc, &wid, &lead);
	ST32(m, (uint32_t)(asc << 16));
	ST32(m + 4, (uint32_t)(desc << 16));
	ST32(m + 8, (uint32_t)(lead << 16));
	ST32(m + 12, (uint32_t)(wid << 16));
	ST32(m + 16, width_table(p));
}

// ---- ports

static void sh_GetPortClipRegion(PPC *c)
{
	Port *p = PORT(A(0));
	Rgn *g = RGN(A(1));
	if (p && g) {
		rgn_copy(g, p->clip);
		rgn_sync(A(1));
	}
	RET(A(1));
}
static void sh_GetPortPenSize(PPC *c)
{
	Port *p = PORT(A(0));
	if (p)
		STPT(A(1), p->pnSize);
	RET(A(1));
}

// IconIDToRgn(rgn, const Rect *, alignment, iconID): the shape of the icon's mask ('ICN#' 32x32, or 'ics#'
// 16x16 for a small rectangle), centered in the rectangle as the icon is drawn (alignment: none)
static void sh_IconIDToRgn(PPC *c)
{
	Rgn *g = RGN(A(0));
	if (!g) {
		RET(-50);
		return;
	}
	QRect r = RECT(A(1));
	int16_t id = (int16_t)A(3);
	int rw = r.right - r.left, rh = r.bottom - r.top;
	int small = rw < 32 || rh < 32;
	uint32_t h = res_get(small ? 'ics#' : 'ICN#', id, 0);
	if (!h && small)
		h = res_get('ICN#', id, 0), small = 0;
	if (!h || !HP(h)) {
		rgn_set_rect(g, r);
		rgn_sync(A(0));
		RET(0);
		return;
	}
	int n = small ? 16 : 32, rowb = n / 8;
	uint32_t mask = HP(h) + (uint32_t)(rowb * n);   // the mask follows the icon
	int ox = r.left + (rw - n) / 2, oy = r.top + (rh - n) / 2;
	rgn_set_empty(g);
	RgnBuild rb;
	rb_begin(&rb, g);
	for (int y = 0; y < n; y++) {
		int16_t xs[64];
		int k = 0, in = 0;
		for (int x = 0; x < n; x++) {
			int on = (LD8(mask + (uint32_t)(y * rowb + x / 8)) >> (7 - (x & 7))) & 1;
			if (on != in) {
				xs[k++] = (int16_t)(ox + x);
				in = on;
			}
		}
		if (in)
			xs[k++] = (int16_t)(ox + n);
		if (k)
			rb_row(&rb, oy + y, xs, k);
	}
	rb_end(&rb);
	rgn_sect_rect(g, r);
	rgn_sync(A(0));
	RET(0);
}

static void sh_ObscureCursor(PPC *c) { (void)c; [NSCursor setHiddenUntilMouseMoves:YES]; }

// GetScriptManagerVariable(selector): smEnabled 4 -> one script; smVersion 0; the rest Roman (0)
static void sh_GetScriptManagerVariable(PPC *c)
{
	switch ((int16_t)A(0)) {
	case 0: RET(0x0710); break;   // smVersion
	case 4: RET(1); break;        // smEnabled
	default: RET(0); break;
	}
}

static void sh_GetPen(PPC *c) { if (qd_port) STPT(A(0), qd_port->pnLoc); }

// QDTextBounds(byteCount, textAddr, Rect *): the text's extent from the pen's baseline origin
static void sh_QDTextBounds(PPC *c)
{
	Port *p = qd_port;
	QRect r = {0, 0, 0, 0};
	if (p) {
		int asc, desc, wid, lead;
		qd_font_info(p, &asc, &desc, &wid, &lead);
		int w = (int)lround(qd_text_width(p, G(A(1)), (int16_t)A(0)));
		r = (QRect){(int16_t)-asc, 0, (int16_t)desc, (int16_t)w};
	}
	PUTRECT(A(2), r);
}

// SubPt(Point src, Point *dst): dst -= src
static void sh_SubPt(PPC *c)
{
	QPoint s = PT(A(0)), d = LDPT(A(1));
	STPT(A(1), (QPoint){(int16_t)(d.v - s.v), (int16_t)(d.h - s.h)});
}
// AddPt(Point src, Point *dst): dst += src
static void sh_AddPt(PPC *c)
{
	QPoint s = PT(A(0)), d = LDPT(A(1));
	STPT(A(1), (QPoint){(int16_t)(d.v + s.v), (int16_t)(d.h + s.h)});
}
// Pt2Rect(Point a, Point b, Rect *): the smallest rectangle enclosing both
static void sh_Pt2Rect(PPC *c)
{
	QPoint a = PT(A(0)), b = PT(A(1));
	QRect r = {a.v < b.v ? a.v : b.v, a.h < b.h ? a.h : b.h, a.v > b.v ? a.v : b.v, a.h > b.h ? a.h : b.h};
	PUTRECT(A(2), r);
}
static void sh_GetPortSpExtra(PPC *c) { Port *p = PORT(A(0)); RET(p ? (uint32_t)p->spExtra : 0); }
static void sh_FixRatio(PPC *c)
{
	int32_t n = (int16_t)A(0), d = (int16_t)A(1);
	RET(d ? (uint32_t)(int32_t)(((int64_t)n << 16) / d) : (n < 0 ? 0x80000000u : 0x7fffffffu));
}
static void sh_GetPortPenLocation(PPC *c) { Port *p = PORT(A(0)); if (p) STPT(A(1), p->pnLoc); RET(A(1)); }
static void sh_TEAutoView(PPC *c) { (void)c; }
static void sh_GetCTSeed(PPC *c) { static uint32_t seed = 1024; RET(++seed); }
static void sh_QTNewAtomContainer(PPC *c) { if (A(0)) ST32(A(0), NewHandleClearG(12)); RET(0); }

// TETextBox(text, length, const Rect *box, just): wrapped at word breaks in the port's font;
// teFlushDefault/Left 0, teCenter 1, teFlushRight -1
static void sh_TETextBox(PPC *c)
{
	Port *p = qd_port;
	if (!p || !A(2))
		return;
	const uint8_t *t = G(A(0));
	int n = (int)A(1);
	QRect r = RECT(A(2));
	int just = (int16_t)A(3), width = r.right - r.left;
	SHIM_CALL("EraseRect", A(2));
	int asc, desc, wid, lead;
	qd_font_info(p, &asc, &desc, &wid, &lead);
	QPoint saved = p->pnLoc;
	int y = r.top + asc, i = 0;
	while (i < n && y - asc < r.bottom) {
		// the longest run of whole words that fits, up to a return
		int end = i, last_break = -1;
		while (end < n && t[end] != 13) {
			if (t[end] == ' ')
				last_break = end;
			if (qd_text_width(p, t + i, end + 1 - i) > width && end > i)
				break;
			end++;
		}
		if (end < n && t[end] != 13 && last_break > i)
			end = last_break;
		int len = end - i;
		int w = (int)lround(qd_text_width(p, t + i, len));
		p->pnLoc.h = (int16_t)(just == 1 ? r.left + (width - w) / 2 : just == -1 ? r.right - w : r.left);
		p->pnLoc.v = (int16_t)y;
		qd_text_draw(p, t + i, len);
		i = end;
		if (i < n && (t[i] == 13 || t[i] == ' '))
			i++;
		y += asc + desc + lead;
	}
	p->pnLoc = saved;
}

static const ShimDef carbonshims[] = {
	S(SubPt), S(AddPt), S(Pt2Rect), S(GetPortSpExtra), S(FixRatio), S(GetPortPenLocation), S(TEAutoView), S(GetCTSeed), S(QTNewAtomContainer), S(TETextBox),
	S(ObscureCursor), S(GetScriptManagerVariable), S(GetPen), S(QDTextBounds),
	S(FixMul), S(FixDiv), S(FixRound), S(Fix2X), S(X2Fix), S(Microseconds), S(GetPalette), S(NSetPalette), {"SetPalette", sh_NSetPalette},
	{"ActivatePalette", sh_palette_nop}, S(RealFont), S(GetOutlinePreferred), S(LMGetFractEnable), S(SpaceExtra),
	S(CharExtra), S(LMGetWidthTabHandle), S(FontMetrics), S(GetPortClipRegion), S(GetPortPenSize), S(IconIDToRgn),
	S(DeviceLoop),
	S(InvokeWindowDefUPP), S(InvokeModalFilterUPP), S(InvokeQDBitsUPP), S(InvokeQDCommentUPP), S(InvokeQDRgnUPP),
	S(InvokePMItemUPP), S(InvokeOSASendUPP),
	S(DisposeCollection), S(GetTheme), S(GetCollectionItem), S(CFStringGetSystemEncoding), S(CFAllocatorGetDefault), S(RestoreDeviceClut), S(CFStringAppendCString),
	S(CFBundleCopyResourcesDirectoryURL), S(GetThemeTextDimensions), S(IsPortColor), S(WakeUpProcess),
	S(InstallEventLoopTimer), S(SetEventLoopTimerNextFireTime), S(RemoveEventLoopTimer), S(InsTime), S(PrimeTime),
	S(RmvTime), {"InsXTime", sh_InsTime}, S(GetMainEventLoop), S(AddEventTypesToHandler),
	S(GetQDGlobalsScreenBits), S(GetCTable), S(DisposeCTable), S(IsRegionRectangular), S(QDRegionToRects),
	S(QDIsPortBuffered), S(CopyDeepMask), S(GetAvailableWindowPositioningBounds), S(ChangeWindowAttributes),
	S(ReshapeCustomWindow), S(SetThemeWindowBackground), S(ShowHide), S(PaintOne), S(SetControlProperty),
	S(NewCollection), S(FindNextComponent), S(ICStart), S(AEInstallCoercionHandler), S(InitDateCache),
	S(LMGetApFontID), S(LMGetKbdType), S(LMGetCurApName), S(HideCursor), S(ShowCursor), S(GetCaretTime), S(CFStringCreateMutable), S(CFBundleGetMainBundle), S(GetFrontProcess),
	S(SameProcess),
};
REGISTER(carbonshims)
