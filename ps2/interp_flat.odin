// The EE interpreter of a FLAT build (core/flat.odin). It does what
// interp_call does, with the same decode, execution, events checks and
// counts, but keeps the call chain as data (kernel.Flat_Ctx) instead of in
// host frames: a call pushes its return address and goes on at the target,
// and `jr $ra` or ERET pops. The host enters it for the console threads
// (flat_run) and for each guest call it makes itself (flat_call, as
// cpu.interp_hook).
//
// On wasm32, native code (recomp/r5900/native.odin) is a step of this
// runner: flat_resume enters it at a pc it has an entry for, and does what
// its exit (cpu.native_exit) leaves to the runner.
package ps2

import "core:fmt"

import "ps:core"

import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"

// Run the console threads, from the current one's run. Never returns: a
// thread's run ends in a switch to another, or fatally.
flat_run :: proc() -> ! {
	if core.learn_on(.Ee) {flat_loop(true)} else {flat_loop(false)}
	cpu.fatal("the EE threads' run ended")
}

// cpu.interp_hook under FLAT: run the guest code at entry until it returns.
flat_call :: proc(entry: u32) {
	kernel.flat_nest_push(entry)
	if core.learn_on(.Ee) {flat_loop(true)} else {flat_loop(false)}
	kernel.flat_nest_pop()
}

// Run the innermost run (kernel.flat_ctx) until it ends. A nested run's end
// returns; a thread's switches to the next thread's run.
//
// The pc is kept in the run (x.pc) before each syscall and events check:
// one may switch threads, or load a snapshot. After it, flat_reload picks
// up the run that is current then (flat_resume).
//
// With L (LEARN on for the EE), each interpreted run is noted as
// interp_call's is: lf is the frame of the function the run is in
// (kernel.flat_learn_top), nil when none is noted. The instructions run
// with none open are no run's, and checked for none: flat_steps notes
// each instruction only as its N variant, which runs while lf is not nil.
@(private = "file")
flat_loop :: proc($L: bool) {
	x, pc, lf, ok := flat_resume(L)
	for ok {
		when L {
			if lf != nil {
				x, pc, lf, ok = flat_steps(true, true, x, pc, lf)
			} else {
				x, pc, lf, ok = flat_steps(true, false, x, pc, lf)
			}
		} else {
			x, pc, lf, ok = flat_steps(false, false, x, pc, lf)
		}
	}
}

// Whether flat_steps with N leaves to flat_loop for the other variant:
// with L, when a run is open (lf) and N is not, or none is and N is.
@(private = "file")
flat_switch :: #force_inline proc($L, $N: bool, lf: ^core.Learn_Frame) -> bool {
	when L {return (lf != nil) != N} else {return false}
}

