// The GPU GS against the software GS, bit for bit on all of local memory,
// for draws that sample the buffers they write: per case a picture
// uploaded, then sprites over it, each pixel sampling a texel the same
// sprite writes later in the software GS's order. Each case runs twice in
// a row in software and twice on the GPU, every GPU case against its
// software twin, so a race between a primitive's samples and its own
// writes shows as a mismatch. Each resolution scale runs in a child of its
// own (the GPU GS starts once a process). Two cases instead upload over a
// decoded texture between two samples of it, for the pages a transfer
// writes, one of them a single page; one draws two sprites per state, the
// second sampling what the first wrote. The clut cases repeat a CLUT load,
// CSM1 and CT16 CSM2, with nothing, an upload, a draw, a depth-only draw,
// or a partial load of another key between (the GPU GS skips a repeat
// whose source pages nobody wrote), and draw with no load after a save
// state is loaded back and in the next frame. The clut hit cases reload an
// older key (the GPU GS reuses its copy, a hit): a PSMT8 draw, a draw
// reading past the hit's entries, a hit then a save state, a hit then a
// ring overflow, hits over each other replayed in order, a hit whose source
// is written before a draw reading past it, a hit wrapping past entry 511,
// 17 hits in a row (one more than a dispatch replays), and a TEX0_2 hit
// before a context 1 draw. Needs a Vulkan device: without one
// it says so on stderr and exits 0, which is a skip, not a pass.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "ps:ps2/gs"
import mem "ps:ps2/mem"

@(private = "file")
failed := 0

@(private = "file")
fail :: proc(msg: string, args: ..any) {
	fmt.eprintfln(msg, ..args)
	failed += 1
}

@(private = "file")
W, H :: 256, 224 // each sprite, from (0, 0)

@(private = "file")
PASSES :: 32

@(private = "file")
ROUNDS :: 2

// The software GS draws a sprite's rows top down, so a pixel sampling a
// texel the sprite writes on a later row reads it as it stood before the
// sprite, which is what the GPU's copy of it gives. Every case samples so:
// a texel written on an earlier row would read new in software and old on
// the GPU, a difference that is no race and that this compare must not see.
// The UVs are half a texel in, so each pixel samples a texel's centre: on a
// texel's edge the GPU's interpolation lands either side of it.
@(private = "file")
Case :: struct {
	name: string,
	draw: proc(),
}

@(private = "file")
CASES := [?]Case {
	{"ct32", ct32},
	{"t8 clut", t8_clut},
	{"region repeat", region_repeat},
	{"z as texture", z_texture},
	{"top pages", top_pages},
	{"past width", past_width},
	{"t8 odd width", t8_odd_width},
	{"one page", one_page},
	{"halves", halves},
	{"clut repeat", clut_repeat},
	{"clut drawn", clut_drawn},
	{"clut in frame", clut_in_frame},
	{"clut partial", clut_partial},
	{"clut csm2", clut_csm2},
	{"clut z", clut_z},
	{"clut snap", clut_snap},
	{"clut frame", clut_frame},
	{"clut hit", clut_hit},
	{"clut hit window", clut_hit_window},
	{"clut hit snap", clut_hit_snap},
	{"clut hit overflow", clut_hit_overflow},
	{"clut hit order", clut_hit_order},
	{"clut hit src", clut_hit_src},
	{"clut hit save", clut_hit_save},
	{"clut hit wrap", clut_hit_wrap},
	{"clut hit full", clut_hit_full},
	{"clut hit ctx2", clut_hit_ctx2},
}

// Local memory after each case of each software round.
@(private = "file")
want: [ROUNDS][len(CASES)][]u32

// A picture of w x h pixels at block bp, PSMCT32, PSMCT16 or PSMT8 (psm),
// every pixel a different colour, alpha kept; another salt, another picture.
@(private = "file")
picture :: proc(bp, bw, w, h: u64, psm: u64 = 0, salt: u32 = 0) {
	words := w * h
	if psm == PSMT8 {words /= 4} else if psm == PSMCT16 {words /= 2}
	px := make([]u32, words, context.temp_allocator)
	seed: u32 = 0x9e3779b9 ~ u32(bp) ~ salt << 16
	for &v in px {
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		v = seed
	}
	gs.gs_write(0x50, bp << 32 | bw << 48 | psm << 56) // BITBLTBUF
	gs.gs_write(0x51, 0) // TRXPOS
	gs.gs_write(0x52, w | h << 32) // TRXREG
	gs.gs_write(0x53, 0) // TRXDIR: host to local
	gs.transfer(slice.to_bytes(px))
}

