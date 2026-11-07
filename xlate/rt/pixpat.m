// Color QuickDraw pixel patterns and PixMap utilities.
//
// A PixPat here is the guest's 28-byte record (patType 0, patMap 2, patData 6,
// patXData 10, patXValid 14, patXMap 16, pat1Data 20) plus a host-side color
// for RGB patterns. Ports draw with a 1-bit pattern in two colors, so setting a
// pixel pattern on a port sets the pen (or background) color and pattern: an
// RGB pattern (patType 2) becomes its color, solid; others use pat1Data.
#import <Foundation/Foundation.h>
#include "qd.h"
#include "hmap.h"

uint32_t res_get(uint32_t type, int16_t id, int one);

typedef struct { RGB16 rgb; int has_rgb; } PatInfo;
static HMap infos;         // PixPatHandle -> PatInfo
static HMap port_pats;     // port token -> uint32_t[3] (pen, back, fill PixPatHandles)

static PatInfo *info(uint32_t pp, int make)
{
	PatInfo *i = hm_get(&infos, pp);
	if (!i && make) {
		i = calloc(1, sizeof *i);
		hm_put(&infos, pp, i);
	}
	return i;
}

static uint32_t *pats_of(Port *p)
{
	uint32_t *v = hm_get(&port_pats, p->tok);
	if (!v) {
		v = calloc(3, sizeof *v);
		hm_put(&port_pats, p->tok, v);
	}
	return v;
}

static uint32_t pixpat_new(void)
{
	uint32_t h = NewHandleClearG(28), p = HP(h);
	ST16(p, 0);                                  // patType: old-style until set
	ST32(p + 2, SHIM_CALL("NewPixMap", 0));      // patMap
	ST32(p + 6, NewHandleClearG(0));             // patData
	ST32(p + 10, NewHandleClearG(0));            // patXData
	ST16(p + 14, (uint16_t)-1);                  // patXValid
	memset(G(p + 20), 0xff, 8);                  // pat1Data: black
	return h;
}

static void apply(Port *p, uint32_t pp, int which)
{
	if (!p || !is_handle(pp) || !HP(pp))
		return;
	uint32_t pt = HP(pp);
	PatInfo *i = info(pp, 0);
	uint8_t pat[8];
	// a solid RGB pattern: all foreground bits for the pen and fill, and all
	// background bits for the back pattern, whose color is the port's bg
	if (i && i->has_rgb && LD16(pt) == 2)
		memset(pat, which == 1 ? 0x00 : 0xff, 8);
	else
		memcpy(pat, G(pt + 20), 8);
	if (which == 0) {
		memcpy(p->pnPat, pat, 8);
		if (i && i->has_rgb)
			p->fg = i->rgb;
	} else if (which == 1) {
		memcpy(p->bkPat, pat, 8);
		if (i && i->has_rgb)
			p->bg = i->rgb;
	} else
		memcpy(p->fillPat, pat, 8);
	pats_of(p)[which] = pp;
}

// the port's pixel pattern, or a new one made from its current pattern and color
static uint32_t port_pat(Port *p, int which)
{
	uint32_t *v = pats_of(p);
	if (v[which] && is_handle(v[which]))
		return v[which];
	uint32_t pp = pixpat_new();
	memcpy(G(HP(pp) + 20), which == 0 ? p->pnPat : which == 1 ? p->bkPat : p->fillPat, 8);
	v[which] = pp;
	return pp;
}

