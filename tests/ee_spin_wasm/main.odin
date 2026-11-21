// The EE spin skip (ps2/spin.odin) under a FLAT build for wasi_wasm32
// (run.mjs), where learned code is a wasm32 blob: the skip at a backward
// branch in learned code (recomp/r5900/native.odin spin) and in the FLAT
// interpreter (spin_step). A wait loop polls FLAG, which the vblank hook
// sets at frame FLAG_FRAME; until then the skip must take cycles. Each case
// runs once, in its own process (run.mjs takes the case): wasi has no
// child processes.
//
// The cases: interp, the loop interpreted (no blob); learned, the loop a
// learned function; call, a learned loop that calls a learned function
// that only returns.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
import r5900 "ps:recomp/r5900"

ENTRY :: u32(0x00100000)
W :: ENTRY + 0x100 // the wait loop's function
F :: ENTRY + 0x200 // the function the call case's loop calls
FLAG :: u32(0x00180000) // what the vblank hook sets; t2 points here
RES :: FLAG + 0x10 // Count as the loop ends
STACK :: FLAG + 0x2000
FLAG_FRAME :: 4
FRAMES :: 6
BLOB :: "spin.bin"

ZERO, T0, T1, T2, SP, RA :: u32(0), u32(8), u32(9), u32(10), u32(29), u32(31)
NOP :: u32(0)
JR_RA :: u32(0x03e00008)

lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
jal :: proc(t: u32) -> u32 {return 0x03 << 26 | t >> 2 & 0x03ffffff}
mfc0_count :: proc(rt: u32) -> u32 {return 0x40000000 | rt << 16 | 9 << 11}
// beq rs, rt to t, the branch at pc.
beq :: proc(pc, rs, rt, t: u32) -> u32 {return 0x04 << 26 | rs << 21 | rt << 16 | (t - pc - 4) >> 2 & 0xffff}

put :: proc(at: u32, words: []u32) {
	for w, i in words {mem.wr32(at + 4 * u32(i), w)}
}

skipped: u64
vblanks: [FRAMES]u64

vblank :: proc() {
	f := kernel.k.frame
	if f == 0 || f > FRAMES {return}
	vblanks[f - 1] = cpu.state.cycles
	if f == FLAG_FRAME {
		skipped = cpu.spin_cycles
		mem.wr32(FLAG, 1)
	}
	if f < FRAMES {return}
	fmt.printfln("res %d vblanks %v", mem.rd32(RES), vblanks)
	fmt.printfln("skipped %d, learned calls %d, wasm fast calls %d", skipped, cpu.learned_calls, cpu.wasm_fast_calls)
	os.exit(skipped > 0 && mem.rd32(RES) != 0 ? 0 : 1)
}

main :: proc() {
	when !core.FLAT || ODIN_ARCH != .wasm32 {
		fmt.eprintln("tests/ee_spin_wasm is for a FLAT build for wasi_wasm32 (run.mjs)")
		os.exit(2)
	}
	if len(os.args) != 2 {
		fmt.eprintln("usage: ee_spin_wasm interp|learned|call")
		os.exit(2)
	}
	name := os.args[1]
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	// ENTRY: call W, then store Count and hang.
	put(ENTRY, {lui(SP, STACK >> 16), lui(T2, FLAG >> 16), jal(W), NOP, mfc0_count(T1), sw(T1, RES - FLAG, T2), beq(ENTRY + 24, ZERO, ZERO, ENTRY + 24), NOP})
	// W: poll FLAG (with the call case, call F each pass first).
	w: [dynamic]u32
	if name == "call" {append(&w, addiu(SP, SP, 0xfff0), sw(RA, 0, SP), jal(F), NOP)}
	loop := W + 4 * u32(len(w))
	if name == "call" {loop = W + 8}
	append(&w, lw(T0, 0, T2))
	at := W + 4 * u32(len(w))
	append(&w, beq(at, T0, ZERO, loop), NOP)
	if name == "call" {append(&w, lw(RA, 0, SP), addiu(SP, SP, 16))}
	append(&w, JR_RA, NOP)
	put(W, w[:])
	f := [?]u32{JR_RA, NOP}
	put(F, f[:])
	switch name {
	case "interp":
	case "learned", "call":
		blob, n := r5900.learned_blob({{W, W, w[:]}, {F, F, f[:]}}, .Wasm32)
		if n != 0 || os.write_entire_file(BLOB, blob) != nil || !ps2.load_learned(BLOB) {
			fmt.eprintfln("fail: blob: %d runs not lowered", n)
			os.exit(1)
		}
	case:
		fmt.eprintln("fail: no case", name)
		os.exit(2)
	}
	ps2.spin_on = true
	kernel.vblank_hook = vblank
	ps2.run(ENTRY)
}
