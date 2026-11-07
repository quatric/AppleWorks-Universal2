// Toolbox calls AppleWorks 6 needs beyond the World Book wizards': OS queues,
// QuickTime and Navigation Services availability, FSRef folder lookup, CFURL
// paths, volume parameters, the rest of MathLib and the C library.
#import <Foundation/Foundation.h>
#include "ppcrt.h"
#include <math.h>

uint32_t cf_tok(CFTypeRef o);
CFTypeRef cf_obj(uint32_t t);
NSString *cf_string(uint32_t t);
const char *fsref_path(uint32_t ref, char *out, size_t n);
int fs_make_ref_for(const char *path, uint32_t ref);
void d_to_x80(double d, uint32_t a);
double x80_to_d(uint32_t a);
NSString *fs_folder_path(uint32_t type);
uint32_t res_get(uint32_t type, int16_t id, int one);

// ---- OS Utilities: queues (QHdr: flags 2, head 4, tail 4; elements link first)

static void sh_Enqueue(PPC *c)
{
	uint32_t e = A(0), q = A(1);
	ST32(e, 0);
	uint32_t tail = LD32(q + 6);
	if (tail)
		ST32(tail, e);
	else
		ST32(q + 2, e);
	ST32(q + 6, e);
}

static void sh_Dequeue(PPC *c)
{
	uint32_t e = A(0), q = A(1), prev = 0, p = LD32(q + 2);
	while (p && p != e) {
		prev = p;
		p = LD32(p);
	}
	if (!p) {
		RET(-1);   // qErr
		return;
	}
	uint32_t next = LD32(p);
	if (prev)
		ST32(prev, next);
	else
		ST32(q + 2, next);
	if (LD32(q + 6) == p)
		ST32(q + 6, prev);
	RET_OK(c);
}

// ---- Memory Manager: the guest heap is large; report room to spare

enum { ROOM = 256 << 20 };
static void sh_FreeMem(PPC *c) { RET(ROOM); }
static void sh_MaxMem(PPC *c)
{
	if (A(0))
		ST32(A(0), 0);   // grow
	RET(ROOM);
}
static void sh_PurgeSpace(PPC *c)
{
	ST32(A(0), ROOM);
	ST32(A(1), ROOM);
}
static void sh_CompactMem(PPC *c) { RET(ROOM); }
static void sh_PurgeMem(PPC *c) { (void)c; }
static void sh_ReserveMem(PPC *c) { (void)c; }
static void sh_StackSpace(PPC *c) { RET(c->r[1] - (STACK_TOP - STACK_SIZE)); }
static void sh_TempFreeMem(PPC *c) { RET(ROOM); }
static void sh_TempMaxMem(PPC *c)
{
	if (A(0))
		ST32(A(0), ROOM);
	RET(ROOM);
}

// ---- availability

static void sh_EnterMovies(PPC *c) { RET_OK(c); }
static void sh_ExitMovies(PPC *c) { (void)c; }
static void sh_NavServicesCanRun(PPC *c) { RET(1); }
static void sh_NavLibraryVersion(PPC *c) { RET(0x02008000); }
static void sh_FontToScript(PPC *c) { RET(0); }   // smRoman
static void sh_FontScript(PPC *c) { RET(0); }

// ---- files

// FSFindFolder(vRefNum, folderType, createFolder, FSRef *)
static void sh_FSFindFolder(PPC *c)
{
	NSString *p = fs_folder_path(A(1));
	BOOL d;
	if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&d]) {
		if (A(2) & 0xff)
			[NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
		else {
			RET(-43);   // fnfErr
			return;
		}
	}
	fs_make_ref_for(p.fileSystemRepresentation, A(3));
	RET_OK(c);
}

// PBHGetVolParmsSync(HParamBlockRec *): GetVolParmsInfoBuffer at ioBuffer
static void sh_PBHGetVolParmsSync(PPC *c)
{
	uint32_t pb = A(0), buf = LD32(pb + 32), n = LD32(pb + 36);
	uint8_t tmp[32] = {0};
	tmp[1] = 3;                                   // vMVersion
	uint32_t attr = (1u << 20) | (1u << 19) | (1u << 17) | (1u << 11);   // FSSpecs, long names, ...
	tmp[2] = attr >> 24, tmp[3] = attr >> 16, tmp[4] = attr >> 8, tmp[5] = attr;
	if (n > sizeof tmp)
		n = sizeof tmp;
	memcpy(G(buf), tmp, n);
	ST32(pb + 40, n);   // ioActCount
	ST16(pb + 16, 0);   // ioResult
	RET_OK(c);
}

// ---- CFURL

static void sh_CFURLCreateFromFSRef(PPC *c)
{
	char p[1024];
	if (!fsref_path(A(1), p, sizeof p)) {
		RET(0);
		return;
	}
	RET(cf_tok(CFBridgingRetain([NSURL fileURLWithPath:@(p)])));
}

