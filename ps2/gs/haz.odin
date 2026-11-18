// Hazard tracker for a GPU consumer of the software GS's primitive stream
// (WEBGPU-GS): groups primitives into batches a GPU can draw with no
// barrier inside, and counts why each batch ends. Off unless haz_set(true)
// (PS_HAZ=1); it draws nothing and changes no emulated state.
//
// A batch ends before:
//   - a primitive that reads a texel word written earlier in the batch
//     (raw): a GPU draws a batch's primitives with no ordering between one
//     primitive's writes and the next one's texture reads;
//   - an upload, copy or CLUT load that writes words the batch wrote or read
//     (xfer); one that touches neither is hoisted ahead of the batch;
//   - a copy source or CLUT load reading words the batch wrote (read).
// A primitive that reads words its own other pixels write is tagged
// snapshot (the GPU reads the value from before the primitive), and
// ordered when one of those pixels comes before the reader in raster order
// (the software GS, drawing serially, reads the new value there).
//
// Words carry the global primitive sequence number of their last writer
// (w) and reader (r); a word belongs to the batch when its stamp is at
// least the batch's first sequence number. Page sets filter transfers
// before any word is looked at.
package ps2_gs

import "core:math"
import "core:simd"
import "ps:core"

haz_on: bool

@(private)
Haz_Tag :: enum {
	Raw, // reads a word an earlier primitive of the batch wrote
	Snapshot, // reads a word its own other pixels write
	Ordered, // ... one written by an earlier pixel in raster order
}

@(private)
Haz_Tags :: bit_set[Haz_Tag]

// Above this many texels a primitive's texture read is taken by page.
@(private)
HAZ_RECT_MAX :: 1 << 18

@(private)
haz: struct {
	// Per word: last writer's and reader's sequence number, and the
	// raster-order index of the first pixel of the writer that wrote it.
	w, r, ord:   []u32,
	seq, first:  u32,
	// Pages the batch wrote, read by word, and read by page only.
	pw, pr, pc:  Page_Set,
}

haz_set :: proc(on: bool) {
	haz_on = on
	if !on || haz.w != nil {return}
	if core.host_allocator.procedure != nil {context.allocator = core.host_allocator}
	haz.w = make([]u32, VRAM_WORDS)
	haz.r = make([]u32, VRAM_WORDS)
	haz.ord = make([]u32, VRAM_WORDS)
	haz.first = 1
}

// Ends the batch; the next one starts at sequence number `first`.
@(private)
haz_cut :: proc(first: u32) {
	band_stats.batches += 1
	haz.first = first
	haz.pw, haz.pr, haz.pc = {}, {}, {}
}

// The word holding pixel (x, y) of a buffer.
@(private)
word_at :: #force_inline proc(psm, bp, bw, x, y: u32) -> u32 {
	switch psm {
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: return addr16(psm, bp, bw, x, y) >> 1
	case PSMT8: return addr8(bp, bw, x, y) >> 2
	case PSMT4: return addr4(bp, bw, x, y) >> 3
	case PSMT8H, PSMT4HL, PSMT4HH: return addr32(PSMCT32, bp, bw, x, y)
	}
	return addr32(psm, bp, bw, x, y)
}

@(private)
page_add :: #force_inline proc "contextless" (p: ^Page_Set, w: u32) {
	pg := w >> 11
	p[pg / 64] |= 1 << (pg % 64)
}

// One walk over a primitive's texel reads. The first pass (self false)
// finds reads of words the batch wrote and stamps the reads; the second,
// after the primitive's writes are stamped, finds reads of its own writes.
@(private)
Haz_Walk :: struct {
	cur:   u32,
	self:  bool,
	o:     u32, // the reading pixel's raster-order index
	exact: bool, // o is exact (texel-exact walk), not a rectangle's
	tags:  Haz_Tags,
	rp:    Page_Set, // pages read, from the first pass
}

