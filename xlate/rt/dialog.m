// Dialog Manager: dialogs built from 'DLOG' and 'DITL' resources (or a DITL
// handle) on the runtime's windows, controls and TextEdit engine. A DialogRef
// is its WindowRef. Buttons, check boxes, radio buttons and resource controls
// are controls; static text is drawn from a text handle, edit text is a
// TextEdit engine framed in the item's rectangle; icon and picture items are
// plotted; user items call the procedure SetDialogItem installed.
// ModalDialog and DialogSelect do what the originals did with the events.
#import <AppKit/AppKit.h>
#include "ctl.h"
#include "te.h"

const uint8_t *res_bytes(uint32_t type, int16_t id, uint32_t *len);
uint32_t res_get(uint32_t type, int16_t id, int one);
void dlg_param_text(int i, uint8_t *out);   // ParamText strings (dlg.m)

enum {
	userItem = 0, helpItem = 1, ctrlItem = 4, btnCtrl = 0, chkCtrl = 1, radCtrl = 2, resCtrl = 3,
	statText = 8, editText = 16, iconItem = 32, picItem = 64, itemDisable = 128,
	kDialogWindowKind = 2,
};

typedef struct {
	int type;              // with itemDisable
	QRect r;
	uint32_t h;            // ControlHandle, text Handle, icon/picture handle, user item procedure
	int hidden;
	TEng *te;              // edit text
	int16_t res_id;        // icon, picture, CNTL
} DItem;

typedef struct Dlg {
	uint32_t win;
	DItem *items;
	int n, cap;
	int def, cancel, focus;   // item numbers (1-based); 0 none
	int tracks_cursor;
	struct Dlg *next;
} Dlg;

static Dlg *dialogs;
static int16_t dialog_font = 0;

static Dlg *DLG(uint32_t w)
{
	for (Dlg *d = dialogs; d; d = d->next)
		if (d->win == w && w)
			return d;
	return NULL;
}

static Win *dwin(Dlg *d) { return WIN(d->win); }

static DItem *item(Dlg *d, int i) { return d && i >= 1 && i <= d->n ? &d->items[i - 1] : NULL; }

static int16_t be16(const uint8_t *p) { return (int16_t)(p[0] << 8 | p[1]); }

static uint32_t text_handle(const uint8_t *s, int n)
{
	uint32_t h = NewHandleG(n);
	if (n)
		memcpy(G(HP(h)), s, n);
	return h;
}

// ^0-^3 replaced by the ParamText strings
static int expand(const uint8_t *s, int n, uint8_t *out, int cap)
{
	int o = 0;
	for (int i = 0; i < n && o < cap; i++) {
		if (s[i] == '^' && i + 1 < n && s[i + 1] >= '0' && s[i + 1] <= '3') {
			uint8_t p[256];
			dlg_param_text(s[i + 1] - '0', p);
			for (int k = 0; k < p[0] && o < cap; k++)
				out[o++] = p[1 + k];
			i++;
			continue;
		}
		out[o++] = s[i];
	}
	return o;
}

static Port *dport(Dlg *d)
{
	Win *w = dwin(d);
	return w ? w->port : NULL;
}

// On Mac OS X a dialog's items are controls in its embedding hierarchy: static
// text erases with the window's background and edit text is white, whatever
// back color the application left in the port.
static RGB16 dialog_bg(Dlg *d)
{
	Win *w = dwin(d);
	return w && w->has_content_color ? w->content_color : (RGB16){0xffff, 0xffff, 0xffff};
}

static void set_text_style(Port *p)
{
	p->txFont = dialog_font;
	p->txSize = 12;
	p->txFace = 0;
}

static TEng *new_edit(Dlg *d, QRect r, const uint8_t *s, int n)
{
	Port *p = dport(d);
	set_text_style(p);
	TEng *e = te_create(p, r, r, 0);
	e->bg = (RGB16){0xffff, 0xffff, 0xffff};
	e->has_bg = 1;
	e->wrap = 1;
	te_set_text(e, s, n);
	te_set_select(e, 0, 0);
	return e;
}

