// Thread Manager: cooperative threads, as on Mac OS. Every guest thread runs
// on the main host thread (the toolbox shims call AppKit): it has its own
// register file, guest stack and host stack, and a switch saves the host's
// callee-saved registers and stack pointer (thread_swap below) and resumes
// another thread where it yielded. A thread runs until it yields, stops
// itself or ends; the application thread (kApplicationThreadID) gives the others their turns
// from the event calls (thread_idle).
#import "ppcrt.h"
#include <sys/mman.h>

// (kReadyThreadState 0, kStoppedThreadState 1, kRunningThreadState 2,
// threadNotFoundErr; thread IDs kNoThreadID 0, kCurrentThreadID 1,
// kApplicationThreadID 2: from the Carbon headers)

// arm64: x19-x28, fp, lr, sp, d8-d15
typedef struct { uint64_t x[13]; double d[8]; } HostCtx;

void thread_swap(HostCtx *from, HostCtx *to);
__asm__(
	".text\n.p2align 2\n.globl _thread_swap\n_thread_swap:\n"
	"stp x19, x20, [x0, #0]\n stp x21, x22, [x0, #16]\n stp x23, x24, [x0, #32]\n"
	"stp x25, x26, [x0, #48]\n stp x27, x28, [x0, #64]\n stp x29, x30, [x0, #80]\n"
	"mov x9, sp\n str x9, [x0, #96]\n"
	"stp d8, d9, [x0, #104]\n stp d10, d11, [x0, #120]\n stp d12, d13, [x0, #136]\n stp d14, d15, [x0, #152]\n"
	"ldp x19, x20, [x1, #0]\n ldp x21, x22, [x1, #16]\n ldp x23, x24, [x1, #32]\n"
	"ldp x25, x26, [x1, #48]\n ldp x27, x28, [x1, #64]\n ldp x29, x30, [x1, #80]\n"
	"ldr x9, [x1, #96]\n mov sp, x9\n"
	"ldp d8, d9, [x1, #104]\n ldp d10, d11, [x1, #120]\n ldp d12, d13, [x1, #136]\n ldp d14, d15, [x1, #152]\n"
	"ret\n");

typedef struct Thread {
	uint32_t id;
	int state, dead;
	PPC *cpu;
	HostCtx ctx;
	void *host_stack;
	size_t host_size;
	uint32_t guest_stack, guest_size;
	uint32_t entry, param, result_ptr;
	uint32_t switch_in, switch_in_param, switch_out, switch_out_param;
	uint32_t term, term_param;
	PPCResume *resume_top;
	struct Thread *next;
} Thread;

static Thread main_thread = {.id = kApplicationThreadID, .state = kRunningThreadState};
static Thread *threads = &main_thread, *cur = &main_thread, *zombie;
static uint32_t next_id = 3;
static int critical;

static Thread *find(uint32_t id)
{
	if (id == kCurrentThreadID)
		return cur;
	for (Thread *t = threads; t; t = t->next)
		if (t->id == id && !t->dead)
			return t;
	return NULL;
}

static void reap(void)
{
	// a finished thread's stacks, once something else runs
	if (!zombie || zombie == cur)
		return;
	Thread *z = zombie;
	zombie = NULL;
	munmap(z->host_stack, z->host_size);
	gfree(z->guest_stack);
	free(z->cpu);
	for (Thread **p = &threads; *p; p = &(*p)->next)
		if (*p == z) {
			*p = z->next;
			break;
		}
	free(z);
}

static void switch_to(Thread *t)
{
	if (t == cur)
		return;
	Thread *from = cur;
	if (from->switch_out)
		ppc_cb2(from->switch_out, from->id, from->switch_out_param);
	if (from->state == kRunningThreadState)
		from->state = kReadyThreadState;
	from->resume_top = ppc_resume_top;
	from->cpu = from == &main_thread ? (from->cpu ? from->cpu : ppc_cpu) : from->cpu;
	cur = t;
	t->state = kRunningThreadState;
	ppc_cpu = t->cpu;
	ppc_resume_top = t->resume_top;
	thread_swap(&from->ctx, &t->ctx);
	// back in `from`
	reap();
	if (cur->switch_in)
		ppc_cb2(cur->switch_in, cur->id, cur->switch_in_param);
}

