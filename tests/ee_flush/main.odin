// The call table as RAM has it (cpu.entries_apply, what the wasm32
// FlushCache check runs), on a synthetic table: function A registered at
// three entries, B at two, as wasm32 code registers each block of a
// function with the function's proc. A changed kept word of A clears every
// entry of A and none of B; a change to a word no entry starts clears
// nothing; the word back brings A back. The result depends on RAM alone:
// applying twice, or applying RAM as it was before a change after one,
// gives the same table. It writes the table while dispatch has it off,
// which is there again once dispatch turns it on.
package main

import "core:fmt"
import "core:os"
import cpu "ps:ps2/cpu"

LO :: u32(0x1000)
HI :: u32(0x2000)
A :: [3]u32{0x1000, 0x1010, 0x1040}
B :: [2]u32{0x1100, 0x1120}

fn_a :: proc() {}
fn_b :: proc() {}

fail :: proc(msg: string) -> ! {
	fmt.eprintln(msg)
	os.exit(1)
}

// Whether every entry of A and of B holds its function (on) or nothing.
expect :: proc(a, b: bool, what: string) {
	for e in A {if (cpu.lookup(e) == fn_a) != a || (cpu.lookup(e) == nil) == a {fail(what)}}
	for e in B {if (cpu.lookup(e) == fn_b) != b || (cpu.lookup(e) == nil) == b {fail(what)}}
}

main :: proc() {
	ram := make([]u8, HI)
	for &b, i in ram {b = u8(i * 7 + 1)}
	cpu.text_range(LO, HI)
	for e in A {cpu.register(e, fn_a)}
	for e in B {cpu.register(e, fn_b)}
	cpu.entries_keep(ram)

	changed, of, fns, slots := cpu.entries_apply(ram)
	if changed != 0 || of != 5 || fns != 0 || slots != 0 {fail("fail: the booted text changed something")}
	expect(true, true, "fail: the booted text dropped a function")

	// A word no entry starts: nothing goes.
	ram[0x1004] += 1
	cpu.entries_apply(ram)
	expect(true, true, "fail: a word past an entry dropped a function")

	// A's second entry: all of A goes, B stays.
	ram[0x1010] += 1
	changed, of, fns, slots = cpu.entries_apply(ram)
	if changed != 1 || fns != 1 || slots != 3 {fail(fmt.tprintf("fail: one changed word of A gave %d words, %d functions, %d entries", changed, fns, slots))}
	expect(false, true, "fail: a changed word of A left an entry of A, or took B")
	cpu.entries_apply(ram)
	expect(false, true, "fail: applying again changed the table")

	// A's word back: A is back.
	ram[0x1010] -= 1
	cpu.entries_apply(ram)
	expect(true, true, "fail: the word back left A out")

	// With dispatch off, the held table is written, and is the table again
	// when dispatch turns on.
	ram[0x1120] += 1
	cpu.dispatch_set(false)
	cpu.entries_apply(ram)
	if cpu.lookup(A[0]) != nil {fail("fail: the table is on with dispatch off")}
	cpu.dispatch_set(true)
	expect(true, false, "fail: the held table does not have B out")
	ram[0x1120] -= 1
	cpu.entries_apply(ram)
	expect(true, true, "fail: B's word back left B out")
	fmt.println("ok call table follows RAM per function")
}
