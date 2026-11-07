// File Manager over POSIX paths: one volume (vRefNum -100, root directory 2
// = "/"), directory IDs given out as paths are met, FSSpecs, FSRefs (a path
// index inside the 80 bytes), data forks by reference number.
#import <Foundation/Foundation.h>
#include "ppcrt.h"
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>

enum { VREF = -100, ROOT_ID = 2 };

static NSMutableArray *dirs;          // dirID - 100 -> path
static NSMutableDictionary *dir_ids;  // path -> dirID
static NSMutableArray *refs;          // FSRef index -> path
static char default_dir[1024];

static int32_t dir_id(NSString *path)
{
	path = path.stringByStandardizingPath;
	if ([path isEqualToString:@"/"])
		return ROOT_ID;
	NSNumber *n = dir_ids[path];
	if (n)
		return n.intValue;
	[dirs addObject:path];
	int32_t id = 100 + (int32_t)dirs.count - 1;
	dir_ids[path] = @(id);
	return id;
}

static NSString *dir_path(int32_t id)
{
	if (id == ROOT_ID || id == 1)
		return @"/";
	if (id >= 100 && id - 100 < (int32_t)dirs.count)
		return dirs[id - 100];
	return nil;
}

void fs_init(void)
{
	dirs = [NSMutableArray new];
	dir_ids = [NSMutableDictionary new];
	refs = [NSMutableArray new];
	snprintf(default_dir, sizeof default_dir, "%s", ppc_app_dir);
}

// a Mac name component (Mac Roman, '/' allowed) -> host
static NSString *host_name(const uint8_t *s, size_t n)
{
	NSString *t = mac_ns(s, n);
	return [t stringByReplacingOccurrencesOfString:@"/" withString:@":"];
}

static NSString *mac_name(NSString *host) { return [host stringByReplacingOccurrencesOfString:@":" withString:@"/"]; }

// resolve vRefNum, dirID and a (partial) path name
static NSString *resolve(int16_t vref, int32_t dir, const uint8_t *name, size_t n)
{
	NSString *base;
	if (dir)
		base = dir_path(dir);
	else if (vref == VREF || vref == -1)
		base = @"/";
	else
		base = @(default_dir);
	if (!base)
		return nil;
	if (!n)
		return base;
	// a full path: "Volume:dir:file" (no leading colon, contains a colon)
	size_t i = 0;
	if (name[0] != ':' && memchr(name, ':', n)) {
		const uint8_t *e = memchr(name, ':', n);
		NSString *vol = host_name(name, e - name);
		NSString *root = @"/";
		if (![vol isEqualToString:@"Macintosh HD"] && ![vol isEqualToString:@":"] &&
			![vol isEqualToString:[NSFileManager.defaultManager displayNameAtPath:@"/"]])
			root = [@"/Volumes" stringByAppendingPathComponent:vol];
		base = root;
		i = e - name + 1;
	} else if (name[0] == ':')
		i = 1;
	NSString *p = base;
	while (i < n) {
		size_t j = i;
		while (j < n && name[j] != ':')
			j++;
		if (j == i) {
			p = p.stringByDeletingLastPathComponent;   // "::" goes up
		} else
			p = [p stringByAppendingPathComponent:host_name(name + i, j - i)];
		i = j + 1;
	}
	return p;
}

static void write_spec(uint32_t spec, NSString *path)
{
	path = path.stringByStandardizingPath;
	ST16(spec, VREF);
	ST32(spec + 2, dir_id(path.stringByDeletingLastPathComponent));
	NSString *nm = mac_name(path.lastPathComponent);
	ns_pstr(nm.length > 63 ? [nm substringToIndex:63] : nm, spec + 6);
}

int fs_make_spec_for(const char *path, uint32_t spec)
{
	write_spec(spec, @(path));
	return 0;
}

const char *fsspec_path(uint32_t spec, char *out, size_t n)
{
	if (!spec)
		return NULL;
	NSString *p = resolve((int16_t)LD16(spec), (int32_t)LD32(spec + 2), G(spec + 7), LD8(spec + 6));
	if (!p)
		return NULL;
	snprintf(out, n, "%s", p.fileSystemRepresentation);
	return out;
}

const char *fs_path3(int16_t vref, int32_t dir, uint32_t name, char *out, size_t n)
{
	NSString *p = resolve(vref, dir, name ? G(name + 1) : NULL, name ? LD8(name) : 0);
	if (!p)
		return NULL;
	snprintf(out, n, "%s", p.fileSystemRepresentation);
	return out;
}

