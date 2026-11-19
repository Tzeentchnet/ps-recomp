// Banded drawing (gs.band_set) against drawing on the GS write path, bit
// for bit on all of local memory and every readback: random streams of
// contexts, primitives and transfers, replayed from the same state with 1,
// 2, 4 and 8 band workers, and with 4 publishing each job as it comes.
//
// The streams set frame, Z and texture buffers on a few shared pages so
// that every hazard band.odin joins at occurs: a context texturing from
// pages it draws to (render-to-texture feedback, drawn serially), Z on
// frame pages, a texture drawn by earlier primitives (read after write),
// a frame over a texture earlier primitives sampled (write after read),
// one page under two formats or widths (alias), host-to-local and
// local-to-local transfers and CLUT loads over drawn pages, local-to-host
// readback, and scissors past the buffer width. Each cause's count has a
// floor. A frame sampled in place through T8H, T4HL or T4HH under an FBMSK
// keeping the bits read draws on workers; one changing them, serially.
//
// The texel span a context's texture reads (band_ctx_new) is checked
// against the sampler's wrap brute force: every result in the span, both
// ends reached. Wrong spans (mutants) must fail the same check.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "ps:ps2/gs"

@(private = "file")
failed := 0

@(private = "file")
fail :: proc(msg: string, args: ..any) {
	fmt.eprintfln(msg, ..args)
	failed += 1
}

@(private = "file")
seed: u64 = 0x9e3779b97f4a7c15

// xorshift64*, fixed seed: the same streams every run.
@(private = "file")
rnd :: proc() -> u64 {
	seed ~= seed >> 12
	seed ~= seed << 25
	seed ~= seed >> 27
	return seed * 0x2545f4914f6cdd1d
}

@(private = "file")
rndn :: proc(n: u64) -> u64 {return rnd() % n}

// One step of a stream: a register write, IMAGE data, or a readback of n bytes.
@(private = "file")
Step :: struct {
	reg:  u8,
	v:    u64,
	data: []u8,
	back: int,
}
@(private = "file")
steps: [dynamic]Step

@(private = "file")
put :: proc(reg: u8, v: u64) {append(&steps, Step{reg = reg, v = v})}

@(private = "file")
FRAME_PSM := [?]u64{0x00, 0x01, 0x02, 0x0a, 0x30, 0x31, 0x32, 0x3a}
@(private = "file")
Z_PSM := [?]u64{0x0, 0x1, 0x2, 0xa}
// T8H, T4HL, T4HH: textures reading only the upper byte of each word.
@(private = "file")
H_PSM := [?]u64{0x1b, 0x24, 0x2c}
@(private = "file")
TEX_PSM := [?]u64{0x00, 0x01, 0x02, 0x0a, 0x13, 0x14, 0x1b, 0x24, 0x2c}

// Pages, as FBP counts them: frames, Z buffers and textures each on a few
// of their own, so most contexts draw on workers; a texture on a frame's
// pages one time in two, on its own context's frame one in eight.
@(private = "file")
frame_page :: proc() -> u64 {return rndn(6) * 24}
@(private = "file")
tex_page :: proc(fbp: u64) -> u64 {
	switch rndn(8) {
	case 0: return fbp
	case 1, 2, 3: return frame_page()
	}
	return 240 + rndn(3) * 24
}