static void add_items(Dlg *d, const uint8_t *ditl, uint32_t len, int dh, int dv)
{
	if (!ditl || len < 2)
		return;
	Win *w = dwin(d);
	int n = be16(ditl) + 1;
	uint32_t o = 2;
	for (int i = 0; i < n && o + 14 <= len; i++) {
		const uint8_t *p = ditl + o;
		DItem it = {0};
		it.r = (QRect){be16(p + 4) + dv, be16(p + 6) + dh, be16(p + 8) + dv, be16(p + 10) + dh};
		it.type = p[12];
		int l = p[13];
		const uint8_t *data = p + 14;
		int kind = it.type & 0x7f;
		if (kind >= ctrlItem && kind <= ctrlItem + resCtrl) {
			if (kind == ctrlItem + resCtrl) {
				it.res_id = l >= 2 ? be16(data) : 0;
				// the item's rectangle places the control
				QPoint at = {.v = it.r.top, .h = it.r.left};
				it.h = ctl_from_resource_at(it.res_id, w, &at);
			} else {
				uint8_t title[256];
				int tl = expand(data, l, title + 1, 255);
				title[0] = tl;
				Ctl *k = ctl_create(w, it.r, title, 1, 0, 0, 1, kind - ctrlItem, 0);
				it.h = k->h;
			}
		} else if (kind == statText) {
			it.h = text_handle(data, l);
		} else if (kind == editText) {
			uint8_t t[256];
			int tl = expand(data, l, t, 255);
			it.h = text_handle(t, tl);
			it.te = new_edit(d, it.r, t, tl);
		} else if (kind == iconItem || kind == picItem) {
			it.res_id = l >= 2 ? be16(data) : 0;
			if (kind == picItem)
				it.h = res_get('PICT', it.res_id, 0);
			else
				it.h = 0;   // plotted by id
		} else {
			it.h = 0;   // user item: no procedure yet
		}
		if (d->n == d->cap) {
			d->cap = d->cap ? d->cap * 2 : 16;
			d->items = realloc(d->items, d->cap * sizeof *d->items);
		}
		if (ppc_verbose >= 2)
			ppc_log("  item %d: type %d rect %d,%d,%d,%d len %d", d->n + 1, it.type, it.r.top, it.r.left, it.r.bottom, it.r.right, l);
		d->items[d->n++] = it;
		o += 14 + l + (l & 1);
	}
	if (!d->focus)
		for (int i = 1; i <= d->n; i++)
			if ((d->items[i - 1].type & 0x7f) == editText) {
				d->focus = i;
				te_set_select(d->items[i - 1].te, 0, d->items[i - 1].te->n);
				break;
			}
}

static void focus_item(Dlg *d, int i)
{
	DItem *old = item(d, d->focus), *it = item(d, i);
	if (old && old->te && old != it) {
		te_activate(old->te, 0);
		te_draw(old->te, NULL);
	}
	d->focus = it && it->te ? i : 0;
	if (it && it->te) {
		Win *w = dwin(d);
		te_activate(it->te, w && w->hilited);
		te_draw(it->te, NULL);
	}
}

static void draw_frame(Dlg *d, QRect r)
{
	uint32_t buf = gcalloc(8);
	ST16(buf, r.top - 3);
	ST16(buf + 2, r.left - 3);
	ST16(buf + 4, r.bottom + 3);
	ST16(buf + 6, r.right + 3);
	SHIM_CALL("FrameRect", buf);
	gfree(buf);
}

static void draw_item(Dlg *d, int i)
{
	DItem *it = item(d, i);
	if (!it || it->hidden)
		return;
	Port *p = dport(d);
	int kind = it->type & 0x7f;
	if (kind >= ctrlItem && kind <= ctrlItem + resCtrl) {
		Ctl *k = CTL(it->h);
		if (k)
			ctl_draw(k);
	} else if (kind == statText) {
		uint32_t n = HSize(it->h);
		uint8_t t[1024];
		int tl = expand(G(HP(it->h)), n > 1024 ? 1024 : n, t, sizeof t);
		set_text_style(p);
		TEng *e = te_create(p, it->r, it->r, 0);
		e->bg = dialog_bg(d);
		e->has_bg = 1;
		te_set_text(e, t, tl);
		te_draw(e, NULL);
		te_dispose(e);
	} else if (kind == editText) {
		draw_frame(d, it->r);
		te_draw(it->te, NULL);
	} else if (kind == iconItem) {
		uint32_t buf = gcalloc(8);
		ST16(buf, it->r.top);
		ST16(buf + 2, it->r.left);
		ST16(buf + 4, it->r.bottom);
		ST16(buf + 6, it->r.right);
		uint32_t ci = SHIM_CALL("GetCIcon", (uint32_t)(uint16_t)it->res_id);
		if (ci)
			SHIM_CALL("PlotCIcon", buf, ci);
		else
			SHIM_CALL("PlotIconID", buf, 0, 0, (uint32_t)(uint16_t)it->res_id);
		gfree(buf);
	} else if (kind == picItem) {
		if (it->h) {
			uint32_t buf = gcalloc(8);
			ST16(buf, it->r.top);
			ST16(buf + 2, it->r.left);
			ST16(buf + 4, it->r.bottom);
			ST16(buf + 6, it->r.right);
			SHIM_CALL("DrawPicture", it->h, buf);
			gfree(buf);
		}
	} else if (kind == userItem) {
		// a user item procedure: the address SetDialogItem gave (a UPP or a routine)
		if (it->h)
			ppc_cb2(it->h, d->win, i);
	}
}