static void write_ref(uint32_t ref, NSString *path)
{
	path = path.stringByStandardizingPath;
	NSUInteger i = [refs indexOfObject:path];
	if (i == NSNotFound) {
		[refs addObject:path];
		i = refs.count - 1;
	}
	memset(G(ref), 0, 80);
	ST32(ref, 'XLfr');
	ST32(ref + 4, (uint32_t)i);
}

int fs_make_ref_for(const char *path, uint32_t ref)
{
	write_ref(ref, @(path));
	return 0;
}

const char *fsref_path(uint32_t ref, char *out, size_t n)
{
	if (!ref || LD32(ref) != 'XLfr' || LD32(ref + 4) >= refs.count)
		return NULL;
	snprintf(out, n, "%s", [refs[LD32(ref + 4)] fileSystemRepresentation]);
	return out;
}

static BOOL exists(NSString *p, BOOL *isdir)
{
	return [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:isdir];
}

// Finder info: type and creator in com.apple.FinderInfo
void fs_set_type(const char *path, uint32_t type, uint32_t creator)
{
	uint8_t fi[32] = {0};
	getxattr(path, "com.apple.FinderInfo", fi, 32, 0, 0);
	uint32_t t = __builtin_bswap32(type), cr = __builtin_bswap32(creator);
	memcpy(fi, &t, 4);
	memcpy(fi + 4, &cr, 4);
	setxattr(path, "com.apple.FinderInfo", fi, 32, 0, 0);
}

static void get_type(const char *path, uint32_t *type, uint32_t *creator, uint16_t *flags)
{
	uint8_t fi[32] = {0};
	*type = *creator = 0;
	*flags = 0;
	if (getxattr(path, "com.apple.FinderInfo", fi, 32, 0, 0) == 32) {
		*type = (uint32_t)fi[0] << 24 | fi[1] << 16 | fi[2] << 8 | fi[3];
		*creator = (uint32_t)fi[4] << 24 | fi[5] << 16 | fi[6] << 8 | fi[7];
		*flags = (uint16_t)(fi[8] << 8 | fi[9]);
	}
	if (!*type) {
		NSString *ext = @(path).pathExtension.lowercaseString;
		if ([ext isEqualToString:@"txt"] || [ext isEqualToString:@"text"])
			*type = 'TEXT';
		else if ([ext isEqualToString:@"pict"] || [ext isEqualToString:@"pct"])
			*type = 'PICT';
	}
}

static uint32_t mac_date(time_t t) { return (uint32_t)(t + 2082844800u); }

// ---- FSSpec calls -----------------------------------------------------------------------------------

static void sh_FSMakeFSSpec(PPC *c)
{
	// FSMakeFSSpec(vRefNum, dirID, fileName, FSSpec *)
	uint32_t nm = A(2);
	NSString *p = resolve((int16_t)A(0), (int32_t)A(1), nm ? G(nm + 1) : NULL, nm ? LD8(nm) : 0);
	if (ppc_verbose >= 3)
		ppc_log("FSMakeFSSpec %d %d '%.*s' -> %s", (int16_t)A(0), (int32_t)A(1), nm ? LD8(nm) : 0, nm ? (char *)G(nm + 1) : "",
			p ? p.fileSystemRepresentation : "(none)");
	if (!p) {
		RET(-120);   // dirNFErr
		return;
	}
	BOOL d;
	if (!exists(p.stringByDeletingLastPathComponent, &d) || !d) {
		RET(-120);
		return;
	}
	write_spec(A(3), p);
	RET(exists(p, NULL) ? 0 : -43);
}

static void sh_FSpMakeFSRef(PPC *c)
{
	char p[1024];
	if (!fsspec_path(A(0), p, sizeof p) || !exists(@(p), NULL)) {
		RET(-43);
		return;
	}
	write_ref(A(1), @(p));
	RET(0);
}

static void sh_FSMakeFSRefUnicode(PPC *c)
{
	// FSMakeFSRefUnicode(parentRef, nameLength, const UniChar *name, encodingHint, FSRef *newRef)
	char p[1024];
	if (!fsref_path(A(0), p, sizeof p)) {
		RET(-35);
		return;
	}
	unichar *u = malloc(2 * (A(1) + 1));
	for (uint32_t i = 0; i < A(1); i++)
		u[i] = (unichar)LD16(A(2) + 2 * i);
	NSString *nm = [NSString stringWithCharacters:u length:A(1)];
	free(u);
	NSString *path = [@(p) stringByAppendingPathComponent:[nm stringByReplacingOccurrencesOfString:@"/" withString:@":"]];
	if (!exists(path, NULL)) {
		RET(-43);
		return;
	}
	write_ref(A(4), path);
	RET(0);
}

