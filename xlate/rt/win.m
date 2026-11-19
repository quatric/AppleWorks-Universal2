// Window Manager (see win.h).
#import <AppKit/AppKit.h>
#include "win.h"
#include "ctl.h"

enum { TAG_WIN = 'wind' };
static Win *windows;   // front to back

uint32_t res_get(uint32_t type, int16_t id, int one);

// ---- the content view -----------------------------------------------------------

@interface XLWinView : NSView {
@public
	Win *win;
	NSTrackingArea *track;
}
@end

@interface XLWindow : NSWindow
@end
int qd_guest_screen_is_virtual(void);
@implementation XLWindow
// the virtual display is not an NSScreen: keep AppKit from pulling windows onto the user's own screen
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)screen { return qd_guest_screen_is_virtual() ? r : [super constrainFrameRect:r toScreen:screen]; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface XLPanel : NSPanel
@end
@implementation XLPanel
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)screen { return qd_guest_screen_is_virtual() ? r : [super constrainFrameRect:r toScreen:screen]; }
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface XLWinDelegate : NSObject <NSWindowDelegate>
@end

static XLWinDelegate *delegate;

@implementation XLWinView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }
- (void)drawRect:(NSRect)dirty
{
	if (getenv("PPC_DBG_FLUSH"))
		ppc_log("drawRect %.0f,%.0f %.0fx%.0f", dirty.origin.x, dirty.origin.y, dirty.size.width, dirty.size.height);
	(void)dirty;
	Port *p = win ? win->port : NULL;
	if (!p || !p->pix)
		return;
	int w = p->bounds.right - p->bounds.left, h = p->bounds.bottom - p->bounds.top;
	CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
	NSRect b = self.bounds;
	if (b.size.width > w || b.size.height > h) {
		CGContextSetRGBFillColor(cg, p->bg.r / 65535.0, p->bg.g / 65535.0, p->bg.b / 65535.0, 1);
		CGContextFillRect(cg, NSRectToCGRect(b));
	}
	CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, G(p->pix), (size_t)p->rowBytes * h, NULL);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGImageRef img = CGImageCreate(w, h, 8, 32, p->rowBytes, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big, dp,
		NULL, false, kCGRenderingIntentDefault);
	CGContextSaveGState(cg);
	CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
	CGContextTranslateCTM(cg, 0, h);
	CGContextScaleCTM(cg, 1, -1);
	CGContextDrawImage(cg, CGRectMake(0, 0, w, h), img);
	CGContextRestoreGState(cg);
	CGImageRelease(img);
	CGDataProviderRelease(dp);
	if (win->skirt && win->skirt_pix) {
		// the custom frame below the content, transparent outside its structure region
		CGContextClearRect(cg, CGRectMake(0, h, b.size.width, win->skirt));
		CGContextRef bc = CGBitmapContextCreate(win->skirt_pix, w, win->skirt, 8, (size_t)w * 4, cs,
			kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef si = bc ? CGBitmapContextCreateImage(bc) : NULL;
		if (si) {
			CGContextSaveGState(cg);
			CGContextTranslateCTM(cg, 0, h + win->skirt);
			CGContextScaleCTM(cg, 1, -1);
			CGContextDrawImage(cg, CGRectMake(0, 0, w, win->skirt), si);
			CGContextRestoreGState(cg);
			CGImageRelease(si);
		}
		if (bc)
			CGContextRelease(bc);
	}
	CGColorSpaceRelease(cs);
}
- (QPoint)globalOf:(NSEvent *)e
{
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	QPoint o = win_origin(win);
	return (QPoint){(int16_t)(o.v + (int)floor(p.y)), (int16_t)(o.h + (int)floor(p.x))};
}
// scripted runs take their input from the script only: keys and clicks from the real keyboard and
// mouse (the app comes to the front) would land in the documents under test
static int real_input(void)
{
	static int scripted = -1;
	if (scripted < 0)
		scripted = getenv("PPC_SCRIPT") != NULL;
	return !scripted;
}
- (void)mouse:(NSEvent *)e what:(int)what
{
	if (!real_input())
		return;
	Ev ev = {0};
	ev.what = (uint16_t)what;
	ev.where = [self globalOf:e];
	ev.modifiers = ev_mac_modifiers(e.modifierFlags) | (what == 2 ? 0x80 : 0);
	ev.message = what == 1 ? (uint32_t)(e.clickCount > 1 ? 1 : 0) : 0;
	ev.win = win;
	ev_post(ev);
}
- (void)mouseDown:(NSEvent *)e { [self mouse:e what:1]; }
- (void)mouseUp:(NSEvent *)e { [self mouse:e what:2]; }
- (void)rightMouseDown:(NSEvent *)e
{
	// a control-click, as on one-button mice
	if (!real_input())
		return;
	Ev ev = {0};
	ev.what = 1;
	ev.where = [self globalOf:e];
	ev.modifiers = ev_mac_modifiers(e.modifierFlags) | 0x1000;
	ev.win = win;
	ev_post(ev);
}
- (void)rightMouseUp:(NSEvent *)e { [self mouse:e what:2]; }
- (void)keyUp:(NSEvent *)e { (void)e; }
- (void)flagsChanged:(NSEvent *)e { (void)e; }
- (void)cursorUpdate:(NSEvent *)e { (void)e; }   // the guest sets the cursor
- (void)updateTrackingAreas
{
	if (track)
		[self removeTrackingArea:track];
	[track release];
	track = [[NSTrackingArea alloc] initWithRect:self.bounds
		options:NSTrackingCursorUpdate | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
	[self addTrackingArea:track];
	[super updateTrackingAreas];
}
@end

// key events: Mac Roman characters and the classic key codes (the same as the virtual key codes)
static uint8_t mac_char(NSEvent *e)
{
	NSString *s = (e.modifierFlags & NSEventModifierFlagCommand) ? e.charactersIgnoringModifiers : e.characters;
	if (!s.length)
		return 0;
	unichar u = [s characterAtIndex:0];
	switch (u) {
	case NSLeftArrowFunctionKey: return 28;
	case NSRightArrowFunctionKey: return 29;
	case NSUpArrowFunctionKey: return 30;
	case NSDownArrowFunctionKey: return 31;
	case NSDeleteFunctionKey: return 127;
	case NSHomeFunctionKey: return 1;
	case NSEndFunctionKey: return 4;
	case NSPageUpFunctionKey: return 11;
	case NSPageDownFunctionKey: return 12;
	case NSHelpFunctionKey: return 5;
	case 0x7f: return 8;      // the delete key is backspace
	case 0x19: return 9;      // back tab
	case 3: return 3;
	}
	if (u >= NSF1FunctionKey && u <= NSF35FunctionKey)
		return 16;
	if (u < 128)
		return (uint8_t)u;
	char buf[8];
	if ([s getCString:buf maxLength:sizeof buf encoding:NSMacOSRomanStringEncoding])
		return (uint8_t)buf[0];
	return '?';
}

@implementation XLWinView (Keys)
- (void)keyDown:(NSEvent *)e
{
	if (!real_input())
		return;
	Ev ev = {0};
	ev.what = e.ARepeat ? 5 : 3;
	ev.message = mac_char(e) | ((uint32_t)e.keyCode << 8);
	ev.where = ev_mouse_global();
	ev.modifiers = ev_mac_modifiers(e.modifierFlags) | 0x80;
	ev.win = win;
	ev_post(ev);
}
- (void)scrollWheel:(NSEvent *)e
{
	extern void ev_scroll(Win *w, NSEvent *e);
	ev_scroll(win, e);
}
@end

@implementation XLWinDelegate
static Win *of(NSNotification *n)
{
	for (Win *w = windows; w; w = w->next)
		if (w->ns == n.object)
			return w;
	return NULL;
}
static Win *ofw(NSWindow *nw)
{
	for (Win *w = windows; w; w = w->next)
		if (w->ns == nw)
			return w;
	return NULL;
}
- (void)windowDidMove:(NSNotification *)n
{
	Win *w = of(n);
	if (!w)
		return;
	NSRect cr = [(NSWindow *)w->ns contentRectForFrameRect:((NSWindow *)w->ns).frame];
	if (ppc_verbose)
		ppc_log("windowDidMove %08x '%.*s': cocoa %.0f,%.0f", w->tok, w->title[0], w->title + 1, cr.origin.x, cr.origin.y);
	int wd = w->frame.right - w->frame.left, ht = w->frame.bottom - w->frame.top;
	w->frame.left = (int16_t)qd_global_x(cr.origin.x);
	w->frame.top = (int16_t)qd_global_y(cr.origin.y + cr.size.height);
	w->frame.right = (int16_t)(w->frame.left + wd);
	w->frame.bottom = (int16_t)(w->frame.top + ht);
}
- (BOOL)windowShouldClose:(NSWindow *)nw
{
	Win *w = ofw(nw);
	if (w)
		ev_post_mouse_part(w, 6, 0);   // inGoAway
	return NO;
}
- (BOOL)windowShouldZoom:(NSWindow *)nw toFrame:(NSRect)f
{
	(void)f;
	Win *w = ofw(nw);
	if (w) {
		QRect cur = w->frame;
		int atStd = !memcmp(&cur, &w->stdState, sizeof cur);
		ev_post_mouse_part(w, atStd ? 7 : 8, 0);   // inZoomIn / inZoomOut
	}
	return NO;
}
- (void)windowDidEndLiveResize:(NSNotification *)n
{
	Win *w = of(n);
	if (!w)
		return;
	NSRect cr = [(NSWindow *)w->ns contentRectForFrameRect:((NSWindow *)w->ns).frame];
	uint32_t size = ((uint32_t)(uint16_t)cr.size.height << 16) | (uint16_t)cr.size.width;
	ev_post_mouse_part(w, 5, size);   // inGrow
}
- (void)windowDidMiniaturize:(NSNotification *)n { Win *w = of(n); if (w) w->collapsed = 1; }
- (void)windowDidDeminiaturize:(NSNotification *)n { Win *w = of(n); if (w) w->collapsed = 0; }
@end

// ---- windows ---------------------------------------------------------------------------

Win *WIN(uint32_t tok) { return tok ? tok_get(tok, TAG_WIN) : NULL; }
Win *win_list(void) { return windows; }

Win *win_front(int visible_only)
{
	for (Win *w = windows; w; w = w->next)
		if (!visible_only || w->visible)
			return w;
	return NULL;
}

static int is_floating(Win *w) { return w->wclass == 5 || w->wclass == 7 || w->wclass == 8; }

QPoint win_origin(Win *w) { return (QPoint){w->frame.top, w->frame.left}; }

// r in the window port's local coordinates as they are now: kept in content coordinates, since the
// app may move the port's origin (SetOrigin) to draw and move it back before the flush
void win_dirty(Win *w, QRect r)
{
	r = rect_off(r, -w->port->portRect.left, -w->port->portRect.top);
	w->dirty = w->has_dirty ? rect_union(w->dirty, r) : r;
	w->has_dirty = 1;
}

void win_flush(Win *w)
{
	if (!w->has_dirty || !w->view)
		return;
	XLWinView *v = w->view;
	QRect r = w->dirty;   // content coordinates
	[v setNeedsDisplayInRect:NSMakeRect(r.left, r.top, r.right - r.left, r.bottom - r.top)];
	if (getenv("PPC_DBG_FLUSH"))
		ppc_log("flush %08x %d,%d,%d,%d (dirty %d,%d,%d,%d portRect %d,%d port %08x)", w->tok, r.top, r.left, r.bottom, r.right,
			w->dirty.top, w->dirty.left, w->dirty.bottom, w->dirty.right, w->port->portRect.top, w->port->portRect.left, w->port->tok);
	w->has_dirty = 0;
}

void win_flush_all(void)
{
	for (Win *w = windows; w; w = w->next)
		win_flush(w);
}

// The update region is kept in content coordinates (0,0 the content's top left), whatever the
// port's origin is when it is invalidated: a region in the port's local coordinates goes in and
// out through these.
void win_update_rgn(Win *w, const Rgn *g, int op)
{
	Rgn *t = rgn_new();
	rgn_copy(t, g);
	rgn_offset(t, -w->port->portRect.left, -w->port->portRect.top);
	rgn_op(w->update, w->update, t, op);
	rgn_free(t);
}

void win_invalidate(Win *w, QRect r)
{
	Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&t, r);
	win_update_rgn(w, &t, RGN_UNION);
	free(t.r);
}