// flat_loop's interpreter, from pc in the run x, until the run ends (ok
// false) or, with N (a run open), lf changes to or from nil: N notes each
// instruction in lf, and without N none is noted.
@(private = "file")
flat_steps :: proc($L, $N: bool, x_: ^kernel.Flat_Ctx, pc_: u32, lf_: ^core.Learn_Frame) -> (x: ^kernel.Flat_Ctx, pc: u32, lf: ^core.Learn_Frame, ok: bool) {
	c := &cpu.state
	x, pc, lf = x_, pc_, lf_
	slot :: #force_inline proc($N: bool, pc: u32, lf: ^core.Learn_Frame) {
		when N {delay_slot(pc, lf)} else {delay_slot(pc, nil)}
	}
	// On wasm32 the loop leaves to flat_loop every 2^20 instructions, which
	// calls it again with the same state. A wasm engine has no on-stack
	// replacement: a call that never returns runs its first, baseline code
	// for the whole run, and V8 left this loop in Liftoff (16.6% of GT4's
	// cycles, 2026-11-19). Each new call takes the optimized code.
	when ODIN_ARCH == .wasm32 {budget := 1 << 20}
	for {
		when ODIN_ARCH == .wasm32 {
			budget -= 1
			if budget == 0 {return x, pc, lf, true}
		}
		i := decode_cached(pc, mem.rd32(pc))
		when N {learn_note(lf, i)}
		c.cycles += cpu.CYCLES_PER_INSN
		when mem.MOD_PROBE {if mem.mod_ram_has(pc) {mem.mod_probe.interp += 1}}
		ret := pc + 8
		switch i.kind {
		case .Alu:
			exec_insn(i)
			pc += 4
		case .Sys:
			x.pc = pc + 4
			if i.op == .ERET {
				exec_insn(i)
				if !flat_return(x, L, false, 0) {return x, pc, lf, false}
				if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				continue
			}
			flat_sys(i)
			if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
		case .Bad:
			cpu.bad_insn(pc, i.w)
		case .Branch:
			taken := branch_taken(i)
			if i.link {c.r[31].d[0] = u64(ret)}
			if !i.likely || taken {slot(N, pc + 4, lf)}
			if !taken {
				pc = ret
			} else if i.link && i.target != ret {
				flat_enter(x, ret, i.target)
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else if i.link {
				pc = ret
			} else if flat_mod_tail(x, L, i.target) {
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else if flat_goto(x, pc, i.target) {
				if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else {
				pc = i.target
				if flat_native_at(pc) {
					x.pc = pc
					when L {kernel.flat_learn_end(x, x.depth)} // a tail call: the run returns, as goto_pc's
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				}
			}
		case .Jump:
			slot(N, pc + 4, lf)
			if flat_mod_tail(x, L, i.target) {
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else if flat_goto(x, pc, i.target) {
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else {
				when N {
					// interp_body's split of a tail call that would make
					// the run .Large: it returns for LEARN, one from the
					// target begins at the same depth.
					if core.learn_past_span(lf, i.target) && flat_frame_gone(x) {
						kernel.flat_learn_begin(x, i.target)
						lf = kernel.flat_learn_top(x)
						if lf == nil {return x, i.target, nil, true}
					}
				}
				pc = i.target
				if flat_native_at(pc) {
					x.pc = pc
					when L {kernel.flat_learn_end(x, x.depth)} // a tail call: the run returns, as goto_pc's
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				}
			}
		case .Call:
			c.r[31].d[0] = u64(ret)
			slot(N, pc + 4, lf)
			if i.target == ret {
				pc = ret
				continue
			}
			flat_enter(x, ret, i.target)
			if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			slot(N, pc + 4, lf)
			if t == ret {
				pc = ret
				continue
			}
			flat_enter(x, ret, t)
			if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			slot(N, pc + 4, lf)
			if i.rs == 31 && !flat_unwind(x, L, t) {
				if !flat_return(x, L, true, t) {return x, pc, lf, false}
				if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				continue
			}
			if i.rs == 31 {
				// No call returns to t: a jump there, as interp_body's,
				// which ends the run for LEARN, so none of the code there is
				// noted in it.
				when L {
					kernel.flat_learn_end(x, x.depth, true)
					lf = nil
				}
				if flat_mod_tail(x, L, t) {
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				} else if flat_goto(x, pc, t) {
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				} else {
					pc = t
					if flat_native_at(pc) {
						x.pc = pc
						when L {kernel.flat_learn_end(x, x.depth)} // a tail call: the run returns, as goto_pc's
						if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
					}
				}
				when N {return x, pc, lf, true} // lf is nil: the steps without one go on at pc
				continue
			}
			// interp_body's two checks: the events check of every such
			// `jr`, then goto_pc's of a backward one. A switch at the first
			// leaves the second to the thread's resume (x.back). A tail call
			// into a hooked function owes its entry instead (x.enter).
			x.pc = t
			tail := flat_mod_tail(x, L, t)
			if c.cycles >= cpu.next_event {
				x.back = t <= pc && !tail
				kernel.flat_sync()
				kernel.run_events()
				kernel.flat_commit()
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else if tail {
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
			} else {
				pc = t
				if flat_native_at(pc) {
					x.pc = pc
					when L {kernel.flat_learn_end(x, x.depth)} // a tail call: the run returns, as goto_pc's
					if x, pc, lf, ok = flat_resume(L); !ok || flat_switch(L, N, lf) {return}
				}
			}
		}
	}
}

// Whether the run's frame is gone: $ra and sp are as at its call (the
// innermost record's, or the run's own at depth 0), so a `j` away is a tail
// call.
@(private = "file")
flat_frame_gone :: proc(x: ^kernel.Flat_Ctx) -> bool {
	ra, sp := x.ra, x.ra_sp
	if x.depth > 0 {ra, sp = x.ret[x.depth - 1], x.sp[x.depth - 1]}
	return u32(cpu.state.r[31].d[0]) == ra && u32(cpu.state.r[29].d[0]) == sp
}

// wasm32: whether native code is loaded (load_native), which flat_resume
// and the interpreter's taken jumps then look pcs up for. With no blob
// they test it and nothing more.
flat_native_on: bool

// What native code is called as: the pc to enter it at, among its
// function's entries.
Wasm_Func :: #type proc(pc: u32)

// The run that is current now and its pc (flat_reload), after running the
// native code there is at it, on wasm32: false when a return in it ended
// the run (flat_return), which the caller then returns from. Native code
// runs from block to block of its function until the interpreter has work
// to do, and leaves the rest to here: due events, a call, a return, a
// SYSCALL, ERET, or a jump out of its blocks (to other native code, or to
// interpret).
//
// With L, also the LEARN frame of the run's function (flat_loop). Native
// code that runs where a run is noted cuts it: the function goes on in code
// the record cannot hold (a return to an entry of its own). Code with no
// block at the pc runs nothing, and cuts nothing: a return into a larger
// function's code, which holds the caller's words but no block after its
// call, goes on interpreted, and its run with it. Interpreting
// where native code jumped out to (.None) and no native code is found
// begins a run there, as learned_goto does after learned_find misses: not
// at a pc jumped to that native code has no block for, nor in learned code,
// which runs here, nor at an entry the learned compiler left to the
// interpreter (learned_refused_at). A pc entered (a call, a thread's start)
// that native code has no block for is an entry, and begins one.
@(private = "file")
flat_resume :: proc($L: bool) -> (x: ^kernel.Flat_Ctx, pc: u32, lf: ^core.Learn_Frame, ok: bool) {
	entered: bool
	x, pc, entered = flat_reload(L)
	when ODIN_ARCH == .wasm32 {
		left, miss := false, false
		native: for flat_native_on {
			f := flat_lookup(pc)
			learned_ran()
			if f == nil {
				miss = left
				break
			}
			e := &cpu.native_exit
			when mem.MOD_PROBE {mem.mod_probe.enters[int(mem.mod_ram_has(pc))] += 1}
			(cast(Wasm_Func)rawptr(f))(pc)
			left = e.reason == .None
			// Cut after the code ran, not before: code with no block at pc
			// (.None there) ran nothing, and the run goes on interpreted.
			when L {if !left || e.pc != pc {kernel.flat_learn_end(x, x.depth, true)}}
			// The frames of calls made in-line whose callee left (cpu.wasm_pend).
			for cpu.wasm_npending > 0 {
				cpu.wasm_npending -= 1
				w := cpu.wasm_pending[cpu.wasm_npending]
				kernel.flat_push_made(x, w.ret, w.sp)
			}
			switch e.reason {
			case .None:
				// An entry its code has no block for: interpret, rather
				// than enter it again. Entered there (a call, a thread's
				// start), the pc is a function's entry, the larger
				// function's code it lies in or not: its run is noted, so
				// the next compile holds code that starts there.
				if e.pc == pc {
					when L {if entered && !learned_refused_at(pc) {kernel.flat_learn_begin(x, pc)}}
					when mem.MOD_PROBE {
						in_mod := mem.mod_ram_has(pc)
						mem.mod_probe.left[int(in_mod)] += 1
						if in_mod && mem.mod_func_words(pc) == 0 {mem.mod_probe.mid += 1}
					}
					break native
				}
				// A jump into a hooked function reaches its chain, as the
				// interpreter's does (flat_mod_tail sets x.pc).
				if !flat_mod_tail(x, L, e.pc) {x.pc = e.pc}
			case .Events:
				x.pc = e.pc
				x.back = e.back != 0
				kernel.flat_sync()
				kernel.run_events()
				kernel.flat_commit()
			case .Call:
				// a jalr to its own return address: no call (.Jalr above)
				if e.arg == e.pc {
					x.pc = e.pc
				} else {
					flat_enter(x, e.arg, e.pc)
				}
			case .Return:
				// Native code's `jr $ra` returns, whatever it jumps to.
				flat_unwind(x, L, e.pc)
				if !flat_return(x, L, true, e.pc) {return}
			case .Sys:
				x.pc = e.pc
				flat_sys(decode_cached(e.pc - 4, mem.rd32(e.pc - 4)))
			case .Eret:
				if !flat_return(x, L, false, 0) {return}
			}
			x, pc, entered = flat_reload(L)
		}
		when L {
			if miss && kernel.flat_learn_top(x) == nil && !learned_refused_at(pc) {kernel.flat_learn_begin(x, pc)}
		}
	}
	when L {lf = kernel.flat_learn_top(x)}
	return x, pc, lf, true
}

// wasm32: native code at t, which a taken jump that checked nothing goes
// on in (flat_resume, after x.pc = t).
@(private = "file")
flat_native_at :: #force_inline proc(t: u32) -> bool {
	when ODIN_ARCH == .wasm32 {
		return flat_native_on && flat_lookup(t) != nil
	} else {
		return false
	}
}

// wasm32: the native code at pc, the game's (the call table), learned
// (learned_at) or a mod's (load_mods), else nil.
@(private = "file")
flat_lookup :: #force_inline proc(pc: u32) -> cpu.Func_Proc {
	if f := cpu.lookup(pc); f != nil {return f}
	if f := learned_at(pc); f != nil {return f}
	if !mem.mod_func_near(pc) {return nil}
	when mem.MOD_PROBE {mem.mod_probe.fallback[int(mem.mod_ram_has(pc))] += 1}
	return mem.mod_func_at(pc)
}

// A SYSCALL, with the run's pc past it (x.pc): it may switch threads.
@(private = "file")
flat_sys :: proc(i: r5900.Insn) {
	kernel.flat_sync()
	exec_insn(i)
	kernel.flat_commit()
}

// The run that is current now, and its pc, after the checks it owes: a
// call's on entry (interp_call), or a backward jump's events check. Each
// may switch to another run, which may owe its own. With L, an
// interpreted call's run is noted from after its events check, as
// interp_call's is. Also whether the pc is an entry (a call's, a thread's
// start) that native code is at: flat_resume notes the run there if that
// code holds no block for it.
@(private = "file")
flat_reload :: proc($L: bool) -> (^kernel.Flat_Ctx, u32, bool) {
	for {
		x := kernel.flat_ctx()
		check := false
		begin := false
		entered := false
		if x.enter {
			x.enter = false
			if x.depth == 0 {x.ra, x.ra_sp = u32(cpu.state.r[31].d[0]), u32(cpu.state.r[29].d[0])}
			if cpu.mod_on {
				mod_flat_enter(x)
				// A call into the mod region, counted as the recursive
				// model's hook does (mod_interp_hook).
				if mem.mod_ram_has(x.pc) {
					if flat_native_at(x.pc) {mem.mod_native_calls += 1} else {mem.mod_interp_calls += 1}
				}
			}
			// Native code at the entry is not interpreted, and traces its
			// own entry (flat_resume runs it next).
			if !flat_native_at(x.pc) {
				interp_enter(x.pc)
				begin = L && !learned_refused_at(x.pc)
			} else {
				entered = true
			}
			check = true
		} else if x.back {
			x.back = false
			check = true
		}
		if check && cpu.state.cycles >= cpu.next_event {
			kernel.flat_sync()
			kernel.run_events()
			kernel.flat_commit()
			when L {if begin {kernel.flat_learn_begin(x, x.pc)}}
			continue
		}
		when L {if begin {kernel.flat_learn_begin(x, x.pc)}}
		return x, x.pc, entered
	}
}

// A call from x to t returning to ret: its entry checks are owed
// (flat_reload). Unlike cpu.call it is no side effect to the spin skip: the
// call is on x's shadow stack, which the probe compares (kernel
// spin_flat_same), and a hooked callee marks one as it enters
// (mod_flat_enter).
@(private = "file")
flat_enter :: #force_inline proc(x: ^kernel.Flat_Ctx, ret, t: u32) {
	kernel.flat_push(x, ret, t)
}

// A jump from x to t that goto_pc takes as a tail call into a hooked
// function's chain (mod_flat_tail): the run goes on at t, whose entry is
// owed (flat_reload). With L, the run's LEARN frame ends, as goto_pc's tail
// call returns from it.
@(private = "file")
flat_mod_tail :: #force_inline proc(x: ^kernel.Flat_Ctx, $L: bool, t: u32) -> bool {
	if !cpu.mod_on || !mod_flat_tail(x, t) {return false}
	when L {kernel.flat_learn_end(x, x.depth)}
	cpu.spin_dirty |= cpu.SPIN_SIDE
	x.pc, x.enter = t, true
	return true
}

// interp_body's goto_pc with nothing registered: a backward jump from pc to
// t checks events, then steps the spin skip (spin_step). True when it ran
// them; the run goes on at x.pc.
@(private = "file")
flat_goto :: #force_inline proc(x: ^kernel.Flat_Ctx, pc, t: u32) -> bool {
	if t > pc || cpu.state.cycles < cpu.next_event {
		spin_step(pc, t)
		return false
	}
	x.pc = t
	kernel.flat_sync()
	kernel.run_events()
	kernel.flat_commit()
	return true
}