static void sh_NewPixPat(PPC *c) { RET(pixpat_new()); }
static void sh_DisposePixPat(PPC *c)
{
	uint32_t pp = A(0);
	if (!is_handle(pp))
		return;
	PatInfo *i = info(pp, 0);
	if (i) {
		hm_put(&infos, pp, NULL);
		free(i);
	}
	SHIM_CALL("DisposeHandle", pp);
}
static void sh_CopyPixPat(PPC *c)
{
	uint32_t s = A(0), d = A(1);
	if (!is_handle(s) || !is_handle(d) || !HP(s) || !HP(d))
		return;
	ST16(HP(d), LD16(HP(s)));
	memcpy(G(HP(d) + 20), G(HP(s) + 20), 8);
	PatInfo *si = info(s, 0);
	if (si)
		*info(d, 1) = *si;
}
static void sh_PixPatChanged(PPC *c) { (void)c; }
// MakeRGBPat(PixPatHandle, const RGBColor *)
static void sh_MakeRGBPat(PPC *c)
{
	uint32_t pp = A(0);
	if (!is_handle(pp) || !HP(pp))
		return;
	PatInfo *i = info(pp, 1);
	i->rgb = (RGB16){LD16(A(1)), LD16(A(1) + 2), LD16(A(1) + 4)};
	i->has_rgb = 1;
	ST16(HP(pp), 2);
	memset(G(HP(pp) + 20), 0xff, 8);
}
// GetPixPat(id): a 'ppat' resource as a PixPat; only its 1-bit pattern is used
static void sh_GetPixPat(PPC *c)
{
	uint32_t r = res_get('ppat', (int16_t)A(0), 0);
	if (!r || !HP(r)) {
		RET(0);
		return;
	}
	uint32_t pp = pixpat_new();
	memcpy(G(HP(pp) + 20), G(HP(r) + 20), 8);
	ST16(HP(pp), 1);
	RET(pp);
}
static void sh_PenPixPat(PPC *c) { apply(qd_port, A(0), 0); }
static void sh_BackPixPat(PPC *c) { apply(qd_port, A(0), 1); }
static void sh_SetPortPenPixPat(PPC *c) { apply(PORT(A(0)), A(1), 0); }
static void sh_SetPortBackPixPat(PPC *c) { apply(PORT(A(0)), A(1), 1); }
static void sh_SetPortFillPixPat(PPC *c) { apply(PORT(A(0)), A(1), 2); }
// GetPortPenPixPat(port, PixPatHandle): copies the port's pattern into the given one
static void get_port(PPC *c, int which)
{
	Port *p = PORT(A(0));
	if (p && is_handle(A(1))) {
		uint32_t s = port_pat(p, which);
		uint32_t a[2] = {s, A(1)};
		c->r[3] = a[0], c->r[4] = a[1];
		sh_CopyPixPat(c);
	}
	RET(A(1));
}
static void sh_GetPortPenPixPat(PPC *c) { get_port(c, 0); }
static void sh_GetPortBackPixPat(PPC *c) { get_port(c, 1); }
static void sh_GetPortFillPixPat(PPC *c) { get_port(c, 2); }

static void sh_GetPattern(PPC *c) { RET(res_get('PAT ', (int16_t)A(0), 0)); }
// LMGetHiliteRGB(RGBColor *)
static void sh_LMGetHiliteRGB(PPC *c)
{
	RGB16 h = qd_port ? qd_port->hilite : (RGB16){0xb5b5, 0xd5d5, 0xffff};
	ST16(A(0), h.r);
	ST16(A(0) + 2, h.g);
	ST16(A(0) + 4, h.b);
}

// GetCPixel(h, v, RGBColor *): the current port's pixel at a local point
static void sh_GetCPixel(PPC *c)
{
	Port *p = qd_port;
	int h = (int16_t)A(0), v = (int16_t)A(1);
	uint8_t r = 255, g = 255, b = 255;
	if (p && p->pix && h >= p->bounds.left && h < p->bounds.right && v >= p->bounds.top && v < p->bounds.bottom) {
		port_shadow_sync(p, 0);
		const uint8_t *px = G(p->pix + (uint32_t)((v - p->bounds.top) * p->rowBytes + (h - p->bounds.left) * 4));
		r = px[1], g = px[2], b = px[3];
	}
	ST16(A(2), (uint16_t)(r * 0x101));
	ST16(A(2) + 2, (uint16_t)(g * 0x101));
	ST16(A(2) + 4, (uint16_t)(b * 0x101));
}

// PixMaps: GetPixBounds(PixMapHandle, Rect *), CopyPixMap(src, dst), DisposePixMap
static void sh_GetPixBounds(PPC *c)
{
	uint32_t h = A(0);
	if (is_handle(h) && HP(h))
		memcpy(G(A(1)), G(HP(h) + 6), 8);
	RET(A(1));
}
static void sh_CopyPixMap(PPC *c)
{
	uint32_t s = A(0), d = A(1);
	if (is_handle(s) && is_handle(d) && HP(s) && HP(d))
		memcpy(G(HP(d)), G(HP(s)), 50);
}
static void sh_DisposePixMap(PPC *c)
{
	uint32_t h = A(0);
	if (!is_handle(h))
		return;
	if (HP(h) && is_handle(LD32(HP(h) + 42)))
		SHIM_CALL("DisposeHandle", LD32(HP(h) + 42));
	SHIM_CALL("DisposeHandle", h);
}

static const ShimDef pixpatshims[] = {
	S(NewPixPat), S(DisposePixPat), S(CopyPixPat), S(PixPatChanged), S(MakeRGBPat), S(GetPixPat), S(PenPixPat),
	S(BackPixPat), S(SetPortPenPixPat), S(SetPortBackPixPat), S(SetPortFillPixPat), S(GetPortPenPixPat),
	S(GetPortBackPixPat), S(GetPortFillPixPat), S(GetPattern), S(LMGetHiliteRGB), S(GetCPixel), S(GetPixBounds),
	S(CopyPixMap), S(DisposePixMap),
};
REGISTER(pixpatshims)