Win *win_at(int h, int v)
{
	for (Win *w = windows; w; w = w->next) {
		if (ppc_verbose >= 3) {
			NSRect f = ((NSWindow *)w->ns).frame;
			ppc_log("win_at %d,%d: %08x vis %d coll %d frame %.0f,%.0f %.0fx%.0f cy %.0f", h, v, w->tok, w->visible, w->collapsed,
				f.origin.x, f.origin.y, f.size.width, f.size.height, qd_cocoa_y(v));
		}
		if (!w->visible || w->collapsed)
			continue;
		NSRect f = ((NSWindow *)w->ns).frame;
		double cy = qd_cocoa_y(v);
		double cx = qd_cocoa_x(h);
		if (cx >= f.origin.x && cx < f.origin.x + f.size.width && cy > f.origin.y && cy <= f.origin.y + f.size.height)
			return w;
	}
	return NULL;
}

static void list_remove(Win *w)
{
	for (Win **p = &windows; *p; p = &(*p)->next)
		if (*p == w) {
			*p = w->next;
			return;
		}
}

static void list_front(Win *w)
{
	list_remove(w);
	// floating windows stay in front of the others
	if (is_floating(w)) {
		w->next = windows;
		windows = w;
		return;
	}
	Win **p = &windows;
	while (*p && is_floating(*p))
		p = &(*p)->next;
	w->next = *p;
	*p = w;
}

