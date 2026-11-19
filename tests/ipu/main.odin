// The IPU's colour conversion (CSC, and IDEC's output) matches a scalar
// per-pixel copy of its formula on random macroblocks and on the edge
// values: Y 0, 16 and 255, Cb and Cr 0, 128 and 255, TH0 off and on, TH1
// at 0, mid and 0x1ff, and the SGN offset both ways. Each pixel takes the
// chroma sample of its 2x2 block.
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import ipu "ps:ps2/ipu"

@(private = "file")
csc_ref :: proc(y: [16][16]u8, cb, cr: [8][8]u8, th0, th1: i32, sgn: bool) -> (out: [256]u32) {
	for row in 0 ..< 16 {
		for x in 0 ..< 16 {
			yy := i32(y[row][x])
			b_ := i32(cb[row >> 1][x >> 1]) - 128
			r_ := i32(cr[row >> 1][x >> 1]) - 128
			lum := (0x95 * max(0, yy - 16)) >> 6
			r := clamp((lum + ((0xcc * r_) >> 6) + 1) >> 1, 0, 255)
			g := clamp((lum + ((-0x68 * r_) >> 6) + ((-0x32 * b_) >> 6) + 1) >> 1, 0, 255)
			b := clamp((lum + ((0x102 * b_) >> 6) + 1) >> 1, 0, 255)
			px := u32(r) | u32(g) << 8 | u32(b) << 16
			px |= r < th1 && g < th1 && b < th1 ? 0x40 << 24 : 0x80 << 24
			if sgn {px ~= 0x808080}
			if th0 > 0 && r < th0 && g < th0 && b < th0 {px = sgn ? 0x808080 : 0}
			out[row * 16 + x] = px
		}
	}
	return
}

main :: proc() {
	failed := 0
	rand.reset(1)
	EDGE :: [3]u8{0, 16, 255}
	CEDGE :: [3]u8{0, 128, 255}
	TH :: [3][2]i32{{0, 0}, {0, 0x80}, {0x60, 0x1ff}}
	for n in 0 ..< 4000 {
		y: [16][16]u8
		cb, cr: [8][8]u8
		for &r in y {for &v in r {v = u8(rand.uint32())}}
		for &r in cb {for &v in r {v = u8(rand.uint32())}}
		for &r in cr {for &v in r {v = u8(rand.uint32())}}
		if n < 27 { // every edge triple, flat over the block
			e, c := EDGE, CEDGE
			for &r in y {for &v in r {v = e[n % 3]}}
			for &r in cb {for &v in r {v = c[(n / 3) % 3]}}
			for &r in cr {for &v in r {v = c[n / 9]}}
		}
		th := TH
		t := th[n % 3]
		if n >= 27 && n % 5 == 0 {t = {i32(rand.uint32() & 0x1ff), i32(rand.uint32() & 0x1ff)}}
		sgn := n & 8 != 0
		got := ipu.csc_probe(y, cb, cr, t[0], t[1], sgn)
		want := csc_ref(y, cb, cr, t[0], t[1], sgn)
		for i in 0 ..< 256 {
			if got[i] != want[i] {
				fmt.eprintfln("csc: case %d pixel %d: %08x, want %08x", n, i, got[i], want[i])
				failed += 1
				break
			}
		}
		if failed > 10 {break}
	}
	if failed > 0 {
		fmt.eprintfln("ipu: %d failed", failed)
		os.exit(1)
	}
	fmt.println("ipu: ok")
}
