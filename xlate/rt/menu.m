// Menu Manager (see menu.h).
//
// A choice in the Cocoa menu bar reaches the guest as a mouse-down whose
// FindWindow part is inMenuBar; MenuSelect then returns the menu and item that
// were chosen. Command keys are Cocoa key equivalents and arrive the same way;
// keys the menus do not take reach the guest as key-downs for MenuKey.
#import <AppKit/AppKit.h>
#include "menu.h"
#include "qd.h"
#include "hmap.h"

const uint8_t *res_bytes(uint32_t type, int16_t id, uint32_t *len);
NSString *qd_font_name(int font);

typedef struct {
	uint8_t text[256];
	uint8_t icon, cmd, mark, style;
	uint8_t mods;          // kMenuShiftModifier 1, Option 2, Control 4, NoCommand 8
	int16_t sub;           // hierarchical menu ID set by SetMenuItemHierarchicalID (any 16-bit ID)
	int enabled;
	uint32_t command;
} Item;

typedef struct Menu {
	uint32_t h;
	int16_t id;
	uint8_t title[256];
	Item *items;
	int n, cap;
	int enabled;
	int inserted;          // 1 menu bar, -1 hierarchical
	int16_t res_id;        // loaded from this MENU resource
	int wid, hgt;          // SetMenuWidth / SetMenuHeight (0: not set)
	uint32_t def;          // a custom definition's procedure (transition vector), 0 for an ordinary menu
} Menu;

static HMap menus;           // MenuHandle -> Menu
static Menu *bar[64];        // the menu bar, in order
static int nbar;
static Menu *hier[64];       // hierarchical menus
static int nhier;
static int dirty = 1;
static int16_t help_id = -16490;
static Menu *help_menu;

void menu_dump(void);
static Menu *M(uint32_t h) { return h ? hm_get(&menus, h) : NULL; }

// the guest's MenuInfo: menuID, width, height, proc, enableFlags, title
static void msync_(Menu *m)
{
	if (!is_handle(m->h))
		return;
	if (HSize(m->h) < 14 + 256u)
		HSetSize(m->h, 14 + 256);
	uint32_t p = HP(m->h);
	ST16(p, m->id);
	ST16(p + 2, (uint16_t)(m->wid ? m->wid : 200));
	ST16(p + 4, (uint16_t)(m->hgt ? m->hgt : m->n * 18));
	ST32(p + 6, 0);
	uint32_t f = m->enabled ? 1 : 0;
	for (int i = 0; i < m->n && i < 31; i++)
		if (m->items[i].enabled)
			f |= 1u << (i + 1);
	if (m->n > 31)
		f |= 0x80000000u;
	ST32(p + 10, f);
	memcpy(G(p + 14), m->title, m->title[0] + 1);
	dirty = 1;
}

static Menu *menu_new(int16_t id, const uint8_t *title)
{
	Menu *m = calloc(1, sizeof *m);
	m->id = id;
	memcpy(m->title, title, title[0] + 1);
	m->enabled = 1;
	m->h = NewHandleClearG(14 + 256);
	hm_put(&menus, m->h, m);
	msync_(m);
	return m;
}

static Item *insert_item(Menu *m, int at)
{
	if (m->n == m->cap) {
		m->cap = m->cap ? m->cap * 2 : 16;
		m->items = realloc(m->items, m->cap * sizeof(Item));
	}
	if (at < 0 || at > m->n)
		at = m->n;
	memmove(m->items + at + 1, m->items + at, (m->n - at) * sizeof(Item));
	m->n++;
	Item *it = &m->items[at];
	memset(it, 0, sizeof *it);
	it->enabled = 1;
	return it;
}

// AppendMenu's metacharacters: ; separates items, ^icon !mark <style /key (disabled
static void append_items(Menu *m, const uint8_t *s, int n, int after)
{
	int i = 0;
	int at = after;
	while (i <= n) {
		int j = i;
		while (j < n && s[j] != ';' && s[j] != 13)
			j++;
		Item tmp = {{0}, 0, 0, 0, 0, 1, 0};
		int k = i;
		int tl = 0;
		while (k < j) {
			uint8_t ch = s[k];
			if (ch == '^' && k + 1 < j) {
				tmp.icon = (uint8_t)(s[k + 1] - 48);
				k += 2;
			} else if (ch == '!' && k + 1 < j) {
				tmp.mark = s[k + 1];
				k += 2;
			} else if (ch == '<' && k + 1 < j) {
				uint8_t st = s[k + 1];
				tmp.style |= st == 'B' ? 1 : st == 'I' ? 2 : st == 'U' ? 4 : st == 'O' ? 8 : st == 'S' ? 16 : 0;
				k += 2;
			} else if (ch == '/' && k + 1 < j) {
				tmp.cmd = s[k + 1];
				k += 2;
			} else if (ch == '(' && tl == 0) {
				tmp.enabled = 0;
				k++;
			} else {
				if (tl < 255)
					tmp.text[1 + tl++] = ch;
				k++;
			}
		}
		tmp.text[0] = (uint8_t)tl;
		if (tl || j < n) {
			Item *it = insert_item(m, at);
			*it = tmp;
			at++;
		}
		i = j + 1;
		if (j >= n)
			break;
	}
	msync_(m);
}

uint32_t menu_load(int16_t id)
{
	uint32_t len;
	const uint8_t *d = res_bytes('MENU', id, &len);
	if (!d || len < 15)
		return 0;
	int16_t mid = (int16_t)(d[0] << 8 | d[1]);
	Menu *m = menu_new(mid, d + 14);
	m->res_id = id;
	if (getenv("PPC_DBG_MENU") && (d[6] | d[7] | d[8] | d[9]))
		ppc_log("menu res %d has a menu definition (MDEF) %02x%02x%02x%02x", id, d[6], d[7], d[8], d[9]);
	uint32_t enable = (uint32_t)d[10] << 24 | d[11] << 16 | d[12] << 8 | d[13];
	m->enabled = enable & 1;
	uint32_t o = 14 + d[14] + 1;
	int idx = 0;
	while (o < len && d[o]) {
		Item *it = insert_item(m, -1);
		memcpy(it->text, d + o, d[o] + 1);
		o += d[o] + 1;
		if (o + 4 > len)
			break;
		it->icon = d[o];
		it->cmd = d[o + 1];
		it->mark = d[o + 2];
		it->style = d[o + 3];
		it->enabled = idx < 31 ? (enable >> (idx + 1)) & 1 : 1;
		o += 4;
		idx++;
	}
	// commands from an xmnu resource
	const uint8_t *x = res_bytes('xmnu', id, &len);
	if (x && len >= 4) {
		int cnt = x[2] << 8 | x[3];
		uint32_t q = 4;
		for (int i = 0; i < cnt && q + 2 <= len; i++) {
			int type = x[q] << 8 | x[q + 1];
			if (type == 1 && q + 6 <= len && i < m->n)
				m->items[i].command = (uint32_t)x[q + 2] << 24 | x[q + 3] << 16 | x[q + 4] << 8 | x[q + 5];
			if (type == 1)
				q += 2 + 4 + 1 + 1 + 4 + 2 + 2 + 4 + 2 + 2;   // the extended entry
			else
				q += 2;
		}
	}
	msync_(m);
	return m->h;
}