static NSRect cocoa_content(QRect r)
{
	return NSMakeRect(qd_cocoa_x(r.left), qd_cocoa_y(r.bottom), r.right - r.left, r.bottom - r.top);
}
// the Cocoa content rectangle of a window: its content plus any custom frame drawn below it
static NSRect win_cocoa_rect(Win *w)
{
	QRect r = w->frame;
	r.bottom = (int16_t)(r.bottom + w->skirt);
	return cocoa_content(r);
}

// A test run's windows stay at the place the guest gave them on the virtual display, even when it changes place
void win_follow_display(void)
{
	if (!qd_guest_screen_is_virtual())
		return;
	for (Win *w = windows; w; w = w->next) {
		NSWindow *nw = w->ns;
		NSRect want = [nw frameRectForContentRect:win_cocoa_rect(w)], have = nw.frame;
		if (fabs(want.origin.x - have.origin.x) > 1 || fabs(want.origin.y - have.origin.y) > 1) {
			if (ppc_verbose)
				ppc_log("window %08x '%.*s' is off its place (%.0f,%.0f, want %.0f,%.0f): moved back", w->tok, w->title[0], w->title + 1,
					have.origin.x, have.origin.y, want.origin.x, want.origin.y);
			[nw setFrameOrigin:want.origin];
		}
	}
}

static void ns_title(Win *w)
{
	NSString *t = mac_ns(w->title + 1, w->title[0]);
	((NSWindow *)w->ns).title = t;
}

// ---- custom window definitions (CreateCustomWindow) -----------------------------------------------
// The definition procedure answers region queries and draws the frame. Cocoa draws the title bar;
// what the definition draws below the content (AppleWorks' Starting Points tabs) is shown in a strip
// under the content view.

static int wdef_busy;   // inside a region query: a nested query answers the standard way

static uint32_t wdef_call(Win *w, int msg, uint32_t param)
{
	uint32_t a[4] = {0, w->tok, (uint32_t)msg, param};
	if (msg == 8)
		wdef_busy++;
	uint32_t r = ppc_callback(w->wdef, 4, a);
	if (msg == 8)
		wdef_busy--;
	return r;
}
static int wdef_drawing;   // inside wdef_render's draw message

// kWindowMsgGetRegion: the region (global coordinates) into g; 0 if the definition gave none
static int wdef_region(Win *w, int code, Rgn *g)
{
	static uint32_t rh, rec;
	static Rgn *rg;
	if (!rh) {
		rh = rgn_handle(&rg);
		rec = gcalloc(8);
	}
	rgn_set_empty(rg);
	rgn_sync(rh);
	ST32(rec, rh);
	ST16(rec + 4, (uint16_t)code);
	wdef_call(w, 8, rec);
	Rgn *got = RGN(rh);
	if (getenv("PPC_DBG_WREG") && got)
		ppc_log("wdef_region %08x code %d -> %d,%d,%d,%d; port rect %d,%d,%d,%d bounds %d,%d,%d,%d cur %08x lr %s", w->tok, code,
			got->bbox.top, got->bbox.left, got->bbox.bottom, got->bbox.right, w->port->portRect.top, w->port->portRect.left,
			w->port->portRect.bottom, w->port->portRect.right, w->port->bounds.top, w->port->bounds.left, w->port->bounds.bottom,
			w->port->bounds.right, qd_port ? qd_port->tok : 0, ppc_func_name(ppc_cpu->lr));
	if (getenv("PPC_DBG_WREG") && got && getenv("PPC_DBG_WREG")[0] == '2')
		for (int i = 0; i < got->n && i < 40; i++)
			ppc_log("  rect %d,%d,%d,%d", got->r[i].top, got->r[i].left, got->r[i].bottom, got->r[i].right);
	if (!got || rgn_empty(got))
		return 0;
	rgn_copy(g, got);
	return 1;
}

static void wdef_render(Win *w)
{
	if (!w->wdef || !w->visible || wdef_busy || wdef_drawing)
		return;
	Rgn *s = rgn_new();
	int skirt = 0;
	if (wdef_region(w, 32, s))   // kWindowStructureRgn
		skirt = s->bbox.bottom - w->frame.bottom;
	if (skirt > 64)
		skirt = 64;
	if (ppc_verbose >= 2)
		ppc_log("wdef_render %08x: structure %d,%d,%d,%d content %d,%d,%d,%d skirt %d", w->tok, s->bbox.top, s->bbox.left,
			s->bbox.bottom, s->bbox.right, w->frame.top, w->frame.left, w->frame.bottom, w->frame.right, skirt);
	int wd = w->frame.right - w->frame.left;
	if (skirt > 0 && wd > 0) {
		// the frame, drawn by the definition as into the Window Manager's port: local coordinates are
		// global ones (it mixes the window's regions, which are global, with points it converts through
		// the port), the port rectangle is the content, and the pixels cover the structure
		QRect sb = s->bbox;
		Port *fp = port_new(0, 0, sb, 1);
		fp->portRect = w->frame;                                   // the content, global
		rgn_set_rect(fp->vis, sb);                                 // the frame is drawn outside it
		PUTRECT(fp->tok + 16, fp->portRect);                       // the CGrafPort copy of it
		fp->coord_win = w;                                         // so LocalToGlobal is the identity
		Port *save = w->port, *savecur = qd_port;
		w->port = fp;
		ST32(w->tok, fp->tok);
		qd_port = fp;
		if (ppc_verbose >= 2)
			ppc_log("wdef_render: frame port %08x", fp->tok);
		wdef_drawing = 1;
		wdef_call(w, 0, 0);   // kWindowMsgDraw, the whole frame
		wdef_drawing = 0;
		if (ppc_verbose >= 2)
			ppc_log("wdef_render: drawn");
		w->port = save;
		ST32(w->tok, save->tok);
		qd_port = savecur;
		uint32_t *px = realloc(w->skirt_pix, (size_t)wd * skirt * 4);
		for (int y = 0; y < skirt; y++)
			for (int x = 0; x < wd; x++) {
				int gh = w->frame.left + x, gv = w->frame.bottom + y;          // global, the frame port's local
				uint32_t v = 0;
				if (rgn_contains(s, gh, gv) && gh >= sb.left && gh < sb.right && gv >= sb.top && gv < sb.bottom) {
					uint32_t q = LD32(fp->pix + (uint32_t)((gv - sb.top) * fp->rowBytes + (gh - sb.left) * 4));
					v = 0xff000000u | (q & 0xffffff);   // guest xRGB -> ARGB
				}
				px[y * wd + x] = v;
			}
		w->skirt_pix = px;
		if (getenv("PPC_DBG_SKIRT")) {
			char fn[256];
			snprintf(fn, sizeof fn, "%s/skirt_%08x.raw", getenv("PPC_DBG_SKIRT"), w->tok);
			FILE *f = fopen(fn, "wb");
			if (f) {
				fwrite(&wd, 4, 1, f);
				fwrite(&skirt, 4, 1, f);
				fwrite(px, 4, (size_t)wd * skirt, f);
				fclose(f);
			}
		}
		gfree(fp->pix);
		port_free(fp);
	}
	rgn_free(s);
	if (skirt < 0)
		skirt = 0;
	if (skirt != w->skirt) {
		w->skirt = skirt;
		NSWindow *nw = w->ns;
		if (skirt) {
			nw.opaque = NO;
			nw.backgroundColor = NSColor.clearColor;
			// a window that is not opaque loses its title bar's fill: give it one
			NSView *tb = [nw standardWindowButton:NSWindowCloseButton].superview;
			if (tb && !tb.subviews.firstObject.identifier) {
				NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:tb.bounds];
				fx.identifier = @"xl-titlefill";
				fx.material = NSVisualEffectMaterialTitlebar;
				fx.blendingMode = NSVisualEffectBlendingModeWithinWindow;
				fx.state = NSVisualEffectStateActive;
				fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
				[tb addSubview:fx positioned:NSWindowBelow relativeTo:nil];
				[fx release];
			}
		}
		[nw setFrame:[nw frameRectForContentRect:win_cocoa_rect(w)] display:NO];
		[(XLWinView *)w->view setFrame:NSMakeRect(0, 0, wd, w->frame.bottom - w->frame.top + skirt)];
	}
	[(XLWinView *)w->view setNeedsDisplay:YES];
}

