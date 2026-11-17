// QuickTime, as far as documents need it: graphics importers (pictures embedded in documents, as JPEG,
// GIF, PNG, TIFF, ...) decoded with ImageIO and drawn into QuickDraw ports, the matrix calls they use,
// and the movie calls answering that a file holds no movie.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "qd.h"
#include "rgn.h"
#include "pict.h"

const char *fsspec_path(uint32_t spec, char *out, size_t n);

enum { TAG_GI = 'grip' };
// noMovieFound, cantFindHandler, badComponentInstance...: the SDK's MacErrors.h

// ---- matrices: Fixed [3][3], the last column Fract; points map as (x, y, 1) * M -------------------

typedef struct { double m[3][3]; } Mat;

static Mat mat_get(uint32_t a)
{
	Mat r;
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++) {
			int32_t v = (int32_t)LD32(a + (uint32_t)(i * 3 + j) * 4);
			r.m[i][j] = j == 2 ? v / 1073741824.0 : v / 65536.0;
		}
	return r;
}
static void mat_put(uint32_t a, Mat r)
{
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			ST32(a + (uint32_t)(i * 3 + j) * 4, (uint32_t)(int32_t)lround(r.m[i][j] * (j == 2 ? 1073741824.0 : 65536.0)));
}
static Mat mat_identity(void) { return (Mat){{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}}; }
static Mat mat_mul(Mat a, Mat b)
{
	Mat r = {{{0}}};
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			for (int k = 0; k < 3; k++)
				r.m[i][j] += a.m[i][k] * b.m[k][j];
	return r;
}
static Mat mat_rect(QRect s, QRect d)
{
	Mat r = mat_identity();
	double sw = s.right - s.left, sh = s.bottom - s.top;
	r.m[0][0] = sw ? (d.right - d.left) / sw : 1;
	r.m[1][1] = sh ? (d.bottom - d.top) / sh : 1;
	r.m[2][0] = d.left - s.left * r.m[0][0];
	r.m[2][1] = d.top - s.top * r.m[1][1];
	return r;
}
// a rectangle through a matrix that only scales and moves (the bounds of its corners otherwise)
static QRect mat_apply(Mat m, QRect r)
{
	double xs[2] = {r.left, r.right}, ys[2] = {r.top, r.bottom}, x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
	for (int i = 0; i < 2; i++)
		for (int j = 0; j < 2; j++) {
			double w = xs[i] * m.m[0][2] + ys[j] * m.m[1][2] + m.m[2][2];
			if (!w)
				w = 1;
			double x = (xs[i] * m.m[0][0] + ys[j] * m.m[1][0] + m.m[2][0]) / w;
			double y = (xs[i] * m.m[0][1] + ys[j] * m.m[1][1] + m.m[2][1]) / w;
			x0 = fmin(x0, x), x1 = fmax(x1, x), y0 = fmin(y0, y), y1 = fmax(y1, y);
		}
	return (QRect){(int16_t)lround(y0), (int16_t)lround(x0), (int16_t)lround(y1), (int16_t)lround(x1)};
}