@(private)
haz_word :: #force_inline proc(hw: ^Haz_Walk, w: u32) #no_bounds_check {
	if !hw.self {
		if haz.w[w] >= haz.first {hw.tags += {.Raw}}
		haz.r[w] = hw.cur
		page_add(&hw.rp, w)
		return
	}
	if haz.w[w] != hw.cur {return}
	if !hw.exact {
		hw.tags += {.Snapshot, .Ordered}
		return
	}
	if haz.ord[w] != hw.o {hw.tags += {.Snapshot}}
	if haz.ord[w] < hw.o {hw.tags += {.Ordered}}
}

// Level n's taps of a sample at texel (u, v), as sample_level takes them:
// a copy of its coordinates (draw.odin sample_level, the lines from
// `u, v := tu * level_scale[n]` to `fl := simd.floor(uv)`). Sharing them
// costs the software GS 2.2% instructions:u (sp, 1510 frames): change both.
@(private)
haz_taps :: #force_inline proc(hw: ^Haz_Walk, t: ^Tex, n: u32, u, v: f32, bil: bool) #no_bounds_check {
	lu, lv := u * level_scale[n], v * level_scale[n]
	UV_EPS :: 1.0 / 512
	if bil {lu, lv = lu - 0.5 + UV_EPS, lv - 0.5 + UV_EPS}
	fl := cast(#simd[4]i32)simd.floor(#simd[4]f32{lu, lu, lv, lv})
	if !bil {
		xy := wrap(fl, &t.wrap[n])
		haz_word(hw, word_at(t.psm, t.mtbp[n], t.mtbw[n], u32(simd.extract(xy, 0)), u32(simd.extract(xy, 2))))
		return
	}
	xy := wrap(fl + {0, 1, 0, 1}, &t.wrap[n])
	x0, x1 := u32(simd.extract(xy, 0)), u32(simd.extract(xy, 1))
	y0, y1 := u32(simd.extract(xy, 2)), u32(simd.extract(xy, 3))
	haz_word(hw, word_at(t.psm, t.mtbp[n], t.mtbw[n], x0, y0))
	haz_word(hw, word_at(t.psm, t.mtbp[n], t.mtbw[n], x1, y0))
	haz_word(hw, word_at(t.psm, t.mtbp[n], t.mtbw[n], x0, y1))
	haz_word(hw, word_at(t.psm, t.mtbp[n], t.mtbw[n], x1, y1))
}

// The levels and filter of a sample at LOD lod, as sample and sample_min
// choose them: levels n0..n1.
@(private)
haz_levels :: #force_inline proc(t: ^Tex, lod: i32) -> (n0, n1: u32, bil: bool) {
	if lod <= 0 {return 0, 0, t.bilinear}
	bil = t.mmin == 1 || t.mmin >= 4
	switch t.mmin {
	case 2, 4:
		n := min(u32((lod + 1 << 22) >> 23), t.mxl)
		return n, n, bil
	case 3, 5:
		n := min(u32(lod >> 23), t.mxl)
		return n, min(n + 1, t.mxl), bil
	}
	return 0, 0, bil
}

// A sprite's reads, texel-exact: every pixel's taps as draw_sprite takes
// them.
@(private)
haz_sprite_reads :: proc(hw: ^Haz_Walk, c: ^Ctx, s: ^Sprite, q: f32) {
	t := &c.tex
	wd := u32(s.px1 - s.px0 + 1)
	for y in s.py0 ..= s.py1 {
		vv, tt := sprite_row(s, y)
		for x in s.px0 ..= s.px1 {
			u, v, lod := sprite_tex(c, s, x, vv, tt, q)
			hw.o = u32(y - s.py0) * wd + u32(x - s.px0)
			n0, n1, bil := haz_levels(t, lod)
			for n in n0 ..= n1 {haz_taps(hw, t, n, u, v, bil)}
		}
	}
}

