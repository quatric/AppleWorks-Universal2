// Inflate for Installer VISE 8 archive streams: deflate whose stored blocks
// start at a 16-bit boundary (VISE's decompressor reads 16-bit words).
// The input is already un-swapped and de-substituted.
// usage (as a library from Python via ctypes):
//   long vise_inflate(const unsigned char *in, long inlen, unsigned char *out, long outlen)
// returns bytes written, or -1 on a malformed stream.
#include <string.h>

typedef struct { const unsigned char *in; long inlen, pos; unsigned bitbuf; int bitcnt; } S;

static int bits(S *s, int n)
{
	while (s->bitcnt < n) {
		unsigned b = s->pos < s->inlen ? s->in[s->pos] : 0;
		s->pos++;
		s->bitbuf |= b << s->bitcnt;
		s->bitcnt += 8;
	}
	int v = s->bitbuf & ((1u << n) - 1);
	s->bitbuf >>= n;
	s->bitcnt -= n;
	return v;
}

typedef struct { short count[16], symbol[320]; } H;

static int build(H *h, const short *len, int n)
{
	short offs[16];
	memset(h->count, 0, sizeof h->count);
	for (int i = 0; i < n; i++) h->count[len[i]]++;
	h->count[0] = 0;
	offs[1] = 0;
	for (int i = 1; i < 15; i++) offs[i + 1] = offs[i] + h->count[i];
	for (int i = 0; i < n; i++) if (len[i]) h->symbol[offs[len[i]]++] = i;
	return 0;
}

static int decode(S *s, const H *h)
{
	int code = 0, first = 0, index = 0;
	for (int l = 1; l < 16; l++) {
		code |= bits(s, 1);
		int c = h->count[l];
		if (code - c < first) return h->symbol[index + (code - first)];
		index += c; first += c; first <<= 1; code <<= 1;
	}
	return -1;
}

static const short lbase[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
static const short lext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
static const short dbase[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
static const short dext[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};

static long codes(S *s, unsigned char *out, long o, long outlen, const H *lc, const H *dc)
{
	for (;;) {
		int sym = decode(s, lc);
		if (sym < 0) return -1;
		if (sym < 256) {
			if (o >= outlen) return o;
			out[o++] = sym;
		} else if (sym == 256) {
			return o;
		} else {
			sym -= 257;
			if (sym >= 29) return -1;
			int len = lbase[sym] + bits(s, lext[sym]);
			int ds = decode(s, dc);
			if (ds < 0 || ds >= 30) return -1;
			long dist = dbase[ds] + bits(s, dext[ds]);
			if (dist > o) return -1;
			while (len-- && o < outlen) { out[o] = out[o - dist]; o++; }
		}
	}
}

long vise_inflate(const unsigned char *in, long inlen, unsigned char *out, long outlen)
{
	S s = {in, inlen, 0, 0, 0};
	long o = 0;
	static H fl, fd;
	static int fixed;
	if (!fixed) {
		short l[288];
		int i;
		for (i = 0; i < 144; i++) l[i] = 8;
		for (; i < 256; i++) l[i] = 9;
		for (; i < 280; i++) l[i] = 7;
		for (; i < 288; i++) l[i] = 8;
		build(&fl, l, 288);
		for (i = 0; i < 30; i++) l[i] = 5;
		build(&fd, l, 30);
		fixed = 1;
	}
	int last;
	do {
		if (o >= outlen) break;
		last = bits(&s, 1);
		int type = bits(&s, 2);
		if (type == 0) {
			// drop the partial byte, then align to a 16-bit word
			s.bitbuf = 0; s.bitcnt = 0;
			if (s.pos & 1) s.pos++;
			if (s.pos + 4 > inlen) return -1;
			unsigned len = in[s.pos] | in[s.pos + 1] << 8, nlen = in[s.pos + 2] | in[s.pos + 3] << 8;
			s.pos += 4;
			if ((len ^ 0xffff) != nlen || s.pos + len > inlen) return -1;
			if (o + len > outlen) len = outlen - o;
			memcpy(out + o, in + s.pos, len);
			o += len; s.pos += len;
		} else if (type == 1) {
			o = codes(&s, out, o, outlen, &fl, &fd);
		} else if (type == 2) {
			static const short order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};
			int nlen = bits(&s, 5) + 257, ndist = bits(&s, 5) + 1, ncode = bits(&s, 4) + 4;
			short l[320];
			H lc, dc;
			memset(l, 0, sizeof l);
			for (int i = 0; i < ncode; i++) l[order[i]] = bits(&s, 3);
			build(&lc, l, 19);
			int i = 0;
			while (i < nlen + ndist) {
				int sym = decode(&s, &lc);
				if (sym < 0) return -1;
				if (sym < 16) l[i++] = sym;
				else {
					int len = 0, rep;
					if (sym == 16) { if (!i) return -1; len = l[i - 1]; rep = 3 + bits(&s, 2); }
					else if (sym == 17) rep = 3 + bits(&s, 3);
					else rep = 11 + bits(&s, 7);
					while (rep-- && i < nlen + ndist) l[i++] = len;
				}
			}
			build(&lc, l, nlen);
			build(&dc, l + nlen, ndist);
			o = codes(&s, out, o, outlen, &lc, &dc);
		} else return -1;
		if (o < 0) return -1;
	} while (!last);
	return o;
}