// Context 1's registers for a case: DECAL, point sampled, UV.
@(private = "file")
setup :: proc(frame, zbuf, test, clamp, tex0: u64) {
	gs.gs_write(0x4c, frame) // FRAME_1
	gs.gs_write(0x4e, zbuf) // ZBUF_1
	gs.gs_write(0x47, test) // TEST_1
	gs.gs_write(0x40, (W - 1) << 16 | (H - 1) << 48) // SCISSOR_1
	gs.gs_write(0x18, 0) // XYOFFSET_1
	gs.gs_write(0x1a, 1) // PRMODECONT
	gs.gs_write(0x14, 0) // TEX1_1: nearest
	gs.gs_write(0x08, clamp) // CLAMP_1
	gs.gs_write(0x06, tex0) // TEX0_1
}

// PASSES sprites, (0, 0) to (W, H), texel (x, y) of the frame from texel
// (u0 + x, v0 + dv * y) (1/16 texel units, per pixel row for dv), at z
// 1, 2, ...
@(private = "file")
sprites :: proc(u0, v0, dv: u64) {
	for p in 1 ..= u64(PASSES) {
		gs.gs_write(0x00, 6 | 1 << 4 | 1 << 8) // PRIM: SPRITE, TME, FST
		gs.gs_write(0x01, 0x80808080)
		gs.gs_write(0x03, u0 | v0 << 16) // UV
		gs.gs_write(0x05, p << 32) // XYZ2 (0, 0)
		gs.gs_write(0x03, u0 + W << 4 | (v0 + dv * H) << 16)
		gs.gs_write(0x05, W << 4 | (H << 4) << 16 | p << 32) // XYZ2 (W, H)
	}
}

// TEX0's fields for a PSMCT32 texture: TBW, log2 width and height, TCC, DECAL.
@(private = "file")
tex0 :: proc(tbp, tbw, tw, th: u64) -> u64 {
	return tbp | tbw << 14 | tw << 26 | th << 30 | 1 << 34 | 1 << 35
}

@(private = "file")
ZMSK :: 1 << 32

@(private = "file")
PSMCT16 :: 0x02
@(private = "file")
PSMT8 :: 0x13
@(private = "file")
PSMT4 :: 0x14

@(private = "file")
Span_Case :: struct {
	name:           string,
	psm, bp, bw:    u32,
	x1, y1:         u32,
	want:           [2]u32,
}

@(private = "file")
SPAN_CASES := [?]Span_Case {
	{"tiny T4 at end", PSMT4, 0x3fff, 2, 7, 7, {511, 1}},
	{"crossing T4 at end", PSMT4, 0x3fff, 2, 32, 16, {511, 2}},
	{"unaligned T4 page", PSMT4, 1, 2, 127, 127, {0, 2}},
	{"tiny T8 at end", PSMT8, 0x3fff, 2, 15, 15, {511, 1}},
	{"tiny CT32 at end", 0, 0x3fff, 1, 7, 7, {511, 1}},
	{"crossing CT32 at end", 0, 0x3fff, 1, 8, 7, {511, 2}},
	{"CT32 past width", 0, 0, 1, 127, 31, {0, 2}},
}

@(private = "file")
span_page :: proc(psm, bp, bw, x, y: u32) -> u32 {
	switch psm {
	case 0: return gs.addr32(psm, bp, bw, x, y) >> 11
	case PSMT8: return gs.addr8(bp, bw, x, y) >> 13
	case PSMT4: return gs.addr4(bp, bw, x, y) >> 14
	}
	return 0
}

@(private = "file")
span_tests :: proc() {
	for c in SPAN_CASES {
		got := gs.probe_hw_tex_span(c.psm, c.bp, c.bw, c.x1, c.y1)
		if got != c.want {
			fail("FAIL gs_hw %s span: got %v, want %v", c.name, got, c.want)
			continue
		}
		for y in 0 ..= c.y1 {
			for x in 0 ..= c.x1 {
				p := span_page(c.psm, c.bp, c.bw, x, y)
				if (p + 512 - got[0]) % 512 >= got[1] {
					fail("FAIL gs_hw %s span %v misses page %d at %d,%d", c.name, got, p, x, y)
					break
				}
			}
		}
	}
}

