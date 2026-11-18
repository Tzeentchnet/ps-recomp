// LEARN for the EE under FLAT (ps2/interp_flat.odin), where learned code is
// a step of the runner: a FLAT build for wasi_wasm32 (run.mjs), the learned
// functions a wasm32 blob. Each case calls a function from the host and
// checks the records written when it returns.
//
//   - An interpreted call opens a run at the callee's entry, and each run
//     is written when it returns, closed.
//   - A call to learned code opens no run: the code runs native.
//   - Learned code's jump out of its blocks to code no native code holds (a
//     lookup miss) opens a run there, as learned_goto does after
//     learned_find misses; it is written when it returns.
//   - A jump into learned code where it has no block is interpreted, and
//     opens no run: the pc is no entry. Before the fix every such pc began
//     a run, cut when native code ran next, and a game wrote one at each.
//   - The same for a function of one block (K): its code is entered at
//     its entry alone, and leaves at any other pc with nothing run. Before
//     the fix it ran from the entry wherever it was entered.
//   - An entry the blob's records hold but the compiler left to the
//     interpreter (ps2.learned_refuse) opens no run, at a lookup miss or
//     an interpreted call: each run there would be recorded again, and
//     refused again.
//   - A transfer whose delay slot is a BREAK or SYSCALL is left to the
//     interpreter at its pc; a branch-likely's only when taken. D is the EE
//     compilers' divide-by-zero trap (`beql a1, zero; break 7`), S a
//     `beql a0, zero` with a SYSCALL slot. Each runs learned as it runs
//     interpreted, on both paths: v0, the cycles, and the BREAK's pc
//     (cpu.trap_hook). The leave opens no run.
//   - The report finds no run left open.
//
// Its files are in the WASI shim's in-memory directory, gone at the exit.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import mem "ps:ps2/mem"
import "ps:recomp/r5900"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL ee_flat_learn: %s (line %d)", what, loc.line)
		failed += 1
	}
}

@(private = "file")
PATH :: "learn.bin"
@(private = "file")
BLOB :: "learned.bin"

// No code here: the host's call returns to it (the run's end).
@(private = "file")
RA :: u32(0x001fff00)
@(private = "file")
SP :: u32(0x001ff000)

// The functions. A1..A4 and B, M are interpreted; L and N are learned.
// A caller keeps $ra on the stack: only a `jr $ra` returns under FLAT.
//   A1: PUSH; jal B; nop; lw ra, 0(sp); addiu v0, v0, 1; jr ra; POP.
//   A2: PUSH; jal L; nop; lw ra, 0(sp); jr ra; POP.
//   A3: PUSH; jal N; nop; lw ra, 0(sp); jr ra; POP.
//   A4: j L + 16; nop.
//   B:  addiu v0, zero, 5; jr ra; nop.
//   L:  addiu v0, v0, 1; beq zero, zero, L + 12; nop; addiu v0, v0, 2;
//       addiu v0, v0, 4; jr ra; nop. Two blocks, the branch's target the
//       second: the code finds the block of the pc it is entered at, and
//       leaves at one no block starts at (L + 16) with nothing run.
//   N:  j M; nop.
//   M:  addiu v0, v0, 8; jr ra; nop.
//   A5: PUSH; jal N2; nop; lw ra, 0(sp); jr ra; POP.
//   A6: PUSH; jal R; nop; lw ra, 0(sp); jr ra; POP.
//   N2: j R; nop. Learned.
//   R:  addiu v0, v0, 16; jr ra; nop. A record's entry with no function.
//   A7: j K + 4; nop.
//   K:  addiu v0, v0, 32; addiu v0, v0, 64; jr ra; nop. Learned, one block.
//   D:  div zero, a0, a1; beql a1, zero, D + 12; break 7; addiu v0, v0, 32;
//       jr ra; nop. Learned.
//   S:  addiu v1, zero, 0x2f; beql a0, zero, S + 12; syscall (GetThreadId);
//       addiu v0, v0, 64; jr ra; nop. Learned.
@(private = "file")
A1 :: u32(0x00100000)
@(private = "file")
A2 :: u32(0x00100100)
@(private = "file")
A3 :: u32(0x00100200)
@(private = "file")
A4 :: u32(0x00100300)
@(private = "file")
B :: u32(0x00101000)
@(private = "file")
L :: u32(0x00110000)
@(private = "file")
N :: u32(0x00111000)
@(private = "file")
M :: u32(0x00112000)
@(private = "file")
A5 :: u32(0x00100400)
@(private = "file")
A6 :: u32(0x00100500)
@(private = "file")
N2 :: u32(0x00113000)
@(private = "file")
R :: u32(0x00114000)
@(private = "file")
A7 :: u32(0x00100600)
@(private = "file")
K :: u32(0x00115000)
@(private = "file")
D :: u32(0x00116000)
@(private = "file")
S :: u32(0x00117000)