@(private = "file")
context_regs :: proc(n: u8) {
	fbw := 2 + rndn(4)
	fbp := frame_page()
	put(0x4c + n, fbp | fbw << 16 | FRAME_PSM[rndn(len(FRAME_PSM))] << 24 | (rndn(4) == 0 ? rnd() & 0xffffffff : 0) << 32)
	zbp := rndn(16) == 0 ? fbp : 144 + rndn(4) * 24
	put(0x4e + n, zbp | Z_PSM[rndn(len(Z_PSM))] << 24 | rndn(2) << 32)
	// Mostly inside the buffer; one in eight past its width.
	x1 := rndn(8) == 0 ? fbw * 64 + rndn(128) : min(fbw * 64 - 1, rndn(256))
	put(0x40 + n, rndn(16) | x1 << 16 | rndn(16) << 32 | rndn(128) << 48)
	put(0x47 + n, rnd() & 0x7ffff)
	put(0x42 + n, rnd() & 0xff | rndn(256) << 32)
	put(0x4a + n, rndn(2))
	put(0x18 + n, 0)
	tw, th := 2 + rndn(5), 2 + rndn(5)
	cld := rndn(2) == 0 ? 1 : rndn(6)
	tbp := tex_page(fbp) * 32
	put(0x06 + n, tbp | (1 + rndn(4)) << 14 | TEX_PSM[rndn(len(TEX_PSM))] << 20 | tw << 26 | th << 30 | rndn(2) << 34 | rndn(4) << 35 | (tex_page(fbp) * 32 + rndn(32)) << 37 | rndn(2) * 2 << 51 | rndn(2) << 55 | rndn(32) << 56 | cld << 61)
	// Region clamp or repeat one time in eight.
	wm :: proc() -> u64 {return rndn(8) == 0 ? 2 + rndn(2) : rndn(2)}
	put(0x08 + n, wm() | wm() << 2 | rndn(1024) << 4 | rndn(1024) << 14 | rndn(1024) << 24 | rndn(1024) << 34)
	put(0x14 + n, rndn(2) | rndn(7) << 2 | rndn(2) << 5 | rndn(8) << 6 | rndn(4) << 19 | (rndn(49) - 24 & 0xfff) << 32)
	put(0x34 + n, tex_page(fbp) * 32 | 2 << 14 | tex_page(fbp) * 32 << 20 | 1 << 34 | tex_page(fbp) * 32 << 40 | 1 << 54)
	put(0x36 + n, tex_page(fbp) * 32 | 1 << 14 | tex_page(fbp) * 32 << 20 | 1 << 34 | tex_page(fbp) * 32 << 40 | 1 << 54)
}

@(private = "file")
prim :: proc() {
	kind := rndn(7)
	put(0x00, kind | rndn(2) << 3 | rndn(2) << 4 | rndn(2) << 5 | rndn(2) << 6 | rndn(2) << 8 | rndn(2) << 9)
	nv := [7]int{1, 2, 4, 3, 5, 5, 2}
	for _ in 0 ..< nv[kind] {
		put(0x01, rnd() & 0xffffffff | u64(transmute(u32)f32(0.5 + f32(rndn(100)) / 50)) << 32)
		put(0x02, u64(transmute(u32)(f32(rndn(1000)) / 500)) | u64(transmute(u32)(f32(rndn(1000)) / 500)) << 32)
		put(0x03, rndn(1 << 14) | rndn(1 << 14) << 16)
		put(0x05, rndn(300 << 4) | rndn(150 << 4) << 16 | rnd() << 32)
	}
}

// A texel span for one axis: wrap mode, level-0 size, MIN (MASK), MAX
// (FIX), level.
@(private = "file")
Span :: proc(mode, size, lo, hi, n: u32) -> (a, b: u32)

// Whether span gives exactly the texels the sampler's wrap reaches from
// every u in -1024..2047 (region modes: 0..1023 reach every result).
@(private = "file")
span_exact :: proc(span: Span, mode, size, lo, hi, n: u32) -> bool {
	axis, _, _ := gs.probe_wrap(mode, size, lo, hi, n)
	a, b := span(mode, size, lo, hi, n)
	rmin, rmax := max(i32), min(i32)
	for u in i32(-1024) ..< 2048 {
		r := (min(max(u, axis[0]), axis[1]) & axis[2]) | axis[3]
		rmin, rmax = min(rmin, r), max(rmax, r)
	}
	return rmin == i32(a) && rmax == i32(b)
}

@(private = "file")
span_real :: proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
	_, a, b = gs.probe_wrap(mode, size, lo, hi, n)
	return
}

// Wrong spans the check must catch.
@(private = "file")
MUTANTS := [?]Span {
	// The old bound: any texel under 1024.
	proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
		if mode >= 2 {return 0, 1023}
		return span_real(mode, size, lo, hi, n)
	},
	// REGION_REPEAT from FIX &~ MASK.
	proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
		if mode == 3 {return hi &~ lo, hi | lo}
		return span_real(mode, size, lo, hi, n)
	},
	// REGION_REPEAT with MASK and FIX swapped.
	proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
		if mode == 3 {return lo, lo | hi}
		return span_real(mode, size, lo, hi, n)
	},
	// REGION_CLAMP unscaled at levels past 0.
	proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
		if mode == 2 {return min(lo, hi), hi}
		return span_real(mode, size, lo, hi, n)
	},
	// REGION_CLAMP as MIN..MAX when MIN > MAX.
	proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
		if mode == 2 {return lo >> n, hi >> n}
		return span_real(mode, size, lo, hi, n)
	},
	// One texel short.
	proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
		a, b = span_real(mode, size, lo, hi, n)
		return a, max(b, 1) - 1
	},
}

