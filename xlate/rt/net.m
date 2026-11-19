// Open Transport (TCP endpoints, Internet services) and Internet Config.
//
// Endpoints are TCP connections over BSD sockets, in synchronous or asynchronous mode; an asynchronous
// endpoint's notifier is called from the event loop (as a deferred task would be), never from inside
// the call that started the work.
//
// Web mirror: the servers the application's Starting Points talk to (awpicts.apple.com) are long gone.
// A host with a folder in the bundle's "Web Mirror" (Web Mirror/<host>/<path>) resolves to a private
// loopback address, and its requests are answered here from those files, as an HTTP/1.0 server would.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ppcrt.h"

enum { TAG_EP = 'otep', TAG_SVC = 'otsv', TAG_CFG = 'otcf' };

// results: kOTNoDataErr and the rest, from the SDK's MacErrors.h
// events
enum {
	T_CONNECT = 0x2, T_DATA = 0x4, T_DISCONNECT = 0x10, T_ORDREL = 0x80, T_GODATA = 0x100,
	T_BINDCOMPLETE = 0x20000001, T_UNBINDCOMPLETE = 0x20000002, T_DISCONNECTCOMPLETE = 0x20000005,
	T_OPTMGMTCOMPLETE = 0x20000006, T_GETPROTADDRCOMPLETE = 0x20000008,
	T_DNRSTRINGTOADDRCOMPLETE = 0x10000001, T_DNRADDRTONAMECOMPLETE = 0x10000002,
};
// endpoint states
enum { T_UNBND = 1, T_IDLE = 2, T_OUTCON = 3, T_DATAXFER = 5, T_OUTREL = 6, T_INREL = 7 };

typedef struct Ev { uint32_t code, cookie; int32_t result; } OtEv;

typedef struct Ep {
	uint32_t tok;
	int svc;                      // Internet services, not an endpoint
	int async, acking;
	uint32_t notifier, context;
	int state;
	int fd;                       // a real connection, or -1
	int mirror;                   // a mirrored host's connection (index + 1)
	uint32_t connect_cookie;      // the TCall an asynchronous connect was given
	uint32_t peer_host;           // network order not kept: host order
	uint16_t peer_port;
	NSMutableData *in;            // bytes waiting for OTRcv
	NSMutableData *req;           // a mirrored connection's request so far
	int eof;                      // the peer has finished sending (orderly release pending)
	int discon;                   // the connection was reset or refused
	int data_told;                // T_DATA delivered, not yet drained
	int ordrel_told, discon_told, connect_pending, connect_told;
	OtEv q[16];
	int nq;
	struct Ep *next;
} Ep;

static Ep *eps;
static int net_verbose = -1;
#define NLOG(...) do { if (net_verbose) ppc_log(__VA_ARGS__); } while (0)

static Ep *EP(uint32_t t)
{
	Ep *e = t ? tok_get(t, TAG_EP) : NULL;
	return e ? e : t ? tok_get(t, TAG_SVC) : NULL;
}

static void post(Ep *e, uint32_t code, int32_t result, uint32_t cookie)
{
	if (!e->notifier || e->nq >= 16)
		return;
	e->q[e->nq++] = (OtEv){code, cookie, result};
}

// ---- the mirror ----------------------------------------------------------------------------------

static NSMutableArray<NSString *> *mirror_hosts;
static NSString *mirror_root(void) { return [@(ppc_app_dir) stringByAppendingPathComponent:@"Web Mirror"]; }
enum { MIRROR_NET = 0x7f4d0000 };   // 127.77.x.y: the mirror's hosts, by index

static int mirror_index(const char *host)
{
	if (!mirror_hosts)
		mirror_hosts = [NSMutableArray new];
	NSString *h = @(host).lowercaseString;
	NSUInteger i = [mirror_hosts indexOfObject:h];
	if (i != NSNotFound)
		return (int)i + 1;
	BOOL d;
	if (![NSFileManager.defaultManager fileExistsAtPath:[mirror_root() stringByAppendingPathComponent:h] isDirectory:&d] || !d)
		return 0;
	[mirror_hosts addObject:h];
	return (int)mirror_hosts.count;
}