// The frame as a 1024 x 512 texture, each pixel from the one below. At
// scales 1 and 2 the GPU decodes it; at scale 3 it is too big to decode
// (512K words a layer) and is read from a copy of its pages.
@(private = "file")
ct32 :: proc() {
	picture(0, 4, W, 256)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, tex0(0, 4, 10, 9))
	sprites(8, 1 << 4 + 8, 16)
}

// The frame's pages as a PSMT8 texture through a CT32 CLUT. 512 texels
// wide, its pages lie in rows of four like the frame's, and the 8-pixel
// block row of texel row v is frame row 8 * (v / 16) up: sampling row
// 2y + 16 reads below pixel row y, rows the sprite writes later.
@(private = "file")
t8_clut :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(CBP, 1, 16, 16)
	PSMT8 :: 0x13
	setup(4 << 16, 0x100 | ZMSK, 0, 0, 8 << 14 | PSMT8 << 20 | 9 << 26 | 9 << 30 | 1 << 34 | 1 << 35 | CBP << 37 | 1 << 61)
	sprites(8, 16 << 4 + 8, 32)
}

// The frame as a 64 x 64 texture in region repeat, MINU = MINV = 255 the
// mask: texels past its 64 rows and columns, each pixel from the one below.
@(private = "file")
region_repeat :: proc() {
	picture(0, 4, W, 256)
	setup(4 << 16, 0x100 | ZMSK, 0, 3 | 3 << 2 | 0xff << 4 | 0xff << 24, tex0(0, 4, 6, 6))
	sprites(8, 1 << 4 + 8, 16)
}

// The depth buffer (PSMZ32, page 64, written by every sprite at z = its
// pass) as a CT32 texture, drawn to a frame on other pages. A Z32 page
// lays its blocks out other than a CT32 page (halves of its rows and
// columns swapped), so a texel's depth pixel can lie anywhere in its page:
// each pixel samples texel row y + 32, in the page row below. Region clamp, which
// here clamps as CLAMP does, keeps the texture undecoded.
@(private = "file")
z_texture :: proc() {
	ZBP :: 64
	picture(ZBP * 32, 4, W, 256)
	ZTE_ALWAYS :: 1 << 16 | 1 << 17
	setup(128 | 4 << 16, ZBP, ZTE_ALWAYS, 2 | 2 << 2 | 255 << 14 | 255 << 34, tex0(ZBP * 32, 4, 8, 8))
	sprites(8, 32 << 4 + 8, 16)
}

// The frame and texture on pages 504 up, which wrap past the last page to
// page 0, each pixel from the one below; region clamp, undecoded.
@(private = "file")
top_pages :: proc() {
	FBP :: 504
	picture(FBP * 32, 4, W, 256)
	setup(FBP | 4 << 16, 0x100 | ZMSK, 0, 2 | 2 << 2 | 255 << 14 | 255 << 34, tex0(FBP * 32, 4, 8, 8))
	sprites(8, 1 << 4 + 8, 16)
}

// The frame as a texture sampled past its buffer's width, TBW 4 (256
// texels): texel (x + 512, v) lies in page (v / 32 + 2) * 4 + x / 64, frame
// pixel (x, v + 64). Each pixel samples v = y + 1, frame row y + 65, up to
// row 288 (page 36): the pages past row 255 (page 32) are in the copy only
// through the span's term for texels past the width. Region clamp, 512..767,
// undecoded.
@(private = "file")
past_width :: proc() {
	picture(0, 4, W, 320)
	setup(4 << 16, 0x100 | ZMSK, 0, 2 | 2 << 2 | 512 << 4 | 767 << 14 | 255 << 34, tex0(0, 4, 10, 8))
	sprites(512 << 4 + 8, 1 << 4 + 8, 16)
}

// A decoded CT32 texture (128 x 64, page 160 up, repeat), then PSMT8 rows
// uploaded over it at DBW 3, then the texture sampled again. A PSMT8 row of
// pages starts DBW / 2 pages after the last but runs over two (192 texels),
// so the upload writes page 161, which the partial decode must take again.
@(private = "file")
t8_odd_width :: proc() {
	TBP :: 160 * 32
	picture(TBP, 2, 128, 64)
	setup(128 | 4 << 16, 0x100 | ZMSK, 0, 0, tex0(TBP, 2, 7, 6))
	sprites(8, 8, 16)
	picture(TBP, 3, 192, 64, PSMT8)
	sprites(8, 8, 16)
}

