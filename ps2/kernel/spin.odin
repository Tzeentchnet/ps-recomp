// The threads, for the spin skip (ps2/spin.odin). A loop that yields with
// RotateThreadReadyQueue to another thread at its priority comes back to
// its probe with the threads switched round and back: what the pass did to
// them is in their saved registers, their statuses and the ready order
// (seq). The first rotate after the probe arms saves the threads; none has
// switched since the arm, so they are as they were then. The probe then
// asks spin_threads_same whether the pass left them so, each thread parked
// at the same syscall (syscall_pc: a thread's registers do not say where it
// resumes, its coroutine does), and on a skip
// spin_threads_skip moves seq and the saved cycles on as the passes
// skipped would have.
//
// seq is never seen by the program (ReferThreadStatus does not report it):
// the kernel only compares it, picking the next thread among those ready at
// one priority and the waiter a semaphore wakes among those at one
// priority, and gives the next value of k.seq to a thread it readies. A
// thread the pass gave a seq to gets one at the same point of every pass;
// with each such thread's seq D on from where it was, D being what k.seq
// went up by, the next pass sees every seq D on from what this one saw, and
// the kernel picks the same threads, as long as no two seqs it compares
// move apart: of two threads ready at one priority, or waiting on one
// semaphore at one priority, both or neither got a seq in the pass.
package ps2_kernel

import "base:runtime"
import "ps:core"
import cpu "../cpu"
import mem "../mem"

@(private = "file")
saved: struct {
	thread_end: int,
	current:    ^Thread,
	seq:        u64,
	ptr:        [len(k.threads)]^Thread,
	t:          [len(k.threads)]Thread,
}

// The current thread's id, which the spin probe keys its arm on; -1 before
// the kernel has one.
current_id :: proc() -> i32 {
	return k.current == nil ? -1 : k.current.id
}

// The syscall entry's mark for RotateThreadReadyQueue (syscall).
@(private)
spin_rotate :: proc() {
	if mem.spin_armed && cpu.spin_dirty & cpu.SPIN_ROTATE == 0 {
		saved.thread_end, saved.current, saved.seq = k.thread_end, k.current, k.seq
		for t, i in k.threads[:k.thread_end] {
			saved.ptr[i] = t
			if t != nil {saved.t[i] = t^}
		}
	}
	cpu.spin_dirty |= cpu.SPIN_ROTATE
}

// Whether the threads are as spin_rotate saved them, but for seq and the
// saved cycles, which a pass may move on as the header says.
spin_threads_same :: proc() -> bool {
	if k.current != saved.current || k.thread_end != saved.thread_end {return false}
	d := k.seq - saved.seq
	threads := k.threads[:k.thread_end]
	for t, i in threads {
		if t != saved.ptr[i] {return false}
		if t == nil {continue}
		was := &saved.t[i]
		if t.status != was.status || t.prio != was.prio || t.wait != was.wait || t.wait_id != was.wait_id || t.wait_result != was.wait_result || t.wakeups != was.wakeups || t.syscall_pc != was.syscall_pc {return false}
		if !runtime.memory_equal(&t.regs, &was.regs, cpu.STATE_BYTES) {return false}
		if t.seq != was.seq && t.seq - was.seq != d {return false}
	}
	for t, i in threads {
		if t == nil {continue}
		moved := t.seq != saved.t[i].seq
		for u, j in threads[i + 1:] {
			if u == nil || u.prio != t.prio || moved == (u.seq != saved.t[i + 1 + j].seq) {continue}
			ready :: proc(t: ^Thread) -> bool {return t.status == .Ready || t.status == .Run}
			if ready(t) && ready(u) || t.wait == .Sema && u.wait == .Sema && t.wait_id == u.wait_id {return false}
		}
	}
	return true
}

// Move the threads on by n more passes like the one spin_threads_same
// passed, of d cycles each: each seq the pass moved, and the cycles of each
// thread that saved its registers in it (a dead value: switch_to keeps
// cpu.state's cycles), so the threads end as without the skip.
spin_threads_skip :: proc(n, d: u64) {
	dseq := k.seq - saved.seq
	for t, i in k.threads[:k.thread_end] {
		if t == nil {continue}
		if t.seq != saved.t[i].seq {t.seq += n * dseq}
		if t.regs.cycles != saved.t[i].regs.cycles {t.regs.cycles += n * d}
	}
	k.seq += n * dseq
}

// FLAT: each run's interpreter state (Flat_Ctx), which a pass may leave
// other than it found it with cpu.state the same: a call it left open, a
// return address on the shadow stack another one (a `jr $ra` that
// unwinds, or no call's, goes by the shadow stack, not by $ra). The probe
// saves every thread's run and the nested runs as it arms
// (spin_flat_save) and skips only with all of them as they were
// (spin_flat_same). No run switches or ends between the two without a
// rotate the threads' compare sees, or a side effect that stops the skip.
// More than SPIN_FLAT_FRAMES calls open in all: the probe does not arm.
SPIN_FLAT_FRAMES :: 1024

@(private = "file")
saved_flat: struct {
	threads:    int, // k.thread_end as saved
	nest_depth: int,
	ctx:        [FLAT_THREADS + FLAT_NEST]Flat_Ctx, // the threads', then the nested runs'; ret and sp unused
	at:         [FLAT_THREADS + FLAT_NEST]int, // where each one's frames start in ret and sp
	wait:       [FLAT_THREADS]bool,
	ret, sp:    [SPIN_FLAT_FRAMES]u32,
}

// Save the runs as the probe arms: false with more calls open than
// SPIN_FLAT_FRAMES, when it must not arm.
spin_flat_save :: proc() -> bool {
	when !core.FLAT {return true} else {
		s := &saved_flat
		s.threads, s.nest_depth = k.thread_end, flat.nest_depth
		n := 0
		for i in 0 ..< s.threads + s.nest_depth {
			x := i < s.threads ? &flat.ee[i] : &flat.nest[i - s.threads]
			d := int(x.depth)
			if d > SPIN_FLAT_FRAMES - n {return false}
			s.ctx[i], s.at[i] = x^, n
			copy(s.ret[n:][:d], x.ret[:d])
			copy(s.sp[n:][:d], x.sp[:d])
			n += d
		}
		copy(s.wait[:s.threads], flat.wait[:s.threads])
		return true
	}
}

// Whether the runs are as spin_flat_save saved them, each one's calls open
// all the same.
spin_flat_same :: proc() -> bool {
	when !core.FLAT {return true} else {
		s := &saved_flat
		if k.thread_end != s.threads || flat.nest_depth != s.nest_depth {return false}
		for i in 0 ..< s.threads + s.nest_depth {
			x := i < s.threads ? &flat.ee[i] : &flat.nest[i - s.threads]
			was := &s.ctx[i]
			if x.pc != was.pc || x.depth != was.depth || x.enter != was.enter || x.back != was.back || x.end != was.end || x.ra != was.ra || x.ra_sp != was.ra_sp {return false}
			d := int(x.depth)
			if d == 0 {continue}
			if !runtime.memory_equal(raw_data(x.ret), &s.ret[s.at[i]], d * size_of(u32)) || !runtime.memory_equal(raw_data(x.sp), &s.sp[s.at[i]], d * size_of(u32)) {return false}
		}
		return runtime.memory_equal(&flat.wait, &s.wait, s.threads * size_of(bool))
	}
}