void win_frame_redraw(Win *w) { wdef_render(w); }

// kWindowMsgHitTest for a global point: the FindWindow part code, -1 if the definition has none
static int wdef_part(Win *w, QPoint p)
{
	if (!w->wdef || wdef_busy)
		return -1;
	static const int8_t parts[13] = {0, 3, 4, 5, 6, 7, 8, -1, -1, 11, 12, 13, 15};
	uint32_t hit = wdef_call(w, 1, (uint32_t)(uint16_t)p.v << 16 | (uint16_t)p.h);
	if (hit < 13)
		return parts[hit];
	// a definition's own hit codes come back two higher, as the window manager has always done
	// (Starting Points' tabs answer 4998, and the app looks for part 5000)
	return hit < 0x7ffe ? (int)hit + 2 : -1;
}

static Win *win_create(int wclass, uint32_t attrs, QRect bounds, const uint8_t *title, int visible, uint32_t refCon, uint32_t behind)
{
	if (ppc_verbose)
		ppc_log("win_create class %d bounds %d,%d,%d,%d (guest screen at x %.0f)", wclass, bounds.top, bounds.left, bounds.bottom, bounds.right, qd_cocoa_x(0));
	Win *w = calloc(1, sizeof *w);
	w->wclass = wclass;
	w->attrs = attrs;
	w->frame = bounds;
	w->refCon = refCon;
	w->kind = 8;   // userKind
	w->update = rgn_new();
	if (title)
		memcpy(w->title, title, title[0] + 1);
	int wd = bounds.right - bounds.left, ht = bounds.bottom - bounds.top;
	w->port = port_new(0, 0, (QRect){0, 0, (int16_t)ht, (int16_t)wd}, 1);
	w->port->win = w;
	w->tok = tok_new(w, 256, TAG_WIN);
	ST32(w->tok + 0, w->port->tok);   // so that a WindowPtr dereferences to its port, as in classic code
	w->stdState = qd_screen_rect();
	w->stdState.top += qd_menubar_height + 22;
	w->stdState = rect_off(w->stdState, 0, 0);
	w->userState = bounds;

	NSWindowStyleMask style;
	BOOL panel = NO;
	switch (wclass) {
	case 11: case 14: case 12: style = NSWindowStyleMaskBorderless; break;     // plain
	case 5: case 7: case 8: style = NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow; panel = YES; break;
	case 1: case 2: case 3: case 4: style = NSWindowStyleMaskTitled; break;   // alerts, modal dialogs
	default: style = NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable; break;
	}
	{   // a window that fills the screen (a slide show) has no title bar
		QRect sr = qd_screen_rect();
		if ((wclass == 3 || wclass == 4) && bounds.right - bounds.left >= (sr.right - sr.left) * 9 / 10 &&
		    bounds.bottom - bounds.top >= (sr.bottom - sr.top) * 9 / 10)
			style = NSWindowStyleMaskBorderless;
	}
	if (style != NSWindowStyleMaskBorderless) {
		if (attrs & 1)
			style |= NSWindowStyleMaskClosable;
		if (attrs & 0x10)
			style |= NSWindowStyleMaskResizable;
		if (!(attrs & 8) && wclass == 6)
			style &= ~NSWindowStyleMaskMiniaturizable;
	}
	NSRect cr = cocoa_content(bounds);
	NSWindow *nw;
	if (panel)
		nw = [[XLPanel alloc] initWithContentRect:cr styleMask:style backing:NSBackingStoreBuffered defer:NO];
	else
		nw = [[XLWindow alloc] initWithContentRect:cr styleMask:style backing:NSBackingStoreBuffered defer:NO];
	if (qd_guest_screen_is_virtual())   // creation pulls a window onto a screen AppKit knows: put it where the guest asked
		[nw setFrameOrigin:[nw frameRectForContentRect:cr].origin];
	if (ppc_verbose)
		ppc_log("win_create: asked for cocoa content %.0f,%.0f %.0fx%.0f, got window frame %.0f,%.0f %.0fx%.0f", cr.origin.x, cr.origin.y, cr.size.width, cr.size.height,
			nw.frame.origin.x, nw.frame.origin.y, nw.frame.size.width, nw.frame.size.height);
	nw.releasedWhenClosed = NO;
	if (!delegate)
		delegate = [XLWinDelegate new];
	nw.delegate = delegate;
	if (panel) {
		nw.level = NSFloatingWindowLevel;
		((NSPanel *)nw).floatingPanel = YES;
		((NSPanel *)nw).hidesOnDeactivate = !getenv("PPC_STAY_ACTIVE");   // test runs are never frontmost
		((NSPanel *)nw).becomesKeyOnlyIfNeeded = YES;
	} else if (wclass >= 1 && wclass <= 4)
		nw.level = NSModalPanelWindowLevel;
	if (!(attrs & 6))
		[nw standardWindowButton:NSWindowZoomButton].enabled = NO;
	else
		[nw standardWindowButton:NSWindowZoomButton].enabled = YES;
	nw.tabbingMode = NSWindowTabbingModeDisallowed;
	XLWinView *v = [[XLWinView alloc] initWithFrame:NSMakeRect(0, 0, wd, ht)];
	v->win = w;
	nw.contentView = v;
	nw.acceptsMouseMovedEvents = YES;
	w->ns = nw;
	w->view = v;
	ns_title(w);
	if (behind == 0xffffffffu || behind == 0) {
		list_front(w);
	} else {
		Win *b = WIN(behind);
		if (b) {
			w->next = b->next;
			b->next = w;
		} else
			list_front(w);
	}
	if (visible) {
		extern void win_show(Win *w);
		win_show(w);
	}
	return w;
}

