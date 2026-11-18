// The EE spin skip (ps2/spin.odin) on loops that call, under FLAT
// (-define:PS_FLAT=true), whose runs keep the calls as data (interp_flat):
// a call there is no side effect, so a loop that calls may be skipped, and
// what the call leaves on the shadow stack is compared instead (kernel
// spin_flat_same). Each case runs as a child process twice, the skip on and
// off, from the same start, and both must print the same: the cycles at
// each vblank, the words the program stores as it leaves the loop (COP0
// Count among them) and the shadow stack's depth and innermost return
// address. The loop polls FLAG, which the vblank hook sets at frame
// FLAG_FRAME; the skip on must take cycles before then where the case says.
//
// The cases: a loop that calls a function that only returns (skipped); one
// whose function counts in memory (not skipped); and one whose passes match
// in cpu.state but not on the shadow stack (not skipped). In the last, more
// than cpu.UNWIND_MAX calls are open, so a `jr $ra` to an address no call
// returns to pops the innermost call and goes on at its return address, P
// or Q in turn: P calls T again from the call returning to Q, Q from the one
// returning to P, and T sets $ra to that address again and branches back.
// The innermost return address is all that tells two passes apart, and it
// decides where the loop ends: a skip of an odd count of passes would leave
// at the other one.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"

ENTRY :: u32(0x00100000)
FLAG :: u32(0x00180000) // what the vblank hook sets; t2 points here
RES :: FLAG + 0x10 // Count as the loop ends, then which way it ended
COUNT :: FLAG + 0x20 // the counting function's word
STACK :: FLAG + 0x2000
NOWHERE :: u32(0x00170000) // no call returns here
FLAG_FRAME :: 4
FRAMES :: 8 // vblanks noted; the child prints at the last
DEPTH :: cpu.UNWIND_MAX + 6 // calls the stack case leaves open first

ZERO, T0, T1, T2, T3, A0, SP, RA :: u32(0), u32(8), u32(9), u32(10), u32(11), u32(4), u32(29), u32(31)
NOP :: u32(0)
JR_RA :: u32(0x03e00008)

Asm :: struct {
	words: [dynamic]u32,
}

pc :: proc(a: ^Asm) -> u32 {return ENTRY + 4 * u32(len(a.words))}
put :: proc(a: ^Asm, w: ..u32) {append(&a.words, ..w)}
lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm & 0xffff}
ori :: proc(rt, rs, imm: u32) -> u32 {return 0x0d << 26 | rs << 21 | rt << 16 | imm & 0xffff}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
jal :: proc(t: u32) -> u32 {return 0x03 << 26 | t >> 2 & 0x03ffffff}
j :: proc(t: u32) -> u32 {return 0x02 << 26 | t >> 2 & 0x03ffffff}
mfc0_count :: proc(rt: u32) -> u32 {return 0x40000000 | rt << 16 | 9 << 11}
// A branch at a's pc, the next word put, to t: a put's first word: beq (4) or bne (5).
br :: proc(a: ^Asm, op, rs, rt, t: u32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (t - pc(a) - 4) >> 2 & 0xffff}

// The loop's end: RES = Count, RES + 4 = t3, and a hang.
done :: proc(a: ^Asm) {
	put(a, mfc0_count(T1), sw(T1, RES - FLAG, T2), sw(T3, RES + 4 - FLAG, T2))
	put(a, br(a, 4, ZERO, ZERO, pc(a)), NOP)
}

// loop: jal F, then poll FLAG and branch back. F returns, counting in
// COUNT first with count.
program_call :: proc(a: ^Asm, count: bool) {
	put(a, lui(SP, STACK >> 16), lui(T2, FLAG >> 16))
	loop := pc(a)
	f := loop + 4 * 16
	put(a, jal(f), NOP, lw(T0, 0, T2))
	put(a, br(a, 4, T0, ZERO, loop), NOP)
	done(a)
	assert(pc(a) <= f)
	for pc(a) < f {put(a, NOP)}
	if count {put(a, lw(T3, COUNT - FLAG, T2), addiu(T3, T3, 1), sw(T3, COUNT - FLAG, T2), addiu(T3, ZERO, 0))}
	put(a, JR_RA, NOP)
}