uint32_t menu_get_handle(int16_t id)
{
	for (int i = 0; i < nbar; i++)
		if (bar[i]->id == id)
			return bar[i]->h;
	for (int i = 0; i < nhier; i++)
		if (hier[i]->id == id)
			return hier[i]->h;
	return 0;
}

static Menu *by_id(int16_t id) { return M(menu_get_handle(id)); }

// While the guest is in ModalDialog its menu bar is not its own: only the Edit commands work, and
// they act on the dialog's text. Anything else a user could choose would start work behind the dialog.
static int modal_depth;
static int in_bar;   // building the menu bar (a pop-up menu in a dialog keeps what the guest enabled)

static int is_edit_cmd(const Item *it)
{
	int c = toupper(it->cmd);
	return c == 'X' || c == 'C' || c == 'V' || c == 'A';
}

static int is_edit_menu(const Menu *m)
{
	int x = 0, v = 0;
	for (int i = 0; i < m->n; i++) {
		int c = toupper(m->items[i].cmd);
		x |= c == 'X';
		v |= c == 'V';
	}
	return x && v;
}

// the guest can switch the whole Edit menu off (EnableItem 0) while its items are live; the macOS bar
// then offered nothing, so an Edit menu counts as on when any of its items is
static int menu_on(const Menu *m)
{
	if (m->enabled || !is_edit_menu(m))
		return m->enabled;
	for (int i = 0; i < m->n; i++)
		if (m->items[i].enabled)
			return 1;
	return 0;
}

int menu_is_modal(void) { return modal_depth > 0; }

void menu_modal(int delta)
{
	int was = modal_depth > 0;
	modal_depth += delta;
	if (modal_depth < 0)
		modal_depth = 0;
	if ((modal_depth > 0) != was)
		dirty = 1;
}

int menu_count(uint32_t h) { Menu *m = M(h); return m ? m->n : 0; }
int16_t menu_id(uint32_t h) { Menu *m = M(h); return m ? m->id : 0; }

void menu_item_text(uint32_t h, int item, uint8_t *p)
{
	Menu *m = M(h);
	p[0] = 0;
	if (m && item >= 1 && item <= m->n)
		memcpy(p, m->items[item - 1].text, m->items[item - 1].text[0] + 1);
}

// ---- Cocoa menus ---------------------------------------------------------------------------------

@interface XLMenuTarget : NSObject
- (void)choose:(NSMenuItem *)it;
- (void)quit:(id)sender;
- (void)about:(id)sender;
@end

static XLMenuTarget *target;
static int popup_choice;
static int in_popup;
static int16_t apple_id;   // the Apple menu, folded into the application menu

@implementation XLMenuTarget
- (void)choose:(NSMenuItem *)it
{
	uint32_t data = (uint32_t)it.tag;
	if (in_popup) {
		popup_choice = (int)(data & 0xffff);
		return;
	}
	if (modal_depth > 0) {
		Menu *m = by_id((int16_t)(data >> 16));
		int i = (int)(data & 0xffff) - 1;
		if (m && i >= 0 && i < m->n && is_edit_menu(m) && is_edit_cmd(&m->items[i])) {
			// Cut, Copy, Paste, Select All reach the dialog as the command keys
			Ev k = {0};
			k.what = 3;
			k.message = (uint32_t)tolower(m->items[i].cmd);
			k.where = ev_mouse_global();
			k.modifiers = 0x100 | 0x80;
			ev_post(k);
		} else
			NSBeep();
		return;
	}
	ev_post_mouse_part(NULL, 1, data);
}
- (void)quit:(id)sender
{
	(void)sender;
	Ev e = {0};
	e.what = 23;   // kHighLevelEvent
	e.message = 'aevt';
	e.where = (QPoint){(int16_t)('quit' >> 16), (int16_t)('quit' & 0xffff)};
	ev_post(e);
}
- (void)about:(id)sender
{
	(void)sender;
	ev_post_mouse_part(NULL, 1, (uint32_t)(uint16_t)apple_id << 16 | 1);
}
@end

static NSString *item_title(const uint8_t *p)
{
	NSString *s = mac_ns(p + 1, p[0]);
	return s ? s : @"";
}

static unichar mark_char(uint8_t mark)
{
	return mark == 0x12 ? 0x2713 : mark == 0xa5 ? 0x2022 : mark == 0x13 ? 0x25c6 : 0;
}

static NSMenu *build(Menu *m, int depth);

static NSMenuItem *build_item(Menu *m, int i, int depth)
{
	Item *it = &m->items[i];
	if (it->text[0] >= 1 && it->text[1] == '-' && (it->text[0] == 1 || it->text[2] == '-'))
		return [NSMenuItem separatorItem];
	NSString *title = item_title(it->text);
	NSMenuItem *ni = [[NSMenuItem alloc] initWithTitle:title action:@selector(choose:) keyEquivalent:@""];
	ni.target = target;
	ni.tag = (NSInteger)((uint32_t)(uint16_t)m->id << 16 | (uint32_t)(i + 1));
	ni.enabled = menu_on(m) && it->enabled;
	if (in_bar && modal_depth > 0)
		ni.enabled = ni.enabled && is_edit_menu(m) && is_edit_cmd(it);
	if (it->cmd == 0x1b) {
		Menu *sub = by_id(it->sub ? it->sub : it->mark);
		if (sub && depth < 4)
			ni.submenu = build(sub, depth + 1);
	} else {
		if (it->cmd > 0x20 && it->cmd < 0x7f) {
			ni.keyEquivalent = [[NSString stringWithFormat:@"%c", it->cmd] lowercaseString];
			NSEventModifierFlags f = (it->mods & 8) ? 0 : NSEventModifierFlagCommand;
			if (it->mods & 1)
				f |= NSEventModifierFlagShift;
			if (it->mods & 2)
				f |= NSEventModifierFlagOption;
			if (it->mods & 4)
				f |= NSEventModifierFlagControl;
			ni.keyEquivalentModifierMask = f;
		}
		if (it->mark) {
			unichar mc = mark_char(it->mark);
			if (mc == 0x2713)
				ni.state = NSControlStateValueOn;
			else if (mc == 0x2022 || mc == 0x25c6)
				ni.state = NSControlStateValueMixed;
			else
				ni.state = NSControlStateValueOn;
		}
	}
	if (it->style) {
		NSFontManager *fm = NSFontManager.sharedFontManager;
		NSFont *f = [NSFont menuFontOfSize:0];
		if (it->style & 1)
			f = [fm convertFont:f toHaveTrait:NSBoldFontMask];
		if (it->style & 2)
			f = [fm convertFont:f toHaveTrait:NSItalicFontMask];
		NSMutableDictionary *at = [NSMutableDictionary dictionaryWithObject:f forKey:NSFontAttributeName];
		if (it->style & 4)
			at[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
		ni.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:at];
	}
	return ni;
}