// Another primitive's reads: every texel of each level within its
// vertices' texel bounding box, widened by the bilinear taps. False when
// the box is unbounded or too large: the reads are then taken by page.
@(private)
haz_rect_reads :: proc(hw: ^Haz_Walk, c: ^Ctx, nv: int, q: ^[3]Vertex) -> bool #no_bounds_check {
	t := &c.tex
	m := tex_map(c)
	u0, v0 := max(f32), max(f32)
	u1, v1 := min(f32), min(f32)
	neg, pos: bool
	for i in 0 ..< nv {
		p := &q[i]
		if !c.fst {
			if p.q < 0 {neg = true} else {pos = true}
		}
		u, v, _ := tex_at(m, {p.s, p.t, p.u, p.v}, p.q)
		if math.is_nan(u) || math.is_nan(v) || math.is_inf(u) || math.is_inf(v) {return false}
		u0, u1, v0, v1 = min(u0, u), max(u1, u), min(v0, v), max(v1, v)
	}
	// Mixed signs of Q put the interpolated S/Q through infinity.
	if neg && pos {return false}
	n1 := t.flat ? 0 : t.mxl
	total: f32
	for n in 0 ..= n1 {
		sc := level_scale[n]
		total += (math.floor(u1 * sc) - math.floor(u0 * sc) + 3) * (math.floor(v1 * sc) - math.floor(v0 * sc) + 3)
	}
	if total > HAZ_RECT_MAX {return false}
	for n in 0 ..= n1 {
		sc := level_scale[n]
		x0, x1 := i32(math.floor(u0 * sc)) - 1, i32(math.floor(u1 * sc)) + 1
		y0, y1 := i32(math.floor(v0 * sc)) - 1, i32(math.floor(v1 * sc)) + 1
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				xy := wrap(#simd[4]i32{x, x, y, y}, &t.wrap[n])
				haz_word(hw, word_at(t.psm, t.mtbp[n], t.mtbw[n], u32(simd.extract(xy, 0)), u32(simd.extract(xy, 2))))
			}
		}
	}
	return true
}

// Every page a context's texture can reach (as band_ctx_new takes them).
@(private)
haz_tex_pages :: proc(c: ^Ctx, out: ^Page_Set) {
	t := &c.tex
	for n in 0 ..= min(t.mxl, 6) {
		w := t.wms >= 2 ? 1024 : max(t.w >> n, 1)
		h := t.wmt >= 2 ? 1024 : max(t.h >> n, 1)
		page_rect(t.psm, t.mtbp[n], t.mtbw[n], 0, 0, w, h, out)
	}
}

// Stamps the frame and Z words of pixels [x0, x1] x [y0, y1]; o counts
// pixels in raster order when exact, else stays 0.
@(private)
haz_writes :: proc(c: ^Ctx, cur: u32, x0, y0, x1, y1: i32, exact: bool, wp: ^Page_Set) #no_bounds_check {
	fb := c.fbmsk != 0xffffffff
	zb := c.zte && !c.zmsk
	if !fb && !zb {return}
	wd := u32(x1 - x0 + 1)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			o := exact ? u32(y - y0) * wd + u32(x - x0) : 0
			if fb {
				w := word_at(c.fpsm, c.fbp, c.fbw, u32(x), u32(y))
				if haz.w[w] != cur {haz.w[w], haz.ord[w] = cur, o}
				page_add(wp, w)
			}
			if zb {
				w := word_at(c.zpsm, c.zbp, c.fbw, u32(x), u32(y))
				if haz.w[w] != cur {haz.w[w], haz.ord[w] = cur, o}
				page_add(wp, w)
			}
		}
	}
}