static void sh_FSCreateFileUnicode(PPC *c)
{
	// FSCreateFileUnicode(parentRef, nameLength, name, whichInfo, catalogInfo, FSRef *newRef, FSSpec *newSpec)
	char p[1024];
	if (!fsref_path(A(0), p, sizeof p)) {
		RET(-35);
		return;
	}
	unichar *u = malloc(2 * (A(1) + 1));
	for (uint32_t i = 0; i < A(1); i++)
		u[i] = (unichar)LD16(A(2) + 2 * i);
	NSString *nm = [NSString stringWithCharacters:u length:A(1)];
	free(u);
	NSString *path = [@(p) stringByAppendingPathComponent:[nm stringByReplacingOccurrencesOfString:@"/" withString:@":"]];
	if (exists(path, NULL)) {
		RET(-48);   // dupFNErr
		return;
	}
	if (![[NSData data] writeToFile:path atomically:NO]) {
		RET(-61);
		return;
	}
	if (A(4) && (A(3) & 0x800)) {   // kFSCatInfoFinderInfo: type and creator at +80 of FSCatalogInfo
		fs_set_type(path.fileSystemRepresentation, LD32(A(4) + 80), LD32(A(4) + 84));
	}
	if (A(5))
		write_ref(A(5), path);
	if (A(6))
		write_spec(A(6), path);
	RET(0);
}

static void sh_FSDeleteObject(PPC *c)
{
	char p[1024];
	if (!fsref_path(A(0), p, sizeof p)) {
		RET(-35);
		return;
	}
	RET(unlink(p) == 0 || rmdir(p) == 0 ? 0 : -43);
}

static void sh_FSGetDataForkName(PPC *c) { ST16(A(0), 0); RET(0); }

// ---- forks ------------------------------------------------------------------------------------------------

typedef struct { int fd; char path[1024]; } Fork;
static Fork forks[64];

static int16_t fork_open(const char *path, int perm)
{
	int flags = perm == 1 ? O_RDONLY : O_RDWR;
	int fd = open(path, flags);
	if (fd < 0 && perm != 1)
		fd = open(path, O_RDONLY);
	if (fd < 0)
		return 0;
	for (int i = 1; i < 64; i++)
		if (!forks[i].fd) {
			forks[i].fd = fd + 1;
			snprintf(forks[i].path, sizeof forks[i].path, "%s", path);
			return (int16_t)(i * 2 + 1000);
		}
	close(fd);
	return 0;
}

static int fork_fd(int16_t ref)
{
	int i = (ref - 1000) / 2;
	if (i < 1 || i >= 64 || !forks[i].fd)
		return -1;
	return forks[i].fd - 1;
}

static void sh_FSpOpenDF(PPC *c)
{
	char p[1024];
	if (!fsspec_path(A(0), p, sizeof p)) {
		RET(-120);
		return;
	}
	BOOL d;
	if (!exists(@(p), &d) || d) {
		RET(-43);
		return;
	}
	int16_t ref = fork_open(p, (int8_t)A(1));
	if (!ref) {
		RET(-54);   // permErr
		return;
	}
	ST16(A(2), ref);
	RET(0);
}

static void sh_FSRead(PPC *c)
{
	// FSRead(refNum, long *count, void *buffer)
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);   // rfNumErr
		return;
	}
	uint32_t want = LD32(A(1));
	ssize_t got = read(fd, G(A(2)), want);
	if (got < 0)
		got = 0;
	ST32(A(1), (uint32_t)got);
	RET((uint32_t)got < want ? -39 : 0);
}

static void sh_FSWrite(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	uint32_t want = LD32(A(1));
	ssize_t put = write(fd, G(A(2)), want);
	if (put < 0) {
		ST32(A(1), 0);
		RET(-61);   // wrPermErr
		return;
	}
	ST32(A(1), (uint32_t)put);
	RET(0);
}

static void sh_FSClose(PPC *c)
{
	int16_t ref = (int16_t)A(0);
	int fd = fork_fd(ref);
	if (fd < 0) {
		RET(-51);
		return;
	}
	close(fd);
	forks[(ref - 1000) / 2].fd = 0;
	RET(0);
}

static void sh_FSCloseFork(PPC *c)
{
	// resource files opened with FSOpenResourceFile are closed with CloseResFile; data forks here
	int16_t ref = (int16_t)A(0);
	if (fork_fd(ref) >= 0) {
		sh_FSClose(c);
		return;
	}
	RET(0);
}

static void sh_GetEOF(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	struct stat st;
	if (fd < 0 || fstat(fd, &st)) {
		RET(-51);
		return;
	}
	ST32(A(1), (uint32_t)st.st_size);
	RET(0);
}

static void sh_SetEOF(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	RET(fd >= 0 && ftruncate(fd, A(1)) == 0 ? 0 : -51);
}