static void draw_dialog(Dlg *d)
{
	Win *w = dwin(d);
	if (!w)
		return;
	uint32_t save = ppc_shim_call("GetQDGlobalsThePort", 0, NULL);
	uint32_t port = SHIM_CALL("GetWindowPort", d->win);
	SHIM_CALL("SetPort", port);
	for (int i = 1; i <= d->n; i++)
		draw_item(d, i);
	if (save)
		SHIM_CALL("SetPort", save);
	win_dirty(w, w->port->portRect);
}

// ---- creation --------------------------------------------------------------------------------

static uint32_t create(QRect r, const uint8_t *title, int visible, int procID, uint32_t behind, int goAway,
                       uint32_t refCon, const uint8_t *ditl, uint32_t ditl_len, int pos)
{
	if (pos) {
		// alertPositionMainScreen / center: centered horizontally, a third down
		QRect s = qd_screen_rect();
		int wd = r.right - r.left, ht = r.bottom - r.top;
		int left = (s.left + s.right - wd) / 2, top = s.top + 44 + (s.bottom - s.top - 44 - ht) / 3;
		if (pos == 0x300a || pos == 0x280a)   // centered
			top = s.top + 22 + (s.bottom - s.top - 22 - ht) / 2;
		r = (QRect){top, left, top + ht, left + wd};
	}
	uint32_t rb = gcalloc(8 + 256);
	ST16(rb, r.top);
	ST16(rb + 2, r.left);
	ST16(rb + 4, r.bottom);
	ST16(rb + 6, r.right);
	memcpy(G(rb + 8), title ? title : (const uint8_t *)"", title ? title[0] + 1 : 1);
	uint32_t w = SHIM_CALL("NewCWindow", 0, rb, rb + 8, 0, (uint32_t)procID, behind, (uint32_t)goAway, refCon);
	gfree(rb);
	if (!w)
		return 0;
	SHIM_CALL("SetWindowKind", w, kDialogWindowKind);
	Dlg *d = calloc(1, sizeof *d);
	d->win = w;
	d->next = dialogs;
	dialogs = d;
	add_items(d, ditl, ditl_len, 0, 0);
	// the first button is the default, as ModalDialog's Return key had it
	for (int i = 1; i <= d->n && !d->def; i++)
		if ((d->items[i - 1].type & 0x7f) == ctrlItem + btnCtrl)
			d->def = i;
	if (item(d, 2) && (item(d, 2)->type & 0x7f) == ctrlItem + btnCtrl)
		d->cancel = 2;
	if (ppc_verbose >= 2)
		ppc_log("dialog %08x: %d items", w, d->n);
	if (visible)
		SHIM_CALL("ShowWindow", w);
	return w;
}

// GetNewDialog(id, storage, behind)
static void sh_GetNewDialog(PPC *c)
{
	uint32_t len, ditl_len;
	const uint8_t *dl = res_bytes('DLOG', (int16_t)A(0), &len);
	if (!dl || len < 21) {
		ppc_log("GetNewDialog %d: no DLOG", (int16_t)A(0));
		RET(0);
		return;
	}
	QRect r = {be16(dl), be16(dl + 2), be16(dl + 4), be16(dl + 6)};
	int procID = be16(dl + 8), visible = dl[10], goAway = dl[12];
	uint32_t refCon = (uint32_t)dl[14] << 24 | dl[15] << 16 | dl[16] << 8 | dl[17];
	int16_t itemsID = be16(dl + 18);
	const uint8_t *title = dl + 20;
	uint32_t tl = 1 + title[0];
	int pos = 0;
	uint32_t after = 20 + tl + ((20 + tl) & 1);
	if (after + 2 <= len)
		pos = (uint16_t)be16(dl + after);
	const uint8_t *ditl = res_bytes('DITL', itemsID, &ditl_len);
	RET(create(r, title, visible, procID, A(2), goAway, refCon, ditl, ditl ? ditl_len : 0, pos));
}