// ---- custom menus: the guest's own drawing and hit testing inside a Cocoa menu --------------------------
static CGImageRef custom_image(Menu *m, int hilite);
static void custom_size(Menu *m, int *w, int *h);
static uint32_t def_call(Menu *m, int msg, uint32_t rect, QPoint hit, uint32_t which);
static void ensure_cells(Menu *m);
static int custom_item_at(Menu *m, int x, int y);

@interface XLCustomView : NSView {
	Menu *menu;
	CGImageRef image;
	NSPoint hot;
}
- (instancetype)initWithMenu:(Menu *)m;
@end

@implementation XLCustomView
- (instancetype)initWithMenu:(Menu *)m
{
	int w, h;
	custom_size(m, &w, &h);
	self = [super initWithFrame:NSMakeRect(0, 0, w, h)];
	menu = m;
	hot = NSMakePoint(-1, -1);
	image = custom_image(m, 0);
	[self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
		options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
	return self;
}
- (void)dealloc
{
	if (image)
		CGImageRelease(image);
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }
- (void)drawRect:(NSRect)r
{
	(void)r;
	CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
	if (image) {
		CGContextSaveGState(cg);
		CGContextTranslateCTM(cg, 0, self.bounds.size.height);
		CGContextScaleCTM(cg, 1, -1);
		CGContextDrawImage(cg, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)), image);
		CGContextRestoreGState(cg);
	}
	if (hot.x >= 0 && menu->n == 256) {   // a palette: the cell under the pointer is outlined
		int c = (int)((hot.x - 1) / 13), rw = (int)((hot.y - 1) / 13);
		if (c >= 0 && c < 16 && rw >= 0 && rw < 16) {
			NSRect cell = NSMakeRect(1 + c * 13, 1 + rw * 13, 13, 13);
			[[NSColor blackColor] set];
			NSFrameRectWithWidth(cell, 2);
			[[NSColor whiteColor] set];
			NSFrameRectWithWidth(NSInsetRect(cell, 2, 2), 1);
		}
	}
}
- (void)mouseEntered:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseMoved:(NSEvent *)e
{
	hot = [self convertPoint:e.locationInWindow fromView:nil];
	[self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)e
{
	(void)e;
	hot = NSMakePoint(-1, -1);
	[self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e
{
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	int item = custom_item_at(menu, (int)p.x, (int)p.y);
	if (item > 0) {
		NSMenuItem *fake = [[NSMenuItem alloc] init];
		fake.tag = (NSInteger)((uint32_t)(uint16_t)menu->id << 16 | (uint32_t)item);
		[target choose:fake];
	}
	for (NSMenu *m = self.enclosingMenuItem.menu; m; m = m.supermenu)
		[m cancelTracking];
}
@end

static NSMenu *build_custom(Menu *m)
{
	ensure_cells(m);
	NSMenu *nm = [[NSMenu alloc] initWithTitle:item_title(m->title)];
	nm.autoenablesItems = NO;
	NSMenuItem *it = [[NSMenuItem alloc] init];
	it.view = [[XLCustomView alloc] initWithMenu:m];
	[nm addItem:it];
	return nm;
}

static NSMenu *build(Menu *m, int depth)
{
	if (m->def)
		return build_custom(m);
	NSMenu *nm = [[NSMenu alloc] initWithTitle:item_title(m->title)];
	nm.autoenablesItems = NO;
	for (int i = 0; i < m->n; i++)
		[nm addItem:build_item(m, i, depth)];
	return nm;
}

static int guest_has_quit(void)
{
	for (int b = 0; b < nbar; b++)
		for (int i = 0; i < bar[b]->n; i++)
			if (bar[b]->items[i].cmd == 'Q' || bar[b]->items[i].cmd == 'q')
				return 1;
	return 0;
}

// The guest re-enables and re-disables its menu items on every idle pass, so "dirty" is nearly always set.
// Replacing the Cocoa menu bar that often, or while the user has a menu open, leaves the open menu dead
// (everything greyed), so the bar is rebuilt only when what it shows has changed and no menu is open.
static int bar_tracking;

static uint64_t bar_signature(void)
{
	uint64_t h = 1469598103934665603ull;
#define MIX(p, n) for (size_t q_ = 0; q_ < (n); q_++) h = (h ^ ((const uint8_t *)(p))[q_]) * 1099511628211ull
	int md = modal_depth > 0;
	MIX(&md, sizeof md);
	for (int pass = 0; pass < 2; pass++) {
		int cnt = pass ? nhier : nbar;
		for (int b = 0; b < cnt; b++) {
			Menu *m = pass ? hier[b] : bar[b];
			MIX(&m->id, sizeof m->id);
			int on_ = menu_on(m);
			MIX(&on_, sizeof on_);
			MIX(m->title, m->title[0] + 1);
			for (int i = 0; i < m->n; i++) {
				Item *it = &m->items[i];
				MIX(it->text, it->text[0] + 1);
				MIX(&it->icon, 5);   // icon, cmd, mark, style, mods
				MIX(&it->sub, sizeof it->sub);
				MIX(&it->enabled, sizeof it->enabled);
			}
		}
	}
#undef MIX
	return h;
}

static void watch_tracking(void)
{
	static int done;
	if (done)
		return;
	done = 1;
	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	[nc addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
		(void)n;
		bar_tracking = 1;
	}];
	[nc addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
		(void)n;
		bar_tracking = 0;
	}];
}

void menu_flush(void)
{
	static uint64_t shown;
	static int have_shown;
	watch_tracking();
	if (!dirty || in_popup || bar_tracking)
		return;
	uint64_t sig = bar_signature();
	if (have_shown && sig == shown) {
		dirty = 0;
		return;
	}
	shown = sig;
	have_shown = 1;
	dirty = 0;
	if (getenv("PPC_DBG_MENU"))
		ppc_log("menu: bar rebuilt");
	if (!target)
		target = [XLMenuTarget new];
	in_bar = 1;
	NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
	main.autoenablesItems = NO;
	NSString *app = NSProcessInfo.processInfo.processName;
	NSString *bn = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
	if (bn)
		app = bn;
	NSMenu *am = [[NSMenu alloc] initWithTitle:app];
	am.autoenablesItems = NO;
	Menu *apple = NULL;
	for (int b = 0; b < nbar; b++)
		if (bar[b]->title[0] == 1 && bar[b]->title[1] == 0x14) {
			apple = bar[b];
			break;
		}
	if (apple) {
		apple_id = apple->id;
		for (int i = 0; i < apple->n; i++)
			[am addItem:build_item(apple, i, 0)];
		[am addItem:[NSMenuItem separatorItem]];
	} else {
		NSMenuItem *ab = [am addItemWithTitle:[@"About " stringByAppendingString:app] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
		ab.target = NSApp;
		[am addItem:[NSMenuItem separatorItem]];
	}
	NSMenuItem *hide = [am addItemWithTitle:[@"Hide " stringByAppendingString:app] action:@selector(hide:) keyEquivalent:@"h"];
	hide.target = NSApp;
	NSMenuItem *ho = [am addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	ho.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
	ho.target = NSApp;
	NSMenuItem *sa = [am addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	sa.target = NSApp;
	[am addItem:[NSMenuItem separatorItem]];
	NSMenuItem *q = [am addItemWithTitle:[@"Quit " stringByAppendingString:app] action:@selector(quit:) keyEquivalent:guest_has_quit() ? @"" : @"q"];
	q.target = target;
	NSMenuItem *ai = [[NSMenuItem alloc] initWithTitle:app action:NULL keyEquivalent:@""];
	ai.submenu = am;
	[main addItem:ai];
	for (int b = 0; b < nbar; b++) {
		Menu *m = bar[b];
		if (m == apple)
			continue;
		NSMenu *nm = build(m, 0);
		NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:nm.title action:NULL keyEquivalent:@""];
		top.submenu = nm;
		top.enabled = menu_on(m) && (modal_depth == 0 || is_edit_menu(m));
		[main addItem:top];
	}
	in_bar = 0;
	NSApp.mainMenu = main;
}

void menu_bar_install(void)
{
	dirty = 1;
	menu_flush();
}

int menu_popup(uint32_t h, QPoint g, int cur, int width, CTFontRef font)
{
	Menu *m = M(h);
	if (!m)
		return 0;
	if (!target)
		target = [XLMenuTarget new];
	NSMenu *nm = build(m, 0);
	if (font)
		nm.font = (__bridge NSFont *)font;
	nm.minimumWidth = width;
	NSMenuItem *pos = cur >= 1 && cur <= (int)nm.numberOfItems ? [nm itemAtIndex:cur - 1] : nil;
	if (pos && pos.state == NSControlStateValueOff)
		pos.state = NSControlStateValueOn;
	popup_choice = 0;
	in_popup = 1;
	NSPoint at = NSMakePoint(qd_cocoa_x(g.h), qd_cocoa_y(g.v));
	if (!pos)
		at.y = qd_cocoa_y(g.v);
	[nm popUpMenuPositioningItem:pos atLocation:at inView:nil];
	in_popup = 0;
	return popup_choice;
}

// ---- shims ----------------------------------------------------------------------------------------

static void sh_GetMenu(PPC *c)
{
	int16_t id = (int16_t)A(0);
	// a menu loaded before (resources are loaded once)
	for (uint32_t i = 0; i < menus.cap; i++)
		if (menus.k[i] && menus.k[i] != 0xffffffffu) {
			Menu *m = menus.v[i];
			if (m->res_id == id && m->id == id)
				return RET(m->h);
		}
	RET(menu_load(id));
}
static void sh_NewMenu(PPC *c) { RET(menu_new((int16_t)A(0), G(A(1)))->h); }
static void sh_GetMCEntry(PPC *c) { (void)c; RET(0); }   // no menu color table entries
static void sh_GetMenuHandle(PPC *c) { RET(menu_get_handle((int16_t)A(0))); }
static void sh_GetMenuID(PPC *c) { Menu *m = M(A(0)); RET(m ? (uint32_t)(int32_t)m->id : 0); }
static void sh_InsertMenu(PPC *c)
{
	Menu *m = M(A(0));
	int16_t before = (int16_t)A(1);
	if (!m || m->inserted)
		return;
	if (before == -1) {
		if (nhier < 64)
			hier[nhier++] = m;
		m->inserted = -1;
	} else {
		int at = nbar;
		for (int i = 0; i < nbar; i++)
			if (before && bar[i]->id == before)
				at = i;
		if (help_menu && at == nbar && m != help_menu)
			for (int i = 0; i < nbar; i++)
				if (bar[i] == help_menu)
					at = i;
		if (nbar < 64) {
			memmove(bar + at + 1, bar + at, (nbar - at) * sizeof *bar);
			bar[at] = m;
			nbar++;
		}
		m->inserted = 1;
	}
	dirty = 1;
}
static void remove_menu(Menu *m)
{
	for (int i = 0; i < nbar; i++)
		if (bar[i] == m) {
			memmove(bar + i, bar + i + 1, (nbar - i - 1) * sizeof *bar);
			nbar--;
			break;
		}
	for (int i = 0; i < nhier; i++)
		if (hier[i] == m) {
			memmove(hier + i, hier + i + 1, (nhier - i - 1) * sizeof *hier);
			nhier--;
			break;
		}
	m->inserted = 0;
	dirty = 1;
}
static void sh_DeleteMenu(PPC *c) { Menu *m = by_id((int16_t)A(0)); if (m) remove_menu(m); }
static void sh_DisposeMenu(PPC *c)
{
	Menu *m = M(A(0));
	if (!m)
		return;
	remove_menu(m);
	hm_del(&menus, m->h);
	DisposeHandleG(m->h);
	free(m->items);
	free(m);
}
static void sh_DrawMenuBar(PPC *c) { (void)c; dirty = 1; }
static void sh_InvalMenuBar(PPC *c) { (void)c; dirty = 1; }
static void sh_HiliteMenu(PPC *c) { (void)c; }
static void sh_FlashMenuBar(PPC *c) { (void)c; }
static void sh_GetMBarHeight(PPC *c) { RET(qd_menubar_height); }
static void sh_ClearMenuBar(PPC *c) { (void)c; while (nbar) remove_menu(bar[0]); }

// GetMenuBar: a handle holding the bar's menus, then the hierarchical ones
// (count, handles; count, handles), which SetMenuBar puts back
static void sh_GetMenuBar(PPC *c)
{
	uint32_t h = NewHandleClearG(8 + 4 * (nbar + nhier));
	uint32_t p = HP(h);
	ST32(p, nbar);
	for (int i = 0; i < nbar; i++)
		ST32(p + 4 + 4 * i, bar[i]->h);
	p += 4 + 4 * nbar;
	ST32(p, nhier);
	for (int i = 0; i < nhier; i++)
		ST32(p + 4 + 4 * i, hier[i]->h);
	RET(h);
}

static void sh_SetMenuBar(PPC *c)
{
	uint32_t p = HP(A(0));
	if (!p)
		return;
	while (nbar)
		remove_menu(bar[0]);
	while (nhier)
		remove_menu(hier[0]);
	uint32_t n = LD32(p);
	for (uint32_t i = 0; i < n && i < 64; i++) {
		Menu *m = M(LD32(p + 4 + 4 * i));
		if (m) {
			bar[nbar++] = m;
			m->inserted = 1;
		}
	}
	p += 4 + 4 * n;
	n = LD32(p);
	for (uint32_t i = 0; i < n && i < 64; i++) {
		Menu *m = M(LD32(p + 4 + 4 * i));
		if (m) {
			hier[nhier++] = m;
			m->inserted = -1;
		}
	}
	dirty = 1;
}

static void sh_AppendMenu(PPC *c)
{
	Menu *m = M(A(0));
	uint32_t s = A(1);
	if (m)
		append_items(m, G(s + 1), LD8(s), m->n);
}
static void sh_InsertMenuItem(PPC *c)
{
	// InsertMenuItem(menu, itemString, afterItem)
	Menu *m = M(A(0));
	uint32_t s = A(1);
	int after = (int16_t)A(2);
	if (m)
		append_items(m, G(s + 1), LD8(s), after < 0 ? 0 : after > m->n ? m->n : after);
}
static void sh_DeleteMenuItem(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	if (!m || i < 1 || i > m->n)
		return;
	memmove(m->items + i - 1, m->items + i, (m->n - i) * sizeof(Item));
	m->n--;
	msync_(m);
}
static void sh_CountMenuItems(PPC *c) { Menu *m = M(A(0)); RET(m ? m->n : 0); }

static int fontname_cmp(const void *a, const void *b)
{
	return [(__bridge NSString *)*(void *const *)a localizedCaseInsensitiveCompare:(__bridge NSString *)*(void *const *)b];
}

static void res_menu(Menu *m, uint32_t type, int after)
{
	if (type != 'FONT' && type != 'FOND')
		return;
	NSArray *fams = NSFontManager.sharedFontManager.availableFontFamilies;
	int n = (int)fams.count;
	CFTypeRef *names = calloc(n, sizeof *names);
	int k = 0;
	for (NSString *f in fams) {
		if ([f hasPrefix:@"."])
			continue;
		names[k++] = (__bridge CFTypeRef)f;
	}
	qsort(names, k, sizeof *names, fontname_cmp);
	for (int i = 0; i < k; i++) {
		NSString *f = (__bridge NSString *)names[i];
		char buf[256];
		if (![f getCString:buf maxLength:sizeof buf encoding:NSMacOSRomanStringEncoding])
			continue;
		Item *it = insert_item(m, after++);
		size_t l = strlen(buf);
		if (l > 255)
			l = 255;
		it->text[0] = (uint8_t)l;
		memcpy(it->text + 1, buf, l);
	}
	free(names);
	msync_(m);
}
static void sh_AppendResMenu(PPC *c) { Menu *m = M(A(0)); if (m) res_menu(m, A(1), m->n); }
static void sh_InsertResMenu(PPC *c)
{
	Menu *m = M(A(0));
	if (m)
		res_menu(m, A(1), (int16_t)A(2) > m->n ? m->n : (int16_t)A(2) < 0 ? 0 : (int16_t)A(2));
}

static Item *ITEM(PPC *c, int mi, int ii)
{
	Menu *m = M(A(mi));
	int i = (int16_t)A(ii);
	return m && i >= 1 && i <= m->n ? &m->items[i - 1] : NULL;
}
static void sh_EnableMenuItem(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	if (!m)
		return;
	if (i == 0)
		m->enabled = 1;
	else if (i <= m->n)
		m->items[i - 1].enabled = 1;
	msync_(m);
}
static void sh_DisableMenuItem(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	if (!m)
		return;
	if (i == 0)
		m->enabled = 0;
	else if (i <= m->n)
		m->items[i - 1].enabled = 0;
	msync_(m);
}
static void sh_IsMenuItemEnabled(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	RET(m && m->enabled && (i == 0 || (i <= m->n && m->items[i - 1].enabled)));
}
static void sh_CheckMenuItem(PPC *c) { Item *it = ITEM(c, 0, 1); if (it && it->cmd != 0x1b) { it->mark = (A(2) & 0xff) ? 0x12 : 0; dirty = 1; } }
static void sh_SetItemMark(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->mark = (uint8_t)A(2); dirty = 1; } }
static void sh_GetItemMark(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST16(A(2), it ? it->mark : 0); }
static void sh_SetItemCmd(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->cmd = (uint8_t)A(2); dirty = 1; } }
static void sh_GetItemCmd(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST16(A(2), it ? it->cmd : 0); }
static void sh_SetItemStyle(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->style = (uint8_t)A(2); dirty = 1; } }
static void sh_GetItemStyle(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST8(A(2), it ? it->style : 0); }
static void sh_SetItemIcon(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->icon = (uint8_t)A(2); dirty = 1; } }
static void sh_GetItemIcon(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST16(A(2), it ? it->icon : 0); }
// CreateCustomMenu(const MenuDefSpec *, MenuID, MenuAttributes, MenuRef *): an ordinary menu; the
// custom definition only draws, and Cocoa draws the menus here
static void sh_CreateCustomMenu(PPC *c)
{
	static const uint8_t empty[1] = {0};
	Menu *m = menu_new((int16_t)A(1), empty);
	m->def = LD32(A(0) + 4);
	if (getenv("PPC_DBG_MENU"))
		ppc_log("CreateCustomMenu id %d spec %08x %08x attrs %08x from %s", (int16_t)A(1), LD32(A(0)), LD32(A(0) + 4), A(2), ppc_func_name(c->lr - 4));
	if (A(3))
		ST32(A(3), m->h);
	RET(0);
}
static void sh_SetMenuItemModifiers(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->mods = (uint8_t)A(2); dirty = 1; } RET(it ? 0 : -5620); }
static void sh_GetMenuItemModifiers(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST8(A(2), it ? it->mods : 0); RET(it ? 0 : -5620); }
// SetMenuItemHierarchicalID(menu, item, MenuID): the classic encoding, cmd 0x1b and the ID in the mark
static void sh_SetMenuItemHierarchicalID(PPC *c)
{
	Item *it = ITEM(c, 0, 1);
	if (it) {
		it->cmd = A(2) ? 0x1b : 0;
		it->mark = A(2) ? (uint8_t)A(2) : 0;
		it->sub = (int16_t)A(2);
		dirty = 1;
	}
	RET(it ? 0 : -5620);
}
static void sh_GetMenuItemHierarchicalID(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST16(A(2), it && it->cmd == 0x1b ? (it->sub ? (uint16_t)it->sub : it->mark) : 0); RET(it ? 0 : -5620); }
static void sh_SetMenuItemKeyGlyph(PPC *c) { RET(0); }   // glyph-only equivalents (F keys, arrows): not shown
static void sh_SetMenuItemText(PPC *c)
{
	Item *it = ITEM(c, 0, 1);
	if (it) {
		memcpy(it->text, G(A(2)), LD8(A(2)) + 1);
		dirty = 1;
	}
}
static void sh_GetMenuItemText(PPC *c)
{
	Item *it = ITEM(c, 0, 1);
	if (it)
		memcpy(G(A(2)), it->text, it->text[0] + 1);
	else
		ST8(A(2), 0);
}
static void sh_SetMenuItemCommandID(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) it->command = A(2); RET(0); }
static void sh_GetMenuItemCommandID(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST32(A(2), it ? it->command : 0); RET(it ? 0 : -5620); }