// The stack case; see the top of the file. BUILD calls BF DEPTH times, BF
// jumping back each time, then on to CP. Q's jump back to CP is longer than
// a spin loop (ps2.SPIN_SPAN), so T's branch back to L, on every pass, is
// the loop's one probe site: a site passed every other pass would see the
// same shadow stack each time, and the skip of an even count of passes from
// there is right. Offsets are fixed up front.
program_stack :: proc(a: ^Asm) {
	build := ENTRY + 4 * 3
	bf := build + 4 * 3 // past a word: a call to its own return address is no call
	cp := bf + 4 * 5
	p := cp + 4 * 2
	cq := p + 4 * (5 + ps2.SPIN_SPAN)
	q := cq + 4 * 2
	l := q + 4 * 5
	t := l + 4 * 2
	done_p := t + 4 * 4
	done_q := done_p + 4 * 3
	put(a, lui(SP, STACK >> 16), lui(T2, FLAG >> 16), addiu(A0, ZERO, DEPTH))
	assert(pc(a) == build)
	put(a, jal(bf), NOP, NOP)
	put(a, addiu(A0, A0, 0xffff))
	put(a, br(a, 5, A0, ZERO, build), NOP, j(cp), NOP)
	assert(pc(a) == cp)
	put(a, jal(t), NOP)
	assert(pc(a) == p)
	put(a, lw(T0, 0, T2))
	put(a, br(a, 5, T0, ZERO, done_p), NOP, j(cq), NOP)
	for pc(a) < cq {put(a, NOP)}
	put(a, jal(t), NOP)
	assert(pc(a) == q)
	put(a, lw(T0, 0, T2))
	put(a, br(a, 5, T0, ZERO, done_q), NOP, j(cp), NOP)
	assert(pc(a) == l)
	put(a, JR_RA, NOP)
	assert(pc(a) == t)
	put(a, lui(RA, NOWHERE >> 16), ori(RA, RA, NOWHERE))
	put(a, br(a, 4, ZERO, ZERO, l), NOP)
	assert(pc(a) == done_p)
	put(a, addiu(T3, ZERO, 1))
	put(a, br(a, 4, ZERO, ZERO, done_q + 4), NOP)
	assert(pc(a) == done_q)
	put(a, addiu(T3, ZERO, 2))
	done(a)
}

Case :: struct {
	name:    string,
	skipped: bool, // whether the skip on must take cycles before FLAG_FRAME
}

CASES :: [?]Case{{"call", true}, {"count", false}, {"stack", false}}

vblanks: [FRAMES]u64
skipped: u64

vblank :: proc() {
	f := kernel.k.frame
	if f == 0 || f > FRAMES {return}
	vblanks[f - 1] = cpu.state.cycles
	if f == FLAG_FRAME {
		skipped = cpu.spin_cycles
		mem.wr32(FLAG, 1)
	}
	if f < FRAMES {return}
	x := kernel.flat_ctx()
	top := x.depth > 0 ? x.ret[x.depth - 1] : 0
	fmt.printfln("res %d %d count %d depth %d top %08x vblanks %v", mem.rd32(RES), mem.rd32(RES + 4), mem.rd32(COUNT), x.depth, top, vblanks)
	fmt.printfln("skipped %d", skipped)
	os.exit(0)
}

// The child: run case name with the skip on or off.
child :: proc(name, on: string) -> ! {
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	a: Asm
	switch name {
	case "call":
		program_call(&a, false)
	case "count":
		program_call(&a, true)
	case "stack":
		program_stack(&a)
	case:
		fmt.eprintln("fail: no case", name)
		os.exit(1)
	}
	for w, n in a.words {mem.wr32(ENTRY + 4 * u32(n), w)}
	ps2.spin_on = on == "on"
	kernel.vblank_hook = vblank
	ps2.run(ENTRY)
}

main :: proc() {
	when !core.FLAT {
		fmt.eprintln("fail: ee_spin_flat: build with -define:PS_FLAT=true")
		os.exit(1)
	}
	if len(os.args) == 3 {child(os.args[1], os.args[2])}
	self, _ := os.get_executable_path(context.temp_allocator)
	failed := 0
	for c in CASES {
		got: [2][]string
		for on, n in ([2]string{"on", "off"}) {
			state, out, errs, perr := os.process_exec({command = {self, c.name, on}}, context.temp_allocator)
			lines := strings.split_lines(strings.trim_space(string(out)), context.temp_allocator)
			if perr != nil || state.exit_code != 0 || len(lines) != 2 {
				fmt.eprintfln("FAIL %s %s: %v exit %d, said %q %q", c.name, on, perr, state.exit_code, string(out), string(errs))
				os.exit(1)
			}
			got[n] = lines
		}
		on_skipped, off_skipped := got[0][1], got[1][1]
		if got[0][0] != got[1][0] {
			failed += 1
			fmt.eprintfln("FAIL %s: skip on and off differ\n  on  %s\n  off %s", c.name, got[0][0], got[1][0])
		}
		if off_skipped != "skipped 0" || (on_skipped != "skipped 0") != c.skipped {
			failed += 1
			fmt.eprintfln("FAIL %s: %s on, %s off; want skipped %v", c.name, on_skipped, off_skipped, c.skipped)
		}
		fmt.printfln("%-6s %s, %s", c.name, got[0][0], on_skipped)
	}
	if failed != 0 {os.exit(1)}
	fmt.println("ok")
}