// NewDialog / NewColorDialog(storage, bounds, title, visible, procID, behind, goAway, refCon, items)
static void sh_NewColorDialog(PPC *c)
{
	uint32_t items = A(8);
	QRect r = RECT(A(1));
	uint8_t title[256] = {0};
	if (A(2))
		memcpy(title, G(A(2)), LD8(A(2)) + 1);
	RET(create(r, title, A(3) & 0xff, (int16_t)A(4), A(5), A(6) & 0xff, A(7), items ? G(HP(items)) : NULL,
	           items ? HSize(items) : 0, 0));
}

static void sh_DisposeDialog(PPC *c)
{
	Dlg *d = DLG(A(0));
	if (!d)
		return;
	for (int i = 0; i < d->n; i++)
		if (d->items[i].te)
			te_dispose(d->items[i].te);
	for (Dlg **p = &dialogs; *p; p = &(*p)->next)
		if (*p == d) {
			*p = d->next;
			break;
		}
	SHIM_CALL("DisposeWindow", d->win);
	free(d->items);
	free(d);
}

static void sh_GetDialogWindow(PPC *c) { RET(A(0)); }
static void sh_GetDialogFromWindow(PPC *c) { RET(DLG(A(0)) ? A(0) : 0); }
static void sh_GetDialogPort(PPC *c) { RET(SHIM_CALL("GetWindowPort", A(0))); }
static void sh_SetPortDialogPort(PPC *c) { SHIM_CALL("SetPort", SHIM_CALL("GetWindowPort", A(0))); }
static void sh_SetDialogFont(PPC *c) { dialog_font = (int16_t)A(0); }

static void sh_DrawDialog(PPC *c)
{
	Dlg *d = DLG(A(0));
	if (d)
		draw_dialog(d);
}

static void sh_UpdateDialog(PPC *c)
{
	Dlg *d = DLG(A(0));
	if (d)
		draw_dialog(d);
}

// ---- items -----------------------------------------------------------------------------------

// GetDialogItem(dialog, item, short *type, Handle *, Rect *)
static void sh_GetDialogItem(PPC *c)
{
	DItem *it = item(DLG(A(0)), (int16_t)A(1));
	if (A(2))
		ST16(A(2), it ? it->type : 0);
	if (A(3))
		ST32(A(3), it ? it->h : 0);
	if (A(4)) {
		QRect r = it ? it->r : (QRect){0, 0, 0, 0};
		ST16(A(4), r.top);
		ST16(A(4) + 2, r.left);
		ST16(A(4) + 4, r.bottom);
		ST16(A(4) + 6, r.right);
	}
}

// SetDialogItem(dialog, item, type, handle, Rect *)
static void sh_SetDialogItem(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *it = item(d, (int16_t)A(1));
	if (!it)
		return;
	it->type = (int16_t)A(2);
	it->h = A(3);
	if (A(4)) {
		QRect r = RECT(A(4));
		if (it->te && memcmp(&r, &it->r, sizeof r))
			te_set_rects(it->te, r, r);
		it->r = r;
	}
}

static DItem *item_by_handle(uint32_t h, Dlg **owner)
{
	for (Dlg *d = dialogs; d; d = d->next)
		for (int i = 0; i < d->n; i++)
			if (d->items[i].h == h && h) {
				if (owner)
					*owner = d;
				return &d->items[i];
			}
	return NULL;
}

// GetDialogItemText(handle, Str255)
static void sh_GetDialogItemText(PPC *c)
{
	DItem *it = item_by_handle(A(0), NULL);
	uint32_t out = A(1);
	if (it && it->te) {
		int n = it->te->n > 255 ? 255 : it->te->n;
		ST8(out, n);
		memcpy(G(out + 1), it->te->t, n);
		return;
	}
	Ctl *k = CTL(A(0));
	if (k) {
		memcpy(G(out), k->title, k->title[0] + 1);
		return;
	}
	uint32_t n = A(0) && HP(A(0)) ? HSize(A(0)) : 0;
	if (n > 255)
		n = 255;
	ST8(out, n);
	if (n)
		memcpy(G(out + 1), G(HP(A(0))), n);
}

