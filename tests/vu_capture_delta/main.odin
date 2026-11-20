// A capture delta (ps2/vu capture_delta), the part of a capture a mid-run
// VU conversion of its first bytes has not seen, gives the converter
// (recomp/vu capture_program_keys) the programs of the whole capture less
// those of its first bytes. Capture A holds image X and two entries into
// it; B, appended, holds a third entry into X (whose image record is only
// in A) and image Y with two entries; the runtime writes a record once per
// file (ps2/vu capture_record), so B repeats none of A. Two mutants must
// fail the check: the delta without the image records it needs from A, and
// a delta from a length inside a record, which capture_delta must refuse.
// A bad record is refused, a record cut short at the end is left out, and
// from 0 gives the whole capture. A record of A repeated in B (an older
// file's) compiles again in the delta: its programs are then those of A+B
// less A's, and the repeated one.
package vu_capture_delta

import "core:fmt"
import "core:os"
import ps2_vu "ps:ps2/vu"
import "ps:recomp/vu"

NOP_L :: 0x8000033c
NOP_U :: 0x000002ff
E_BIT :: 1 << 30
HX :: 0x1111_2222_3333_4444
HY :: 0x5555_6666_7777_8888

// A VU1 micro memory of NOP pairs, with the E bit on the pairs in ends.
image :: proc(ends: []int) -> []u8 {
	m := make([]u8, 16384) // VU1 micro memory, the capture format's image size
	for i in 0 ..< len(m) / 8 {
		put_u32(m[i * 8:], NOP_L)
		put_u32(m[i * 8 + 4:], NOP_U)
	}
	for e in ends {put_u32(m[e * 8 + 4:], NOP_U | E_BIT)}
	return m
}

put_u32 :: proc(b: []u8, x: u32) {for k in 0 ..< 4 {b[k] = u8(x >> (8 * uint(k)))}}
put_u64 :: proc(b: []u8, x: u64) {for k in 0 ..< 8 {b[k] = u8(x >> (8 * uint(k)))}}

rec_i :: proc(out: ^[dynamic]u8, hash: u64, micro: []u8) {
	h: [8]u8
	put_u64(h[:], hash)
	append(out, 'I')
	append(out, ..h[:])
	append(out, ..micro)
}

rec_e :: proc(out: ^[dynamic]u8, hash: u64, pc: u32) {
	r: [12]u8
	put_u64(r[:], hash)
	put_u32(r[8:], pc)
	append(out, 'E')
	append(out, ..r[:])
}

keys_of :: proc(data: []u8) -> map[string]bool {
	k, ok := vu.capture_program_keys(data, .VU1)
	if !ok {fmt.eprintln("vu_capture_delta: the converter rejected a capture")}
	return k
}

// Whether a holds exactly the keys of b not in c.
same_less :: proc(a, b, c: map[string]bool) -> bool {
	n := 0
	for k in b {
		if k in c {continue}
		if k not_in a {return false}
		n += 1
	}
	return n == len(a)
}

main :: proc() {
	failed := 0
	fail :: proc(failed: ^int, msg: string) {
		fmt.eprintln("FAIL vu_capture_delta:", msg)
		failed^ += 1
	}
	x, y := image({2, 6, 10}), image({1, 5})
	ab: [dynamic]u8
	rec_i(&ab, HX, x)
	rec_e(&ab, HX, 0)
	rec_e(&ab, HX, 32)
	a_len := len(ab)
	rec_e(&ab, HX, 64)
	rec_i(&ab, HY, y)
	rec_e(&ab, HY, 0)
	rec_e(&ab, HY, 24)

	full_ab, full_a := keys_of(ab[:]), keys_of(ab[:a_len])
	if len(full_a) != 2 || len(full_ab) != 5 {
		fail(&failed, fmt.tprintf("the captures give %d and %d programs, not 2 and 5", len(full_a), len(full_ab)))
	}
	delta, ok := ps2_vu.capture_delta(ab[:], a_len, 1)
	if !ok {fail(&failed, "the delta at A's length was refused")}
	if !same_less(keys_of(delta), full_ab, full_a) {fail(&failed, "the delta's programs are not those of A+B less A's")}

	// Mutant: the records past A alone, without X's image record.
	if same_less(keys_of(ab[a_len:]), full_ab, full_a) {fail(&failed, "the delta without its image records passes the check")}
	// Mutants: from inside a record.
	for from in ([]int{a_len - 2, 5, a_len + 1}) {
		if _, mid := ps2_vu.capture_delta(ab[:], from, 1); mid {
			fail(&failed, fmt.tprintf("a delta from %d, inside a record, was not refused", from))
		}
	}
	// A bad record anywhere is refused.
	bad := make([dynamic]u8, 0, len(ab) + 13)
	append(&bad, ..ab[:])
	rec_e(&bad, HX, 96)
	bad[len(ab)] = 'Z'
	if _, b := ps2_vu.capture_delta(bad[:], a_len, 1); b {fail(&failed, "a capture with a bad record was not refused")}
	// A record cut short at the end is left out.
	cut := bad[:len(bad) - 4]
	cut[len(ab)] = 'E'
	if end, w := ps2_vu.capture_whole(cut, 1); !w || end != len(ab) {
		fail(&failed, fmt.tprintf("the whole records of a capture cut short end at %d, not %d", end, len(ab)))
	}
	if d, c := ps2_vu.capture_delta(cut, a_len, 1); !c || string(d) != string(delta) {
		fail(&failed, "a delta of a capture cut short is not the delta of its whole records")
	}
	// A repeat of A's entry X@32 in B.
	rep := make([dynamic]u8, 0, len(ab) + 13)
	append(&rep, ..ab[:])
	rec_e(&rep, HX, 32)
	rd, r := ps2_vu.capture_delta(rep[:], a_len, 1)
	rk := keys_of(rd)
	if !r || len(rk) != len(full_ab) - len(full_a) + 1 {
		fail(&failed, fmt.tprintf("a delta with a repeated entry gives %d programs, not %d", len(rk), len(full_ab) - len(full_a) + 1))
	}
	for k in full_ab {if k not_in full_a && k not_in rk {fail(&failed, "a delta with a repeated entry lost a program")}}
	// from 0: the whole capture.
	if d, z := ps2_vu.capture_delta(ab[:], 0, 1); !z || string(d) != string(ab[:]) {fail(&failed, "a delta from 0 is not the capture")}

	if failed > 0 {os.exit(1)}
	fmt.println("vu_capture_delta: ok")
}