// A decoded CT32 texture (128 x 64, pages 170 to 173, repeat), then one
// page of it (171) uploaded again, then the texture sampled again: the
// partial decode must take that page and only it.
@(private = "file")
one_page :: proc() {
	TBP :: 170 * 32
	picture(TBP, 2, 128, 64)
	setup(128 | 4 << 16, 0x100 | ZMSK, 0, 0, tex0(TBP, 2, 7, 6))
	sprites(8, 8, 16)
	picture(171 * 32, 1, 64, 32)
	sprites(8, 8, 16)
}

// The frame as a texture, region clamp, undecoded: per pass two sprites on
// one state, the left half sampling the right and then the right half
// sampling what the left just wrote. Neither samples pixels it writes, so
// each must see the frame as the one before left it.
@(private = "file")
halves :: proc() {
	picture(0, 4, W, 256)
	setup(4 << 16, 0x100 | ZMSK, 0, 2 | 2 << 2 | 255 << 14 | 255 << 34, tex0(0, 4, 8, 8))
	HW :: W / 2
	for p in 1 ..= u64(PASSES / 4) {
		for half in 0 ..< u64(2) {
			x0, u0 := half * HW, (1 - half) * HW
			gs.gs_write(0x00, 6 | 1 << 4 | 1 << 8) // PRIM: SPRITE, TME, FST
			gs.gs_write(0x01, 0x80808080)
			gs.gs_write(0x03, u0 << 4 + 8 | 8 << 16) // UV
			gs.gs_write(0x05, x0 << 4 | p << 32) // XYZ2 (x0, 0)
			gs.gs_write(0x03, (u0 + HW) << 4 + 8 | (8 + H << 4) << 16)
			gs.gs_write(0x05, (x0 + HW) << 4 | (H << 4) << 16 | p << 32) // XYZ2 (x0 + HW, H)
		}
	}
}

main :: proc() {
	if len(os.args) == 2 {
		scale, _ := strconv.parse_uint(os.args[1])
		child(u32(scale))
	}
	span_tests()
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("FAIL gs_hw: cannot find the test: %v", err)
		os.exit(1)
	}
	for scale in 1 ..= 3 {
		state, out, errs, perr := os.process_exec({command = {self, fmt.tprint(scale)}}, context.temp_allocator)
		os.write(os.stdout, out)
		os.write(os.stderr, errs)
		switch {
		case perr != nil:
			fail("FAIL gs_hw scale %d: cannot run the child: %v", scale, perr)
		case state.exited && state.exit_code == 2:
			os.exit(0) // no Vulkan device, said on stderr
		case state.exited && state.exit_code == 0:
		case:
			fail("FAIL gs_hw scale %d: status %d", scale, state.exit_code)
		}
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok gs_hw")
}

// One scale: the software rounds, then the GPU rounds against them. Exits
// 0 when every case matches, 1 when one does not, 2 with no Vulkan device.
@(private = "file")
child :: proc(scale: u32) -> ! {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer

	for r in 0 ..< ROUNDS {
		for c, i in CASES {
			c.draw()
			want[r][i] = slice.clone(gs.vram[:])
		}
	}

	if !gs.hw_init(nil, scale) {
		fmt.eprintln("gs_hw: skip, no Vulkan device")
		os.exit(2)
	}
	for r in 0 ..< ROUNDS {
		for c, i in CASES {
			c.draw()
			gs.hw_download()
			for v, a in gs.vram {
				if v != want[r][i][a] {
					fail("FAIL gs_hw scale %d, round %d, %s: word %x %08x, software %08x", scale, r + 1, c.name, a, v, want[r][i][a])
					break
				}
			}
		}
	}
	screen_overflow(scale)
	os.exit(failed != 0 ? 1 : 0)
}