static Item *find_command(uint32_t menu, uint32_t cmd, Menu **owner)
{
	Menu *only = M(menu);
	for (uint32_t k = 0; k < menus.cap; k++) {
		if (!menus.k[k] || menus.k[k] == 0xffffffffu)
			continue;
		Menu *m = menus.v[k];
		if (only && m != only)
			continue;
		for (int i = 0; i < m->n; i++)
			if (m->items[i].command == cmd) {
				if (owner)
					*owner = m;
				return &m->items[i];
			}
	}
	return NULL;
}
// GetIndMenuItemWithCommandID(menu, commandID, index, MenuRef *outMenu, MenuItemIndex *outIndex)
static void sh_GetIndMenuItemWithCommandID(PPC *c)
{
	Menu *only = M(A(0));
	uint32_t want = A(2) ? A(2) : 1, seen = 0;
	for (uint32_t k = 0; k < menus.cap; k++) {
		if (!menus.k[k] || menus.k[k] == 0xffffffffu)
			continue;
		Menu *m = menus.v[k];
		if (only && m != only)
			continue;
		for (int i = 0; i < m->n; i++)
			if (m->items[i].command == A(1) && ++seen == want) {
				if (A(3))
					ST32(A(3), m->h);
				if (A(4))
					ST16(A(4), (uint16_t)(i + 1));
				RET(0);
				return;
			}
	}
	RET(-5620);   // errMenuItemNotFound... (menuItemNotFoundErr)
}
static void sh_EnableMenuCommand(PPC *c) { Menu *m; Item *it = find_command(A(0), A(1), &m); if (it) { it->enabled = 1; msync_(m); } }
static void sh_DisableMenuCommand(PPC *c) { Menu *m; Item *it = find_command(A(0), A(1), &m); if (it) { it->enabled = 0; msync_(m); } }
static void sh_IsMenuCommandEnabled(PPC *c)
{
	Item *it = find_command(A(0), A(1), NULL);
	RET(it ? it->enabled : A(1) == 'quit');
}