static void sh_SetIdentityMatrix(PPC *c) { mat_put(A(0), mat_identity()); }
// RectMatrix(matrix, srcRect, dstRect)
static void sh_RectMatrix(PPC *c) { mat_put(A(0), mat_rect(RECT(A(1)), RECT(A(2)))); }
// TranslateMatrix(matrix, Fixed dx, Fixed dy)
static void sh_TranslateMatrix(PPC *c)
{
	Mat t = mat_identity();
	t.m[2][0] = (int32_t)A(1) / 65536.0;
	t.m[2][1] = (int32_t)A(2) / 65536.0;
	mat_put(A(0), mat_mul(mat_get(A(0)), t));
}
// ScaleMatrix(matrix, Fixed sx, Fixed sy, Fixed aboutX, Fixed aboutY)
static void sh_ScaleMatrix(PPC *c)
{
	double sx = (int32_t)A(1) / 65536.0, sy = (int32_t)A(2) / 65536.0, ax = (int32_t)A(3) / 65536.0, ay = (int32_t)A(4) / 65536.0;
	Mat t = mat_identity();
	t.m[0][0] = sx;
	t.m[1][1] = sy;
	t.m[2][0] = ax - ax * sx;
	t.m[2][1] = ay - ay * sy;
	mat_put(A(0), mat_mul(mat_get(A(0)), t));
}
// TransformRect(matrix, Rect *, FixedPoint *points): true when the result is still a rectangle
static void sh_TransformRect(PPC *c)
{
	Mat m = mat_get(A(0));
	QRect r = RECT(A(1));
	PUTRECT(A(1), mat_apply(m, r));
	RET(!m.m[0][1] && !m.m[1][0]);
}
// TransformRgn(matrix, rgn): moved and scaled (the region's rectangles, each through the matrix)
static void sh_TransformRgn(PPC *c)
{
	Mat m = mat_get(A(0));
	Rgn *g = RGN(A(1));
	if (g && !rgn_empty(g)) {
		Rgn *out = rgn_new();
		for (int i = 0; i < g->n; i++) {
			Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
			rgn_set_rect(&t, mat_apply(m, g->r[i]));
			rgn_op(out, out, &t, RGN_UNION);
			free(t.r);
		}
		if (!g->n) {
			Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
			rgn_set_rect(&t, mat_apply(m, g->bbox));
			rgn_op(out, out, &t, RGN_UNION);
			free(t.r);
		}
		rgn_copy(g, out);
		rgn_free(out);
		rgn_sync(A(1));
	}
	RET(0);
}
static void sh_EqualRgn(PPC *c)
{
	Rgn *a = RGN(A(0)), *b = RGN(A(1));
	if (!a || !b) {
		RET(a == b);
		return;
	}
	Rgn *x = rgn_new();
	rgn_op(x, a, b, RGN_XOR);
	RET(rgn_empty(x));
	rgn_free(x);
}

// ---- graphics importers ----------------------------------------------------------------------------

typedef struct {
	uint32_t tok, subtype;
	NSData *data;
	CGImageRef img;
	QRect natural;
	Mat mat;
	uint32_t port, gdh;
	Rgn *clip;                  // NULL: none
	uint32_t mode;
	uint16_t opcolor[3];
} Gi;

static Gi *GI(uint32_t t) { return t ? tok_get(t, TAG_GI) : NULL; }

// the subtypes ImageIO reads
static int gi_supported(uint32_t sub)
{
	switch (sub) {
	case 'JPEG': case 'GIFf': case 'PNGf': case 'TIFF': case 'BMPf': case '8BPS': case 'qtif': case 'SGI ': case 'TPIC':
	case 'jp2 ': case 'PICT': case 0:
		return 1;
	}
	return 0;
}

static uint32_t gi_new(uint32_t sub)
{
	Gi *g = calloc(1, sizeof *g);
	g->subtype = sub;
	g->mat = mat_identity();
	g->mode = 0x40;   // ditherCopy
	g->tok = tok_new(g, 16, TAG_GI);
	return g->tok;
}

static void gi_set_data(Gi *g, NSData *d)
{
	[g->data release];
	if (g->img)
		CGImageRelease(g->img);
	g->img = NULL;
	g->data = [d retain];
	g->natural = (QRect){0, 0, 0, 0};
	if (!d.length)
		return;
	CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)d, NULL);
	if (src) {
		g->img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
		CFRelease(src);
	}
	if (!g->img && d.length > 512)   // a PICT file: its 512-byte header, then the picture
		g->img = pict_image((const uint8_t *)d.bytes + 512, (uint32_t)d.length - 512);
	if (!g->img)
		g->img = pict_image(d.bytes, (uint32_t)d.length);
	if (g->img)
		g->natural = (QRect){0, 0, (int16_t)CGImageGetHeight(g->img), (int16_t)CGImageGetWidth(g->img)};
}

// OpenDefaultComponent(type, subType): 'grip' (graphics importers) for what ImageIO reads
static void sh_OpenDefaultComponent(PPC *c)
{
	uint32_t type = A(0), sub = A(1);
	RET(type == 'grip' && gi_supported(sub) ? gi_new(sub) : 0);
}
// OpenADefaultComponent(type, subType, ComponentInstance *)
static void sh_OpenADefaultComponent(PPC *c)
{
	uint32_t type = A(0), sub = A(1), ci = type == 'grip' && gi_supported(sub) ? gi_new(sub) : 0;
	if (A(2))
		ST32(A(2), ci);
	RET(ci ? 0 : cantFindHandler);
}
static void sh_CloseComponent(PPC *c)
{
	Gi *g = GI(A(0));
	if (!g) {
		RET(0);
		return;
	}
	[g->data release];
	if (g->img)
		CGImageRelease(g->img);
	if (g->clip)
		rgn_free(g->clip);
	tok_free(g->tok);
	free(g);
	RET(0);
}