static void sh_GetFPos(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	ST32(A(1), (uint32_t)lseek(fd, 0, SEEK_CUR));
	RET(0);
}

static void sh_SetFPos(PPC *c)
{
	// SetFPos(refNum, posMode, offset)
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	int mode = (int16_t)A(1) & 3;
	int32_t off = (int32_t)A(2);
	struct stat st;
	fstat(fd, &st);
	off_t cur = lseek(fd, 0, SEEK_CUR), to = cur;
	switch (mode) {
	case 0: to = cur; break;
	case 1: to = off; break;
	case 2: to = st.st_size + off; break;
	case 3: to = cur + off; break;
	}
	if (to < 0) {
		RET(-40);   // posErr
		return;
	}
	int err = 0;
	if (to > st.st_size) {
		to = st.st_size;
		err = -39;
	}
	lseek(fd, to, SEEK_SET);
	RET(err);
}


// ---- FSRef forks (FSOpenFork and the 64-bit fork calls) -------------------------------------

static int fork_index(int16_t ref) { return fork_fd(ref) >= 0 ? (ref - 1000) / 2 : -1; }

static off_t fork_seek(int fd, int mode, int64_t off, int *err)
{
	struct stat st;
	fstat(fd, &st);
	off_t cur = lseek(fd, 0, SEEK_CUR), to = cur;
	switch (mode & 3) {
	case 0: to = cur; break;
	case 1: to = off; break;
	case 2: to = st.st_size + off; break;
	case 3: to = cur + off; break;
	}
	*err = 0;
	if (to < 0) {
		*err = -40;
		return cur;
	}
	return to;
}


// FSOpenFork(ref, nameLength, UniChar *name, permissions, short *refNum)
static void sh_FSOpenFork(PPC *c)
{
	char p[1024];
	if (!fsref_path(A(0), p, sizeof p)) {
		RET(-35);   // nsvErr
		return;
	}
	BOOL d;
	if (!exists(@(p), &d) || d) {
		RET(-43);
		return;
	}
	int rsrc = 0;
	uint32_t n = A(1);
	if (n && A(2)) {
		// "RESOURCE_FORK"
		rsrc = n == 13 && LD16(A(2)) == 'R';
	}
	char q[1100];
	snprintf(q, sizeof q, rsrc ? "%s/..namedfork/rsrc" : "%s", p);
	int perm = (int8_t)A(3);
	if (rsrc && perm != 1) {
		int fd = open(q, O_RDWR | O_CREAT, 0644);
		if (fd >= 0)
			close(fd);
	}
	int16_t ref = fork_open(q, perm);
	if (!ref) {
		RET(rsrc ? -39 : -54);
		return;
	}
	if (A(4))
		ST16(A(4), ref);
	RET(0);
}

// FSReadFork(ref, mode, SInt64 offset, count, buffer, *actual)
static void sh_FSReadFork(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	int err;
	off_t to = fork_seek(fd, (int16_t)A(1), (int64_t)((uint64_t)A(2) << 32 | A(3)), &err);
	if (err) {
		if (A(6)) ST32(A(6), 0);
		RET(err);
		return;
	}
	lseek(fd, to, SEEK_SET);
	uint32_t want = A(4);
	ssize_t got = want ? read(fd, G(A(5)), want) : 0;
	if (got < 0)
		got = 0;
	if (A(6))
		ST32(A(6), (uint32_t)got);
	RET((uint32_t)got < want ? -39 : 0);
}

static void sh_FSWriteFork(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	int err;
	off_t to = fork_seek(fd, (int16_t)A(1), (int64_t)((uint64_t)A(2) << 32 | A(3)), &err);
	if (err) {
		if (A(6)) ST32(A(6), 0);
		RET(err);
		return;
	}
	lseek(fd, to, SEEK_SET);
	ssize_t put = A(4) ? write(fd, G(A(5)), A(4)) : 0;
	if (A(6))
		ST32(A(6), put < 0 ? 0 : (uint32_t)put);
	RET(put < 0 ? -61 : 0);
}

// FSSetForkPosition(ref, mode, SInt64 offset)
static void sh_FSSetForkPosition(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	int err;
	off_t to = fork_seek(fd, (int16_t)A(1), (int64_t)((uint64_t)A(2) << 32 | A(3)), &err);
	if (!err) {
		struct stat st;
		fstat(fd, &st);
		if (to > st.st_size) {
			to = st.st_size;
			err = -39;
		}
		lseek(fd, to, SEEK_SET);
	}
	RET(err);
}

static void sh_FSGetForkPosition(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	ST64(A(1), lseek(fd, 0, SEEK_CUR));
	RET(0);
}