// Every wrap mode over random and edge registers at levels 0..6; then
// each mutant must miss somewhere.
@(private = "file")
region_spans :: proc() {
	Case :: struct {mode, size, lo, hi, n: u32}
	cases: [dynamic]Case
	defer delete(cases)
	edges := [?]u32{0, 1, 0x1f, 0x200, 0x3fe, 0x3ff}
	for mode in u32(0) ..< 4 {
		for lo in edges {for hi in edges {append(&cases, Case{mode, 1 << (lo & 7), lo, hi, hi & 7 % 7})}}
		for _ in 0 ..< 300 {
			append(&cases, Case{mode, 1 << u32(rndn(11)), u32(rndn(1024)), u32(rndn(1024)), u32(rndn(7))})
		}
	}
	for c in cases {
		if !span_exact(span_real, c.mode, c.size, c.lo, c.hi, c.n) {
			a, b := span_real(c.mode, c.size, c.lo, c.hi, c.n)
			fail("wrap mode %d size %d min %x max %x level %d: span %d..%d not exact", c.mode, c.size, c.lo, c.hi, c.n, a, b)
		}
	}
	for m, i in MUTANTS {
		caught := false
		for c in cases {
			if !span_exact(m, c.mode, c.size, c.lo, c.hi, c.n) {
				caught = true
				break
			}
		}
		if !caught {fail("span mutant %d passes", i)}
	}
}

// A transfer: host to local, local to host, or local to local.
@(private = "file")
transfer :: proc() {
	@(static, rodata) psms := [4]u64{0x00, 0x02, 0x13, 0x14}
	@(static, rodata) bits := [4]int{32, 16, 8, 4}
	k := rndn(4)
	psm, b := psms[k], bits[k]
	w, h := 8 * (1 + rndn(8)), 1 + rndn(64)
	dir := rndn(3)
	put(0x50, tex_page(0) * 32 | (1 + rndn(8)) << 16 | psm << 24 | tex_page(0) * 32 << 32 | (1 + rndn(8)) << 48 | psm << 56)
	put(0x51, rndn(64) | rndn(64) << 16 | rndn(64) << 32 | rndn(64) << 48)
	put(0x52, w | h << 32)
	put(0x53, dir)
	n := int(w * h) * b / 8
	switch dir {
	case 0:
		data := make([]u8, n)
		for &d in data {d = u8(rnd())}
		append(&steps, Step{data = data})
	case 1:
		append(&steps, Step{back = n})
	}
}