@(private = "file")
NOP :: u32(0)
@(private = "file")
JR_RA :: u32(0x03e00008)
@(private = "file")
PUSH_1 :: u32(0x27bdfff0) // addiu sp, sp, -16
@(private = "file")
PUSH_2 :: u32(0xafbf0000) // sw ra, 0(sp)
@(private = "file")
LOAD_RA :: u32(0x8fbf0000) // lw ra, 0(sp)
@(private = "file")
POP :: u32(0x27bd0010) // addiu sp, sp, 16

@(private = "file")
jal :: proc(t: u32) -> u32 {return 0x03 << 26 | t >> 2 & 0x03ffffff}
@(private = "file")
j :: proc(t: u32) -> u32 {return 0x02 << 26 | t >> 2 & 0x03ffffff}
@(private = "file")
addiu_v0 :: proc(rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | 2 << 16 | imm & 0xffff}

@(private = "file")
put :: proc(at: u32, words: []u32) {
	for w, i in words {mem.wr32(at + 4 * u32(i), w)}
}

// Call entry from the host as a game's host call does (cpu.call, which
// runs a nested flat run under FLAT) with a0 and a1: v0 as it returns, and
// whether learned code ran.
@(private = "file")
call :: proc(entry: u32, a0: u32 = 0, a1: u32 = 0) -> (u32, bool) {
	cpu.state.r = {}
	cpu.state.r[29].d[0], cpu.state.r[31].d[0] = u64(SP), u64(RA)
	cpu.state.r[4].d[0], cpu.state.r[5].d[0] = u64(a0), u64(a1)
	calls := cpu.learned_calls
	cpu.call(entry)
	return u32(cpu.state.r[2].d[0]), cpu.learned_calls != calls
}

// cpu.trap_hook here: the pc of the last BREAK run, 0 for none.
@(private = "file")
broke: u32

// What a call of a slot case leaves: v0, the BREAK's pc, the cycles it took.
@(private = "file")
Slot_Run :: struct {
	v0, broke: u32,
	cycles:    u64,
}

@(private = "file")
slot_run :: proc(entry, a0, a1: u32) -> (Slot_Run, bool) {
	broke = 0
	at := cpu.state.cycles
	v0, ran := call(entry, a0, a1)
	return {v0, broke, cpu.state.cycles - at}, ran
}

// The slot cases, each an entry and its a0 and a1: D with a divisor and
// without, S with a0 not 0 (the SYSCALL skipped) and 0.
@(private = "file")
SLOT_CASES := [4][3]u32{{D, 7, 3}, {D, 7, 0}, {S, 1, 0}, {S, 0, 0}}

@(private = "file")
Want :: struct {
	entry: u32,
	n:     int,
}