static void sh_FSGetForkSize(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	struct stat st;
	if (fd < 0 || fstat(fd, &st)) {
		RET(-51);
		return;
	}
	ST64(A(1), st.st_size);
	RET(0);
}

// FSSetForkSize(ref, mode, SInt64 offset)
static void sh_FSSetForkSize(PPC *c)
{
	int fd = fork_fd((int16_t)A(0));
	if (fd < 0) {
		RET(-51);
		return;
	}
	int err;
	off_t to = fork_seek(fd, (int16_t)A(1), (int64_t)((uint64_t)A(2) << 32 | A(3)), &err);
	RET(err ? err : ftruncate(fd, to) ? -34 : 0);
}

static void sh_FSFlushFork(PPC *c) { RET(fork_fd((int16_t)A(0)) >= 0 ? 0 : -51); }

// FSGetForkCBInfo(refNum, volume, short *iterator, short *actualRefNum, FSForkInfo *, FSRef *, HFSUniStr255 *)
static void sh_FSGetForkCBInfo(PPC *c)
{
	int16_t ref = (int16_t)A(0);
	if (!ref && A(2)) {
		// iterate the open forks
		int it = (int16_t)LD16(A(2));
		int i = it ? (it - 1000) / 2 + 1 : 1;
		for (; i < 64 && !forks[i].fd; i++)
			;
		if (i >= 64) {
			RET(-1302);   // errFSNoMoreItems
			return;
		}
		ref = (int16_t)(i * 2 + 1000);
		ST16(A(2), ref);
	}
	int i = fork_index(ref);
	if (i < 0) {
		RET(-51);
		return;
	}
	int fd = forks[i].fd - 1;
	char base[1024];
	snprintf(base, sizeof base, "%s", forks[i].path);
	char *nf = strstr(base, "/..namedfork/");
	int rsrc = nf != NULL;
	if (nf)
		*nf = 0;
	if (A(3))
		ST16(A(3), ref);
	if (A(4)) {
		struct stat st;
		fstat(fd, &st);
		uint32_t fi = A(4);
		memset(G(fi), 0, 48);
		ST8(fi + 1, 3);
		ST16(fi + 2, (uint16_t)-1);
		ST32(fi + 8, (uint32_t)st.st_ino);
		ST32(fi + 12, rsrc);
		ST64(fi + 16, lseek(fd, 0, SEEK_CUR));
		ST64(fi + 24, st.st_size);
		ST64(fi + 32, (st.st_size + 511) & ~511LL);
	}
	if (A(5))
		write_ref(A(5), @(base));
	if (A(6)) {
		static const char *rn = "RESOURCE_FORK";
		uint32_t u = A(6);
		int n = rsrc ? 13 : 0;
		ST16(u, n);
		for (int k = 0; k < n; k++)
			ST16(u + 2 + 2 * k, rn[k]);
	}
	RET(0);
}

static void sh_FSpCreate(PPC *c)
{
	// FSpCreate(spec, creator, fileType, scriptTag)
	char p[1024];
	if (!fsspec_path(A(0), p, sizeof p)) {
		RET(-120);
		return;
	}
	if (exists(@(p), NULL)) {
		RET(-48);
		return;
	}
	int fd = open(p, O_CREAT | O_WRONLY | O_EXCL, 0644);
	if (fd < 0) {
		RET(-120);
		return;
	}
	close(fd);
	fs_set_type(p, A(2), A(1));
	RET(0);
}

static void sh_FSpDelete(PPC *c)
{
	char p[1024];
	if (!fsspec_path(A(0), p, sizeof p)) {
		RET(-120);
		return;
	}
	RET(unlink(p) == 0 || rmdir(p) == 0 ? 0 : -43);
}

// HParamBlockRec: ioResult 16, ioNamePtr 18, ioVRefNum 22, ioDirID 48
static NSString *hpb_path(uint32_t pb)
{
	uint32_t np = LD32(pb + 18);
	return resolve((int16_t)LD16(pb + 22), (int32_t)LD32(pb + 48), np ? G(np + 1) : NULL, np ? LD8(np) : 0);
}
static void pb_done(PPC *c, uint32_t pb, int16_t err)
{
	ST16(pb + 16, (uint16_t)err);
	RET((uint32_t)(int32_t)err);
}
static void sh_PBHCreateSync(PPC *c)
{
	NSString *p = hpb_path(A(0));
	if (!p) {
		pb_done(c, A(0), -120);
		return;
	}
	if (exists(p, NULL)) {
		pb_done(c, A(0), -48);
		return;
	}
	int fd = open(p.fileSystemRepresentation, O_CREAT | O_WRONLY | O_EXCL, 0644);
	if (fd >= 0)
		close(fd);
	pb_done(c, A(0), fd >= 0 ? 0 : -120);
}
static void sh_PBHDeleteSync(PPC *c)
{
	NSString *p = hpb_path(A(0));
	const char *s = p.fileSystemRepresentation;
	pb_done(c, A(0), !p ? -120 : unlink(s) == 0 || rmdir(s) == 0 ? 0 : -43);
}