// SetDialogItemText(handle, Str255)
static void sh_SetDialogItemText(PPC *c)
{
	Dlg *d = NULL;
	DItem *it = item_by_handle(A(0), &d);
	const uint8_t *s = G(A(1));
	int n = s[0];
	Ctl *k = CTL(A(0));
	if (k && !it) {
		SHIM_CALL("SetControlTitle", A(0), A(1));
		return;
	}
	if (A(0) && HP(A(0))) {
		HSetSize(A(0), n);
		memcpy(G(HP(A(0))), s + 1, n);
	}
	if (it && it->te) {
		te_set_text(it->te, s + 1, n);
		te_set_select(it->te, n, n);
	}
	if (d && it) {
		Win *w = dwin(d);
		if (w && w->visible) {
			uint32_t save = ppc_shim_call("GetQDGlobalsThePort", 0, NULL);
			SHIM_CALL("SetPort", SHIM_CALL("GetWindowPort", d->win));
			uint32_t buf = gcalloc(8);
			QRect r = it->r;
			ST16(buf, r.top);
			ST16(buf + 2, r.left);
			ST16(buf + 4, r.bottom);
			ST16(buf + 6, r.right);
			SHIM_CALL("EraseRect", buf);
			gfree(buf);
			draw_item(d, (int)(it - d->items) + 1);
			win_dirty(w, r);
			if (save)
				SHIM_CALL("SetPort", save);
		}
	}
}

// GetDialogItemAsControl(dialog, item, ControlRef *)
static void sh_GetDialogItemAsControl(PPC *c)
{
	DItem *it = item(DLG(A(0)), (int16_t)A(1));
	int kind = it ? it->type & 0x7f : -1;
	if (it && kind >= ctrlItem && kind <= ctrlItem + resCtrl) {
		ST32(A(2), it->h);
		RET(0);
		return;
	}
	ST32(A(2), 0);
	RET(-30599);   // errItemNotControl
}

static void sh_HideDialogItem(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *it = item(d, (int16_t)A(1));
	if (!it || it->hidden)
		return;
	it->hidden = 1;
	if (CTL(it->h))
		SHIM_CALL("HideControl", it->h);
	if (dwin(d))
		win_invalidate(dwin(d), (QRect){it->r.top - 4, it->r.left - 4, it->r.bottom + 4, it->r.right + 4});
}

static void sh_ShowDialogItem(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *it = item(d, (int16_t)A(1));
	if (!it || !it->hidden)
		return;
	it->hidden = 0;
	if (CTL(it->h))
		SHIM_CALL("ShowControl", it->h);
	if (dwin(d))
		win_invalidate(dwin(d), (QRect){it->r.top - 4, it->r.left - 4, it->r.bottom + 4, it->r.right + 4});
}

// FindDialogItem(dialog, Point) -> item - 1, or -1
static void sh_FindDialogItem(PPC *c)
{
	Dlg *d = DLG(A(0));
	QPoint pt = PT(A(1));
	for (int i = 1; d && i <= d->n; i++) {
		QRect r = d->items[i - 1].r;
		if (!d->items[i - 1].hidden && pt.h >= r.left && pt.h < r.right && pt.v >= r.top && pt.v < r.bottom) {
			RET(i - 1);
			return;
		}
	}
	RET(-1);
}

// SelectDialogItemText(dialog, item, start, end)
static void sh_SelectDialogItemText(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *it = item(d, (int16_t)A(1));
	if (!it || !it->te)
		return;
	focus_item(d, (int16_t)A(1));
	int a = (int16_t)A(2), b = (int16_t)A(3);
	if (a < 0) a = 0;
	if (b > it->te->n || b < 0) b = it->te->n;
	te_set_select(it->te, a, b);
	te_draw(it->te, NULL);
}

static void sh_GetDialogKeyboardFocusItem(PPC *c) { Dlg *d = DLG(A(0)); RET(d ? d->focus : 0); }

static void sh_GetDialogTextEditHandle(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *it = item(d, d ? d->focus : 0);
	RET(it && it->te ? te_handle(it->te) : 0);
}

static void sh_SetDialogDefaultItem(PPC *c)
{
	Dlg *d = DLG(A(0));
	if (!d) {
		RET(0);
		return;
	}
	DItem *old = item(d, d->def);
	if (old && CTL(old->h))
		CTL(old->h)->is_default = 0;
	d->def = (int16_t)A(1);
	DItem *it = item(d, d->def);
	if (it && CTL(it->h)) {
		CTL(it->h)->is_default = 1;
		ctl_draw(CTL(it->h));
	}
	RET(0);
}

