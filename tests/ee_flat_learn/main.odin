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
//   - Learned code's call to learned code (C calls E) is made in place by
//     the in-line call routine (ps2.learned_entry), with no trip through
//     the runner, twice. E's words stored over make the call fall to the
//     runner, which interprets E and records it; E's words put back run
//     it in place again. A lookup that skipped the compare would run the
//     old E, and give v0 129 for 257.
//   - A callee whose entry a larger learned function holds in-line (G in
//     H) is called in place by learned code at its own entry, and H at
//     its: learned_entry's cache gives what learned_search would. H's
//     first word stored over leaves G's words as learned, so G is still
//     called in place.
//   - The report finds no run left open.
//   - A loop that stores more often than the store log holds is checked
//     all through, and compiled when clean (S1); storing into its own code
//     it is left to the interpreter (S2).
//   - A stale record an earlier build wrote (.Smc_Unknown, S3's) is
//     compacted away: its entry is not left to the interpreter, so its run
//     is recorded again, clean, and compiled, a stale record beside it or
//     not. A .Smc one (S2's) stays left to the interpreter.
//   - An interpreted call into learned code where it has no block (A14's
//     to L + 16) is an entry: its run is noted, so the next compile holds
//     code that starts there. A4's jump there still notes none. Before
//     the fix such an entry, a thread's loop inside a larger learned
//     function, was interpreted for good.
//
// Its files are in the WASI shim's in-memory directory, gone at the exit.
package main

import "core:fmt"
import "core:hash/xxhash"
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
//   A9: PUSH; jal C2; nop; lw ra, 0(sp); jr ra; POP. A10 the same with C3.
//   C2: PUSH; jal G; nop; lw ra, 0(sp); addiu v0, v0, 1; jr ra; POP.
//       C3 the same with H. Learned.
//   H:  addiu v0, v0, 512, then G: addiu v0, v0, 1024; jr ra; nop. H and
//       G learned, H's words holding G's.
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
A8 :: u32(0x00100700)
@(private = "file")
C :: u32(0x00118000)
@(private = "file")
E :: u32(0x00119000)
@(private = "file")
A9 :: u32(0x00100800)
@(private = "file")
A10 :: u32(0x00100900)
@(private = "file")
C2 :: u32(0x0011a000)
@(private = "file")
C3 :: u32(0x0011b000)
@(private = "file")
H :: u32(0x0011c000)
@(private = "file")
G :: H + 4

// The store loops, their interpreted callers (PUSH; jal S; nop; lw ra,
// 0(sp); jr ra; POP), and their passes (more stores than core.LEARN_STORES_MAX).
@(private = "file")
S1 :: u32(0x00120000)
@(private = "file")
S2 :: u32(0x001f0000) // its stores go down from here, clear of the rest
@(private = "file")
A11 :: u32(0x00100a00)
@(private = "file")
A12 :: u32(0x00100b00)
// S3: S1's loop at another entry, storing from 0x180000 up; A13 calls it.
@(private = "file")
S3 :: u32(0x00121000)
@(private = "file")
A13 :: u32(0x00100c00)
// A14: PUSH; jal L + 16; nop; lw ra, 0(sp); jr ra; POP. A call into L where
// it has no block, as a thread's start or a call can enter a larger
// learned function's code at an entry of its own.
@(private = "file")
A14 :: u32(0x00100d00)
@(private = "file")
LOOPS :: u32(70000)
#assert(LOOPS > core.LEARN_STORES_MAX)

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