static void sh_MenuSelect(PPC *c)
{
	// MenuSelect(Point startPt): the choice made in the Cocoa menu bar
	(void)c;
	menu_flush();
	if (ev_last.part == 1 && !ev_last.win && ev_last.data) {
		uint32_t d = ev_last.data;
		ev_last.data = 0;
		// the app has adjusted its menus by now (as for a real click): a choice they do not offer cannot be made
		if (!menu_item_enabled(menu_get_handle((int16_t)(d >> 16)), (int)(d & 0xffff))) {
			ppc_log("menu: %d %d is not available", (int16_t)(d >> 16), (int)(d & 0xffff));
			if (getenv("PPC_DBG_MENU"))
				menu_dump();
			RET(0);
			return;
		}
		RET(d);
		return;
	}
	RET(0);
}

int menu_key(uint8_t ch, uint16_t mods)
{
	(void)mods;
	uint8_t u = (uint8_t)toupper(ch);
	for (int b = 0; b < nbar; b++) {
		Menu *m = bar[b];
		if (!m->enabled)
			continue;
		for (int i = 0; i < m->n; i++) {
			Item *it = &m->items[i];
			if (it->cmd && it->cmd != 0x1b && toupper(it->cmd) == u)
				return it->enabled ? (int)((uint32_t)(uint16_t)m->id << 16 | (uint32_t)(i + 1)) : 0;
		}
	}
	return 0;
}
static void sh_MenuKey(PPC *c) { RET(menu_key((uint8_t)A(0), 0x100)); }
static void sh_MenuEvent(PPC *c)
{
	uint32_t e = A(0);
	uint16_t mods = LD16(e + 14);
	if (!(mods & 0x100)) {
		RET(0);
		return;
	}
	RET(menu_key((uint8_t)LD32(e + 2), mods));
}
static void sh_PopUpMenuSelect(PPC *c)
{
	// PopUpMenuSelect(menu, top, left, popUpItem)
	Menu *m = M(A(0));
	if (!m) {
		RET(0);
		return;
	}
	QPoint g = {(int16_t)A(1), (int16_t)A(2)};
	int item = menu_popup(m->h, g, (int16_t)A(3), 0, NULL);
	void ev_drop_mouseups(void);
	ev_drop_mouseups();
	RET(item ? (uint32_t)(uint16_t)m->id << 16 | (uint32_t)item : 0);
}
static void sh_HMGetHelpMenu(PPC *c)
{
	// HMGetHelpMenu(MenuRef *, MenuItemIndex *firstCustomItem)
	if (!help_menu) {
		static const uint8_t t[] = {4, 'H', 'e', 'l', 'p'};
		help_menu = menu_new(help_id, t);
		bar[nbar++] = help_menu;
		help_menu->inserted = 1;
		dirty = 1;
	}
	if (A(0))
		ST32(A(0), help_menu->h);
	if (A(1))
		ST16(A(1), (uint16_t)(help_menu->n + 1));
	RET(0);
}
static void sh_SetMenuTitle(PPC *c) { Menu *m = M(A(0)); if (m) { memcpy(m->title, G(A(1)), LD8(A(1)) + 1); msync_(m); } }
static void sh_CalcMenuSize(PPC *c) { (void)c; }

