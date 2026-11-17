// Appearance Manager: theme brushes, text colors, fonts and primitives.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "qd.h"

void theme_font_metrics(int id, int *size, int *bold);

static RGB16 brush_color(int brush)
{
	switch (brush) {
	case 15: case 16:                          // document window background
	case 13: case 14:                          // list view background
	case 3: case 4:                            // alert background
	case 23: case 24:                          // utility window background
		return brush == 23 || brush == 24 ? (RGB16){0xeeee, 0xeeee, 0xeeee} : (RGB16){0xffff, 0xffff, 0xffff};
	case -1: case -2:                          // white, black
		return brush == -1 ? (RGB16){0xffff, 0xffff, 0xffff} : (RGB16){0, 0, 0};
	case 3 + 100:
		break;
	case 5: case 6:                            // modeless dialog background
	case 1: case 2:                            // dialog background
	default:
		break;
	}
	return (RGB16){0xeded, 0xeded, 0xeded};
}

static RGB16 text_color(int k, int depth)
{
	(void)depth;
	switch (k) {
	case 2: case 4: case 6: case 8: case 12: case 14: case 16: case 18: case 20: case 25: case 27:   // inactive
		return (RGB16){0x7fff, 0x7fff, 0x7fff};
	case 35: case 36:                          // white (selected) text
		return (RGB16){0xffff, 0xffff, 0xffff};
	default:
		return (RGB16){0, 0, 0};
	}
}

static void sh_SetThemeBackground(PPC *c)
{
	// SetThemeBackground(brush, depth, isColorDevice)
	if (qd_port)
		qd_port->bg = brush_color((int16_t)A(0));
	RET(0);
}
static void sh_ApplyThemeBackground(PPC *c)
{
	// ApplyThemeBackground(kind, bounds, state, depth, isColor)
	if (qd_port)
		qd_port->bg = (RGB16){0xeded, 0xeded, 0xeded};
	RET(0);
}
static void sh_SetThemePen(PPC *c) { if (qd_port) qd_port->fg = brush_color((int16_t)A(0)); RET(0); }
static void sh_SetThemeTextColor(PPC *c) { if (qd_port) qd_port->fg = text_color((int16_t)A(0), A(1)); RET(0); }
static void sh_GetThemeTextColor(PPC *c)
{
	// GetThemeTextColor(color, depth, isColor, RGBColor *)
	RGB16 col = text_color((int16_t)A(0), A(1));
	ST16(A(3), col.r);
	ST16(A(3) + 2, col.g);
	ST16(A(3) + 4, col.b);
	RET(0);
}
static void sh_GetThemeBrushAsColor(PPC *c)
{
	RGB16 col = brush_color((int16_t)A(0));
	ST16(A(3), col.r);
	ST16(A(3) + 2, col.g);
	ST16(A(3) + 4, col.b);
	RET(0);
}
static void sh_GetThemeAccentColors(PPC *c) { if (A(0)) ST32(A(0), 0); RET(-1); }
static void sh_IsThemeInColor(PPC *c) { (void)c; RET(1); }

static void sh_GetThemeFont(PPC *c)
{
	// GetThemeFont(fontID, script, Str255 name, SInt16 *size, Style *style)
	int id = (int16_t)A(0);
	int size, style;
	theme_font_metrics(id, &size, &style);
	if (A(2)) {
		static const char nm[] = "Lucida Grande";
		ST8(A(2), (uint8_t)(sizeof nm - 1));
		memcpy(G(A(2) + 1), nm, sizeof nm - 1);
	}
	if (A(3))
		ST16(A(3), size);
	if (A(4))
		ST8(A(4), style);
	RET(0);
}

static CGRect cgr(QRect r) { return CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top); }