// the next ready thread after the current one, round robin
static Thread *next_ready(Thread *after)
{
	Thread *t = after;
	for (;;) {
		t = t->next ? t->next : threads;
		if (t == after)
			return NULL;
		if (!t->dead && t->state == kReadyThreadState)
			return t;
	}
}

static void thread_main(void) __attribute__((noreturn));
static void thread_main(void)
{
	Thread *t = cur;
	reap();
	if (t->switch_in)
		ppc_cb2(t->switch_in, t->id, t->switch_in_param);
	PPC *c = t->cpu;
	uint32_t r = ppc_cb1(t->entry, t->param);
	if (t->result_ptr)
		ST32(t->result_ptr, r);
	if (t->term)
		ppc_cb2(t->term, t->id, t->term_param);
	(void)c;
	t->dead = 1;
	zombie = t;
	Thread *n = next_ready(t);
	if (!n) {
		main_thread.state = kReadyThreadState;
		n = &main_thread;
	}
	t->switch_out = 0;
	switch_to(n);
	ppc_log("thread %u resumed after it ended", t->id);
	abort();
}

void thread_idle(void)
{
	// the application thread lets every ready thread run once
	if (cur != &main_thread || critical)
		return;
	Thread *t = next_ready(cur);
	if (t)
		switch_to(t);
}