static void sh_SetMenuWidth(PPC *c) { Menu *m = M(A(0)); if (m) { m->wid = (int16_t)A(1); msync_(m); } }
static void sh_SetMenuHeight(PPC *c) { Menu *m = M(A(0)); if (m) { m->hgt = (int16_t)A(1); msync_(m); } }
static void sh_GetMenuWidth(PPC *c) { Menu *m = M(A(0)); RET(m && m->wid ? m->wid : 200); }
static void sh_GetMenuHeight(PPC *c) { Menu *m = M(A(0)); RET(m && m->hgt ? m->hgt : m ? m->n * 18 : 0); }
static void sh_SetPt(PPC *c) { ST16(A(0), (uint16_t)A(2)); ST16(A(0) + 2, (uint16_t)A(1)); }
static void sh_GetMenuTitle(PPC *c) { Menu *m = M(A(0)); if (m && A(1)) memcpy(G(A(1)), m->title, m->title[0] + 1); RET(0); }

// the parts of a custom menu definition's drawing that come from the theme
static void theme_fill(QRect r, double gray)
{
	Port *p = qd_port;
	if (!p)
		return;
	CGContextRef cg = qd_cg_begin(p);
	CGContextSetGrayFillColor(cg, gray, 1);
	CGContextFillRect(cg, CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top));
	qd_cg_end(p);
	qd_dirty(p, r);
}
static void sh_DrawThemeMenuBackground(PPC *c) { theme_fill(RECT(A(0)), 0.97); RET(0); }
static void sh_DrawThemeMenuItem(PPC *c)
{
	// DrawThemeMenuItem(menuRect, itemRect, ...state in r7): a chosen item is highlighted
	if (A(4) >= 0 && (A(4) & 0xffff) >= 1 && (A(4) & 0xffff) <= 3 && ((A(4) & 0xffff) == 2 || (A(4) & 0xffff) == 3))
		theme_fill(RECT(A(1)), 0.75);
	else
		theme_fill(RECT(A(1)), 0.97);
	RET(0);
}
static void sh_DrawThemeMenuSeparator(PPC *c)
{
	QRect r = RECT(A(0));
	r.top = (int16_t)((r.top + r.bottom) / 2);
	r.bottom = (int16_t)(r.top + 1);
	theme_fill(r, 0.7);
	RET(0);
}