// The screen read after a ring overflow is still the last frame put out:
// one overflow moves recording into the slot that holds that frame's scan.
@(private = "file")
screen_overflow :: proc(scale: u32) {
	set_priv :: proc(off: u32, v: u64) {(^u64)(&mem.gsregs[off])^ = v}
	set_priv(0x00, 1) // PMODE: circuit 1
	set_priv(0x20, 0) // SMODE2: progressive
	set_priv(0x70, W / 64 << 9) // DISPFB1: block 0, PSMCT32
	set_priv(0x80, (W - 1) << 32 | (H - 1) << 44) // DISPLAY1
	picture(0, W / 64, W, H, 0, 1)
	gs.scanout()
	picture(0, W / 64, W, H, 0, 2)
	gs.scanout()
	px, _, _ := gs.hw_screen()
	shown := slice.clone(px, context.temp_allocator)
	// 50000 sprites of 6 vertices: one overflow of the 1 << 18 vertex ring,
	// drawn at page 200, away from the shown buffer.
	gs.gs_write(0x4c, 200 | W / 64 << 16) // FRAME_1
	gs.gs_write(0x4e, 0x100 | ZMSK) // ZBUF_1
	gs.gs_write(0x47, 0) // TEST_1
	for i in 0 ..< u64(50000) {
		x, y := i % W, i / W % H
		gs.gs_write(0x00, 6) // PRIM: SPRITE
		gs.gs_write(0x01, 0x80000000 | i)
		gs.gs_write(0x05, (x << 4) | (y << 4) << 16) // XYZ2
		gs.gs_write(0x05, (x + 1) << 4 | ((y + 1) << 4) << 16)
	}
	px, _, _ = gs.hw_screen()
	if !slice.equal(px, shown) {
		fail("FAIL gs_hw scale %d, screen after overflow: not the last frame put out", scale)
	}
}

// Rows 28 k .. 28 k + 27 of the frame (k < 8), from texel rows 0..27 of
// TEX0 tex as it stands: one sprite, z = k + 1.
@(private = "file")
clut_band :: proc(k: u64, tex: u64) {
	gs.gs_write(0x06, tex) // TEX0_1: the load
	band_draw(k)
}

// Band k of clut_band with no TEX0 write: context 1 as it stands.
@(private = "file")
band_draw :: proc(k: u64) {
	BAND :: 28
	gs.gs_write(0x00, 6 | 1 << 4 | 1 << 8) // PRIM: SPRITE, TME, FST, CTXT 1
	gs.gs_write(0x01, 0x80808080)
	gs.gs_write(0x03, 8 | 8 << 16) // UV
	gs.gs_write(0x05, (k * BAND << 4) << 16 | (k + 1) << 32) // XYZ2 (0, 28 k)
	gs.gs_write(0x03, W << 4 + 8 | (BAND << 4 + 8) << 16)
	gs.gs_write(0x05, W << 4 | ((k + 1) * BAND << 4) << 16 | (k + 1) << 32) // XYZ2 (W, 28 k + 28)
}

// A 256 x 64 PSMT8 texture at page 128, its CLD = 1 TEX0 for a CT32 CSM1
// CLUT at block cbp (PSMT4 and entries csa * 16 up when t4; a CT16 CSM2
// CLUT, from where TEXCLUT says, when csm2).
@(private = "file")
clut_tex :: proc(cbp: u64, t4 := false, csa: u64 = 0, csm2 := false) -> u64 {
	t: u64 = 128 * 32 | 4 << 14 | (t4 ? PSMT4 : PSMT8) << 20 | 8 << 26 | 6 << 30 | 1 << 34 | 1 << 35 | cbp << 37 | csa << 56 | 1 << 61
	return csm2 ? t | PSMCT16 << 51 | 1 << 55 : t
}

// TEX0 tex with CLD = 0: no CLUT load, the draw uses the CLUT as it stands.
@(private = "file")
no_load :: proc(tex: u64) -> u64 {return tex &~ (7 << 61)}

// The same CLUT load before each band, from a 16 x 16 source on page 300:
// (a) nothing written between, (c) the source uploaded again.
@(private = "file")
clut_repeat :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(128 * 32, 4, W, 64, PSMT8)
	picture(CBP, 1, 16, 16)
	t := clut_tex(CBP)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	clut_band(0, t)
	clut_band(1, t) // (a)
	picture(CBP, 1, 16, 16, 0, 1) // (c)
	clut_band(2, t)
}

// (b) The same CLUT load around a sprite drawn over half its source.
@(private = "file")
clut_drawn :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(CBP, 1, 16, 16, 0, 2)
	t := clut_tex(CBP)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	clut_band(0, t)
	gs.gs_write(0x4c, 300 | 1 << 16) // FRAME_1: page 300, 64 wide
	gs.gs_write(0x00, 6) // PRIM: SPRITE, flat
	gs.gs_write(0x01, 0x80402010)
	gs.gs_write(0x05, 0) // XYZ2 (0, 0)
	gs.gs_write(0x05, 8 << 4 | (16 << 4) << 16) // XYZ2 (8, 16)
	gs.gs_write(0x4c, 4 << 16) // FRAME_1 back
	clut_band(1, t)
}