static void write_unistr255(uint32_t a, NSString *s)
{
	NSUInteger n = s.length > 255 ? 255 : s.length;
	ST16(a, (uint16_t)n);
	for (NSUInteger i = 0; i < n; i++)
		ST16(a + 2 + 2 * (uint32_t)i, [s characterAtIndex:i]);
}
static void write_utc(uint32_t a, struct timespec t)
{
	ST16(a, 0);
	ST32(a + 2, (uint32_t)(t.tv_sec + 2082844800u));
	ST16(a + 6, (uint16_t)(t.tv_nsec * 65536.0 / 1e9));
}

// FSGetCatalogInfo(ref, whichInfo, FSCatalogInfo *, HFSUniStr255 *outName, FSSpec *, FSRef *parentRef)
static void sh_FSGetCatalogInfo(PPC *c)
{
	char p[1024];
	if (!fsref_path(A(0), p, sizeof p)) {
		RET(-35);
		return;
	}
	struct stat st;
	if (stat(p, &st)) {
		RET(-43);
		return;
	}
	NSString *ps = @(p);
	int dir = S_ISDIR(st.st_mode);
	uint32_t ci = A(2), want = A(1);
	if (ci) {
		memset(G(ci), 0, 144);
		ST16(ci, dir ? 0x10 : 0);                                   // nodeFlags: kFSNodeIsDirectoryMask
		ST16(ci + 2, (uint16_t)VREF);                                // volume
		ST32(ci + 4, (uint32_t)dir_id(ps.stringByDeletingLastPathComponent));   // parentDirID
		ST32(ci + 8, dir ? (uint32_t)dir_id(ps) : (uint32_t)st.st_ino);         // nodeID
		write_utc(ci + 16, st.st_birthtimespec);                     // createDate
		write_utc(ci + 24, st.st_mtimespec);                         // contentModDate
		write_utc(ci + 32, st.st_ctimespec);                         // attributeModDate
		write_utc(ci + 40, st.st_atimespec);                         // accessDate
		ST32(ci + 56, st.st_uid);                                    // permissions: owner, group, mode
		ST32(ci + 60, st.st_gid);
		ST16(ci + 66, (uint16_t)(st.st_mode & 07777));
		if (dir) {
			int n = 0;
			DIR *d = opendir(p);
			for (struct dirent *e; d && (e = readdir(d));)
				if (e->d_name[0] != '.')
					n++;
			if (d)
				closedir(d);
			ST32(ci + 136, (uint32_t)n);                             // valence
		} else {
			uint32_t t, cr;
			uint16_t fl;
			get_type(p, &t, &cr, &fl);
			ST32(ci + 72, t);                                        // finderInfo: FileInfo
			ST32(ci + 76, cr);
			ST16(ci + 80, fl);
			ST64(ci + 104, (uint64_t)st.st_size);                    // dataLogicalSize
			ST64(ci + 112, (uint64_t)(st.st_blocks * 512));
			char q[1100];
			snprintf(q, sizeof q, "%s/..namedfork/rsrc", p);
			struct stat rs;
			if (stat(q, &rs) == 0) {
				ST64(ci + 120, (uint64_t)rs.st_size);                // rsrcLogicalSize
				ST64(ci + 128, (uint64_t)((rs.st_size + 4095) / 4096 * 4096));
			}
		}
	}
	(void)want;
	if (A(3))
		write_unistr255(A(3), [ps isEqualToString:@"/"] ? @"Macintosh HD" : mac_name(ps.lastPathComponent));
	if (A(4))
		write_spec(A(4), ps);
	if (A(5))
		write_ref(A(5), ps.stringByDeletingLastPathComponent);
	RET(0);
}

static void sh_FSpDirCreate(PPC *c)
{
	char p[1024];
	if (!fsspec_path(A(0), p, sizeof p)) {
		RET(-120);
		return;
	}
	if (exists(@(p), NULL)) {
		RET(-48);
		return;
	}
	if (mkdir(p, 0755)) {
		RET(-120);
		return;
	}
	if (A(2))
		ST32(A(2), dir_id(@(p)));
	RET(0);
}