// Append a record of words at entry, as a LEARN file holds it.
@(private = "file")
record :: proc(b: ^[dynamic]u8, flags: core.Learn_Flags, entry: u32, words: []u32) {
	bytes := slice.to_bytes(words)
	h: [core.LEARN_HEADER]u8
	core.learn_header(h[:], .Ee, flags, entry, entry, u32(len(words)), xxhash.XXH3_64_default(bytes))
	append(b, ..h[:])
	append(b, ..bytes)
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
	put(A8, {PUSH_1, PUSH_2, jal(C), NOP, LOAD_RA, JR_RA, POP})
	cc := [?]u32{PUSH_1, PUSH_2, jal(E), NOP, LOAD_RA, addiu_v0(2, 1), JR_RA, POP}
	ee := [?]u32{addiu_v0(2, 128), JR_RA, NOP}
	put(C, cc[:])
	put(E, ee[:])
	put(A9, {PUSH_1, PUSH_2, jal(C2), NOP, LOAD_RA, JR_RA, POP})
	put(A10, {PUSH_1, PUSH_2, jal(C3), NOP, LOAD_RA, JR_RA, POP})
	c2 := [?]u32{PUSH_1, PUSH_2, jal(G), NOP, LOAD_RA, addiu_v0(2, 1), JR_RA, POP}
	c3 := [?]u32{PUSH_1, PUSH_2, jal(H), NOP, LOAD_RA, addiu_v0(2, 1), JR_RA, POP}
	hh := [?]u32{addiu_v0(2, 512), addiu_v0(2, 1024), JR_RA, NOP}
	put(C2, c2[:])
	put(C3, c3[:])
	put(H, hh[:])
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

	blob, skipped := r5900.learned_blob({{L, L, l[:]}, {N, N, n[:]}, {N2, N2, n2[:]}, {K, K, k[:]}, {D, D, dz[:]}, {S, S, sc[:]}, {C, C, cc[:]}, {E, E, ee[:]}, {C2, C2, c2[:]}, {C3, C3, c3[:]}, {H, H, hh[:]}, {G, G, hh[1:]}}, .Wasm32)
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