// GetGraphicsImporterForFile(FSSpec *, ComponentInstance *)
static void sh_GetGraphicsImporterForFile(PPC *c)
{
	char p[1024];
	if (A(1))
		ST32(A(1), 0);
	NSData *d = fsspec_path(A(0), p, sizeof p) ? [NSData dataWithContentsOfFile:@(p)] : nil;
	if (!d) {
		RET(-43);
		return;
	}
	uint32_t t = gi_new(0);
	Gi *g = GI(t);
	gi_set_data(g, d);
	if (!g->img) {
		SHIM_CALL("CloseComponent", t);
		RET(cantFindHandler);
		return;
	}
	if (A(1))
		ST32(A(1), t);
	RET(0);
}

#define GIARG Gi *g = GI(A(0)); if (!g) { RET(badComponentInstance); return; }

// GraphicsImportSetDataHandle(gi, Handle): the image's bytes (taken now)
static void sh_GraphicsImportSetDataHandle(PPC *c)
{
	GIARG
	uint32_t h = A(1);
	gi_set_data(g, h && HP(h) ? [NSData dataWithBytes:G(HP(h)) length:HSize(h)] : nil);
	RET(0);
}
static void sh_GraphicsImportGetNaturalBounds(PPC *c)
{
	GIARG
	if (A(1))
		PUTRECT(A(1), g->natural);
	RET(g->img ? 0 : invalidImageIndexErr);
}
static void sh_GraphicsImportValidate(PPC *c)
{
	GIARG
	if (A(1))
		ST8(A(1), g->img != NULL);
	RET(0);
}
static void sh_GraphicsImportSetGWorld(PPC *c)
{
	GIARG
	g->port = A(1);
	g->gdh = A(2);
	RET(0);
}
static void sh_GraphicsImportGetGWorld(PPC *c)
{
	GIARG
	if (A(1))
		ST32(A(1), g->port ? g->port : qd_port ? qd_port->tok : 0);
	if (A(2))
		ST32(A(2), g->gdh);
	RET(0);
}
static void sh_GraphicsImportSetBoundsRect(PPC *c)
{
	GIARG
	g->mat = mat_rect(g->natural, RECT(A(1)));
	RET(0);
}
static void sh_GraphicsImportSetMatrix(PPC *c)
{
	GIARG
	g->mat = A(1) ? mat_get(A(1)) : mat_identity();
	RET(0);
}
static void sh_GraphicsImportGetMatrix(PPC *c)
{
	GIARG
	if (A(1))
		mat_put(A(1), g->mat);
	RET(0);
}
static void sh_GraphicsImportSetClip(PPC *c)
{
	GIARG
	Rgn *r = RGN(A(1));
	if (g->clip)
		rgn_free(g->clip);
	g->clip = NULL;
	if (r) {
		g->clip = rgn_new();
		rgn_copy(g->clip, r);
	}
	RET(0);
}
static void sh_GraphicsImportGetClip(PPC *c)
{
	GIARG
	if (A(1)) {
		uint32_t h = 0;
		if (g->clip) {
			Rgn *r;
			h = rgn_handle(&r);
			rgn_copy(r, g->clip);
			rgn_sync(h);
		}
		ST32(A(1), h);
	}
	RET(0);
}
static void sh_GraphicsImportSetGraphicsMode(PPC *c)
{
	GIARG
	g->mode = A(1);
	if (A(2))
		for (int i = 0; i < 3; i++)
			g->opcolor[i] = LD16(A(2) + 2 * (uint32_t)i);
	RET(0);
}
static void sh_GraphicsImportGetGraphicsMode(PPC *c)
{
	GIARG
	if (A(1))
		ST32(A(1), g->mode);
	if (A(2))
		for (int i = 0; i < 3; i++)
			ST16(A(2) + 2 * (uint32_t)i, g->opcolor[i]);
	RET(0);
}
// GraphicsImportDraw(gi): into its port (or the current one), where the matrix puts it, inside its clip
static void sh_GraphicsImportDraw(PPC *c)
{
	GIARG
	Port *p = g->port ? PORT(g->port) : qd_port;
	if (!g->img || !p) {
		RET(g->img ? badComponentInstance : invalidImageIndexErr);
		return;
	}
	QRect dst = mat_apply(g->mat, g->natural);
	Rgn *saved = NULL;
	if (g->clip) {
		saved = rgn_new();
		rgn_copy(saved, p->clip);
		rgn_op(p->clip, p->clip, g->clip, RGN_SECT);
	}
	qd_draw_image(p, g->img, dst);
	if (saved) {
		rgn_copy(p->clip, saved);
		rgn_free(saved);
	}
	RET(0);
}
// GraphicsImportGetImageDescription(gi, ImageDescriptionHandle *)
static void sh_GraphicsImportGetImageDescription(PPC *c)
{
	GIARG
	uint32_t h = NewHandleClearG(86);
	uint32_t d = HP(h);
	ST32(d, 86);
	ST32(d + 4, g->subtype ? g->subtype : 'jpeg');
	ST16(d + 32, (uint16_t)(g->natural.right - g->natural.left));
	ST16(d + 34, (uint16_t)(g->natural.bottom - g->natural.top));
	ST32(d + 36, 72 << 16);
	ST32(d + 40, 72 << 16);
	ST16(d + 48, 1);
	ST16(d + 82, 32);
	ST16(d + 84, (uint16_t)-1);
	if (A(1))
		ST32(A(1), h);
	RET(0);
}
static void sh_GraphicsImportGetAsPicture(PPC *c) { if (A(1)) ST32(A(1), 0); RET(cantFindHandler); }
static void sh_GraphicsImportGetMIMETypeList(PPC *c) { if (A(1)) ST32(A(1), 0); RET(cantFindHandler); }
static void sh_GraphicsImportGetExportImageTypeList(PPC *c) { if (A(1)) ST32(A(1), 0); RET(cantFindHandler); }