// (b) The CLUT in the frame itself, rows 192..207 (page 24): band 6 (rows
// 168..195) draws over it after the load before it, then band 7 loads it.
@(private = "file")
clut_in_frame :: proc() {
	picture(0, 4, W, 256)
	t := clut_tex(24 * 32)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	for k in 4 ..< u64(8) {clut_band(k, t)}
}

// (d) Partial loads: a PSMT8 load, a PSMT4 load into entries 16..31 from
// page 302, the same at entries 32..47 (only CSA differs), the PSMT8 load
// again.
@(private = "file")
clut_partial :: proc() {
	CBP, CBP4 :: 9600, 9664
	picture(0, 4, W, 256)
	picture(CBP4, 1, 8, 2)
	t, t4, t4b := clut_tex(CBP), clut_tex(CBP4, true, 1), clut_tex(CBP4, true, 2)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	clut_band(0, t)
	clut_band(1, t4)
	clut_band(2, t4b)
	clut_band(3, t)
	clut_band(4, t4b)
}

// (c) A CT16 CSM2 CLUT, one 256-entry row of a 256-wide buffer at page
// 300: loaded, repeated, its row uploaded again, then row 1 (COV 1, another
// key), then row 0 again.
@(private = "file")
clut_csm2 :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(128 * 32, 4, W, 64, PSMT8)
	picture(CBP, 4, 256, 2, PSMCT16)
	t := clut_tex(CBP, csm2 = true)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	gs.gs_write(0x1c, 4) // TEXCLUT: CBW 4, COU 0, COV 0
	clut_band(0, t)
	clut_band(1, t)
	picture(CBP, 4, 256, 1, PSMCT16, 3)
	clut_band(2, t)
	gs.gs_write(0x1c, 4 | 1 << 12) // COV 1
	clut_band(3, t)
	gs.gs_write(0x1c, 4)
	clut_band(4, t)
}

// (b) The same CLUT load around a sprite that writes only depth, all of
// page 300 (the CLUT's source) as the Z buffer.
@(private = "file")
clut_z :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(CBP, 1, 16, 16, 0, 4)
	t := clut_tex(CBP)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	clut_band(0, t)
	gs.gs_write(0x4c, 4 << 16 | 0xffffffff << 32) // FRAME_1: every bit masked
	gs.gs_write(0x4e, 300) // ZBUF_1: page 300, Z32, written
	gs.gs_write(0x47, 1 << 16 | 1 << 17) // TEST_1: ZTE, ZTST ALWAYS
	gs.gs_write(0x00, 6) // PRIM: SPRITE, flat
	gs.gs_write(0x01, 0x80402010)
	gs.gs_write(0x05, 0x5a5a1234 << 32) // XYZ2 (0, 0)
	gs.gs_write(0x05, 64 << 4 | (32 << 4) << 16 | 0x5a5a1234 << 32) // XYZ2 (64, 32)
	gs.gs_write(0x4c, 4 << 16)
	gs.gs_write(0x4e, 0x100 | ZMSK)
	gs.gs_write(0x47, 0)
	clut_band(1, t)
}

// The GS's save state regions and, on the GPU, its snapshot.
@(private = "file")
snap_parts: [dynamic][]u8

@(private = "file")
snap_saved: [dynamic][]u8

@(private = "file")
SNAP_ID :: 7

@(private = "file")
snap_save :: proc() {
	clear(&snap_parts)
	clear(&snap_saved)
	gs.snap_regions(proc(b: []u8) {append(&snap_parts, b)})
	for b in snap_parts {append(&snap_saved, slice.clone(b, context.temp_allocator))}
	if gs.hw_on {gs.hw_snap_save(SNAP_ID)}
}

@(private = "file")
snap_load :: proc() {
	for b, i in snap_parts {copy(b, snap_saved[i])}
	// What the GS snap hook does on a load (gs_snap, regs.odin): the texture
	// cache drops its entries. Its ctx_gen bump is left to the TEX0 write of
	// each draw after a load.
	gs.tc_flush()
	if gs.hw_on {gs.hw_snap_load(SNAP_ID)}
}