	for pass in 0 ..< 2 {
		fast, nils, calls := cpu.wasm_fast_calls, cpu.wasm_fall_nil, cpu.learned_calls
		v0, ran = call(A8)
		check(v0 == 129 && ran && cpu.wasm_fast_calls - fast == 1 && cpu.wasm_fall_nil == nils && cpu.learned_calls - calls == 2, fmt.tprintf("A8 pass %d: v0 %d, ran %v, %d in place, %d fell for no code, %d learned calls; want 129, ran, 1, 0, 2", pass, v0, ran, cpu.wasm_fast_calls - fast, cpu.wasm_fall_nil - nils, cpu.learned_calls - calls))
	}
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {A8, 7}, {B, 3}, {M, 3}}, "learned code's call to learned code")
	e2 := [?]u32{addiu_v0(2, 256), JR_RA, NOP}
	put(E, e2[:])
	{
		fast, nils, stale := cpu.wasm_fast_calls, cpu.wasm_fall_nil, cpu.learned_stale
		v0, ran = call(A8)
		check(v0 == 257 && ran && cpu.wasm_fast_calls == fast && cpu.wasm_fall_nil - nils == 1 && cpu.learned_stale > stale, fmt.tprintf("A8, E stored over: v0 %d, ran %v, %d in place, %d fell for no code, %d interpreted; want 257, ran, 0, 1, some", v0, ran, cpu.wasm_fast_calls - fast, cpu.wasm_fall_nil - nils, cpu.learned_stale - stale))
	}
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {A8, 7}, {B, 3}, {M, 3}, {E, 3}}, "learned code's call to learned code stored over")
	put(E, ee[:])
	{
		fast := cpu.wasm_fast_calls
		v0, ran = call(A8)
		check(v0 == 129 && ran && cpu.wasm_fast_calls - fast == 1, fmt.tprintf("A8, E put back: v0 %d, ran %v, %d in place; want 129, ran, 1", v0, ran, cpu.wasm_fast_calls - fast))
	}
	put(E, e2[:]) // the words E's record holds, for the checks below

	// G in H: each called in place at its own entry, twice (the second a
	// cache hit), and G still in place with H's first word stored over.
	for pass in 0 ..< 3 {
		if pass == 2 {mem.wr32(H, NOP)}
		fast, nils := cpu.wasm_fast_calls, cpu.wasm_fall_nil
		v0, ran = call(A9)
		check(v0 == 1025 && ran && cpu.wasm_fast_calls - fast == 1 && cpu.wasm_fall_nil == nils, fmt.tprintf("A9 pass %d: v0 %d, ran %v, %d in place, %d fell for no code; want 1025, ran, 1, 0", pass, v0, ran, cpu.wasm_fast_calls - fast, cpu.wasm_fall_nil - nils))
		if pass == 2 {break}
		fast, nils = cpu.wasm_fast_calls, cpu.wasm_fall_nil
		v0, ran = call(A10)
		check(v0 == 1537 && ran && cpu.wasm_fast_calls - fast == 1 && cpu.wasm_fall_nil == nils, fmt.tprintf("A10 pass %d: v0 %d, ran %v, %d in place, %d fell for no code; want 1537, ran, 1, 0", pass, v0, ran, cpu.wasm_fast_calls - fast, cpu.wasm_fall_nil - nils))
	}
	put(H, hh[:])

	for c, i in SLOT_CASES {
		got, native_ran := slot_run(c[0], c[1], c[2])
		w := want_slot[i]
		check(native_ran && got == w, fmt.tprintf("learned %08x(%d, %d): v0 %d, BREAK at %08x, %d cycles, learned code ran %v; want v0 %d, BREAK at %08x, %d cycles, ran", c[0], c[1], c[2], got.v0, got.broke, got.cycles, native_ran, w.v0, w.broke, w.cycles))
	}
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {A8, 7}, {A9, 7}, {A10, 7}, {B, 3}, {M, 3}, {E, 3}}, "a leave to the interpreter at a delay slot's transfer")

	core.learn_report()
	check_file({{A1, 8}, {A2, 7}, {A3, 7}, {A4, 2}, {A5, 7}, {A6, 7}, {A7, 2}, {A8, 7}, {A9, 7}, {A10, 7}, {B, 3}, {M, 3}, {E, 3}}, "the report")

	// A loop that stores more often than the store log holds (each pass to
	// the next word, the log noting each): its run is checked all through,
	// clean, and compiled; the same loop storing into its own code first is
	// marked .Smc, left out, and runs interpreted.
	//   lui t1, hi; ori t1, t1, lo; lui t0, 1; ori t0, t0, 0x1170 (70000);
	//   nop; loop: sw zero, 0(t1); addiu t1, t1, step; addiu t0, t0, -1;
	//   bne t0, zero, loop; addiu v0, v0, 1; jr ra; nop.
	// S1 stores from 0x130000 up, clear of its code. S2 stores from its nop
	// down, over its first words (run by then) and on below: its first
	// store is into a word its run fetched, as a store after it fetched one
	// is all a record can be marked by.
	{
		loop :: proc(at, step: u32) -> [12]u32 {
			return {
				0x3c09_0000 | at >> 16, 0x3529_0000 | at & 0xffff, 0x3c08_0001, 0x3508_1170, NOP,
				0xad20_0000, 0x2529_0000 | step & 0xffff, 0x2508_ffff, 0x1500_fffc, addiu_v0(2, 1), JR_RA, NOP,
			}
		}
		s1, s2 := loop(0x0013_0000, 4), loop(S2 + 16, ~u32(3))
		put(S1, s1[:])
		put(S2, s2[:])
		put(A11, {PUSH_1, PUSH_2, jal(S1), NOP, LOAD_RA, JR_RA, POP})
		put(A12, {PUSH_1, PUSH_2, jal(S2), NOP, LOAD_RA, JR_RA, POP})
		long_path :: "long.bin"
		check(core.learn_open_path(long_path, {.Ee}), "open for the loops")
		v0, ran = call(A11)
		check(v0 == LOOPS && !ran, fmt.tprintf("S1: v0 %d, learned code ran %v; want %d, none", v0, ran, LOOPS))
		v0, ran = call(A12)
		check(v0 == LOOPS && !ran, fmt.tprintf("S2: v0 %d, learned code ran %v; want %d, none", v0, ran, LOOPS))
		put(S2, s2[:]) // its stores zeroed its first words
		core.learn_report()
		// Not the temp allocator: learned_blob frees it all.
		data, err := os.read_entire_file(long_path, context.allocator)
		check(err == nil, fmt.tprintf("read %s: %v", long_path, err))
		recs, bad := core.learn_read(data, context.allocator)
		check(bad == 0, fmt.tprintf("loops: %d bad records", bad))
		flags: [2]core.Learn_Flags
		seen: [2]int
		for r in recs {
			if r.entry != S1 && r.entry != S2 {continue}
			k := r.entry == S1 ? 0 : 1
			flags[k] = r.flags
			seen[k] += 1
		}
		check(seen == {1, 1} && flags[0] == {} && flags[1] == {.Smc}, fmt.tprintf("loops: S1 %d records %v, S2 %d %v; want 1 clean, 1 .Smc", seen[0], flags[0], seen[1], flags[1]))
		out, _, smc := core.learn_compilable(recs[:], .Ee, context.allocator)
		runs := make([dynamic]r5900.Learned, context.allocator)
		for r in out {
			if r.entry == S1 || r.entry == S2 {append(&runs, r5900.Learned{r.entry, r.lo, r.words})}
		}
		check(len(runs) == 1 && runs[0].entry == S1 && smc >= 1, fmt.tprintf("loops: %d compiled, %d stored into; want S1 alone", len(runs), smc))
		loops_blob, loops_skipped := r5900.learned_blob(runs[:], .Wasm32)
		check(loops_skipped == 0, fmt.tprintf("loops: %d runs not lowered", loops_skipped))
		check(os.write_entire_file("loops.bin", loops_blob) == nil, "write the loops' blob")
		check(ps2.load_learned("loops.bin"), "load the loops' blob")
		v0, ran = call(A11)
		check(v0 == LOOPS && ran, fmt.tprintf("S1 learned: v0 %d, learned code ran %v; want %d, ran", v0, ran, LOOPS))
		v0, ran = call(A12)
		check(v0 == LOOPS && !ran, fmt.tprintf("S2 left out: v0 %d, learned code ran %v; want %d, none", v0, ran, LOOPS))

		// Records an earlier build wrote: S3's .Smc_Unknown (its store log
		// overflowed), stale; S2's .Smc, a real store. Compacted, the stale
		// record is gone and S2's kept, so S3 is no entry left to the
		// interpreter (learned_refuse, as play makes it from the records):
		// its run is recorded again, clean, and compiled, a stale record
		// beside it or not. S2 stays left out, and opens no run.
		s3 := loop(0x0018_0000, 4)
		put(S3, s3[:])
		put(A13, {PUSH_1, PUSH_2, jal(S3), NOP, LOAD_RA, JR_RA, POP})
		put(S2, s2[:]) // the last call's stores zeroed its first words
		stale := make([dynamic]u8, context.allocator)
		record(&stale, {.Smc_Unknown, .Open}, S3, s3[:])
		record(&stale, {.Smc}, S2, s2[:])
		compact, n := core.learn_compact(stale[:])
		crecs, _ := core.learn_read(compact, context.allocator)
		check(n == 1 && crecs[0].entry == S2 && crecs[0].flags == {.Smc}, fmt.tprintf("stale: compacted to %d records %v; want S2's .Smc alone", n, crecs[:]))
		entries := make([dynamic]u32, context.allocator)
		for r in crecs {append(&entries, r.entry)}
		ps2.learned_refuse(entries[:])
		check(!ps2.learned_refused_at(S3) && ps2.learned_refused_at(S2), "stale: S2 alone left to the interpreter")
		relearn_path :: "relearn.bin"
		check(os.write_entire_file(relearn_path, compact) == nil, "write the compacted records")
		check(core.learn_open_path(relearn_path, {.Ee}), "open for the relearn")
		v0, ran = call(A13)
		check(v0 == LOOPS && !ran, fmt.tprintf("S3 relearned: v0 %d, learned code ran %v; want %d, none", v0, ran, LOOPS))
		v0, ran = call(A12)
		check(v0 == LOOPS && !ran, fmt.tprintf("S2 refused: v0 %d, learned code ran %v; want %d, none", v0, ran, LOOPS))
		put(S2, s2[:])
		core.learn_report()
		again, aerr := os.read_entire_file(relearn_path, context.allocator)
		check(aerr == nil, fmt.tprintf("read %s: %v", relearn_path, aerr))
		append(&stale, ..again) // the stale record beside the new clean one
		compact, n = core.learn_compact(stale[:])
		all, _ := core.learn_read(compact, context.allocator)
		clear(&crecs)
		for r in all {
			if r.entry == S2 || r.entry == S3 {append(&crecs, r)} // not A13's
		}
		Want_Flags :: struct {
			entry: u32,
			flags: core.Learn_Flags,
		}
		want := [?]Want_Flags{{S2, {.Smc}}, {S3, {}}}
		slice.sort_by(crecs[:], proc(a, b: core.Learn_Record) -> bool {return a.entry > b.entry})
		ok := len(crecs) == 2
		for r, i in crecs {ok &&= i < 2 && r.entry == want[i].entry && r.flags == want[i].flags}
		check(ok, fmt.tprintf("relearned: %d records %v; want S3 clean, S2 .Smc", len(crecs), crecs[:]))
		out, _, _ = core.learn_compilable(crecs[:], .Ee, context.allocator)
		clear(&runs)
		for r in out {
			if r.entry == S2 || r.entry == S3 {append(&runs, r5900.Learned{r.entry, r.lo, r.words})}
		}
		check(len(runs) == 1 && runs[0].entry == S3, fmt.tprintf("relearned: %d compiled; want S3 alone", len(runs)))
		relearned, rskipped := r5900.learned_blob(runs[:], .Wasm32)
		check(rskipped == 0 && os.write_entire_file("relearned.bin", relearned) == nil && ps2.load_learned("relearned.bin"), "load the relearned blob")
		v0, ran = call(A13)
		check(v0 == LOOPS && ran, fmt.tprintf("S3 relearned, learned: v0 %d, learned code ran %v; want %d, ran", v0, ran, LOOPS))
	}
	{
		eblob, eskipped := r5900.learned_blob({{L, L, l[:]}}, .Wasm32)
		check(eskipped == 0 && os.write_entire_file("entered.bin", eblob) == nil && ps2.load_learned("entered.bin"), "load L's blob")
		ps2.learned_refuse({L})
		put(A14, {PUSH_1, PUSH_2, jal(L + 16), NOP, LOAD_RA, JR_RA, POP})
		entered_path :: "entered-learn.bin"
		check(core.learn_open_path(entered_path, {.Ee}), "open for the entered call")
		v0, _ = call(A4)
		check(v0 == 4, fmt.tprintf("entered: A4: v0 %d, want 4", v0))
		v0, _ = call(A14)
		check(v0 == 4, fmt.tprintf("entered: A14: v0 %d, want 4", v0))
		core.learn_report()
		edata, eerr := os.read_entire_file(entered_path, context.allocator)
		check(eerr == nil, fmt.tprintf("read %s: %v", entered_path, eerr))
		erecs, _ := core.learn_read(edata, context.allocator)
		slice.sort_by(erecs[:], proc(a, b: core.Learn_Record) -> bool {return a.entry < b.entry})
		ewant := [?]Want{{A14, 7}, {L + 16, 3}} // A4's record is written already
		eok := len(erecs) == len(ewant)
		for r, i in erecs {eok &&= i < len(ewant) && r.entry == ewant[i].entry && r.lo == r.entry && r.flags == {} && len(r.words) == ewant[i].n}
		check(eok, fmt.tprintf("entered: %d records; want A14 n 7, L + 16 n 3 (A4 first, noting none there)", len(erecs)))
		if !eok {for r in erecs {fmt.eprintfln("  %08x lo %08x %v n %d", r.entry, r.lo, r.flags, len(r.words))}}
	}
	if failed != 0 {os.exit(1)}
	fmt.println("ok ee_flat_learn: an interpreted call's runs are written as they return; a call to learned code opens none; learned code's jump to a lookup miss opens one there; a jump into learned code where it has no block opens none, in a function of one block too; an entry left to the interpreter opens none; a transfer with a BREAK or SYSCALL slot runs learned as interpreted and opens none; learned code's call to learned code is made in place while RAM holds the callee's words, at an entry a larger function holds in-line too; the report finds none open; a loop storing more often than the store log holds is checked all through and compiled when clean, and left to the interpreter when it stores into its own code; a stale .Smc_Unknown record is compacted away, so its entry is recorded again and compiled, while a .Smc one stays left to the interpreter; a call into learned code where it has no block notes a run there, a jump there none")
}
