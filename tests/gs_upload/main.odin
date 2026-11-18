// Host-to-local PSMT8 transfers (gs.transfer) against write_raw per pixel,
// byte for byte over all of local memory: every x and y alignment 0..15,
// widths and heights 1..40, DBW 1, 2, 4 and 10, offsets that cross a page
// edge or run past 2048 and wrap, with the data in one packet or split
// at odd byte counts.
package main

import "core:fmt"
import "core:os"
import "ps:ps2/gs"

@(private = "file")
seed: u64 = 0x9e3779b97f4a7c15

// xorshift64*, fixed seed: the same trials every run.
@(private = "file")
rnd :: proc() -> u64 {
	seed ~= seed >> 12
	seed ~= seed << 25
	seed ~= seed >> 27
	return seed * 0x2545f4914f6cdd1d
}

@(private = "file")
saved, want: [gs.VRAM_WORDS]u32

@(private = "file")
data: [40 * 40]u8

@(private = "file")
failed, trials := 0, 0

// One transfer of w x h pixels to (dx, dy) of the buffer at block dbp,
// width dbw, against write_raw from the same local memory. split: packet
// sizes cycle through 1, 7 and 33 bytes instead of one packet.
@(private = "file")
trial :: proc(dbp, dbw, dx, dy, w, h: u32, split: bool) {
	trials += 1
	n := int(w * h)
	for &b in data[:n] {b = u8(rnd())}
	saved = gs.vram
	for y in 0 ..< h {
		for x in 0 ..< w {
			gs.write_raw(gs.PSMT8, dbp, dbw, (dx + x) & 2047, (dy + y) & 2047, u32(data[y * w + x]))
		}
	}
	want = gs.vram
	gs.vram = saved
	gs.gs_write(0x50, u64(dbp) << 32 | u64(dbw) << 48 | u64(gs.PSMT8) << 56) // BITBLTBUF: DBP, DBW, DPSM
	gs.gs_write(0x51, u64(dx) << 32 | u64(dy) << 48) // TRXPOS: DSAX, DSAY
	gs.gs_write(0x52, u64(w) | u64(h) << 32) // TRXREG: RRW, RRH
	gs.gs_write(0x53, 0) // TRXDIR: host to local
	if split {
		sizes := [3]int{1, 7, 33}
		for i, k := 0, 0; i < n; k += 1 {
			m := min(sizes[k % 3], n - i)
			gs.transfer(data[i:][:m])
			i += m
		}
	} else {
		gs.transfer(data[:n])
	}
	if gs.vram != want {
		failed += 1
		if failed <= 10 {
			for v, i in gs.vram {
				if v != want[i] {
					fmt.eprintfln("FAIL dbp %d dbw %d at (%d, %d) %dx%d split %v: word %x is %08x, want %08x", dbp, dbw, dx, dy, w, h, split, i, v, want[i])
					break
				}
			}
		}
	}
}

main :: proc() {
	gs.state.write = gs.write
	for i in 0 ..< len(gs.vram) {gs.vram[i] = u32(rnd())}
	dbws := [?]u32{1, 2, 4, 10}
	// Every alignment, with sizes stepping through 1..40.
	k: u32 = 0
	for dbw in dbws {
		for ay in u32(0) ..< 16 {
			for ax in u32(0) ..< 16 {
				w, h := 1 + k % 40, 1 + (k * 7 + 3) % 40
				trial(0x100, dbw, 128 + ax, 64 + ay, w, h, k & 1 == 1)
				k += 1
			}
		}
	}
	// Every size at two alignments.
	for h in u32(1) ..= 40 {
		for w in u32(1) ..= 40 {
			trial(0x200, 2, 16 + 5 * (w & 1), 32 + 3 * (h & 1), w, h, (w + h) & 1 == 1)
		}
	}
	// Page edges (PSMT8 pages are 128 x 64) and the 2048 wrap.
	for dbw in dbws {
		for o in ([?][2]u32{{120, 0}, {0, 56}, {121, 59}, {2040, 0}, {0, 2041}, {2039, 2037}, {2047, 2047}}) {
			trial(0x40, dbw, o[0], o[1], 23, 17, false)
			trial(0x40, dbw, o[0], o[1], 40, 40, true)
		}
	}
	if failed > 0 {
		fmt.eprintfln("%d of %d transfers differ", failed, trials)
		os.exit(1)
	}
	fmt.printfln("ok gs_upload: %d transfers", trials)
}