static void sh_SetDialogCancelItem(PPC *c)
{
	Dlg *d = DLG(A(0));
	if (d)
		d->cancel = (int16_t)A(1);
	RET(0);
}

static void sh_GetDialogDefaultItem(PPC *c) { Dlg *d = DLG(A(0)); RET(d ? d->def : 0); }
static void sh_GetDialogCancelItem(PPC *c) { Dlg *d = DLG(A(0)); RET(d ? d->cancel : 0); }
static void sh_SetDialogTracksCursor(PPC *c) { Dlg *d = DLG(A(0)); if (d) d->tracks_cursor = A(1) & 0xff; RET(0); }
static void sh_CountDITL(PPC *c) { Dlg *d = DLG(A(0)); RET(d ? d->n : 0); }

// AppendDITL(dialog, DITL handle, method): overlay 0, right 1, bottom 2, or -n relative to item n
static void sh_AppendDITL(PPC *c)
{
	Dlg *d = DLG(A(0));
	uint32_t h = A(1);
	int method = (int16_t)A(2);
	if (!d || !h)
		return;
	int dh = 0, dv = 0;
	QRect all = {32767, 32767, -32768, -32768};
	for (int i = 0; i < d->n; i++) {
		QRect r = d->items[i].r;
		if (r.top < all.top) all.top = r.top;
		if (r.left < all.left) all.left = r.left;
		if (r.bottom > all.bottom) all.bottom = r.bottom;
		if (r.right > all.right) all.right = r.right;
	}
	if (method == 1)
		dh = d->n ? all.right : 0;
	else if (method == 2)
		dv = d->n ? all.bottom : 0;
	else if (method < 0 && item(d, -method)) {
		DItem *ref = item(d, -method);
		dh = ref->r.left;
		dv = ref->r.top;
	}
	int before = d->n;
	add_items(d, G(HP(h)), HSize(h), dh, dv);
	// grow the window to hold the new items
	Win *w = dwin(d);
	if (w && (method == 1 || method == 2 || method < 0)) {
		int right = w->port->portRect.right, bottom = w->port->portRect.bottom;
		for (int i = before; i < d->n; i++) {
			if (d->items[i].r.right + 10 > right) right = d->items[i].r.right + 10;
			if (d->items[i].r.bottom + 10 > bottom) bottom = d->items[i].r.bottom + 10;
		}
		SHIM_CALL("SizeWindow", d->win, (uint32_t)right, (uint32_t)bottom, 1);
	}
}

// ShortenDITL(dialog, n): the last n items go
static void sh_ShortenDITL(PPC *c)
{
	Dlg *d = DLG(A(0));
	int n = (int16_t)A(1);
	while (d && n-- > 0 && d->n) {
		DItem *it = &d->items[--d->n];
		if (it->te)
			te_dispose(it->te);
		if (CTL(it->h))
			SHIM_CALL("DisposeControl", it->h);
		if (d->focus > d->n)
			d->focus = 0;
	}
}

// ---- events ----------------------------------------------------------------------------------

enum { nullEvent = 0, mouseDown = 1, keyDown = 3, autoKey = 5, updateEvt = 6, activateEvt = 8 };

static Dlg *event_dialog(uint32_t ev)
{
	uint16_t what = LD16(ev);
	if (what == updateEvt || what == activateEvt)
		return DLG(LD32(ev + 2));
	if (what == mouseDown) {
		uint32_t wp = gcalloc(4);
		int part = (int16_t)SHIM_CALL("FindWindow", LD32(ev + 10), wp);
		uint32_t w = LD32(wp);
		gfree(wp);
		return part == 3 ? DLG(w) : NULL;   // inContent
	}
	Win *f = win_front(1);
	return f ? DLG(f->tok) : NULL;
}

static void sh_IsDialogEvent(PPC *c)
{
	uint16_t what = LD16(A(0));
	Dlg *d = event_dialog(A(0));
	RET(d && (what != keyDown && what != autoKey ? 1 : 1));
}

static void flash(Dlg *d, int i)
{
	DItem *it = item(d, i);
	if (!it || !CTL(it->h))
		return;
	SHIM_CALL("HiliteControl", it->h, 1);
	win_flush(dwin(d));
	usleep(80000);
	SHIM_CALL("HiliteControl", it->h, 0);
	win_flush(dwin(d));
}

static int enabled(DItem *it) { return it && !(it->type & itemDisable) && !it->hidden; }