static void sh_FSpGetFInfo(PPC *c)
{
	char p[1024];
	BOOL d;
	if (!fsspec_path(A(0), p, sizeof p) || !exists(@(p), &d) || d) {
		RET(-43);
		return;
	}
	uint32_t t, cr;
	uint16_t fl;
	get_type(p, &t, &cr, &fl);
	uint32_t fi = A(1);
	memset(G(fi), 0, 16);
	ST32(fi, t);
	ST32(fi + 4, cr);
	ST16(fi + 8, fl);
	RET(0);
}

static void sh_FSpSetFInfo(PPC *c)
{
	char p[1024];
	if (!fsspec_path(A(0), p, sizeof p) || !exists(@(p), NULL)) {
		RET(-43);
		return;
	}
	fs_set_type(p, LD32(A(1)), LD32(A(1) + 4));
	RET(0);
}

static void sh_FSpExchangeFiles(PPC *c)
{
	char a[1024], b[1024];
	if (!fsspec_path(A(0), a, sizeof a) || !fsspec_path(A(1), b, sizeof b)) {
		RET(-43);
		return;
	}
	char t[1100];
	snprintf(t, sizeof t, "%s.xlswap", a);
	if (rename(a, t) || rename(b, a) || rename(t, b)) {
		RET(-43);
		return;
	}
	RET(0);
}

// ---- catalog information ---------------------------------------------------------------------------------

