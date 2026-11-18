// Counts for a FLAT run (core/flat.odin), printed as the game ends.
package ps2_cpu

import "core:fmt"

import "ps:core"

// Calls returned by `jr $ra`, and those of them whose $ra was not the
// address the call pushed: the run went on at the pushed one, as the
// coroutine model's interpreter does (ps2/kernel/flat.odin).
flat_returns, flat_mismatch: u64
// The deepest shadow return stack of any run.
flat_max_depth: u32
// The IOP's counts (r3000.flat_print, or r3000.interp_print without FLAT),
// set once the IOP is (iop_cpu_init).
iop_flat_print: proc()
// IPU commands re-run from a checkpoint after input ran dry, the quadwords
// they replayed, and the most quadwords pulled since any one checkpoint
// (ps2/ipu, the restartable command).
ipu_reruns, ipu_replayed: u64
ipu_journal_max: u32

// Why wasm32 native code (recomp/r5900/native.odin) returned to the FLAT
// runner, which does the rest: compiled code never runs events or a
// syscall in-line, since only the runner may switch threads. A guest call
// it makes in-line (wasm_depth) leaves the runner its frame (wasm_pend).
Native_Exit_Reason :: enum u32 {
	None,   // go on at pc
	Events, // run the due events, then go on at pc; back: a backward jr's second check is owed
	Call,   // a call of pc returning to arg (the runner's flat_enter)
	Return, // `jr $ra` to pc (flat_return)
	Sys,    // the SYSCALL at pc - 4 is to run, then go on at pc
	Eret,   // ERET ran: return from the exception (flat_return)
}

// Written by the code just before it returns; each reason sets the fields
// it names, the rest are stale.
Native_Exit :: struct {
	reason: Native_Exit_Reason,
	pc:     u32,
	arg:    u32,
	back:   u32,
}
native_exit: Native_Exit

// wasm32: native code's calls of native code in-line, without leaving to
// the runner (recomp/r5900/native.odin WASM_CALL). wasm_depth is how many
// are on the host stack now; at WASM_CALL_MAX a call leaves as before.
// wasm_fast_calls counts those made, wasm_fall_* those left to the runner
// by why: events due, mods loaded, no native code at the target in the
// call table, the cap, and (left) a callee that returned some other way
// than a `jr $ra` to the call's return address with the caller's sp.
WASM_CALL_MAX :: 64
wasm_depth: u32
wasm_fast_calls: u64
wasm_fall_events, wasm_fall_mod, wasm_fall_nil, wasm_fall_depth, wasm_fall_left: u64

// The frames of in-line calls whose callee left for the runner, innermost
// first (each caller adds its own as its call returns): the runner pushes
// them, outermost first, before it does what the callee left for, so the
// shadow stack is the one the calls' exits would have made.
Wasm_Frame :: struct {
	ret, sp: u32,
}
wasm_pending: [WASM_CALL_MAX]Wasm_Frame
wasm_npending: u32

// Native code's call of an in-line call's frame, returning to ret with the
// guest sp the call was made with.
wasm_pend :: proc(ret, sp: u32) {
	wasm_pending[wasm_npending] = {ret, sp}
	wasm_npending += 1
	wasm_fall_left += 1
}

flat_print :: proc() {
	when core.FLAT {
		fmt.eprintfln("ee flat: %d returns, %d with $ra not the call's return address, %d deep at most", flat_returns, flat_mismatch, flat_max_depth)
		when ODIN_ARCH == .wasm32 {
			fmt.eprintfln("ee flat: %d native calls in-line; left to the runner: %d events due, %d mods, %d no native code, %d at the cap, %d returned otherwise", wasm_fast_calls, wasm_fall_events, wasm_fall_mod, wasm_fall_nil, wasm_fall_depth, wasm_fall_left)
		}
		fmt.eprintfln("ipu flat: %d re-runs, %d quadwords replayed, %d quadwords since a checkpoint at most", ipu_reruns, ipu_replayed, ipu_journal_max)
		if iop_flat_print != nil {iop_flat_print()}
	} else {
		fmt.eprintfln("ee interp: %d calls open at most, %d barrier records", interp_max_depth, interp_barriers)
		fmt.eprintfln("ee interp: %d unwinds (%d across native code), %d jumps (%d across native code), %d jumps refused at NATIVE_STALE_MAX", interp_unwinds, interp_unwinds_native, interp_jumps, interp_jumps_native, interp_stale)
		if iop_flat_print != nil {iop_flat_print()}
	}
}