static void sh_DrawThemeFocusRect(PPC *c)
{
	// DrawThemeFocusRect(rect, hasFocus)
	Port *p = qd_port;
	if (!p || !(A(1) & 0xff))
		return RET(0);
	QRect r = RECT(A(0));
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawFocusRect(&cr, true, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 4), (int16_t)(r.left - 4), (int16_t)(r.bottom + 4), (int16_t)(r.right + 4)});
	RET(0);
}
static void sh_DrawThemeFocusRegion(PPC *c)
{
	Rgn *g = RGN(A(0));
	Port *p = qd_port;
	if (!p || !g || !(A(1) & 0xff))
		return RET(0);
	QRect r = g->bbox;
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawFocusRect(&cr, true, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 4), (int16_t)(r.left - 4), (int16_t)(r.bottom + 4), (int16_t)(r.right + 4)});
	RET(0);
}
static void sh_DrawThemeEditTextFrame(PPC *c)
{
	// DrawThemeEditTextFrame(rect, state): the frame is outside the rectangle
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeFrameDrawInfo fi = {0, kHIThemeFrameTextFieldSquare, (A(1) == 0) ? kThemeStateInactive : kThemeStateActive, false};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawFrame(&cr, &fi, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 2), (int16_t)(r.left - 2), (int16_t)(r.bottom + 2), (int16_t)(r.right + 2)});
	RET(0);
}
static void sh_DrawThemeTabPane(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeTabPaneDrawInfo ti = {1, A(1) ? kThemeStateActive : kThemeStateInactive, kThemeTabNorth, kHIThemeTabSizeNormal, kHIThemeTabKindNormal, kHIThemeTabAdornmentNone};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawTabPane(&cr, &ti, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_DrawThemeSeparator(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeSeparatorDrawInfo si = {0, A(1) ? kThemeStateActive : kThemeStateInactive};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawSeparator(&cr, &si, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_DrawThemePrimaryGroup(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeGroupBoxDrawInfo gi = {0, A(1) ? kThemeStateActive : kThemeStateInactive, kHIThemeGroupBoxKindPrimary};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawGroupBox(&cr, &gi, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_DrawThemeWindowHeader(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeHeaderDrawInfo hi = {0, A(1) ? kThemeStateActive : kThemeStateInactive, kHIThemeHeaderKindWindow};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawHeader(&cr, &hi, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}

// drawing state: a saved copy of the port's pen, colors and text
typedef struct {
	RGB16 fg, bg;
	uint8_t pnPat[8], bkPat[8];
	QPoint pnSize;
	int pnMode, txFont, txFace, txSize, txMode;
} DState;

static void sh_GetThemeDrawingState(PPC *c)
{
	Port *p = qd_port;
	DState *s = calloc(1, sizeof *s);
	if (p) {
		s->fg = p->fg;
		s->bg = p->bg;
		memcpy(s->pnPat, p->pnPat, 8);
		memcpy(s->bkPat, p->bkPat, 8);
		s->pnSize = p->pnSize;
		s->pnMode = p->pnMode;
		s->txFont = p->txFont;
		s->txFace = p->txFace;
		s->txSize = p->txSize;
		s->txMode = p->txMode;
	}
	ST32(A(0), tok_new(s, 16, 'XLds'));
	RET(0);
}
static void sh_SetThemeDrawingState(PPC *c)
{
	DState *s = tok_get(A(0), 'XLds');
	Port *p = qd_port;
	if (s && p) {
		p->fg = s->fg;
		p->bg = s->bg;
		memcpy(p->pnPat, s->pnPat, 8);
		memcpy(p->bkPat, s->bkPat, 8);
		p->pnSize = s->pnSize;
		p->pnMode = s->pnMode;
		p->txFont = s->txFont;
		p->txFace = s->txFace;
		p->txSize = s->txSize;
		p->txMode = s->txMode;
	}
	if (s && (A(1) & 0xff)) {
		tok_free(A(0));
		free(s);
	}
	RET(0);
}
static void sh_DisposeThemeDrawingState(PPC *c)
{
	DState *s = tok_get(A(0), 'XLds');
	if (s) {
		tok_free(A(0));
		free(s);
	}
	RET(0);
}
static void sh_NormalizeThemeDrawingState(PPC *c)
{
	(void)c;
	Port *p = qd_port;
	if (p) {
		p->fg = (RGB16){0, 0, 0};
		p->bg = (RGB16){0xffff, 0xffff, 0xffff};
		memset(p->pnPat, 0xff, 8);
		memset(p->bkPat, 0, 8);
		p->pnSize = (QPoint){1, 1};
		p->pnMode = 8;
		p->txFont = 0;
		p->txFace = 0;
		p->txSize = 0;
		p->txMode = 1;
	}
	RET(0);
}

static void sh_RegisterAppearanceClient(PPC *c) { (void)c; RET(0); }
static void sh_UnregisterAppearanceClient(PPC *c) { (void)c; RET(0); }

// ---- theme text: CFStrings drawn and measured with the theme font in the current port

CFTypeRef cf_obj(uint32_t t);

static NSString *cfstr(uint32_t t)
{
	CFTypeRef s = cf_obj(t);
	return s && CFGetTypeID(s) == CFStringGetTypeID() ? (__bridge NSString *)s : @"";
}

// Appearance theme fonts: kThemeSystemFont 0, Small 1, SmallEmphasized 2, Views 3, EmphasizedSystem 4,
// Application 5, Label 6, MenuTitle..WindowTitle 100-104, PushButton 105, UtilityWindowTitle 106,
// AlertHeader 107, Toolbar 108, MiniSystem 109
void theme_font_metrics(int id, int *size, int *bold)
{
	int sz = 13, b = 0;
	switch (id) {
	case 1: case 6: case 106: case 108: sz = 11; break;
	case 2: sz = 11; b = 1; break;
	case 3: sz = 12; break;
	case 4: case 107: b = 1; break;
	case 5: sz = 12; break;
	case 109: sz = 9; break;
	default: break;
	}
	*size = sz, *bold = b;
}

typedef struct { int font, size, face; } SavedFont;
static SavedFont theme_font_set(Port *p, int id)
{
	SavedFont s = {p->txFont, p->txSize, p->txFace};
	int size, face;
	theme_font_metrics(id, &size, &face);
	p->txFont = qd_font_num(@"Lucida Grande");
	p->txSize = size;
	p->txFace = face;
	return s;
}
static void theme_font_restore(Port *p, SavedFont s) { p->txFont = s.font, p->txSize = s.size, p->txFace = s.face; }

static NSData *roman(NSString *s)
{
	NSData *d = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	return d ? d : [NSData data];
}

// one line of theme text measured the way DrawThemeTextBox and TruncateThemeText draw and measure it;
// -1 without a port
int theme_text_metrics(int id, NSString *s, int *height, int *descent)
{
	Port *p = qd_port;
	if (!p)
		return -1;
	SavedFont sf = theme_font_set(p, id);
	int asc, desc, wid, lead;
	qd_font_info(p, &asc, &desc, &wid, &lead);
	NSData *d = roman(s);
	int w = (int)ceil(qd_text_width(p, d.bytes, (int)d.length));
	theme_font_restore(p, sf);
	*height = asc + desc;
	*descent = desc;
	return w;
}

// TruncateThemeText(CFMutableStringRef, fontID, state, SInt16 pixelWidth, TruncCode, Boolean *truncated):
// truncEnd 0, truncMiddle 0x4000
static void sh_TruncateThemeText(PPC *c)
{
	CFTypeRef o = cf_obj(A(0));
	Port *p = qd_port;
	if (A(5))
		ST8(A(5), 0);
	if (!o || CFGetTypeID(o) != CFStringGetTypeID() || !p) {
		RET(0);
		return;
	}
	SavedFont sf = theme_font_set(p, (int16_t)A(1));
	NSString *s = (__bridge NSString *)o;
	int width = (int16_t)A(3), middle = (int16_t)A(4) == 0x4000;
	NSData *d = roman(s);
	if (qd_text_width(p, d.bytes, (int)d.length) > width) {
		NSString *ell = @"\u2026", *t = s;
		for (NSUInteger keep = s.length; keep > 0; keep--) {
			if (middle) {
				NSUInteger a = (keep + 1) / 2, b = keep / 2;
				t = [NSString stringWithFormat:@"%@%@%@", [s substringToIndex:a], ell, [s substringFromIndex:s.length - b]];
			} else
				t = [[s substringToIndex:keep] stringByAppendingString:ell];
			NSData *td = roman(t);
			if (qd_text_width(p, td.bytes, (int)td.length) <= width)
				break;
			if (keep == 1)
				t = ell;
		}
		CFStringReplaceAll((CFMutableStringRef)o, (__bridge CFStringRef)t);
		if (A(5))
			ST8(A(5), 1);
	}
	theme_font_restore(p, sf);
	RET(0);
}

// DrawThemeTextBox(CFStringRef, fontID, state, Boolean wrapToWidth, const Rect *, SInt16 just, context):
// teFlushDefault/Left 0, teCenter 1, teFlushRight -1
static void sh_DrawThemeTextBox(PPC *c)
{
	Port *p = qd_port;
	if (!p || !A(4)) {
		RET(0);
		return;
	}
	SavedFont sf = theme_font_set(p, (int16_t)A(1));
	QRect r = RECT(A(4));
	int just = (int16_t)A(5), wrap = A(3) & 0xff, width = r.right - r.left;
	int asc, desc, wid, lead;
	qd_font_info(p, &asc, &desc, &wid, &lead);
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	for (NSString *para in [cfstr(A(0)) componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
		if (!wrap) {
			[lines addObject:para];
			continue;
		}
		NSMutableString *cur = [NSMutableString string];
		for (NSString *w in [para componentsSeparatedByString:@" "]) {
			NSString *try = cur.length ? [NSString stringWithFormat:@"%@ %@", cur, w] : w;
			NSData *d = roman(try);
			if (cur.length && qd_text_width(p, d.bytes, (int)d.length) > width) {
				[lines addObject:[cur copy]];
				[cur setString:w];
			} else
				[cur setString:try];
		}
		[lines addObject:cur];
	}
	QPoint saved = p->pnLoc;
	int y = r.top + asc;
	for (NSString *ln in lines) {
		if (y - asc >= r.bottom)
			break;
		NSData *d = roman(ln);
		int w = (int)lround(qd_text_width(p, d.bytes, (int)d.length));
		int x = just == 1 ? r.left + (width - w) / 2 : just == -1 ? r.right - w : r.left;
		p->pnLoc.h = (int16_t)x;
		p->pnLoc.v = (int16_t)y;
		qd_text_draw(p, d.bytes, (int)d.length);
		y += asc + desc + lead;
	}
	p->pnLoc = saved;
	theme_font_restore(p, sf);
	RET(0);
}

// DrawThemeButton(const Rect *, ThemeButtonKind, const ThemeButtonDrawInfo *newInfo, prevInfo, eraseProc,
// labelProc, userData): ThemeButtonDrawInfo { state, value, adornment } as UInt32, UInt16, UInt16
static void sh_DrawThemeButton(PPC *c)
{
	Port *p = qd_port;
	if (!p || !A(0)) {
		RET(0);
		return;
	}
	QRect r = RECT(A(0));
	uint32_t ni = A(2);
	HIThemeButtonDrawInfo bi = {0, ni ? LD32(ni) : kThemeStateActive, (ThemeButtonKind)(uint16_t)A(1),
		ni ? LD16(ni + 4) : kThemeButtonOff, ni ? LD16(ni + 6) : kThemeAdornmentNone, {0}};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawButton(&cr, &bi, cg, kHIThemeOrientationNormal, NULL);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 2), (int16_t)(r.left - 2), (int16_t)(r.bottom + 2), (int16_t)(r.right + 2)});
	if (A(5)) {
		// the label procedure draws the title: (bounds, kind, info, userData, depth, isColor)
		uint32_t a[6] = {A(0), A(1), A(2), A(6), 32, 1};
		ppc_callback(A(5), 6, a);
	}
	RET(0);
}

static const ShimDef themeshims[] = {
	S(DrawThemeButton),
	S(TruncateThemeText), S(DrawThemeTextBox),
	S(RegisterAppearanceClient), S(UnregisterAppearanceClient),
	S(SetThemeBackground), S(ApplyThemeBackground), S(SetThemePen), S(SetThemeTextColor), S(GetThemeTextColor),
	S(GetThemeBrushAsColor), S(GetThemeAccentColors), S(IsThemeInColor), S(GetThemeFont), S(DrawThemeFocusRect),
	S(DrawThemeFocusRegion), S(DrawThemeEditTextFrame), S(DrawThemeTabPane), S(DrawThemeSeparator),
	S(DrawThemePrimaryGroup), S(DrawThemeWindowHeader), S(GetThemeDrawingState), S(SetThemeDrawingState),
	S(DisposeThemeDrawingState), S(NormalizeThemeDrawingState),
};
REGISTER(themeshims)