// A load, a save state, a load of another source with the same key, the
// state loaded back, then a draw with no load: it must use the CLUT the
// state holds, not the last load's.
@(private = "file")
clut_snap :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(CBP, 1, 16, 16, 0, 5)
	t := clut_tex(CBP)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	clut_band(0, t)
	snap_save()
	picture(CBP, 1, 16, 16, 0, 6)
	clut_band(1, t)
	snap_load()
	clut_band(2, no_load(t))
}

// Two loads a frame apart, then a draw with no load in the next frame: on
// the GPU each frame has a slot of its own, and the CLUT copy in the first
// slot's ring is of the first load.
@(private = "file")
clut_frame :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(CBP, 1, 16, 16, 0, 7)
	t := clut_tex(CBP)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, t)
	clut_band(0, t)
	gs.scanout()
	picture(CBP, 1, 16, 16, 0, 8)
	clut_band(1, t)
	gs.scanout()
	clut_band(2, no_load(t))
}

// CLUT sources for the hit cases: two PSMT8 (256 entries) and two PSMT4 (16)
// CT32 CSM1 tables on pages 300..303.
@(private = "file")
HA, HB, H4, H4B :: 9600, 9632, 9664, 9696

@(private = "file")
hit_setup :: proc(salt: u32) {
	picture(0, 4, W, 256)
	picture(128 * 32, 4, W, 64, PSMT8)
	picture(HA, 1, 16, 16, 0, salt)
	picture(HB, 1, 16, 16, 0, salt + 1)
	picture(H4, 1, 8, 2, 0, salt + 2)
	picture(H4B, 1, 8, 2, 0, salt + 3)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, clut_tex(HA))
}

// PSMT8 loads A, B, A again (a hit), each drawn.
@(private = "file")
clut_hit :: proc() {
	hit_setup(10)
	a, b := clut_tex(HA), clut_tex(HB)
	clut_band(0, a)
	clut_band(1, b)
	clut_band(2, a)
	clut_band(3, b)
}

// A PSMT4 load at entries 16..31, a PSMT8 load, the PSMT4 load again (a
// hit, its copy exact in 16..31 only), then draws with no load reading
// entries 32..47 and all 256: both must read the PSMT8 load's entries.
@(private = "file")
clut_hit_window :: proc() {
	hit_setup(20)
	t4, b := clut_tex(H4, true, 1), clut_tex(HB)
	clut_band(0, t4)
	clut_band(1, b)
	clut_band(2, t4)
	clut_band(3, no_load(clut_tex(H4, true, 2)))
	clut_band(4, t4)
	clut_band(5, no_load(b))
}

// A PSMT8 load A, a PSMT4 load at 16..31, A again (a hit), a save state;
// then B, the PSMT4 load, B again (a hit, pending at the restore), the
// state loaded back, and a draw with no load of entries 16..31: the saved
// CLUT has A's there, and B's hit is not replayed over it. Before the
// restore A's source is written and A loaded from it; after, A is loaded
// again from the source as saved: not a hit on the copy of the written one.
@(private = "file")
clut_hit_snap :: proc() {
	hit_setup(30)
	a, t4 := clut_tex(HA), clut_tex(H4, true, 1)
	clut_band(0, a)
	clut_band(1, t4)
	clut_band(2, a)
	snap_save()
	b := clut_tex(HB)
	clut_band(3, b)
	clut_band(4, t4)
	clut_band(5, b)
	picture(HA, 1, 16, 16, 0, 34)
	clut_band(3, a)
	clut_band(4, t4)
	snap_load()
	clut_band(6, no_load(t4))
	clut_band(7, a)
}

// A PSMT8 load, a PSMT4 load at 16..31, the PSMT8 load again (a hit), then
// enough sprites to overflow the vertex ring, then a draw with no load of
// entries 16..31: the new slot's CLUT has the hit's.
@(private = "file")
clut_hit_overflow :: proc() {
	hit_setup(40)
	a, t4 := clut_tex(HA), clut_tex(H4, true, 1)
	clut_band(0, a)
	clut_band(1, t4)
	clut_band(2, a)
	gs.gs_write(0x4c, 200 | 4 << 16) // FRAME_1: page 200
	for i in 0 ..< u64(50000) {
		x, y := i % W, i / W % H
		gs.gs_write(0x00, 6) // PRIM: SPRITE, flat
		gs.gs_write(0x01, 0x80000000 | i)
		gs.gs_write(0x05, (x << 4) | (y << 4) << 16) // XYZ2
		gs.gs_write(0x05, (x + 1) << 4 | ((y + 1) << 4) << 16)
	}
	gs.gs_write(0x4c, 4 << 16)
	clut_band(3, no_load(t4))
}