static void sh_CFURLCreateCopyAppendingPathComponent(PPC *c)
{
	NSURL *u = (__bridge NSURL *)cf_obj(A(1));
	NSString *s = cf_string(A(2));
	if (!u || !s) {
		RET(0);
		return;
	}
	RET(cf_tok(CFBridgingRetain([u URLByAppendingPathComponent:s isDirectory:(A(3) & 0xff) != 0])));
}

// CFURLGetFSRef(url, FSRef *) -> Boolean
static void sh_CFURLGetFSRef(PPC *c)
{
	NSURL *u = (__bridge NSURL *)cf_obj(A(0));
	if (!u || !u.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:u.path]) {
		RET(0);
		return;
	}
	fs_make_ref_for(u.path.fileSystemRepresentation, A(1));
	RET(1);
}

// ---- MathLib and libm

static void sh_fabs(PPC *c) { FRET(fabs(c->f[1].d)); }
static void sh_sin(PPC *c) { FRET(sin(c->f[1].d)); }
static void sh_cos(PPC *c) { FRET(cos(c->f[1].d)); }
static void sh_tan(PPC *c) { FRET(tan(c->f[1].d)); }
static void sh_asin(PPC *c) { FRET(asin(c->f[1].d)); }
static void sh_acos(PPC *c) { FRET(acos(c->f[1].d)); }
static void sh_atan(PPC *c) { FRET(atan(c->f[1].d)); }
static void sh_atan2(PPC *c) { FRET(atan2(c->f[1].d, c->f[2].d)); }
static void sh_exp(PPC *c) { FRET(exp(c->f[1].d)); }
static void sh_log(PPC *c) { FRET(log(c->f[1].d)); }
static void sh_log2(PPC *c) { FRET(log2(c->f[1].d)); }
static void sh_fmod(PPC *c) { FRET(fmod(c->f[1].d, c->f[2].d)); }
// compound(rate, periods) = (1 + rate)^periods; annuity(rate, periods) = (1 - (1 + rate)^-periods) / rate
static void sh_compound(PPC *c) { FRET(pow(1 + c->f[1].d, c->f[2].d)); }
static void sh_annuity(PPC *c)
{
	double r = c->f[1].d, n = c->f[2].d;
	FRET(r == 0 ? n : (1 - pow(1 + r, -n)) / r);
}
// randomx(double *seed): Lehmer generator, 16807 mod 2^31-1
static void sh_randomx(PPC *c)
{
	double s = LDD(A(0));
	s = fmod(16807.0 * s, 2147483647.0);
	STD(A(0), s);
	FRET(s);
}
static void sh___inf(PPC *c) { FRET(INFINITY); }
static void sh___isnan(PPC *c) { RET(isnan(c->f[1].d)); }
static void sh___isnanf(PPC *c) { RET(isnan(c->f[1].d)); }
static void sh___isfinited(PPC *c) { RET(isfinite(c->f[1].d)); }
static void sh___signbit(PPC *c) { RET(signbit(c->f[1].d) != 0); }
static void sh___signbitd(PPC *c) { RET(signbit(c->f[1].d) != 0); }
// __fpclassify: MSL values FP_NAN 1, FP_INFINITE 2, FP_ZERO 3, FP_NORMAL 4, FP_SUBNORMAL 5
static int msl_class(double d)
{
	switch (fpclassify(d)) {
	case FP_NAN: return 1;
	case FP_INFINITE: return 2;
	case FP_ZERO: return 3;
	case FP_SUBNORMAL: return 5;
	default: return 4;
	}
}
static void sh___fpclassify(PPC *c) { RET(msl_class(c->f[1].d)); }
static void sh___fpclassifyd(PPC *c) { RET(msl_class(c->f[1].d)); }
// extended80 <-> double (long double is double here)
static void sh_dtox80(PPC *c) { d_to_x80(LDD(A(0)), A(1)); }
static void sh_ldtox80(PPC *c) { d_to_x80(LDD(A(0)), A(1)); }
static void sh_x80told(PPC *c) { STD(A(1), x80_to_d(A(0))); }