void win_show(Win *w)
{
	if (w->visible)
		return;
	Win *oldfront = win_front(1);
	w->visible = 1;
	NSWindow *nw = w->ns;
	if (!qd_guest_screen_is_virtual())
		[NSApp activateIgnoringOtherApps:YES];
	NSRect before = nw.frame;
	if (w == win_front(0) || is_floating(w))
		[nw makeKeyAndOrderFront:nil];
	else
		[nw orderFront:nil];
	if (ppc_verbose && !NSEqualRects(before, nw.frame))
		ppc_log("win_show %08x '%.*s': frame %.0f,%.0f %.0fx%.0f -> %.0f,%.0f %.0fx%.0f", w->tok, w->title[0], w->title + 1,
			before.origin.x, before.origin.y, before.size.width, before.size.height, nw.frame.origin.x, nw.frame.origin.y,
			nw.frame.size.width, nw.frame.size.height);
	win_invalidate(w, w->port->portRect);
	wdef_render(w);
	if (win_front(1) == w && !is_floating(w) && oldfront != w) {
		if (oldfront && !is_floating(oldfront))
			ev_activate(oldfront, 0);
		ev_activate(w, 1);
	}
}

static void win_hide(Win *w)
{
	if (!w->visible)
		return;
	int wasfront = win_front(1) == w;
	w->visible = 0;
	[(NSWindow *)w->ns orderOut:nil];
	if (wasfront) {
		ev_activate(w, 0);
		Win *f = win_front(1);
		if (f) {
			[(NSWindow *)f->ns makeKeyWindow];
			ev_activate(f, 1);
		}
	}
}

static void select_window(Win *w)
{
	Win *old = NULL;
	for (Win *x = windows; x; x = x->next)
		if (x->visible && !is_floating(x)) {
			old = x;
			break;
		}
	list_front(w);
	[(NSWindow *)w->ns makeKeyAndOrderFront:nil];
	if (old != w && !is_floating(w)) {
		if (old)
			ev_activate(old, 0);
		ev_activate(w, 1);
	}
}

static void win_dispose(Win *w)
{
	int wasfront = win_front(1) == w;
	if (w->wdef)
		wdef_call(w, 4, 0);   // kWindowMsgCleanUp
	free(w->skirt_pix);
	w->skirt_pix = NULL;
	if (w->root)
		ctl_dispose_all(w);
	list_remove(w);
	NSWindow *nw = w->ns;
	nw.delegate = nil;
	[nw orderOut:nil];
	[nw close];
	((XLWinView *)w->view)->win = NULL;
	[(XLWinView *)w->view release];
	[nw release];
	gfree(w->port->pix);
	port_free(w->port);
	rgn_free(w->update);
	tok_free(w->tok);
	extern void ev_forget_window(Win *w);
	ev_forget_window(w);
	free(w);
	if (wasfront) {
		Win *f = win_front(1);
		if (f && !is_floating(f)) {
			[(NSWindow *)f->ns makeKeyWindow];
			ev_activate(f, 1);
		}
	}
}

static void size_window(Win *w, int wd, int ht)
{
	if (wd <= 0 || ht <= 0)
		return;
	QRect pr = w->port->portRect;
	port_resize(w->port, (QRect){pr.top, pr.left, (int16_t)(pr.top + ht), (int16_t)(pr.left + wd)});
	w->frame.right = (int16_t)(w->frame.left + wd);
	w->frame.bottom = (int16_t)(w->frame.top + ht);
	NSWindow *nw = w->ns;
	NSRect cr = win_cocoa_rect(w);
	[nw setFrame:[nw frameRectForContentRect:cr] display:NO];
	[(XLWinView *)w->view setFrame:NSMakeRect(0, 0, wd, ht + w->skirt)];
	[(XLWinView *)w->view setNeedsDisplay:YES];
	wdef_render(w);
}

static void move_window(Win *w, int h, int v)
{
	int wd = w->frame.right - w->frame.left, ht = w->frame.bottom - w->frame.top;
	w->frame = (QRect){(int16_t)v, (int16_t)h, (int16_t)(v + ht), (int16_t)(h + wd)};
	NSWindow *nw = w->ns;
	NSRect cr = win_cocoa_rect(w);
	[nw setFrame:[nw frameRectForContentRect:cr] display:NO];
}

// ---- shims -------------------------------------------------------------------------------------

// classic window definition IDs -> Carbon classes and attributes
static void proc_class(int proc, int goAway, int *cls, uint32_t *attrs)
{
	*attrs = goAway ? 1 : 0;
	int var = proc & 15;
	if (proc < 64) {
		switch (proc) {
		case 0: *cls = 6; *attrs |= 0x10 | 8; break;          // documentProc
		case 1: case 2: case 3: *cls = proc == 1 ? 3 : 11; break;
		case 4: *cls = 6; *attrs |= 8; break;                 // noGrowDocProc
		case 5: *cls = 4; break;                              // movableDBoxProc
		case 8: *cls = 6; *attrs |= 0x10 | 6 | 8; break;      // zoomDocProc
		case 12: *cls = 6; *attrs |= 6 | 8; break;
		case 16: *cls = 6; break;
		default: *cls = 6; break;
		}
		return;
	}
	switch (proc >> 4) {
	case 64:   // kWindowDocumentProc 1024..
		*cls = 6;
		*attrs |= 8;
		if (var & 1)
			*attrs |= 0x10;
		if (var & 2)
			*attrs |= 4;
		if (var & 4)
			*attrs |= 2;
		break;
	case 65:   // dialogs 1040..
		*cls = var == 0 ? 3 : var == 1 ? 11 : var == 2 ? 11 : var == 3 ? 4 : var == 5 ? 2 : var == 6 ? 1 : 3;
		break;
	case 66: case 67: case 68: case 69:   // floating 1056.., side floating
		*cls = 7;
		if (var & 1)
			*attrs |= 0x10;
		break;
	default: *cls = 6; break;
	}
}

static void sh_NewCWindow(PPC *c)
{
	// NewCWindow(storage, bounds, title, visible, procID, behind, goAwayFlag, refCon)
	int cls;
	uint32_t attrs;
	proc_class((int16_t)A(4), A(6) & 0xff, &cls, &attrs);
	uint8_t title[256] = {0};
	if (A(2))
		memcpy(title, G(A(2)), LD8(A(2)) + 1);
	Win *w = win_create(cls, attrs, RECT(A(1)), title, A(3) & 0xff, A(7), A(5));
	w->procID = (int16_t)A(4);
	w->goAway = A(6) & 0xff;
	RET(w->tok);
}