static NSString *http_date(time_t t)
{
	char b[64];
	struct tm tm;
	gmtime_r(&t, &tm);
	strftime(b, sizeof b, "%a, %d %b %Y %H:%M:%S GMT", &tm);
	return @(b);
}

// a whole request is in: the response goes to the connection's input, then the server closes
static void mirror_answer(Ep *e)
{
	const char *r = e->req.bytes;
	NSUInteger n = e->req.length;
	NSString *text = [[NSString alloc] initWithBytes:r length:n encoding:NSISOLatin1StringEncoding];
	NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
	NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
	NSString *method = first.count > 0 ? first[0] : @"", *target = first.count > 1 ? first[1] : @"/";
	NSString *ims = nil;
	for (NSString *l in lines)
		if ([l.lowercaseString hasPrefix:@"if-modified-since:"])
			ims = [[l substringFromIndex:18] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	// an absolute URL (as to a proxy) or a path
	NSString *path = target;
	if ([path hasPrefix:@"http://"]) {
		NSRange s = [path rangeOfString:@"/" options:0 range:NSMakeRange(7, path.length - 7)];
		path = s.location == NSNotFound ? @"/" : [path substringFromIndex:s.location];
	}
	NSRange q = [path rangeOfString:@"?"];
	if (q.location != NSNotFound)
		path = [path substringToIndex:q.location];
	path = path.stringByRemovingPercentEncoding ?: path;
	NSString *host = mirror_hosts[e->mirror - 1];
	NSString *file = [[mirror_root() stringByAppendingPathComponent:host] stringByAppendingPathComponent:path];
	file = file.stringByStandardizingPath;
	struct stat st;
	int ok = [file hasPrefix:[mirror_root() stringByAppendingPathComponent:host]] && stat(file.fileSystemRepresentation, &st) == 0
		&& S_ISREG(st.st_mode);
	NSMutableString *h = [NSMutableString string];
	NSData *body = nil;
	if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"]) {
		[h appendString:@"HTTP/1.0 501 Not Implemented\r\n"];
		body = [@"Not implemented\n" dataUsingEncoding:NSASCIIStringEncoding];
	} else if (!ok && [path hasSuffix:@"6-1.cwk.gz"]) {
		// a Starting Points Web tab item with no surviving copy (Extras): "not modified", so the app
		// keeps its placeholder instead of alerting "Unable to locate the requested item" at every visit
		[h appendString:@"HTTP/1.0 304 Not Modified\r\n"];
	} else if (!ok) {
		[h appendString:@"HTTP/1.0 404 Not Found\r\n"];
		body = [@"<HTML><BODY>Not found</BODY></HTML>\n" dataUsingEncoding:NSASCIIStringEncoding];
		[h appendString:@"Content-Type: text/html\r\n"];
	} else {
		NSString *lm = http_date(st.st_mtime);
		if (ims && [ims isEqualToString:lm]) {
			[h appendString:@"HTTP/1.0 304 Not Modified\r\n"];
			[h appendFormat:@"Last-Modified: %@\r\n", lm];
		} else {
			[h appendString:@"HTTP/1.0 200 OK\r\n"];
			[h appendFormat:@"Last-Modified: %@\r\n", lm];
			NSString *ext = file.pathExtension.lowercaseString;
			[h appendFormat:@"Content-Type: %@\r\n", [ext isEqualToString:@"gz"] ? @"application/x-gzip"
				: [ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"] ? @"text/html" : @"application/x-binary"];
			body = [NSData dataWithContentsOfFile:file];
		}
	}
	[h appendFormat:@"Date: %@\r\nServer: AppleWorks Web Mirror\r\nConnection: close\r\n", http_date(time(NULL))];
	if (body)
		[h appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
	[h appendString:@"\r\n"];
	NLOG("net: mirror %s %s%s -> %s", method.UTF8String, host.UTF8String, path.UTF8String,
		[[lines.count ? h : @"" componentsSeparatedByString:@"\r\n"].firstObject UTF8String]);
	[e->in appendData:[h dataUsingEncoding:NSISOLatin1StringEncoding]];
	if (body && ![method isEqualToString:@"HEAD"])
		[e->in appendData:body];
	e->eof = 1;
	[e->req setLength:0];
}

// ---- moving bytes ---------------------------------------------------------------------------------

// what a real connection has for us now (never blocks)
static void pull(Ep *e)
{
	if (e->fd < 0 || e->eof || e->discon)
		return;
	for (;;) {
		char b[16384];
		ssize_t n = recv(e->fd, b, sizeof b, 0);
		if (n > 0) {
			[e->in appendBytes:b length:(NSUInteger)n];
			continue;
		}
		if (n == 0)
			e->eof = 1;
		else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
			e->discon = 1;
		break;
	}
}

// the endpoint's pending events, for its notifier
static void events(Ep *e)
{
	if (e->connect_pending && e->fd >= 0) {
		struct pollfd p = {e->fd, POLLOUT, 0};
		if (poll(&p, 1, 0) > 0) {
			int err = 0;
			socklen_t l = sizeof err;
			getsockopt(e->fd, SOL_SOCKET, SO_ERROR, &err, &l);
			e->connect_pending = 0;
			if (err) {
				e->discon = 1;
				e->state = T_IDLE;
			} else
				e->connect_told = 1;
			post(e, err ? T_DISCONNECT : T_CONNECT, 0, err ? 0 : e->connect_cookie);
		}
		return;
	}
	if (e->state != T_DATAXFER && e->state != T_OUTREL)
		return;
	pull(e);
	if (e->in.length && !e->data_told) {
		e->data_told = 1;
		post(e, T_DATA, 0, 0);
	} else if (!e->in.length && e->eof && !e->ordrel_told) {
		e->ordrel_told = 1;
		post(e, T_ORDREL, 0, 0);
	} else if (!e->in.length && e->discon && !e->discon_told) {
		e->discon_told = 1;
		post(e, T_DISCONNECT, 0, 0);
	}
}

// from the event loop: the notifiers' events
void net_run(void)
{
	static int running;
	if (running || !eps)
		return;
	running = 1;
	for (Ep *e = eps; e; e = e->next)
		if (!e->svc && e->notifier)
			events(e);
	for (int pass = 0; pass < 8; pass++) {
		int any = 0;
		for (Ep *e = eps; e; e = e->next) {
			if (!e->nq)
				continue;
			OtEv v = e->q[0];
			memmove(e->q, e->q + 1, sizeof *e->q * (size_t)--e->nq);
			any = 1;
			NLOG("net: notify %08x event %08x result %d", e->tok, v.code, v.result);
			ppc_cb4(e->notifier, e->context, v.code, (uint32_t)v.result, v.cookie);
			break;   // the list may have changed
		}
		if (!any)
			break;
	}
	running = 0;
}

// ---- Open Transport ---------------------------------------------------------------------------------

static void sh_InitOpenTransportInContext(PPC *c)
{
	if (net_verbose < 0)
		net_verbose = getenv("PPC_DBG_NET") != NULL;
	if (A(1))
		ST32(A(1), 0x6f74636f);   // a client context
	RET(0);
}
static void sh_CloseOpenTransportInContext(PPC *c) { RET(0); }

// OTCreateConfiguration(path): "tcp", "dnr", ...
static void sh_OTCreateConfiguration(PPC *c)
{
	char s[64] = {0};
	if (A(0))
		strncpy(s, (const char *)G(A(0)), sizeof s - 1);
	uint32_t t = gcalloc(64);
	memcpy(G(t), s, strlen(s) + 1);
	RET(t);
}

static Ep *ep_new(int svc)
{
	if (net_verbose < 0)
		net_verbose = getenv("PPC_DBG_NET") != NULL;
	Ep *e = calloc(1, sizeof *e);
	e->svc = svc;
	e->fd = -1;
	e->state = T_UNBND;
	e->in = [NSMutableData new];
	e->req = [NSMutableData new];
	e->tok = tok_new(e, 16, svc ? TAG_SVC : TAG_EP);
	e->next = eps;
	eps = e;
	return e;
}

// OTOpenEndpointInContext(config, oflag, TEndpointInfo *info, OSStatus *err, context)
static void sh_OTOpenEndpointInContext(PPC *c)
{
	Ep *e = ep_new(0);
	uint32_t info = A(2);
	if (info) {
		ST32(info, 16);           // addr: an InetAddress
		ST32(info + 4, 1024);     // options
		ST32(info + 8, 0);        // tsdu: a byte stream
		ST32(info + 12, 1);       // etsdu (urgent data)
		ST32(info + 16, (uint32_t)-2);   // connect: no data with the connection
		ST32(info + 20, (uint32_t)-2);   // discon
		ST32(info + 24, 4);       // servtype T_COTS_ORD
		ST32(info + 28, 0x20000000);   // flags: T_SENDZERO
	}
	if (A(3))
		ST32(A(3), 0);
	if (A(0))
		gfree(A(0));
	NLOG("net: open endpoint %08x", e->tok);
	RET(e->tok);
}

// OTOpenInternetServicesInContext(config, oflag, OSStatus *err, context)
static void sh_OTOpenInternetServicesInContext(PPC *c)
{
	Ep *e = ep_new(1);
	if (A(2))
		ST32(A(2), 0);
	if (A(0) && A(0) != (uint32_t)-3)   // kDefaultInternetServicesPath is (OTConfigurationRef)-3
		gfree(A(0));
	RET(e->tok);
}

static void ep_close_fd(Ep *e)
{
	if (e->fd >= 0)
		close(e->fd);
	e->fd = -1;
}

static void sh_OTCloseProvider(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	NLOG("net: close %08x", e->tok);
	ep_close_fd(e);
	for (Ep **p = &eps; *p; p = &(*p)->next)
		if (*p == e) {
			*p = e->next;
			break;
		}
	[e->in release];
	[e->req release];
	tok_free(e->tok);
	free(e);
	RET(0);
}

static void sh_OTSetAsynchronous(PPC *c) { Ep *e = EP(A(0)); if (e) e->async = 1; RET(e ? 0 : kOTBadReferenceErr); }
static void sh_OTInstallNotifier(PPC *c)
{
	Ep *e = EP(A(0));
	if (e) {
		e->notifier = A(1);
		e->context = A(2);
	}
	RET(e ? 0 : kOTBadReferenceErr);
}
static void sh_OTRemoveNotifier(PPC *c) { Ep *e = EP(A(0)); if (e) { e->notifier = 0; e->nq = 0; } }
static void sh_OTAckSends(PPC *c) { Ep *e = EP(A(0)); if (e) e->acking = 1; RET(0); }
static void sh_OTDontAckSends(PPC *c) { Ep *e = EP(A(0)); if (e) e->acking = 0; RET(0); }
static void sh_OTIsAckingSends(PPC *c) { Ep *e = EP(A(0)); RET(e && e->acking); }
static void sh_OTGetEndpointState(PPC *c) { Ep *e = EP(A(0)); RET(e ? (uint32_t)e->state : (uint32_t)kOTBadReferenceErr); }

static void netbuf_set(uint32_t nb, const void *p, uint32_t n)
{
	if (!nb || !LD32(nb + 8))
		return;
	uint32_t max = LD32(nb);
	if (n > max)
		n = max;
	memcpy(G(LD32(nb + 8)), p, n);
	ST32(nb + 4, n);
}
static void inet_addr_put(uint32_t nb, uint32_t host, uint16_t port)
{
	uint8_t a[16] = {0, 2, (uint8_t)(port >> 8), (uint8_t)port, (uint8_t)(host >> 24), (uint8_t)(host >> 16), (uint8_t)(host >> 8),
		(uint8_t)host};
	netbuf_set(nb, a, 16);
}

// OTBind(ref, TBind *req, TBind *ret)
static void sh_OTBind(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	e->state = T_IDLE;
	if (A(2))
		inet_addr_put(A(2), 0x7f000001, 0), ST32(A(2) + 12, 0);
	if (e->async)
		post(e, T_BINDCOMPLETE, 0, A(2));   // the cookie: the TBind the result went to
	RET(0);
}
static void sh_OTUnbind(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	e->state = T_UNBND;
	if (e->async)
		post(e, T_UNBINDCOMPLETE, 0, 0);
	RET(0);
}

// OTOptionManagement(ref, TOptMgmt *req, TOptMgmt *ret): the options as asked (TOptMgmt: opt TNetbuf, flags)
static void sh_OTOptionManagement(PPC *c)
{
	Ep *e = EP(A(0));
	uint32_t req = A(1), ret = A(2);
	if (req && ret && LD32(req + 8) && LD32(ret + 8)) {
		uint32_t n = LD32(req + 4), max = LD32(ret);
		if (n > max)
			n = max;
		memmove(G(LD32(ret + 8)), G(LD32(req + 8)), n);
		ST32(ret + 4, n);
		// each TOption's status: T_SUCCESS (0x20) at +8
		for (uint32_t o = 0; o + 16 <= n;) {
			uint32_t len = LD32(LD32(ret + 8) + o);
			ST32(LD32(ret + 8) + o + 8, 0x20);
			if (len < 16)
				break;
			o += (len + 3) & ~3u;
		}
		ST32(ret + 12, 0x20);   // flags: T_SUCCESS
	}
	if (e && e->async)
		post(e, T_OPTMGMTCOMPLETE, 0, ret);
	RET(0);
}

// OTConnect(ref, TCall *snd, TCall *rcv): snd's addr is an InetAddress
static void sh_OTConnect(PPC *c)
{
	Ep *e = EP(A(0));
	uint32_t call = A(1);
	if (!e || !call || LD32(call + 4) < 8) {
		RET(e ? kOTBadAddressErr : kOTBadReferenceErr);
		return;
	}
	uint32_t a = LD32(call + 8);
	uint16_t port = LD16(a + 2);
	uint32_t host = LD32(a + 4);
	e->peer_host = host;
	e->peer_port = port;
	e->connect_cookie = call;
	[e->in setLength:0];
	e->eof = e->discon = e->data_told = e->ordrel_told = e->discon_told = e->connect_told = 0;
	if ((host & 0xffff0000) == MIRROR_NET && mirror_hosts && (host & 0xffff) >= 1 && (host & 0xffff) <= mirror_hosts.count) {
		e->mirror = (int)(host & 0xffff);
		NLOG("net: connect %08x to mirror of %s port %d", e->tok, mirror_hosts[e->mirror - 1].UTF8String, port);
		e->state = T_DATAXFER;
		if (e->async) {
			e->state = T_OUTCON;
			e->connect_told = 1;
			post(e, T_CONNECT, 0, e->connect_cookie);
			RET(kOTNoDataErr);
		} else
			RET(0);
		return;
	}
	e->mirror = 0;
	ep_close_fd(e);
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(host)};
	int r = connect(fd, (struct sockaddr *)&sa, sizeof sa);
	e->fd = fd;
	NLOG("net: connect %08x to %d.%d.%d.%d:%d", e->tok, host >> 24, (host >> 16) & 255, (host >> 8) & 255, host & 255, port);
	if (r == 0) {
		e->state = T_DATAXFER;
		if (e->async) {
			e->state = T_OUTCON;
			e->connect_told = 1;
			post(e, T_CONNECT, 0, e->connect_cookie);
			RET(kOTNoDataErr);
		} else
			RET(0);
		return;
	}
	if (errno != EINPROGRESS) {
		ep_close_fd(e);
		RET(errno == ECONNREFUSED ? kECONNREFUSEDErr : kOTBadAddressErr);
		return;
	}
	if (e->async) {
		e->state = T_OUTCON;
		e->connect_pending = 1;
		RET(kOTNoDataErr);
		return;
	}
	// synchronous: wait for it (up to 20 seconds)
	struct pollfd p = {fd, POLLOUT, 0};
	int err = 0;
	if (poll(&p, 1, 20000) <= 0)
		err = ETIMEDOUT;
	else {
		socklen_t l = sizeof err;
		getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l);
	}
	if (err) {
		ep_close_fd(e);
		RET(err == ECONNREFUSED ? kECONNREFUSEDErr : kETIMEDOUTErr);
		return;
	}
	e->state = T_DATAXFER;
	RET(0);
}

// OTRcvConnect(ref, TCall *call): the connection is made
static void sh_OTRcvConnect(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (e->state != T_OUTCON || !e->connect_told) {
		RET(e->state == T_DATAXFER ? 0 : kOTNoDataErr);
		return;
	}
	e->state = T_DATAXFER;
	if (A(1)) {
		inet_addr_put(A(1), e->peer_host, e->peer_port);
		ST32(A(1) + 16, 0);   // no options
		ST32(A(1) + 28, 0);   // no data
	}
	RET(0);
}

// OTSnd(ref, buf, nbytes, flags): the bytes sent
static void sh_OTSnd(PPC *c)
{
	Ep *e = EP(A(0));
	uint32_t n = A(2);
	if (!e || (e->state != T_DATAXFER && e->state != T_INREL)) {
		RET(e ? kOTOutStateErr : kOTBadReferenceErr);
		return;
	}
	if (e->mirror) {
		[e->req appendBytes:G(A(1)) length:n];
		// an HTTP request ends with an empty line (no body: GET and HEAD)
		if (e->req.length >= 4 && memmem(e->req.bytes, e->req.length, "\r\n\r\n", 4))
			mirror_answer(e);
		RET(n);
		return;
	}
	if (e->discon) {
		RET(kOTLookErr);
		return;
	}
	ssize_t r = send(e->fd, G(A(1)), n, 0);
	if (r < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			RET(kOTFlowErr);
		else {
			e->discon = 1;
			RET(kOTLookErr);
		}
		return;
	}
	RET((uint32_t)r);
}

// OTRcv(ref, buf, nbytes, OTFlags *flags): the bytes received, kOTNoDataErr, or kOTLookErr when the
// connection is closing
static void sh_OTRcv(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (A(3))
		ST32(A(3), 0);
	pull(e);
	if (!e->in.length) {
		e->data_told = 0;
		RET(e->eof || e->discon ? kOTLookErr : kOTNoDataErr);
		return;
	}
	uint32_t n = A(2);
	if (n > e->in.length)
		n = (uint32_t)e->in.length;
	memcpy(G(A(1)), e->in.bytes, n);
	[e->in replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
	if (!e->in.length)
		e->data_told = 0;   // drained: the next data is told again
	RET(n);
}

static void sh_OTCountDataBytes(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	pull(e);
	if (A(1))
		ST32(A(1), (uint32_t)e->in.length);
	RET(e->in.length ? 0 : kOTNoDataErr);
}

// OTLook(ref): the event waiting on the endpoint
static void sh_OTLook(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (e->connect_pending)
		events(e);
	if (e->state == T_OUTCON && e->connect_told) {
		RET(T_CONNECT);
		return;
	}
	pull(e);
	if (e->in.length)
		RET(T_DATA);
	else if (e->discon && e->state != T_IDLE)
		RET(T_DISCONNECT);
	else if (e->eof && (e->state == T_DATAXFER || e->state == T_OUTREL))
		RET(T_ORDREL);
	else
		RET(0);
}

static void sh_OTSndOrderlyDisconnect(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (e->fd >= 0)
		shutdown(e->fd, SHUT_WR);
	e->state = e->state == T_INREL ? T_IDLE : T_OUTREL;
	if (e->state == T_IDLE)
		ep_close_fd(e);
	RET(0);
}
static void sh_OTRcvOrderlyDisconnect(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (!e->eof || e->in.length) {
		RET(kOTNoReleaseErr);
		return;
	}
	e->state = e->state == T_OUTREL ? T_IDLE : T_INREL;
	if (e->state == T_IDLE)
		ep_close_fd(e);
	RET(0);
}
// OTSndDisconnect(ref, TCall *): an abortive close
static void sh_OTSndDisconnect(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (e->fd >= 0) {
		struct linger l = {1, 0};
		setsockopt(e->fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
	}
	ep_close_fd(e);
	[e->in setLength:0];
	e->connect_pending = 0;
	e->state = T_IDLE;
	if (e->async)
		post(e, T_DISCONNECTCOMPLETE, 0, A(1));
	RET(0);
}
static void sh_OTRcvDisconnect(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (!e->discon) {
		RET(kOTNoDisconnectErr);
		return;
	}
	ep_close_fd(e);
	[e->in setLength:0];
	e->state = T_IDLE;
	if (A(1))
		ST32(A(1) + 12, (uint32_t)kECONNREFUSEDErr);   // TDiscon: udata (12), reason
	RET(0);
}

// OTGetProtAddress(ref, TBind *bound, TBind *peer)
static void sh_OTGetProtAddress(PPC *c)
{
	Ep *e = EP(A(0));
	if (!e) {
		RET(kOTBadReferenceErr);
		return;
	}
	if (A(1))
		inet_addr_put(A(1), 0x7f000001, 0);
	if (A(2))
		inet_addr_put(A(2), e->peer_host, e->peer_port);
	if (e->async)
		post(e, T_GETPROTADDRCOMPLETE, 0, A(2));
	RET(0);
}

static void sh_OTListen(PPC *c) { RET(kOTNotSupportedErr); }
static void sh_OTAccept(PPC *c) { RET(kOTNotSupportedErr); }

static void sh_OTStrEqual(PPC *c) { RET(A(0) && A(1) && !strcmp((const char *)G(A(0)), (const char *)G(A(1)))); }

// OTFindPort(OTPortRecord *, const char *name): the TCP/IP port ("enet")
static void sh_OTFindPort(PPC *c) { RET(0); }
static void sh_OTGetDeviceTypeFromPortRef(PPC *c) { RET((A(0) >> 16) & 0xff); }

// ---- Internet services ----------------------------------------------------------------------------

// OTInetStringToAddress(ref, char *name, InetHostInfo *): name[256], then up to ten addresses
static void sh_OTInetStringToAddress(PPC *c)
{
	Ep *e = EP(A(0));
	uint32_t hi = A(2);
	char name[256] = {0};
	strncpy(name, (const char *)G(A(1)), sizeof name - 1);
	char *colon = strchr(name, ':');
	if (colon)
		*colon = 0;
	int32_t err = 0;
	uint32_t addrs[10] = {0};
	int n = 0;
	struct in_addr ia;
	int m = mirror_index(name);
	if (m) {
		addrs[n++] = MIRROR_NET | (uint32_t)m;
	} else if (inet_aton(name, &ia)) {
		addrs[n++] = ntohl(ia.s_addr);
	} else {
		struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM}, *res = NULL;
		if (getaddrinfo(name, NULL, &hints, &res) == 0) {
			for (struct addrinfo *a = res; a && n < 10; a = a->ai_next)
				addrs[n++] = ntohl(((struct sockaddr_in *)a->ai_addr)->sin_addr.s_addr);
			freeaddrinfo(res);
		}
		if (!n)
			err = kOTBadNameErr;
	}
	NLOG("net: lookup %s -> %d address(es)%s", name, n, m ? " (mirror)" : "");
	if (hi) {
		memset(G(hi), 0, 256 + 40);
		strncpy((char *)G(hi), name, 255);
		for (int i = 0; i < n; i++)
			ST32(hi + 256 + 4 * (uint32_t)i, addrs[i]);
	}
	if (e && e->async) {
		post(e, T_DNRSTRINGTOADDRCOMPLETE, err, hi);
		RET(0);
	} else
		RET((uint32_t)err);
}

// OTInetAddressToName(ref, InetHost, InetDomainName name)
static void sh_OTInetAddressToName(PPC *c)
{
	Ep *e = EP(A(0));
	uint32_t host = A(1), out = A(2);
	char name[256] = {0};
	int32_t err = 0;
	if ((host & 0xffff0000) == MIRROR_NET && mirror_hosts && (host & 0xffff) >= 1 && (host & 0xffff) <= mirror_hosts.count)
		strncpy(name, mirror_hosts[(host & 0xffff) - 1].UTF8String, 255);
	else {
		struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_addr.s_addr = htonl(host)};
		if (getnameinfo((struct sockaddr *)&sa, sizeof sa, name, sizeof name, NULL, 0, NI_NAMEREQD))
			err = kOTBadNameErr;
	}
	if (out)
		strncpy((char *)G(out), name, 255);
	if (e && e->async) {
		post(e, T_DNRADDRTONAMECOMPLETE, err, out);
		RET(0);
	} else
		RET((uint32_t)err);
}

// OTInetGetInterfaceInfo(InetInterfaceInfo *, SInt32 index): one interface, the machine's
static void sh_OTInetGetInterfaceInfo(PPC *c)
{
	int32_t idx = (int32_t)A(1);
	if (idx != -1 && idx != 0) {
		RET(kOTNotFoundErr);
		return;
	}
	uint32_t info = A(0);
	memset(G(info), 0, 284);
	ST32(info, 0x7f000001);         // fAddress
	ST32(info + 4, 0xff000000);     // fNetmask
	ST32(info + 8, 0x7fffffff);     // fBroadcastAddr
	ST32(info + 12, 0x7f000001);    // fDefaultGatewayAddr
	ST32(info + 16, 0x7f000001);    // fDNSAddr
	ST16(info + 20, 3);             // fVersion: kInetInterfaceInfoVersion
	RET(0);
}

// ---- Internet Config --------------------------------------------------------------------------------

// ICGetPref(inst, key, attr *, buf, size *): no preference set (no proxy, no helpers)
static void sh_ICGetPref(PPC *c) { RET(-666); }   // icPrefNotFoundErr
static void sh_ICMapFilename(PPC *c) { RET(-666); }
static void sh_ICStop(PPC *c) { RET(0); }
static void sh_ICEditPreferences(PPC *c) { RET(0); }
// ICLaunchURL(inst, hint, data, len, selStart *, selEnd *): the URL in the user's browser
static void sh_ICLaunchURL(PPC *c)
{
	uint32_t data = A(2), len = A(3);
	uint32_t s = A(4) ? LD32(A(4)) : 0, en = A(5) ? LD32(A(5)) : len;
	if (en > len)
		en = len;
	if (s > en)
		s = en;
	NSString *u = [[[NSString alloc] initWithBytes:G(data + s) length:en - s encoding:NSMacOSRomanStringEncoding] autorelease];
	u = [u stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<> \t\r\n\"'"]];
	if ([u hasPrefix:@"URL:"])
		u = [u substringFromIndex:4];
	NSURL *url = [NSURL URLWithString:u];
	if (!url || !url.scheme) {
		RET(-673);   // icNoURLErr
		return;
	}
	NLOG("net: launch %s", u.UTF8String);
	if (!getenv("PPC_SCRIPT"))
		[NSWorkspace.sharedWorkspace openURL:url];
	RET(0);
}

static const ShimDef netshims[] = {
	S(InitOpenTransportInContext), S(CloseOpenTransportInContext), S(OTCreateConfiguration), S(OTOpenEndpointInContext),
	S(OTOpenInternetServicesInContext), S(OTCloseProvider), S(OTSetAsynchronous), S(OTInstallNotifier), S(OTRemoveNotifier),
	S(OTAckSends), S(OTDontAckSends), S(OTIsAckingSends), S(OTGetEndpointState), S(OTBind), S(OTUnbind), S(OTOptionManagement),
	S(OTConnect), S(OTRcvConnect), S(OTSnd), S(OTRcv), S(OTCountDataBytes), S(OTLook), S(OTSndOrderlyDisconnect),
	S(OTRcvOrderlyDisconnect), S(OTSndDisconnect), S(OTRcvDisconnect), S(OTGetProtAddress), S(OTListen), S(OTAccept),
	S(OTStrEqual), S(OTFindPort), S(OTGetDeviceTypeFromPortRef), S(OTInetStringToAddress), S(OTInetAddressToName),
	S(OTInetGetInterfaceInfo), S(ICGetPref), S(ICMapFilename), S(ICStop), S(ICEditPreferences), S(ICLaunchURL),
};
REGISTER(netshims)