// `jr $ra` (jr, with ra the address it jumps to) or ERET ends the
// innermost call: go on at the address its call pushed (x.pc), as
// interp_body's return to its caller does. At depth 0 it ends the run:
// false for a nested run, which returns to the host. A return address
// marked by a hooked call (FLAT_MOD_MARK) runs its after hooks first
// (mod_flat_return), and may end the run. A `jr $ra` to an outer call's
// return address has unwound to it first (flat_unwind). With L, the
// returning function's LEARN frame ends.
@(private = "file")
flat_return :: proc(x: ^kernel.Flat_Ctx, $L: bool, jr: bool, ra: u32) -> bool {
	if x.depth > 0 {
		when L {kernel.flat_learn_end(x, x.depth)}
		x.depth -= 1
		ret := x.ret[x.depth]
		for ret & FLAT_MOD_MARK != 0 {
			again: bool
			if ret, again = mod_flat_return(ret); again {return flat_end(x, L)}
		}
		x.pc = ret &~ kernel.FLAT_HOST_TAIL
		when mem.MOD_PROBE {if mem.mod_ram_has(x.pc) {mem.mod_probe.returns += 1}}
		if jr && ret & kernel.FLAT_HOST_TAIL == 0 {
			cpu.flat_returns += 1
			if ra != x.pc {cpu.flat_mismatch += 1}
		}
		return true
	}
	return flat_end(x, L)
}