static NSArray *listing(NSString *dir)
{
	NSArray *a = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
	NSMutableArray *v = [NSMutableArray array];
	for (NSString *s in [a sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
		if (![s hasPrefix:@"."] || [s hasPrefix:@".World Book"])
			[v addObject:s];
	return v;
}

static void sh_PBGetCatInfoSync(PPC *c)
{
	uint32_t pb = A(0);
	int16_t vref = (int16_t)LD16(pb + 22);
	int16_t index = (int16_t)LD16(pb + 28);
	int32_t dir = (int32_t)LD32(pb + 48);
	uint32_t namep = LD32(pb + 18);
	NSString *path;
	if (index > 0) {
		NSString *d = resolve(vref, dir, NULL, 0);
		NSArray *l = d ? listing(d) : nil;
		if (!l || index > (int)l.count) {
			ST16(pb + 16, -43);
			RET(-43);
			return;
		}
		path = [d stringByAppendingPathComponent:l[index - 1]];
		if (namep)
			ns_pstr([path isEqualToString:@"/"] ? @"Macintosh HD" : mac_name([path lastPathComponent]), namep);
	} else if (index < 0) {
		path = resolve(vref, dir, NULL, 0);
		if (namep && path)
			ns_pstr([path isEqualToString:@"/"] ? @"Macintosh HD" : mac_name([path lastPathComponent]), namep);
	} else {
		path = resolve(vref, dir, namep ? G(namep + 1) : NULL, namep ? LD8(namep) : 0);
	}
	BOOL d;
	if (!path || !exists(path, &d)) {
		ST16(pb + 16, -43);
		RET(-43);
		return;
	}
	struct stat st;
	stat(path.fileSystemRepresentation, &st);
	ST16(pb + 22, VREF);
	if (d) {
		ST8(pb + 30, 0x10);
		memset(G(pb + 32), 0, 16);
		ST32(pb + 48, dir_id(path));
		ST16(pb + 52, (uint16_t)listing(path).count);
		ST32(pb + 72, mac_date(st.st_birthtime));
		ST32(pb + 76, mac_date(st.st_mtime));
		ST32(pb + 100, dir_id(path.stringByDeletingLastPathComponent));
	} else {
		ST8(pb + 30, 0);
		uint32_t t, cr;
		uint16_t fl;
		get_type(path.fileSystemRepresentation, &t, &cr, &fl);
		memset(G(pb + 32), 0, 16);
		ST32(pb + 32, t);
		ST32(pb + 36, cr);
		ST16(pb + 40, fl);
		ST32(pb + 54, (uint32_t)st.st_size);
		ST32(pb + 58, (uint32_t)((st.st_size + 511) & ~511));
		ssize_t rl = getxattr(path.fileSystemRepresentation, "com.apple.ResourceFork", NULL, 0, 0, 0);
		ST32(pb + 64, rl > 0 ? (uint32_t)rl : 0);
		ST32(pb + 72, mac_date(st.st_birthtime));
		ST32(pb + 76, mac_date(st.st_mtime));
		ST32(pb + 100, dir_id(path.stringByDeletingLastPathComponent));
	}
	ST16(pb + 16, 0);
	RET(0);
}

static void sh_PBSetCatInfoSync(PPC *c)
{
	uint32_t pb = A(0);
	uint32_t namep = LD32(pb + 18);
	NSString *path = resolve((int16_t)LD16(pb + 22), (int32_t)LD32(pb + 48), namep ? G(namep + 1) : NULL, namep ? LD8(namep) : 0);
	BOOL d;
	if (path && exists(path, &d) && !d)
		fs_set_type(path.fileSystemRepresentation, LD32(pb + 32), LD32(pb + 36));
	ST16(pb + 16, 0);
	RET(0);
}

static void sh_PBHGetVInfoSync(PPC *c)
{
	uint32_t pb = A(0);
	if (LD32(pb + 18))
		c2p("Macintosh HD", LD32(pb + 18));
	ST16(pb + 22, VREF);
	ST32(pb + 30, mac_date(0));      // ioVCrDate
	ST32(pb + 34, mac_date(time(NULL)));
	ST16(pb + 46, 0);                // ioVAtrb
	ST16(pb + 48, 1000);             // ioVNmFls
	ST16(pb + 52, 0xfffe);           // ioVNmAlBlks
	ST32(pb + 54, 32768);            // ioVAlBlkSiz
	ST16(pb + 70, 0xfff0);           // ioVFrBlk
	ST16(pb + 16, 0);
	RET(0);
}

static void sh_PBXGetVolInfoSync(PPC *c)
{
	sh_PBHGetVInfoSync(c);
	uint32_t pb = A(0);
	ST64(pb + 76, 1ull << 40);   // ioVTotalBytes
	ST64(pb + 84, 1ull << 39);   // ioVFreeBytes
	RET(0);
}

static void sh_FlushVol(PPC *c) { RET(0); }

NSString *fs_folder_path(uint32_t type)
{
	NSString *home = NSHomeDirectory(), *p;
	switch (type) {
	case 'pref': p = [home stringByAppendingPathComponent:@"Library/Preferences"]; break;
	case 'temp': case 'tmp ': p = NSTemporaryDirectory(); break;
	case 'desk': p = [home stringByAppendingPathComponent:@"Desktop"]; break;
	case 'docs': p = [home stringByAppendingPathComponent:@"Documents"]; break;
	case 'asup': p = [home stringByAppendingPathComponent:@"Library/Application Support"]; break;
	case 'trsh': p = [home stringByAppendingPathComponent:@".Trash"]; break;
	case 'apps': p = @"/Applications"; break;
	case 'macs': p = @"/System"; break;
	case 'font': p = [home stringByAppendingPathComponent:@"Library/Fonts"]; break;
	default: p = [home stringByAppendingPathComponent:@"Library/Application Support"]; break;
	}
	return p;
}

static void sh_FindFolder(PPC *c)
{
	// FindFolder(vRefNum, folderType, createFolder, short *foundVRefNum, long *foundDirID)
	NSString *p = fs_folder_path(A(1));
	BOOL d;
	if (!exists(p, &d)) {
		if (A(2) & 0xff)
			[NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
		else {
			RET(-43);
			return;
		}
	}
	ST16(A(3), VREF);
	ST32(A(4), dir_id(p));
	RET(0);
}

static void sh_NewAlias(PPC *c)
{
	// NewAlias(fromFile, target, AliasHandle *): the path, enough for the guest to keep around
	char p[1024];
	const char *path = fsspec_path(A(1), p, sizeof p);
	uint32_t n = path ? (uint32_t)strlen(path) : 0;
	uint32_t h = NewHandleClearG(8 + n);
	ST32(HP(h), 0);
	ST16(HP(h) + 4, 8 + n);
	if (n)
		memcpy(G(HP(h) + 8), path, n);
	ST32(A(2), h);
	RET(0);
}

static const ShimDef fileshims[] = {
	S(FSMakeFSSpec), S(FSpMakeFSRef), S(FSMakeFSRefUnicode), S(FSCreateFileUnicode), S(FSDeleteObject),
	S(FSGetDataForkName), S(FSpOpenDF), S(FSRead), S(FSWrite), S(FSClose), S(FSCloseFork), S(GetEOF), S(SetEOF),
	S(GetFPos), S(SetFPos), S(FSpCreate), S(FSpDelete), S(PBHCreateSync), S(PBHDeleteSync), S(FSGetCatalogInfo), S(FSpDirCreate), S(FSpGetFInfo), S(FSpSetFInfo),
	S(FSpExchangeFiles), S(PBGetCatInfoSync), S(PBSetCatInfoSync), S(PBHGetVInfoSync), S(PBXGetVolInfoSync),
	S(FlushVol), S(FindFolder), S(NewAlias), S(FSOpenFork), S(FSReadFork), S(FSWriteFork),
	S(FSSetForkPosition), S(FSGetForkPosition), S(FSGetForkSize), S(FSSetForkSize), S(FSFlushFork), S(FSGetForkCBInfo),
};
REGISTER(fileshims)