// The file at PATH holds the records want, by entry, each closed and
// starting at its entry with the words RAM holds there.
@(private = "file")
check_file :: proc(want: []Want, what: string) {
	data, err := os.read_entire_file(PATH, context.temp_allocator)
	if err != nil {
		check(false, fmt.tprintf("%s: read %s: %v", what, PATH, err))
		return
	}
	recs, bad := core.learn_read(data, context.temp_allocator)
	check(bad == 0, fmt.tprintf("%s: %d bad records", what, bad))
	slice.sort_by(recs[:], proc(a, b: core.Learn_Record) -> bool {return a.entry < b.entry})
	if len(recs) != len(want) {
		check(false, fmt.tprintf("%s: %d records, want %d", what, len(recs), len(want)))
		for r in recs {fmt.eprintfln("  %08x lo %08x %v n %d", r.entry, r.lo, r.flags, len(r.words))}
		return
	}
	for r, i in recs {
		w := want[i]
		ok := r.cpu == .Ee && r.entry == w.entry && r.lo == w.entry && r.flags == {} && len(r.words) == w.n
		for v, k in r.words {
			ok &&= v == mem.rd32(r.lo + 4 * u32(k))
		}
		check(ok, fmt.tprintf("%s: record %d is %08x lo %08x %v n %d, want %08x n %d", what, i, r.entry, r.lo, r.flags, len(r.words), w.entry, w.n))
	}
}