// str2dec(const char *s, short *ix, decimal *d, short *vp): parse a number
// at s[*ix] into a SANE decimal record (sgn, exp, sig as up to 36 digits)
static void sh_str2dec(PPC *c)
{
	const char *s = G(A(0));
	int ix = (int16_t)LD16(A(1));
	uint32_t d = A(2);
	const char *p = s + ix;
	int sgn = 0;
	while (*p == ' ' || *p == '\t')
		p++;
	if (*p == '+' || *p == '-')
		sgn = *p++ == '-';
	char dig[40];
	int nd = 0, exp = 0, any = 0;
	while (*p >= '0' && *p <= '9') {
		any = 1;
		if (nd < 36 && (nd || *p != '0'))
			dig[nd++] = *p;
		else if (nd >= 36)
			exp++;
		p++;
	}
	if (*p == '.') {
		p++;
		while (*p >= '0' && *p <= '9') {
			any = 1;
			if (nd < 36 && (nd || *p != '0')) {
				dig[nd++] = *p;
				exp--;
			} else if (!nd)
				exp--;
			p++;
		}
	}
	if (any && (*p == 'e' || *p == 'E')) {
		const char *q = p + 1;
		int es = 0, ev = 0, ok = 0;
		if (*q == '+' || *q == '-')
			es = *q++ == '-';
		while (*q >= '0' && *q <= '9')
			ev = ev * 10 + (*q++ - '0'), ok = 1;
		if (ok) {
			exp += es ? -ev : ev;
			p = q;
		}
	}
	if (!nd) {
		dig[nd++] = '0';
		exp = 0;
	}
	ST8(d, sgn);
	ST8(d + 1, 0);
	ST16(d + 2, (uint16_t)(int16_t)exp);
	ST8(d + 4, nd);
	memcpy(G(d + 5), dig, nd);
	ST16(A(1), (uint16_t)(p - s));
	ST8(A(3), any);   // valid prefix
}

// ---- Script Manager

// GetScriptVariable(script, selector): Roman on a US system
static void sh_GetScriptVariable(PPC *c)
{
	switch ((int16_t)A(1)) {
	case 0x0c: case 0x10: RET(1); break;          // smScriptSysFond / smScriptAppFond: Geneva... use applFont
	case 0x0e: case 0x12: RET(12); break;         // smScriptSysFondSize / smScriptAppFondSize
	case 0x0a: RET(0); break;                     // smScriptLang: English
	default: RET(0); break;
	}
}

// ---- Palette Manager and PixMaps (the screen is direct color: palettes have no effect)

// GetNewPalette(id): a copy of the 'pltt' resource
static void sh_GetNewPalette(PPC *c)
{
	uint32_t h = res_get('pltt', (int16_t)A(0), 0);
	RET(h ? NewHandleFrom(G(HP(h)), HSize(h)) : 0);
}
static void sh_SetEntryUsage(PPC *c) { (void)c; }

// NewPixMap(): a 32-bit direct PixMap with an empty color table
static void sh_NewPixMap(PPC *c)
{
	uint32_t h = NewHandleClearG(50), p = HP(h);
	uint32_t ct = NewHandleClearG(16);
	ST16(HP(ct) + 6, 0);            // ctSize: one entry
	ST16(p + 4, 0x8000);            // rowBytes: a PixMap
	ST32(p + 22, 72 << 16);         // hRes
	ST32(p + 26, 72 << 16);         // vRes
	ST16(p + 30, 16);               // pixelType: RGBDirect
	ST16(p + 32, 32);               // pixelSize
	ST16(p + 34, 3);                // cmpCount
	ST16(p + 36, 8);                // cmpSize
	ST32(p + 42, ct);               // pmTable
	RET(h);
}

// ---- Picture Utilities

// GetPictInfo(PicHandle, PictInfo *, verb, colorsRequested, colorPickMethod, version): the frame
// and resolution; no color survey
static void sh_GetPictInfo(PPC *c)
{
	uint32_t pic = A(0), pi = A(1);
	if (!is_handle(pic) || !HP(pic)) {
		RET(-128);
		return;
	}
	memset(G(pi), 0, 104);
	ST16(pi + 0, (uint16_t)A(5));        // version
	ST32(pi + 14, 72 << 16);             // hRes
	ST32(pi + 18, 72 << 16);             // vRes
	ST16(pi + 22, 32);                   // depth
	memcpy(G(pi + 24), G(HP(pic) + 2), 8);   // sourceRect: picFrame
	RET(0);
}

static const ShimDef awshims[] = {
	S(GetScriptVariable), S(GetNewPalette), S(SetEntryUsage), S(NewPixMap), S(GetPictInfo),
	S(FreeMem), S(MaxMem), S(PurgeSpace), S(CompactMem), S(PurgeMem), S(ReserveMem), S(StackSpace),
	S(TempFreeMem), S(TempMaxMem),
	S(Enqueue), S(Dequeue), S(EnterMovies), S(ExitMovies), S(NavServicesCanRun), S(NavLibraryVersion),
	S(FontToScript), S(FontScript), S(FSFindFolder), S(PBHGetVolParmsSync), S(CFURLCreateFromFSRef),
	S(CFURLCreateCopyAppendingPathComponent), S(CFURLGetFSRef),
	S(fabs), S(sin), S(cos), S(tan), S(asin), S(acos), S(atan), S(atan2), S(exp), S(log), S(log2), S(fmod),
	S(compound), S(annuity), S(randomx), S(__inf), S(__isnan), S(__isnanf), S(__isfinited), S(__signbit),
	S(__signbitd), S(__fpclassify), S(__fpclassifyd), S(dtox80), S(ldtox80), S(x80told), S(str2dec),
};
REGISTER(awshims)