static const ShimDef menushims[] = {
	S(SetMenuWidth), S(SetMenuHeight), S(GetMenuWidth), S(GetMenuHeight), S(SetPt), S(GetMenuTitle),
	S(DrawThemeMenuBackground), S(DrawThemeMenuItem), S(DrawThemeMenuSeparator),
	S(GetMenu), S(NewMenu), S(GetMenuHandle), S(GetMCEntry), S(GetMenuID), S(InsertMenu), S(DeleteMenu), S(DisposeMenu),
	S(GetMenuBar), S(SetMenuBar), S(DrawMenuBar), S(InvalMenuBar), S(HiliteMenu), S(FlashMenuBar), S(GetMBarHeight), S(ClearMenuBar),
	S(AppendMenu), S(InsertMenuItem), S(DeleteMenuItem), S(CountMenuItems), S(AppendResMenu), S(InsertResMenu),
	S(EnableMenuItem), S(DisableMenuItem), S(IsMenuItemEnabled), S(CheckMenuItem), S(SetItemMark), S(GetItemMark),
	S(SetItemCmd), S(GetItemCmd), S(SetItemStyle), S(SetMenuItemText), S(GetMenuItemText), S(SetMenuItemCommandID),
	S(GetMenuItemCommandID), S(EnableMenuCommand), S(DisableMenuCommand), S(IsMenuCommandEnabled), S(MenuSelect),
	S(MenuKey), S(MenuEvent), S(PopUpMenuSelect), S(HMGetHelpMenu), S(SetMenuTitle), S(CalcMenuSize),
	{"MacAppendMenu", sh_AppendMenu}, {"MacInsertMenu", sh_InsertMenu}, {"MacDeleteMenu", sh_DeleteMenu},
	{"EnableMenuItemIcon", sh_HiliteMenu}, {"CountMItems", sh_CountMenuItems}, {"EnableItem", sh_EnableMenuItem},
	{"DisableItem", sh_DisableMenuItem}, {"GetMenuItemTextWithCFString", sh_HiliteMenu},
	S(GetItemStyle), S(SetItemIcon), S(GetItemIcon), S(CreateCustomMenu), S(GetIndMenuItemWithCommandID),
	S(SetMenuItemModifiers), S(GetMenuItemModifiers), S(SetMenuItemHierarchicalID), S(GetMenuItemHierarchicalID),
	S(SetMenuItemKeyGlyph),
};
REGISTER(menushims)

int menu_item_enabled(uint32_t menu, int item)
{
	Menu *m = M(menu);
	return m && item >= 1 && item <= m->n && m->items[item - 1].enabled;
}