main :: proc() {
	when !core.FLAT || ODIN_ARCH != .wasm32 {
		fmt.eprintln("tests/ee_flat_learn is for a FLAT build for wasi_wasm32: -define:PS_FLAT=true -target:wasi_wasm32 (run.mjs)")
		os.exit(2)
	}
	ps2.init()
	cpu.next_event = max(u64)
	put(A1, {PUSH_1, PUSH_2, jal(B), NOP, LOAD_RA, addiu_v0(2, 1), JR_RA, POP})
	put(A2, {PUSH_1, PUSH_2, jal(L), NOP, LOAD_RA, JR_RA, POP})
	put(A3, {PUSH_1, PUSH_2, jal(N), NOP, LOAD_RA, JR_RA, POP})
	put(A4, {j(L + 16), NOP})
	put(B, {addiu_v0(0, 5), JR_RA, NOP})
	l := [?]u32{addiu_v0(2, 1), 0x10000001, NOP, addiu_v0(2, 2), addiu_v0(2, 4), JR_RA, NOP} // beq zero, zero, L + 12
	n := [?]u32{j(M), NOP}
	put(L, l[:])
	put(N, n[:])
	put(M, {addiu_v0(2, 8), JR_RA, NOP})
	put(A5, {PUSH_1, PUSH_2, jal(N2), NOP, LOAD_RA, JR_RA, POP})
	put(A6, {PUSH_1, PUSH_2, jal(R), NOP, LOAD_RA, JR_RA, POP})
	n2 := [?]u32{j(R), NOP}
	put(N2, n2[:])
	put(R, {addiu_v0(2, 16), JR_RA, NOP})
	put(A7, {j(K + 4), NOP})
	k := [?]u32{addiu_v0(2, 32), addiu_v0(2, 64), JR_RA, NOP}
	put(K, k[:])
	dz := [?]u32{0x0085001a, 0x50a00001, 0x0007000d, addiu_v0(2, 32), JR_RA, NOP} // div zero, a0, a1; beql a1, zero, +1; break 7
	sc := [?]u32{0x2403002f, 0x50800001, 0x0000000c, addiu_v0(2, 64), JR_RA, NOP} // addiu v1, zero, 0x2f; beql a0, zero, +1; syscall
	put(D, dz[:])
	put(S, sc[:])
	cpu.trap_hook = proc(pc: u32) {broke = pc}
	// The slot cases interpreted, before learning is on: no records.
	want_slot: [len(SLOT_CASES)]Slot_Run
	for c, i in SLOT_CASES {want_slot[i], _ = slot_run(c[0], c[1], c[2])}
	check(want_slot[0].broke == 0 && want_slot[1].broke == D + 8, fmt.tprintf("interpreted D: BREAK at %08x and %08x, want none and %08x", want_slot[0].broke, want_slot[1].broke, D + 8))
	check(want_slot[2].v0 == 64, fmt.tprintf("interpreted S: v0 %d, want 64", want_slot[2].v0))
	core.learn_cpu(.Ee, &cpu.state.cycles, cpu.CYCLES_PER_INSN, proc(a: u32) -> u32 {return mem.rd32(a)}, mem.RAM_SIZE, false)
	check(core.learn_open_path(PATH, {.Ee}), "open")

	v0, ran := call(A1)
	check(v0 == 6 && !ran, fmt.tprintf("A1: v0 %d, learned code ran %v; want 6, none", v0, ran))
	check_file({{A1, 8}, {B, 3}}, "an interpreted call")

	blob, skipped := r5900.learned_blob({{L, L, l[:]}, {N, N, n[:]}, {N2, N2, n2[:]}, {K, K, k[:]}, {D, D, dz[:]}, {S, S, sc[:]}}, .Wasm32)
	check(skipped == 0, fmt.tprintf("%d runs not lowered", skipped))
	check(os.write_entire_file(BLOB, blob) == nil, "write the blob")
	check(ps2.load_learned(BLOB), "load the blob")
	ps2.learned_refuse({L, N, R, N2, R})
	check(!ps2.learned_refused_at(L) && !ps2.learned_refused_at(N2) && ps2.learned_refused_at(R), "the refused set is R alone")

	v0, ran = call(A2)
	check(v0 == 7 && ran, fmt.tprintf("A2: v0 %d, learned code ran %v; want 7, L", v0, ran))
	check_file({{A1, 8}, {A2, 7}, {B, 3}}, "a call to learned code")

	v0, ran = call(A3)
	check(v0 == 8 && ran, fmt.tprintf("A3: v0 %d, learned code ran %v; want 8, N", v0, ran))
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {B, 3}, {M, 3}}, "learned code's jump to a lookup miss")

	v0, _ = call(A4)
	check(v0 == 4, fmt.tprintf("A4: v0 %d, want 4", v0))
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {B, 3}, {M, 3}}, "a jump into learned code where it has no block")

	v0, ran = call(A5)
	check(v0 == 16 && ran, fmt.tprintf("A5: v0 %d, learned code ran %v; want 16, N2", v0, ran))
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {B, 3}, {M, 3}}, "learned code's jump to a refused entry")

	v0, _ = call(A6)
	check(v0 == 16, fmt.tprintf("A6: v0 %d, want 16", v0))
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {B, 3}, {M, 3}}, "an interpreted call to a refused entry")

	v0, _ = call(A7)
	check(v0 == 64, fmt.tprintf("A7: v0 %d, want 64", v0))
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {B, 3}, {M, 3}}, "a jump into a learned function of one block past its entry")

	for c, i in SLOT_CASES {
		got, native_ran := slot_run(c[0], c[1], c[2])
		w := want_slot[i]
		check(native_ran && got == w, fmt.tprintf("learned %08x(%d, %d): v0 %d, BREAK at %08x, %d cycles, learned code ran %v; want v0 %d, BREAK at %08x, %d cycles, ran", c[0], c[1], c[2], got.v0, got.broke, got.cycles, native_ran, w.v0, w.broke, w.cycles))
	}
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {B, 3}, {M, 3}}, "a leave to the interpreter at a delay slot's transfer")

	core.learn_report()
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {B, 3}, {M, 3}}, "the report")
	if failed != 0 {os.exit(1)}
	fmt.println("ok ee_flat_learn: an interpreted call's runs are written as they return; a call to learned code opens none; learned code's jump to a lookup miss opens one there; a jump into learned code where it has no block opens none, in a function of one block too; an entry left to the interpreter opens none; a transfer with a BREAK or SYSCALL slot runs learned as interpreted and opens none; the report finds none open")
}