static void sh_GetNewCWindow(PPC *c)
{
	uint32_t h = res_get('WIND', (int16_t)A(0), 0);
	if (!h) {
		RET(0);
		return;
	}
	uint32_t p = HP(h);
	QRect r = RECT(p);
	int proc = (int16_t)LD16(p + 8), vis = LD16(p + 10) != 0, goAway = LD16(p + 12) != 0;
	uint32_t refCon = LD32(p + 14);
	uint8_t title[256];
	memcpy(title, G(p + 18), LD8(p + 18) + 1);
	uint32_t pos_off = p + 18 + 1 + title[0];
	if (pos_off & 1)
		pos_off++;
	if (pos_off + 2 <= p + HSize(h)) {
		int pos = LD16(pos_off);
		QRect s = qd_screen_rect();
		int wd = r.right - r.left, ht = r.bottom - r.top;
		if (pos == 0x280a || pos == 0xa80a) {   // center on the main screen
			r.left = (int16_t)((s.right - wd) / 2);
			r.top = (int16_t)(qd_menubar_height + (s.bottom - qd_menubar_height - ht) / 2);
		} else if (pos == 0x300a || pos == 0xb00a) {   // alert position
			r.left = (int16_t)((s.right - wd) / 2);
			r.top = (int16_t)(qd_menubar_height + (s.bottom - qd_menubar_height - ht) / 3);
		}
		r.right = (int16_t)(r.left + wd);
		r.bottom = (int16_t)(r.top + ht);
	}
	int cls;
	uint32_t attrs;
	proc_class(proc, goAway, &cls, &attrs);
	Win *w = win_create(cls, attrs, r, title, vis, refCon, A(2));
	w->procID = proc;
	w->goAway = goAway;
	RET(w->tok);
}

static void sh_CreateNewWindow(PPC *c)
{
	// CreateNewWindow(class, attributes, const Rect *bounds, WindowRef *)
	Win *w = win_create((int)A(0), A(1), RECT(A(2)), NULL, 0, 0, 0xffffffffu);
	ST32(A(3), w->tok);
	RET(0);
}

static void sh_CreateCustomWindow(PPC *c)
{
	// CreateCustomWindow(const WindowDefSpec *, class, attributes, const Rect *, WindowRef *)
	Win *w = win_create((int)A(1), A(2), RECT(A(3)), NULL, 0, 0, 0xffffffffu);
	// WindowDefSpec { defType; union { proc, classRef, procID } }: only kWindowDefProcPtr (0) runs here
	w->wdef = A(0) && LD32(A(0)) == 0 ? LD32(A(0) + 4) : 0;
	ST32(A(4), w->tok);
	if (ppc_verbose && A(0))
		ppc_log("CreateCustomWindow: defType %u proc %08x", LD32(A(0)), w->wdef);
	if (w->wdef)
		wdef_call(w, 3, 0);   // kWindowMsgInitialize
	RET(0);
}

static void sh_DisposeWindow(PPC *c) { Win *w = WIN(A(0)); if (w) win_dispose(w); }
static void sh_ShowWindow(PPC *c) { Win *w = WIN(A(0)); if (w) win_show(w); }
static void sh_HideWindow(PPC *c) { Win *w = WIN(A(0)); if (w) win_hide(w); }
static void sh_SelectWindow(PPC *c) { Win *w = WIN(A(0)); if (w) select_window(w); }
static void sh_BringToFront(PPC *c) { Win *w = WIN(A(0)); if (w) select_window(w); }
// ReshapeCustomWindow: the definition's regions changed (the Starting Points tabs, say): the frame is
// asked for them again and redrawn
static void sh_ReshapeCustomWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (w)
		wdef_render(w);
	RET(0);
}
static void sh_HiliteWindow(PPC *c) { Win *w = WIN(A(0)); if (w && w->hilited != (int)(A(1) & 0xff)) { w->hilited = A(1) & 0xff; wdef_render(w); } }
static void sh_SendBehind(PPC *c)
{
	Win *w = WIN(A(0)), *b = WIN(A(1));
	if (!w)
		return;
	int wasfront = win_front(1) == w;
	list_remove(w);
	if (b) {
		w->next = b->next;
		b->next = w;
		[(NSWindow *)w->ns orderWindow:NSWindowBelow relativeTo:((NSWindow *)b->ns).windowNumber];
	} else {
		Win **p = &windows;
		while (*p)
			p = &(*p)->next;
		*p = w;
		w->next = NULL;
		[(NSWindow *)w->ns orderBack:nil];
	}
	if (wasfront && win_front(1) != w) {
		ev_activate(w, 0);
		Win *f = win_front(1);
		if (f) {
			[(NSWindow *)f->ns makeKeyWindow];
			ev_activate(f, 1);
		}
	}
}
static void sh_FrontWindow(PPC *c) { Win *w = win_front(1); RET(w ? w->tok : 0); }
static void sh_FrontNonFloatingWindow(PPC *c)
{
	for (Win *w = windows; w; w = w->next)
		if (w->visible && !is_floating(w)) {
			RET(w->tok);
			return;
		}
	RET(0);
}
static void sh_GetFrontWindowOfClass(PPC *c)
{
	for (Win *w = windows; w; w = w->next)
		if ((w->wclass == (int)A(0) || (int)A(0) == -1) && (w->visible || !(A(1) & 0xff))) {
			RET(w->tok);
			return;
		}
	RET(0);
}
static void sh_GetNextWindowOfClass(PPC *c)
{
	Win *w = WIN(A(0));
	for (w = w ? w->next : NULL; w; w = w->next)
		if ((w->wclass == (int)A(1) || (int)A(1) == -1) && (w->visible || !(A(2) & 0xff))) {
			RET(w->tok);
			return;
		}
	RET(0);
}
static void sh_GetWindowList(PPC *c) { RET(windows ? windows->tok : 0); }
static void sh_GetNextWindow(PPC *c) { Win *w = WIN(A(0)); RET(w && w->next ? w->next->tok : 0); }
static void sh_GetWRefCon(PPC *c) { Win *w = WIN(A(0)); RET(w ? w->refCon : 0); }
static void sh_SetWRefCon(PPC *c) { Win *w = WIN(A(0)); if (w) w->refCon = A(1); }
static void sh_GetWTitle(PPC *c) { Win *w = WIN(A(0)); if (w) memcpy(G(A(1)), w->title, w->title[0] + 1); }
static void sh_SetWTitle(PPC *c)
{
	Win *w = WIN(A(0));
	if (w && A(1)) {
		memcpy(w->title, G(A(1)), LD8(A(1)) + 1);
		ns_title(w);
	}
}
static void sh_GetWindowKind(PPC *c) { Win *w = WIN(A(0)); RET(w ? w->kind : 0); }
static void sh_SetWindowKind(PPC *c) { Win *w = WIN(A(0)); if (w) w->kind = (int16_t)A(1); }
static void sh_GetWindowClass(PPC *c) { Win *w = WIN(A(0)); if (w) ST32(A(1), w->wclass); RET(w ? 0 : -5600); }
static void sh_GetWindowPort(PPC *c) { Win *w = WIN(A(0)); RET(w ? w->port->tok : 0); }
static void sh_SetPortWindowPort(PPC *c) { Win *w = WIN(A(0)); if (w) qd_port = w->port; }
static void sh_GetWindowFromPort(PPC *c) { Port *p = PORT(A(0)); RET(p && p->win ? p->win->tok : 0); }
static void sh_IsWindowVisible(PPC *c) { Win *w = WIN(A(0)); RET(w && w->visible); }
static void sh_IsValidWindowPtr(PPC *c) { RET(WIN(A(0)) != NULL); }
// GetWindowFeatures(window, UInt32 *): the definition's own answer, or what a standard frame has:
// kWindowCanGrow 1, CanZoom 2, CanCollapse 4, CanGetWindowRegion 0x20, HasTitleBar 0x40
static void sh_GetWindowFeatures(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w) {
		RET(-5600);
		return;
	}
	uint32_t f = 0;
	if (w->wdef) {
		uint32_t b = gcalloc(4);
		wdef_call(w, 7, b);   // kWindowMsgGetFeatures
		f = LD32(b);
		gfree(b);
	} else {
		NSWindowStyleMask m = ((NSWindow *)w->ns).styleMask;
		if (m & NSWindowStyleMaskResizable)
			f |= 1;
		if (w->attrs & 6)
			f |= 2;
		if (m & NSWindowStyleMaskTitled)
			f |= 4 | 0x40;
		f |= 0x20;
	}
	if (A(1))
		ST32(A(1), f);
	RET(0);
}
static void sh_IsWindowCollapsable(PPC *c) { Win *w = WIN(A(0)); RET(w && (((NSWindow *)w->ns).styleMask & NSWindowStyleMaskTitled)); }
static void sh_IsWindowCollapsed(PPC *c) { Win *w = WIN(A(0)); RET(w && w->collapsed); }
static void sh_CollapseWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	if (A(1) & 0xff)
		[(NSWindow *)w->ns miniaturize:nil];
	else
		[(NSWindow *)w->ns deminiaturize:nil];
	RET(0);
}