// debugging: the menu bar's menus and items, to the log
void menu_dump(void)
{
	for (int i = 0; i < nbar + nhier; i++) {
		Menu *m = i < nbar ? bar[i] : hier[i - nbar];
		ppc_log("menu %d '%.*s'", m->id, m->title[0], m->title + 1);
		for (int k = 0; k < m->n; k++) {
			ppc_log("  item %d '%.*s' %s cmd '%c'%s", k + 1, m->items[k].text[0], m->items[k].text + 1,
				m->items[k].enabled ? "on" : "off", m->items[k].cmd >= 32 ? m->items[k].cmd : ' ', m->items[k].cmd == 0x1b ? " submenu" : "");
			if (m->items[k].cmd == 0x1b)
				ppc_log("    -> sub %d mark %d", m->items[k].sub, m->items[k].mark);
		}
		if (m->n == 0)
			ppc_log("  (no items; menu res %d)", m->res_id);
	}
}

uint32_t ppc_callback(uint32_t tvec, int n, const uint32_t *args);
uint32_t ppc_callback(uint32_t tvec, int n, const uint32_t *args);
// A custom menu definition draws itself (the palettes of the Text Color and Fill menus): its drawing,
// made with the guest's own code into a port of its own, shown as the contents of the Cocoa menu.
// Messages: draw 0, size 2, find item 10, highlight item 11.
static uint32_t def_call(Menu *m, int msg, uint32_t rect, QPoint hit, uint32_t which)
{
	uint32_t a[5] = {(uint32_t)msg, m->h, rect, (uint32_t)(uint16_t)hit.v << 16 | (uint16_t)hit.h, which};
	return ppc_callback(m->def, 5, a);
}

static void custom_size(Menu *m, int *w, int *h)
{
	if (!m->wid || !m->hgt) {
		uint32_t rect = gcalloc(16), which = gcalloc(4);
		def_call(m, 2, rect, (QPoint){0, 0}, which);
		gfree(rect);
		gfree(which);
	}
	*w = m->wid ? m->wid : 100;
	*h = m->hgt ? m->hgt : 100;
}

// the palettes have no items of their own: one per cell, so the choice (menu, cell) is one the guest can take
static void ensure_cells(Menu *m)
{
	if (m->n)
		return;
	for (int i = 0; i < 256; i++) {
		Item *it = insert_item(m, -1);
		it->text[0] = 1;
		it->text[1] = ' ';
	}
}

static CGImageRef custom_image(Menu *m, int hilite)
{
	int w, h;
	custom_size(m, &w, &h);
	Port *p = port_new(0, 0, (QRect){0, 0, (int16_t)h, (int16_t)w}, 1);
	Port *saved = qd_port;
	qd_port = p;
	uint32_t rect = gcalloc(16), which = gcalloc(4);
	PUTRECT(rect, ((QRect){0, 0, (int16_t)h, (int16_t)w}));
	def_call(m, 0, rect, (QPoint){0, 0}, which);
	if (hilite > 0) {
		ST16(which, (uint16_t)hilite);
		def_call(m, 11, rect, (QPoint){0, 0}, which);
	}
	gfree(rect);
	gfree(which);
	qd_port = saved;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef bc = CGBitmapContextCreate(G(p->pix), w, h, 8, p->rowBytes, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big);
	CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
	if (bc)
		CGContextRelease(bc);
	CGColorSpaceRelease(cs);
	port_free(p);
	return img;
}

static int custom_item_at(Menu *m, int x, int y)
{
	int w, h;
	custom_size(m, &w, &h);
	uint32_t rect = gcalloc(16), which = gcalloc(40);
	PUTRECT(rect, ((QRect){0, 0, (int16_t)h, (int16_t)w}));
	memset(G(which), 0, 40);
	def_call(m, 10, rect, (QPoint){(int16_t)x, (int16_t)y}, which);
	int item = (int16_t)LD16(which + 6);
	gfree(rect);
	gfree(which);
	return item;
}

// debugging: ask a custom menu definition what it makes of itself
void menu_probe(int16_t id, int msg)
{
	Menu *m = by_id(id);
	if (!m || !m->def) {
		ppc_log("probe: menu %d is not custom", id);
		return;
	}
	ensure_cells(m);
	if (msg == 0) {
		CGImageRef img = custom_image(m, 0);
		const char *path = getenv("PPC_MENU_PNG");
		if (img && path) {
			NSURL *u = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
			CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)u, CFSTR("public.png"), 1, NULL);
			CGImageDestinationAddImage(d, img, NULL);
			CGImageDestinationFinalize(d);
			CFRelease(d);
		}
		ppc_log("probe: def code %08x toc %08x", LD32(m->def), LD32(m->def + 4));
		ppc_log("probe: menu %d drawn %zu x %zu", id, img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0);
		if (img)
			CGImageRelease(img);
		return;
	}
	if (msg == 10 || msg == 1) {
		uint32_t rect = gcalloc(16), which = gcalloc(40);
		PUTRECT(rect, ((QRect){0, 0, (int16_t)m->hgt, (int16_t)m->wid}));
		for (int y = 6; y < m->hgt; y += getenv("PPC_PROBE_ONE") ? 1000 : 13) {
			char line[256] = "";
			for (int x = 6; x < m->wid; x += getenv("PPC_PROBE_ONE") ? 1000 : 13) {
				memset(G(which), 0, 40);
				def_call(m, msg, rect, (QPoint){(int16_t)x, (int16_t)y}, which);
				snprintf(line + strlen(line), 20, " %d", (int16_t)LD16(which + 6));
			}
			ppc_log("probe find y %d:%s", y, line);
		}
		return;
	}
	uint32_t rect = gcalloc(16), which = gcalloc(4);
	ST16(rect, 0), ST16(rect + 2, 0), ST16(rect + 4, 0), ST16(rect + 6, 0);
	uint32_t a[5] = {(uint32_t)msg, m->h, rect, 0, which};
	uint32_t r = ppc_callback(m->def, 5, a);
	ppc_log("probe: menu %d msg %d -> %08x rect %d,%d,%d,%d item %d n %d", id, msg, r, (int16_t)LD16(rect), (int16_t)LD16(rect + 2),
		(int16_t)LD16(rect + 4), (int16_t)LD16(rect + 6), (int16_t)LD16(which), m->n);
	gfree(rect);
	gfree(which);
}

// debugging: what a click at x, y in a custom menu chooses, as the palette view does
void menu_custom_click(int16_t id, int x, int y)
{
	Menu *m = by_id(id);
	if (!m || !m->def)
		return;
	ensure_cells(m);
	int item = custom_item_at(m, x, y);
	ppc_log("custom menu %d click %d,%d -> item %d", id, x, y, item);
	if (item > 0)
		ev_post_mouse_part(NULL, 1, (uint32_t)(uint16_t)id << 16 | (uint32_t)item);
}