// one event for dialog d: the item hit, or 0
static int handle(Dlg *d, uint32_t ev)
{
	uint16_t what = LD16(ev);
	uint32_t msg = LD32(ev + 2);
	uint16_t mods = LD16(ev + 14);
	Win *w = dwin(d);
	if (!w)
		return 0;
	switch (what) {
	case updateEvt:
		SHIM_CALL("BeginUpdate", d->win);
		draw_dialog(d);
		SHIM_CALL("EndUpdate", d->win);
		return 0;
	case activateEvt: {
		DItem *f = item(d, d->focus);
		if (f && f->te)
			te_activate(f->te, mods & 1);
		return 0;
	}
	case mouseDown: {
		QPoint g = PT(LD32(ev + 10)), o = win_origin(w);
		QPoint pt = {g.v - o.v, g.h - o.h};
		SHIM_CALL("SetPort", SHIM_CALL("GetWindowPort", d->win));
		for (int i = d->n; i >= 1; i--) {
			DItem *it = item(d, i);
			QRect r = it->r;
			int kind = it->type & 0x7f;
			if (it->hidden)
				continue;
			if (kind >= ctrlItem && kind <= ctrlItem + resCtrl) {
				Ctl *k = CTL(it->h);
				int part = 0;
				Ctl *hit = ctl_find(w, pt, &part);
				if (k && hit == k) {
					int r2 = ctl_track(k, pt, 0xffffffff, mods);
					return r2 && enabled(it) ? i : 0;
				}
				continue;
			}
			if (pt.h < r.left || pt.h >= r.right || pt.v < r.top || pt.v >= r.bottom)
				continue;
			if (kind == editText) {
				if (d->focus != i)
					focus_item(d, i);
				te_click(it->te, pt, (mods & 0x200) != 0);
				return enabled(it) ? i : 0;
			}
			return enabled(it) ? i : 0;
		}
		// a control that isn't an item (embedded user controls)
		int part = 0;
		Ctl *k = ctl_find(w, pt, &part);
		if (k)
			ctl_track(k, pt, 0xffffffff, mods);
		return 0;
	}
	case keyDown:
	case autoKey: {
		uint8_t ch = msg & 0xff;
		int cmd = (mods & 0x100) != 0;
		if ((ch == 13 || ch == 3) && d->def && enabled(item(d, d->def))) {
			flash(d, d->def);
			return d->def;
		}
		if ((ch == 27 || (cmd && ch == '.')) && d->cancel && enabled(item(d, d->cancel))) {
			flash(d, d->cancel);
			return d->cancel;
		}
		DItem *f = item(d, d->focus);
		if (ch == 9) {
			// the next edit text item
			for (int k = 1; k <= d->n; k++) {
				int i = (d->focus + k - 1) % d->n + 1;
				if (i != d->focus && item(d, i)->te && !item(d, i)->hidden) {
					focus_item(d, i);
					te_set_select(item(d, i)->te, 0, item(d, i)->te->n);
					te_draw(item(d, i)->te, NULL);
					break;
				}
			}
			return 0;
		}
		if (!f || !f->te)
			return 0;
		if (cmd) {
			if (ch == 'x' || ch == 'X') { te_copy(f->te); te_delete_sel(f->te); }
			else if (ch == 'c' || ch == 'C') te_copy(f->te);
			else if (ch == 'v' || ch == 'V') te_paste(f->te);
			else if (ch == 'a' || ch == 'A') te_set_select(f->te, 0, f->te->n);
			else return 0;
			te_draw(f->te, NULL);
			return d->focus;
		}
		te_key(f->te, ch, mods);
		return d->focus;
	}
	case nullEvent: {
		DItem *f = item(d, d->focus);
		if (f && f->te)
			te_idle(f->te);
		return 0;
	}
	}
	return 0;
}

// DialogSelect(event, DialogRef *, short *itemHit) -> Boolean
static void sh_DialogSelect(PPC *c)
{
	uint32_t ev = A(0);
	Dlg *d = event_dialog(ev);
	if (!d) {
		RET(0);
		return;
	}
	if (A(1))
		ST32(A(1), d->win);
	int hit = handle(d, ev);
	if (A(2))
		ST16(A(2), hit);
	RET(hit ? 1 : 0);
}