// Render to texture with bands in step: context 0 draws CT32 rows of page
// f, context 1 samples them into page g, context 0 draws over f again.
// The sample reads rows other bands draw (read after write), and the
// redraw writes rows other bands sample (write after read). Then context 0
// draws f's top rows and context 1 loads a CSM1 CLUT from them for a T8
// sprite on page h (read on the producer of rows bands draw).
@(private = "file")
chain :: proc() {
	f := frame_page()
	g := (f + 24 * (1 + rndn(5))) % 144
	// Rows [y0, y1), sampling from row v0 down.
	sprite :: proc(ctxt, tme: u64, y0, y1: u64, v0: u64 = 0) {
		put(0x00, 6 | tme << 4 | 1 << 8 | ctxt << 9)
		put(0x01, rnd() & 0xffffffff)
		put(0x03, 0 | v0 << 20)
		put(0x05, 0 | y0 << 20)
		put(0x03, 256 << 4 | (v0 + y1 - y0) << 20)
		put(0x05, 256 << 4 | y1 << 20)
	}
	for n in u64(0) ..< 2 {
		put(0x4c + u8(n), (n == 0 ? f : g) | 4 << 16)
		put(0x4e + u8(n), 144 | 1 << 32)
		put(0x40 + u8(n), 255 << 16 | 127 << 48)
		put(0x47 + u8(n), 0)
		put(0x4a + u8(n), 0)
		put(0x18 + u8(n), 0)
	}
	// CT32, TBW 4, 256 x 128, decal, clamp, nearest.
	put(0x07, f * 32 | 4 << 14 | 8 << 26 | 7 << 30 | 1 << 34 | 1 << 35)
	put(0x09, 1 | 1 << 2)
	put(0x15, 0)
	for _ in 0 ..< 1 + rndn(3) {
		y0 := rndn(48)
		sprite(0, 0, y0, y0 + 1 + rndn(16))
	}
	// Eight 8-row jobs, each from rows 8 to 24 further down, so a band
	// samples rows other bands draw and lagging bands fall further behind.
	for k in u64(0) ..< 8 {sprite(1, 1, 8 * k, 8 * k + 8, 8 * k + 8 * (1 + rndn(3)))}
	// Host to local over sampled rows of f, then the same context samples
	// them again into g's rows 64 down: workers' caches must drop f's tiles.
	put(0x50, f * 32 << 32 | 4 << 48)
	put(0x51, rndn(48) << 48)
	put(0x52, 64 | 16 << 32)
	put(0x53, 0)
	data := make([]u8, 64 * 16 * 4)
	for &d in data {d = u8(rnd())}
	append(&steps, Step{data = data})
	for k in u64(0) ..< 8 {sprite(1, 1, 64 + 8 * k, 72 + 8 * k, 8 * k + 8 * (1 + rndn(3)))}
	for _ in 0 ..< 1 + rndn(3) {
		y0 := rndn(48)
		sprite(0, 0, y0, y0 + 1 + rndn(16))
	}
	sprite(0, 0, 0, 16)
	h := (g + 24 * (1 + rndn(5))) % 144
	if h == f {h = (h + 24) % 144}
	put(0x4d, h | 4 << 16)
	// T8 on a texture page, CT32 CLUT at f's first four blocks, CSM1, load.
	put(0x07, (240 + rndn(3) * 24) * 32 | 4 << 14 | 0x13 << 20 | 8 << 26 | 6 << 30 | 1 << 34 | 1 << 35 | f * 32 << 37 | 1 << 61)
	sprite(1, 1, 0, 64)
}

// A frame sampled in place as T8H, T4HL or T4HH (Okami's f300 glow pass):
// context 0 draws CT32 page f under FBMSK mask in 32 x 128 sprite strips,
// bilinear, each strip reading texels of rows other bands draw. FBMSK
// ff000000 keeps the bits the texture reads, so the strips go to workers;
// FBMSK 0 changes them, so they draw serially.
@(private = "file")
in_place :: proc(mask: u64, psm: u64 = 0x1b) {
	f := frame_page()
	put(0x4c, f | 4 << 16 | mask << 32)
	put(0x4e, 144 | 1 << 32)
	put(0x40, 255 << 16 | 127 << 48)
	put(0x47, 0)
	put(0x4a, 0)
	put(0x18, 0)
	// TBW 4, 256 x 128, CT32 CLUT on a texture page, load; clamp; bilinear.
	put(0x06, f * 32 | 4 << 14 | psm << 20 | 8 << 26 | 7 << 30 | 1 << 34 | 1 << 35 | (240 + rndn(3) * 24) * 32 << 37 | 1 << 61)
	put(0x08, 1 | 1 << 2)
	put(0x14, 1 << 5 | 1 << 6)
	for k in u64(0) ..< 8 {
		put(0x00, 6 | 1 << 4 | 1 << 8)
		put(0x01, rnd() & 0xffffffff)
		// Texels a few pixels off the strip, so taps cross strips and bands.
		d := rndn(16)
		put(0x03, (32 * k + d) << 4 | 8 | rndn(8) << 20)
		put(0x05, 32 * k << 4)
		put(0x03, (32 * k + 32 + d) << 4 | 8 | (120 + rndn(8)) << 20)
		put(0x05, (32 * k + 32) << 4 | 128 << 20)
	}
}

@(private = "file")
build :: proc() {
	for s in steps {delete(s.data)}
	clear(&steps)
	put(0x1a, 1) // PRMODECONT
	put(0x46, rndn(2)) // COLCLAMP
	put(0x3b, rnd() & 0xff | rndn(2) << 15 | (rnd() & 0xff) << 32) // TEXA
	put(0x1c, rndn(4) | rndn(4) << 6 | rndn(8) << 12) // TEXCLUT
	context_regs(0)
	context_regs(1)
	for _ in 0 ..< 400 {
		switch rndn(16) {
		case 0: context_regs(u8(rndn(2)))
		case 1: transfer()
		case 2: chain()
		case 3: in_place(rndn(2) == 0 ? 0xff000000 : rnd() & 0xffffffff, H_PSM[rndn(len(H_PSM))])
		case: prim()
		}
	}
}