// NewThread(style, entry, param, stackSize, options, void **result, ThreadID *id)
static void sh_NewThread(PPC *c)
{
	uint32_t stack = A(3);
	if (stack < 0x40000)
		stack = 0x40000;
	Thread *t = calloc(1, sizeof *t);
	t->id = next_id++;
	t->state = kReadyThreadState;
	t->entry = A(1);
	t->param = A(2);
	t->result_ptr = A(5);
	t->cpu = calloc(1, sizeof(PPC));
	t->guest_size = stack;
	t->guest_stack = gcalloc(stack);
	t->cpu->r[1] = (t->guest_stack + stack - 256) & ~15u;
	ST32(t->cpu->r[1], 0);
	t->host_size = 4 << 20;
	t->host_stack = mmap(NULL, t->host_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	uint64_t sp = ((uint64_t)t->host_stack + t->host_size - 64) & ~15ull;
	t->ctx.x[11] = (uint64_t)thread_main;   // lr: where the first switch "returns" to
	t->ctx.x[10] = 0;                        // fp
	t->ctx.x[12] = sp;
	t->next = NULL;
	Thread **p = &threads;
	while (*p)
		p = &(*p)->next;
	*p = t;
	// options: kNewSuspend (1 << 0)... created stopped
	if (A(4) & 1)
		t->state = kStoppedThreadState;
	if (A(6))
		ST32(A(6), t->id);
	if (ppc_verbose)
		ppc_log("NewThread %u entry %08x param %08x stack %x", t->id, t->entry, t->param, stack);
	RET_OK(c);
}

static void sh_CreateThreadPool(PPC *c) { RET_OK(c); }

static void sh_GetCurrentThread(PPC *c)
{
	if (A(0))
		ST32(A(0), cur->id);
	RET_OK(c);
}

static void sh_YieldToAnyThread(PPC *c)
{
	Thread *t = next_ready(cur);
	if (t)
		switch_to(t);
	RET_OK(c);
}

static void sh_YieldToThread(PPC *c)
{
	Thread *t = find(A(0));
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (t->state == kStoppedThreadState)
		t->state = kReadyThreadState;
	switch_to(t);
	RET_OK(c);
}

static void set_state(PPC *c, uint32_t id, int state, uint32_t suggested)
{
	Thread *t = find(id);
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (t != cur) {
		t->state = state == kRunningThreadState ? kReadyThreadState : state;
		if (state == kRunningThreadState)
			switch_to(t);
		RET_OK(c);
		return;
	}
	if (state == kStoppedThreadState) {
		t->state = kStoppedThreadState;
		Thread *n = suggested ? find(suggested) : NULL;
		if (!n || n->state == kStoppedThreadState || n == t)
			n = next_ready(t);
		if (!n) {
			// nothing else to run: the application thread wakes
			if (t == &main_thread) {
				t->state = kRunningThreadState;
				RET_OK(c);
				return;
			}
			n = &main_thread;
			n->state = kReadyThreadState;
		}
		switch_to(n);
	}
	RET_OK(c);
}

// SetThreadState(id, state, suggested)
static void sh_SetThreadState(PPC *c) { set_state(c, A(0), A(1), A(2)); }

static void sh_SetThreadStateEndCritical(PPC *c)
{
	if (critical > 0)
		critical--;
	set_state(c, A(0), A(1), A(2));
}

static void sh_ThreadBeginCritical(PPC *c)
{
	critical++;
	RET_OK(c);
}

static void sh_ThreadEndCritical(PPC *c)
{
	if (critical > 0)
		critical--;
	RET_OK(c);
}

// DisposeThread(id, result, recycle)
static void sh_DisposeThread(PPC *c)
{
	Thread *t = find(A(0));
	if (!t || t == &main_thread) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (t->result_ptr)
		ST32(t->result_ptr, A(1));
	if (t->term)
		ppc_cb2(t->term, t->id, t->term_param);
	t->dead = 1;
	if (t == cur) {
		zombie = t;
		Thread *n = next_ready(t);
		if (!n) {
			n = &main_thread;
			n->state = kReadyThreadState;
		}
		t->switch_out = 0;
		switch_to(n);
		abort();
	}
	// not running: its stacks can go now
	if (zombie && zombie != cur)
		reap();
	zombie = t;
	reap();
	RET_OK(c);
}

// SetThreadSwitcher(id, proc, param, inOrOut)
static void sh_SetThreadSwitcher(PPC *c)
{
	Thread *t = find(A(0));
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (A(3) & 0xff) {
		t->switch_in = A(1);
		t->switch_in_param = A(2);
	} else {
		t->switch_out = A(1);
		t->switch_out_param = A(2);
	}
	RET_OK(c);
}

// SetThreadTerminator(id, proc, param)
static void sh_SetThreadTerminator(PPC *c)
{
	Thread *t = find(A(0));
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	t->term = A(1);
	t->term_param = A(2);
	RET_OK(c);
}

// GetThreadCurrentTaskRef(ThreadTaskRef *): one task, the application
static void sh_GetThreadCurrentTaskRef(PPC *c)
{
	if (A(0))
		ST32(A(0), 0x7461736b);
	RET_OK(c);
}

// GetThreadStateGivenTaskRef(task, id, ThreadState *)
static void sh_GetThreadStateGivenTaskRef(PPC *c)
{
	Thread *t = find(A(1));
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (A(2))
		ST16(A(2), t->state);
	RET_OK(c);
}

static void sh_GetThreadState(PPC *c)
{
	Thread *t = find(A(0));
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (A(1))
		ST16(A(1), t->state);
	RET_OK(c);
}

// SetThreadReadyGivenTaskRef(task, id): from interrupt level, a stopped thread
static void sh_SetThreadReadyGivenTaskRef(PPC *c)
{
	Thread *t = find(A(1));
	if (!t) {
		RET_ERR(c, threadNotFoundErr);
		return;
	}
	if (t->state == kStoppedThreadState)
		t->state = kReadyThreadState;
	RET_OK(c);
}

static void sh_GetFreeThreadCount(PPC *c)
{
	if (A(1))
		ST16(A(1), 16);
	RET_OK(c);
}

static void sh_GetDefaultThreadStackSize(PPC *c)
{
	if (A(1))
		ST32(A(1), 0x40000);
	RET_OK(c);
}

static void sh_ThreadCurrentStackSpace(PPC *c)
{
	Thread *t = find(A(0));
	uint32_t room = 0x40000;
	if (t && t != &main_thread)
		room = c->r[1] - t->guest_stack;
	if (A(1))
		ST32(A(1), room);
	RET_OK(c);
}

static const ShimDef threadshims[] = {
	S(NewThread), S(CreateThreadPool), S(GetCurrentThread), S(YieldToAnyThread), S(YieldToThread),
	S(SetThreadState), S(SetThreadStateEndCritical), S(ThreadBeginCritical), S(ThreadEndCritical),
	S(DisposeThread), S(SetThreadSwitcher), S(SetThreadTerminator), S(GetThreadCurrentTaskRef),
	S(GetThreadStateGivenTaskRef), S(GetThreadState), S(SetThreadReadyGivenTaskRef), S(GetFreeThreadCount),
	S(GetDefaultThreadStackSize), S(ThreadCurrentStackSpace),
};
REGISTER(threadshims)