// ModalDialog(filterProc, short *itemHit)
static void sh_ModalDialog(PPC *c)
{
	uint32_t filter = A(0), hitp = A(1);
	Win *f = win_front(1);
	Dlg *d = f ? DLG(f->tok) : NULL;
	if (!d) {
		for (d = dialogs; d && !(dwin(d) && dwin(d)->visible); d = d->next)
			;
		if (!d) {
			ST16(hitp, 0);
			return;
		}
	}
	uint32_t ev = gcalloc(16);
	for (;;) {
		SHIM_CALL("WaitNextEvent", 0xffff, ev, 2, 0);
		uint16_t what = LD16(ev);
		ST16(hitp, 0);
		if (filter) {
			uint32_t r = ppc_cb3(filter, d->win, ev, hitp);
			if (r & 0xff) {
				if ((int16_t)LD16(hitp))
					break;
				continue;
			}
		}
		// events for other windows: updates get drawn, the rest wait
		Dlg *ed = event_dialog(ev);
		if (what == updateEvt && !ed) {
			continue;
		}
		if (ed && ed != d && what != updateEvt)
			continue;
		if (what == mouseDown && !ed) {
			NSBeep();
			continue;
		}
		int hit = handle(ed ? ed : d, ev);
		if (hit && (ed ? ed : d) == d) {
			ST16(hitp, hit);
			break;
		}
	}
	gfree(ev);
}

static void sh_DialogCut(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *f = item(d, d ? d->focus : 0);
	if (f && f->te) {
		te_copy(f->te);
		te_delete_sel(f->te);
		te_draw(f->te, NULL);
	}
}
static void sh_DialogCopy(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *f = item(d, d ? d->focus : 0);
	if (f && f->te)
		te_copy(f->te);
}
static void sh_DialogPaste(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *f = item(d, d ? d->focus : 0);
	if (f && f->te) {
		te_paste(f->te);
		te_draw(f->te, NULL);
	}
}
static void sh_DialogDelete(PPC *c)
{
	Dlg *d = DLG(A(0));
	DItem *f = item(d, d ? d->focus : 0);
	if (f && f->te) {
		te_delete_sel(f->te);
		te_draw(f->te, NULL);
	}
}

// GetStdFilterProc(ModalFilterUPP *): our ModalDialog does the standard keys itself
static void sh_GetStdFilterProc(PPC *c)
{
	ST32(A(0), 0);
	RET(0);
}

// StdFilterProc(dialog, event, itemHit): Return/Enter, Escape/Cmd-period
static void sh_StdFilterProc(PPC *c)
{
	Dlg *d = DLG(A(0));
	uint32_t ev = A(1);
	uint16_t what = LD16(ev);
	if (d && (what == keyDown || what == autoKey)) {
		uint8_t ch = LD32(ev + 2) & 0xff;
		int cmd = (LD16(ev + 14) & 0x100) != 0;
		if ((ch == 13 || ch == 3) && d->def) {
			flash(d, d->def);
			ST16(A(2), d->def);
			RET(1);
			return;
		}
		if ((ch == 27 || (cmd && ch == '.')) && d->cancel) {
			flash(d, d->cancel);
			ST16(A(2), d->cancel);
			RET(1);
			return;
		}
	}
	RET(0);
}

static const ShimDef dialogshims[] = {
	S(GetNewDialog), {"NewDialog", sh_NewColorDialog}, S(NewColorDialog), S(DisposeDialog), S(GetDialogWindow),
	S(GetDialogFromWindow), S(GetDialogPort), S(SetPortDialogPort), S(SetDialogFont), S(DrawDialog),
	S(UpdateDialog), S(GetDialogItem), S(SetDialogItem), S(GetDialogItemText), S(SetDialogItemText),
	S(GetDialogItemAsControl), S(HideDialogItem), S(ShowDialogItem), S(FindDialogItem), S(SelectDialogItemText),
	S(GetDialogKeyboardFocusItem), S(GetDialogTextEditHandle), S(SetDialogDefaultItem), S(SetDialogCancelItem),
	S(GetDialogDefaultItem), S(GetDialogCancelItem), S(SetDialogTracksCursor), S(CountDITL), S(AppendDITL),
	S(ShortenDITL), S(IsDialogEvent), S(DialogSelect), S(ModalDialog), S(DialogCut), S(DialogCopy),
	S(DialogPaste), S(DialogDelete), S(GetStdFilterProc), S(StdFilterProc),
	{"GetDItem", sh_GetDialogItem}, {"SetDItem", sh_SetDialogItem}, {"GetIText", sh_GetDialogItemText},
	{"SetIText", sh_SetDialogItemText}, {"SelIText", sh_SelectDialogItemText}, {"HideDItem", sh_HideDialogItem},
	{"ShowDItem", sh_ShowDialogItem},
};
REGISTER(dialogshims)