// Primitive `kind` of the queue, about to be drawn with context c: its
// tags (Raw: the batch was cut before it).
@(private)
haz_draw :: proc(c: ^Ctx, kind: u64) -> Haz_Tags {
	@(static, rodata) verts := [8]int{1, 2, 2, 3, 3, 3, 2, 1}
	haz.seq += 1
	if haz.seq == 0 {
		// Wrapped: every stamp is stale.
		for &x in haz.w {x = 0}
		for &x in haz.r {x = 0}
		haz.seq = 1
		haz_cut(1)
	}
	cur := haz.seq
	hw := Haz_Walk{cur = cur}
	s, sprite := Sprite{}, false
	if kind == 6 {
		s, sprite = sprite_span(c, &queue[0], &queue[1])
		if !sprite || s.px1 < s.px0 || s.py1 < s.py0 {return {}}
	}
	// Reads against the batch's writes.
	coarse: Page_Set
	is_coarse := false
	if c.tme {
		if sprite {
			hw.exact = true
			haz_sprite_reads(&hw, c, &s, queue[1].q)
		} else if !haz_rect_reads(&hw, c, verts[kind & 7], &queue) {
			is_coarse = true
			haz_tex_pages(c, &coarse)
			if pages_meet(&coarse, &haz.pw) {hw.tags += {.Raw}}
		}
	}
	if .Raw in hw.tags {
		band_stats.haz_raw += 1
		haz_cut(cur)
	}
	for v, i in hw.rp {haz.pr[i] |= v}
	for v, i in coarse {haz.pc[i] |= v}
	// Writes.
	wp: Page_Set
	if sprite {
		haz_writes(c, cur, s.px0, s.py0, s.px1, s.py1, true, &wp)
	} else {
		x0, y0, x1, y1, ok := prim_rect(c, kind, &queue)
		if ok {haz_writes(c, cur, i32(x0), i32(y0), i32(x1) - 1, i32(y1) - 1, false, &wp)}
	}
	for v, i in wp {haz.pw[i] |= v}
	// Reads of its own writes.
	if c.tme && is_coarse {
		if pages_meet(&coarse, &wp) {hw.tags += {.Snapshot, .Ordered}}
	} else if c.tme && pages_meet(&hw.rp, &wp) {
		hw.self = true
		if sprite {
			haz_sprite_reads(&hw, c, &s, queue[1].q)
		} else {
			haz_rect_reads(&hw, c, verts[kind & 7], &queue)
		}
	}
	if .Snapshot in hw.tags {band_stats.haz_snap += 1}
	if .Ordered in hw.tags {band_stats.haz_ordered += 1}
	return hw.tags
}

// A transfer about to write w x h pixels of a buffer from (x0, y0): cuts
// the batch when it wrote or read them, else hoists the transfer ahead.
@(private)
haz_write :: proc(psm, bp, bw, x0, y0, w, h: u32) #no_bounds_check {
	p: Page_Set
	page_rect(psm, bp, bw, x0, y0, x0 + w, y0 + h, &p)
	cut := pages_meet(&p, &haz.pc)
	if !cut && (pages_meet(&p, &haz.pw) || pages_meet(&p, &haz.pr)) {
		scan: for y in y0 ..< y0 + h {
			for x in x0 ..< x0 + w {
				i := word_at(psm, bp, bw, x & 2047, y & 2047)
				if haz.w[i] >= haz.first || haz.r[i] >= haz.first {
					cut = true
					break scan
				}
			}
		}
	}
	if !cut {
		band_stats.haz_hoist += 1
		return
	}
	band_stats.haz_xfer += 1
	haz_cut(haz.seq + 1)
}

// A copy or CLUT load about to read w x h pixels of a buffer: cuts the
// batch when it wrote them.
@(private)
haz_read :: proc(psm, bp, bw, x0, y0, w, h: u32) #no_bounds_check {
	p: Page_Set
	page_rect(psm, bp, bw, x0, y0, x0 + w, y0 + h, &p)
	if !pages_meet(&p, &haz.pw) {return}
	for y in y0 ..< y0 + h {
		for x in x0 ..< x0 + w {
			if haz.w[word_at(psm, bp, bw, x & 2047, y & 2047)] >= haz.first {
				band_stats.haz_read += 1
				haz_cut(haz.seq + 1)
				return
			}
		}
	}
}

// `haz_read` of blocks [b0, b1) (a CSM1 CLUT).
@(private)
haz_read_blocks :: proc(b0, b1: u32) #no_bounds_check {
	for b in b0 ..< b1 {
		for i in 0 ..< u32(64) {
			if haz.w[(b * 64 + i) & (VRAM_WORDS - 1)] >= haz.first {
				band_stats.haz_read += 1
				haz_cut(haz.seq + 1)
				return
			}
		}
	}
}