static QRect structure_rect(Win *w)
{
	NSRect f = ((NSWindow *)w->ns).frame;
	return (QRect){(int16_t)qd_global_y(f.origin.y + f.size.height), (int16_t)qd_global_x(f.origin.x),
		(int16_t)qd_global_y(f.origin.y), (int16_t)qd_global_x(f.origin.x + f.size.width)};
}

static QRect region_rect(Win *w, int code)
{
	switch (code) {
	case 32: case 35: return structure_rect(w);           // structure, opaque
	case 33: case 40: return w->frame;                    // content, global port
	case 0: case 5: {                                     // title bar, drag
		QRect s = structure_rect(w);
		s.bottom = w->frame.top;
		return s;
	}
	case 34: return w->update->n ? rect_off(w->update->bbox, w->frame.left, w->frame.top) : (QRect){0, 0, 0, 0};
	default: return (QRect){0, 0, 0, 0};
	}
}

static void sh_GetWindowBounds(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w) {
		RET(-5600);
		return;
	}
	int code = (int)A(1);
	QRect r = region_rect(w, code);
	if (w->wdef && code != 33 && code != 34 && code != 40 && !wdef_busy) {
		Rgn *g = rgn_new();
		if (wdef_region(w, code, g))
			r = g->bbox;
		rgn_free(g);
	}
	if (getenv("PPC_DBG_WB"))
		ppc_log("GetWindowBounds %08x code %d -> %d,%d,%d,%d", w->tok, code, r.top, r.left, r.bottom, r.right);
	PUTRECT(A(2), r);
	RET(0);
}
static void sh_GetWindowPortBounds(PPC *c)
{
	Win *w = WIN(A(0));
	if (w)
		PUTRECT(A(1), w->port->portRect);
	RET(A(1));
}
static void sh_GetWindowRegion(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(2));
	if (!w || !g) {
		RET(-50);
		return;
	}
	int code = (int)A(1);
	if (!(w->wdef && code != 33 && code != 34 && code != 40 && !wdef_busy && wdef_region(w, code, g)))
		rgn_set_rect(g, region_rect(w, code));
	rgn_sync(A(2));
	RET(0);
}

static Win *port_win(void) { return qd_port ? qd_port->win : NULL; }

static void sh_InvalWindowRect(PPC *c)
{
	Win *w = WIN(A(0));
	if (w) {
		win_invalidate(w, RECT(A(1)));
		RET(0);
	} else
		RET(-5600);
}
static void sh_InvalWindowRgn(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(1));
	if (w && g)
		win_update_rgn(w, g, RGN_UNION);
	RET(0);
}
static void sh_ValidWindowRect(PPC *c)
{
	Win *w = WIN(A(0));
	if (w) {
		Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
		rgn_set_rect(&t, RECT(A(1)));
		win_update_rgn(w, &t, RGN_DIFF);
		free(t.r);
	}
	RET(0);
}
static void sh_ValidWindowRgn(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(1));
	if (w && g)
		win_update_rgn(w, g, RGN_DIFF);
	RET(0);
}

static void sh_BeginUpdate(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	Port *p = w->port;
	if (!w->saved_vis)
		w->saved_vis = rgn_new();
	rgn_copy(w->saved_vis, p->vis);
	w->saved_org = (QPoint){p->portRect.top, p->portRect.left};
	if (ppc_verbose >= 2)
		ppc_log("BeginUpdate %08x: vis %d,%d,%d,%d update %d,%d,%d,%d port %d,%d,%d,%d", w->tok, p->vis->bbox.top, p->vis->bbox.left,
			p->vis->bbox.bottom, p->vis->bbox.right, w->update->bbox.top, w->update->bbox.left, w->update->bbox.bottom,
			w->update->bbox.right, p->portRect.top, p->portRect.left, p->portRect.bottom, p->portRect.right);
	// the update region, from content coordinates to the port's
	rgn_offset(w->update, p->portRect.left, p->portRect.top);
	rgn_op(p->vis, p->vis, w->update, RGN_SECT);
	rgn_set_empty(w->update);
	w->in_update = 1;
}
static void sh_EndUpdate(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w || !w->in_update)
		return;
	// the visible region is in local coordinates: an origin moved during the update moves it too
	Port *p = w->port;
	rgn_offset(w->saved_vis, p->portRect.left - w->saved_org.h, p->portRect.top - w->saved_org.v);
	rgn_copy(p->vis, w->saved_vis);
	w->in_update = 0;
}
static void sh_DrawGrowIcon(PPC *c) { (void)c; }
static void sh_SetWindowContentColor(PPC *c)
{
	Win *w = WIN(A(0));
	if (w) {
		w->content_color = (RGB16){(uint16_t)LD16(A(1)), (uint16_t)LD16(A(1) + 2), (uint16_t)LD16(A(1) + 4)};
		w->has_content_color = 1;
	}
	RET(0);
}
static void sh_SetWindowStandardState(PPC *c) { Win *w = WIN(A(0)); if (w) w->stdState = RECT(A(1)); RET(0); }
static void sh_SetWindowUserState(PPC *c) { Win *w = WIN(A(0)); if (w) w->userState = RECT(A(1)); RET(0); }