// The longjmps shown so far, each kind once under PS_DEBUG (a search past
// cpu.UNWIND_MAX once always): not state.
@(private = "file")
flat_unwind_shown: bit_set[enum {Done, Host, Max, Jump, Under}]

// interp_body's unwind (interp_unwind_find) on the shadow stacks, for a
// `jr $ra` to ra, not with the innermost call's return address and sp
// (x.ra and x.ra_sp at depth 0): the innermost of the cpu.UNWIND_MAX calls
// returning to ra with the guest sp now becomes the innermost, the calls
// above it dropped, when none between was made by the host or is a hooked
// call's (FLAT_HOST_TAIL, FLAT_MOD_MARK). A call that returns to ra with
// another sp is no match. The search goes on into the runs x is nested in
// (the host's, kernel.flat.nest, then the thread's), each one past host
// code. Else the return pops the innermost as before, except when no call
// matches: true, a jump there. With L, the LEARN frames of the calls
// dropped end, as each returns in interp_body's unwind.
@(private = "file")
flat_unwind :: proc(x: ^kernel.Flat_Ctx, $L: bool, ra: u32) -> bool {
	MARKS :: kernel.FLAT_HOST_TAIL | FLAT_MOD_MARK
	sp := u32(cpu.state.r[29].d[0])
	if x.depth > 0 {
		r := x.ret[x.depth - 1]
		if r == ra && x.sp[x.depth - 1] == sp || r & MARKS != 0 {return false}
	} else if ra == x.ra && sp == x.ra_sp {
		return false
	}
	assert(x == kernel.flat_ctx())
	ok := true
	n := 1
	nest := kernel.flat.nest_depth
	for j := 0; j <= nest; j += 1 {
		c := j < nest ? &kernel.flat.nest[nest - 1 - j] : &kernel.flat.ee[kernel.k.current.id]
		top := int(c.depth) - 1
		if j == 0 {
			top -= 1
		} else {
			ok = false
		}
		for k := top; k >= 0; k -= 1 {
			if n == cpu.UNWIND_MAX {
				if .Max not_in flat_unwind_shown {
					flat_unwind_shown += {.Max}
					fmt.eprintfln("ee: jr $ra to %08x: no call returns there in the %d innermost; returning as before", ra, cpu.UNWIND_MAX)
				}
				return false
			}
			n += 1
			r := c.ret[k]
			if r & MARKS != 0 {
				ok = false
				continue
			}
			if r != ra || c.sp[k] != sp {continue}
			if !ok {
				if cpu.debug >= 1 && .Host not_in flat_unwind_shown {
					flat_unwind_shown += {.Host}
					fmt.eprintfln("ee: jr $ra to %08x: the call %d out returns there, past host code; returning as before", ra, n)
				}
				return false
			}
			if cpu.debug >= 1 && .Done not_in flat_unwind_shown {
				flat_unwind_shown += {.Done}
				fmt.eprintfln("ee: jr $ra to %08x: unwound to the call %d out", ra, n)
			}
			when L {kernel.flat_learn_end(x, u32(k) + 2)}
			x.depth = u32(k) + 1
			return false
		}
	}
	if !ok {
		if cpu.debug >= 1 && .Under not_in flat_unwind_shown {
			flat_unwind_shown += {.Under}
			fmt.eprintfln("ee: jr $ra to %08x: no call returns there, host code under the run; returning as before", ra)
		}
		return false
	}
	if cpu.debug >= 1 && .Jump not_in flat_unwind_shown {
		flat_unwind_shown += {.Jump}
		fmt.eprintfln("ee: jr $ra to %08x: no call returns there; a jump", ra)
	}
	return true
}

// The end of run x, at depth 0: false for a nested run. With L, the LEARN
// frames left in it end.
@(private = "file")
flat_end :: proc(x: ^kernel.Flat_Ctx, $L: bool) -> bool {
	when L {kernel.flat_learn_end(x, 0)}
	switch x.end {
	case .Call:
		return false
	case .Main:
		cpu.fatal("entry returned")
	case .Exec:
		cpu.fatal("program %08x started by ExecPS2 returned", kernel.k.current.entry)
	case .Thread:
		kernel.flat_thread_end()
	}
	return true
}