// ---- movies: a file holds none ---------------------------------------------------------------------

static void sh_OpenMovieFile(PPC *c) { if (A(1)) ST16(A(1), 0); RET(0); }
static void sh_CloseMovieFile(PPC *c) { RET(0); }
// NewMovieFromFile(Movie *, resRefNum, short *resId, name, flags, Boolean *dataRefWasChanged)
static void sh_NewMovieFromFile(PPC *c)
{
	if (A(0))
		ST32(A(0), 0);
	if (A(5))
		ST8(A(5), 0);
	RET(noMovieFound);
}
static void sh_NewMovieFromHandle(PPC *c) { if (A(0)) ST32(A(0), 0); RET(noMovieFound); }
static void sh_NewMovieFromScrap(PPC *c) { RET(0); }
// GetMovieImporterForDataRef(dataRefType, dataRef, flags, Component *)
static void sh_GetMovieImporterForDataRef(PPC *c) { if (A(3)) ST32(A(3), 0); RET(cantFindHandler); }
static void sh_GetMoviesError(PPC *c) { RET(0); }
static void sh_GetMoviesStickyError(PPC *c) { RET(0); }

static const ShimDef qtshims[] = {
	S(SetIdentityMatrix), S(RectMatrix), S(TranslateMatrix), S(ScaleMatrix), S(TransformRect), S(TransformRgn), S(EqualRgn),
	S(OpenDefaultComponent), S(OpenADefaultComponent), S(CloseComponent), S(GetGraphicsImporterForFile),
	S(GraphicsImportSetDataHandle), S(GraphicsImportGetNaturalBounds), S(GraphicsImportValidate), S(GraphicsImportSetGWorld),
	S(GraphicsImportGetGWorld), S(GraphicsImportSetBoundsRect), S(GraphicsImportSetMatrix), S(GraphicsImportGetMatrix),
	S(GraphicsImportSetClip), S(GraphicsImportGetClip), S(GraphicsImportSetGraphicsMode), S(GraphicsImportGetGraphicsMode),
	S(GraphicsImportDraw), S(GraphicsImportGetImageDescription), S(GraphicsImportGetAsPicture),
	S(GraphicsImportGetMIMETypeList), S(GraphicsImportGetExportImageTypeList),
	S(OpenMovieFile), S(CloseMovieFile), S(NewMovieFromFile), S(NewMovieFromHandle), S(NewMovieFromScrap),
	S(GetMovieImporterForDataRef), S(GetMoviesError), S(GetMoviesStickyError),
};
REGISTER(qtshims)