static void sh_MoveWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	move_window(w, (int16_t)A(1), (int16_t)A(2));
	if (A(3) & 0xff)
		select_window(w);
}
static void sh_SizeWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (w)
		size_window(w, (int16_t)A(1), (int16_t)A(2));
}
static void sh_DragWindow(PPC *c) { (void)c; }   // Cocoa moves windows by their title bars
static void sh_GrowWindow(PPC *c)
{
	// the size the user gave the window (inGrow comes after the live resize)
	if (ev_last.part == 5)
		RET(ev_last.data);
	else
		RET(0);
}
static void sh_TrackGoAway(PPC *c) { RET(1); }
static void sh_TrackBox(PPC *c) { RET(1); }
static void sh_ZoomWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	QRect r = (int16_t)A(1) == 8 ? w->stdState : w->userState;
	if ((int16_t)A(1) == 8)
		w->userState = w->frame;
	move_window(w, r.left, r.top);
	size_window(w, r.right - r.left, r.bottom - r.top);
	win_invalidate(w, w->port->portRect);
}
static void sh_RepositionWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w) {
		RET(-50);
		return;
	}
	int method = (int)A(2);
	QRect s = qd_screen_rect();
	Win *parent = WIN(A(1));
	if (parent && (method == 2 || method == 4 || method == 6)) {
		s = parent->frame;
	} else
		s.top = (int16_t)qd_menubar_height;
	int wd = w->frame.right - w->frame.left, ht = w->frame.bottom - w->frame.top;
	int h = s.left + (s.right - s.left - wd) / 2;
	int v = (method == 3 || method == 4) ? s.top + (s.bottom - s.top - ht) / 3 : s.top + (s.bottom - s.top - ht) / 2;
	if (v < qd_menubar_height + 22)
		v = qd_menubar_height + 22;
	move_window(w, h, v);
	RET(0);
}
static void sh_HideFloatingWindows(PPC *c) { RET(0); }
static void sh_ShowFloatingWindows(PPC *c) { RET(0); }
static void sh_IsWindowPathSelectClick(PPC *c) { RET(0); }
static void sh_WindowPathSelect(PPC *c) { RET(-128); }
static void sh_TrackWindowProxyDrag(PPC *c) { RET(-5604); }
static void sh_GetWindowEventTarget(PPC *c)
{
	Win *w = WIN(A(0));
	if (w && !w->evtarget)
		w->evtarget = tok_new(w, 16, 'evtg');
	RET(w ? w->evtarget : 0);
}

// FindWindow(Point, WindowRef *) -> part
static void sh_FindWindow_(PPC *c);
static void sh_FindWindow(PPC *c)
{
	QPoint p = PT(A(0));
	sh_FindWindow_(c);
	if (ppc_verbose >= 2)
		ppc_log("FindWindow %d,%d -> part %d window %08x", p.h, p.v, c->r[3], A(1) ? LD32(A(1)) : 0);
}
static void sh_FindWindow_(PPC *c)
{
	QPoint p = PT(A(0));
	uint32_t out = A(1);
	if (ev_last.part && ev_last.where.h == p.h && ev_last.where.v == p.v) {
		if (out)
			ST32(out, ev_last.win ? ev_last.win->tok : 0);
		RET(ev_last.part);
		return;
	}
	if (out)
		ST32(out, 0);
	if (p.v < qd_menubar_height && p.v >= 0) {
		RET(1);   // inMenuBar
		return;
	}
	Win *w = win_at(p.h, p.v);
	if (!w) {
		RET(0);
		return;
	}
	if (out)
		ST32(out, w->tok);
	if (w->skirt && p.v >= w->frame.bottom && p.h >= w->frame.left && p.h < w->frame.right) {
		int part = wdef_part(w, p);
		if (part >= 0) {
			if (!part && out)
				ST32(out, 0);
			RET((uint32_t)part);
			return;
		}
	}
	if (p.v >= w->frame.top && p.v < w->frame.bottom && p.h >= w->frame.left && p.h < w->frame.right)
		RET(3);   // inContent
	else
		RET(4);   // inDrag
}

static const ShimDef winshims[] = {
	S(NewCWindow), S(GetNewCWindow), S(CreateNewWindow), S(CreateCustomWindow), S(DisposeWindow), S(ShowWindow),
	S(HideWindow), S(SelectWindow), S(BringToFront), S(HiliteWindow), S(ReshapeCustomWindow), S(SendBehind), S(FrontWindow), S(FrontNonFloatingWindow),
	S(GetFrontWindowOfClass), S(GetNextWindowOfClass), S(GetWindowList), S(GetNextWindow), S(GetWRefCon),
	S(SetWRefCon), S(GetWTitle), S(SetWTitle), S(GetWindowKind), S(SetWindowKind), S(GetWindowClass),
	S(GetWindowPort), S(SetPortWindowPort), S(GetWindowFromPort), S(IsWindowVisible), S(IsValidWindowPtr),
	S(IsWindowCollapsed), S(CollapseWindow), S(GetWindowBounds), S(GetWindowPortBounds), S(GetWindowRegion),
	S(InvalWindowRect), S(InvalWindowRgn), S(ValidWindowRect), S(ValidWindowRgn), S(BeginUpdate), S(EndUpdate),
	S(DrawGrowIcon), S(SetWindowContentColor), S(SetWindowStandardState), S(SetWindowUserState), S(MoveWindow),
	S(SizeWindow), S(DragWindow), S(GrowWindow), S(TrackGoAway), S(TrackBox), S(ZoomWindow), S(RepositionWindow),
	S(HideFloatingWindows), S(ShowFloatingWindows), S(IsWindowPathSelectClick), S(WindowPathSelect),
	S(TrackWindowProxyDrag), S(GetWindowEventTarget), S(FindWindow), S(GetWindowFeatures), S(IsWindowCollapsable),
	{"NewWindowDefUPP", sh_DrawGrowIcon},
};
REGISTER(winshims)