// Loads A, B (PSMT8) and a PSMT4 load at 16..31, then hits A, B, A over
// one another (A last, though its first hit came first), then a PSMT4 load at 32..47 (a dispatch, the hits replayed
// before it), then a draw with no load of entries 16..31: A's, the last
// hit over them.
@(private = "file")
clut_hit_order :: proc() {
	hit_setup(50)
	a, b, t4 := clut_tex(HA), clut_tex(HB), clut_tex(H4, true, 1)
	clut_band(0, a)
	clut_band(1, b)
	clut_band(2, t4)
	clut_band(3, a)
	clut_band(4, b)
	clut_band(5, a)
	clut_band(6, clut_tex(H4B, true, 2))
	clut_band(0, no_load(t4))
}

// PSMT8 loads A, B, A again (a hit), A's source written, then draws with no
// load of entries 320..335 (past the hit's: a whole copy) and all 256: both
// read A's entries as loaded, not as written after.
@(private = "file")
clut_hit_src :: proc() {
	hit_setup(60)
	a, b := clut_tex(HA), clut_tex(HB)
	clut_band(0, a)
	clut_band(1, b)
	clut_band(2, a)
	picture(HA, 1, 16, 16, 0, 64)
	clut_band(3, no_load(clut_tex(H4, true, 20)))
	clut_band(4, no_load(a))
}

// A PSMT8 load A, a PSMT4 load at 16..31, A again (a hit), a save state,
// then a draw with no load of entries 16..31: the save brought A's hit into
// the CLUT before it, and the draw after reads the CLUT as saved.
@(private = "file")
clut_hit_save :: proc() {
	hit_setup(70)
	a, t4 := clut_tex(HA), clut_tex(H4, true, 1)
	clut_band(0, a)
	clut_band(1, t4)
	clut_band(2, a)
	snap_save()
	clut_band(3, no_load(t4))
}

// PSMT8 loads A at entries 496..511 and 0..239, B at 0..255, A again (a
// hit), then draws with no load of entries 496..511, 0..15 (in the hit's
// range across 511), 240..255 (past it: a whole copy, the hit replayed) and
// all 256 from 496.
@(private = "file")
clut_hit_wrap :: proc() {
	hit_setup(80)
	a, b := clut_tex(HA, false, 31), clut_tex(HB)
	clut_band(0, a)
	clut_band(1, b)
	clut_band(2, a)
	clut_band(3, no_load(clut_tex(H4, true, 31)))
	clut_band(4, no_load(clut_tex(H4, true, 0)))
	clut_band(5, no_load(clut_tex(H4, true, 15)))
	clut_band(6, no_load(a))
}

// PSMT4 loads at entries 0..15 up to 256..271 (17 keys), a PSMT8 load over
// 256..511, then the 17 again: 16 hits pend, the 17th is a dispatch. Then a
// draw with no load of 256..511 (past the last load's entries): the 17th
// load's entries, then the PSMT8 load's.
@(private = "file")
clut_hit_full :: proc() {
	hit_setup(90)
	for csa in u64(0) ..= 16 {gs.gs_write(0x06, clut_tex(H4, true, csa))}
	gs.gs_write(0x06, clut_tex(HB, false, 16))
	for csa in u64(0) ..= 16 {gs.gs_write(0x06, clut_tex(H4, true, csa))}
	clut_band(0, no_load(clut_tex(HA, false, 16)))
	clut_band(1, no_load(clut_tex(HA)))
}

// PSMT4 load at 16..31 and PSMT8 load B (TEX0_1), then the PSMT4 load again
// through TEX0_2 (a hit), then a context 1 draw with no TEX0_1 write of all
// 256 entries (past the hit's): B's, the hit's at 16..31.
@(private = "file")
clut_hit_ctx2 :: proc() {
	hit_setup(100)
	t4, b := clut_tex(H4, true, 1), clut_tex(HB)
	clut_band(0, t4)
	clut_band(1, b)
	gs.gs_write(0x07, t4) // TEX0_2
	band_draw(2)
}