// The software GS's saved state (gs.snap_regions), copied once.
@(private = "file")
regions: [dynamic][]u8
@(private = "file")
saved: [dynamic][]u8

@(private = "file")
saved_regs: type_of(gs.state.regs)

@(private = "file")
add_region :: proc(b: []u8) {append(&regions, b)}

// Replay the stream from the saved state with n workers: local memory and
// the readback bytes after.
@(private = "file")
run :: proc(n: int, back: ^[dynamic]u8) {
	for r, i in regions {copy(r, saved[i])}
	gs.state.regs = saved_regs
	gs.tc_flush()
	clear(back)
	gs.band_set(n)
	for s in steps {
		switch {
		case s.data != nil: gs.gs_image(s.data)
		case s.back > 0:
			buf := make([]u8, s.back, context.temp_allocator)
			gs.readback(buf)
			append(back, ..buf)
		case: gs.gs_write(s.reg, s.v)
		}
	}
	gs.band_set(0)
}

@(private = "file")
ref, got: [1 << 20]u32

main :: proc() {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	gs.gs_snap()
	gs.snap_regions(add_region)
	for r in regions {append(&saved, make([]u8, len(r)))}

	TRIALS :: 60
	ref_back, got_back: [dynamic]u8
	for t in 0 ..< TRIALS {
		for &v in gs.vram {v = u32(rnd())}
		for r, i in regions {copy(saved[i], r)}
		saved_regs = gs.state.regs
		build()
		run(1, &ref_back)
		ref = gs.vram
		// Lazy and skewed: jobs reach the workers only at joins, and odd
		// workers lag, so bands run far apart.
		for cfg in ([?][2]int{{2, 1}, {4, 1}, {8, 1}, {4, 0}}) {
			n := cfg[0]
			gs.band_lazy = cfg[1] != 0
			gs.band_skew = cfg[1] * 2000
			run(n, &got_back)
			got = gs.vram
			if got != ref {
				for v, j in got {
					if v != ref[j] {
						fail("trial %d, %d bands (lazy %v): word %x got %08x want %08x", t, n, gs.band_lazy, j, v, ref[j])
						break
					}
				}
			}
			if mem.compare(got_back[:], ref_back[:]) != 0 {fail("trial %d, %d bands (lazy %v): readback differs", t, n, gs.band_lazy)}
		}
		free_all(context.temp_allocator)
	}
	// The in-place stream alone: on workers under FBMSK ff000000, serially
	// (all 8 strips, 4 bands) under FBMSK 0; both bit equal to 1 band.
	for mask in ([?]u64{0xff000000, 0}) {
		for &v in gs.vram {v = u32(rnd())}
		for r, i in regions {copy(saved[i], r)}
		saved_regs = gs.state.regs
		for s in steps {delete(s.data)}
		clear(&steps)
		put(0x1a, 1)
		in_place(mask)
		run(1, &ref_back)
		ref = gs.vram
		gs.band_lazy, gs.band_skew = true, 2000
		before := gs.band_stats
		run(4, &got_back)
		got = gs.vram
		if got != ref {fail("in place, FBMSK %08x: 4 bands differ from 1", mask)}
		serial, jobs := gs.band_stats.serial - before.serial, gs.band_stats.jobs - before.jobs
		want := mask == 0 ? u64(8) : 0
		if serial != want || jobs != 8 - want {fail("in place, FBMSK %08x: %d serial, %d on workers, want %d serial", mask, serial, jobs, want)}
	}
	region_spans()
	st := gs.band_stats
	fmt.printfln("over %d trials x 4 runs: %d primitives on workers; joins: serial %d, raw %d, war %d, alias %d, xfer %d, read %d", TRIALS, st.jobs, st.serial, st.raw, st.war, st.alias, st.xfer, st.read)
	floors := [?]u64{st.jobs, st.serial, st.raw, st.war, st.alias, st.xfer, st.read}
	for f, i in floors {if f < 20 {fail("cause %d joined %d times, floor 20", i, f)}}
	if failed > 0 {
		fmt.eprintfln("gs_band: %d failures", failed)
		os.exit(1)
	}
	fmt.println("gs_band: ok")
}
