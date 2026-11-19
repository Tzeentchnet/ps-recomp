// Primitive assembly, rasterisation and the per-pixel pipeline: texture
// mapping, fog, alpha test, destination alpha test, depth test, blending
// and masked frame/depth writes.
//
// write, vertex, decode_ctx, fetch and pixel run without bounds checks.
// Every index there is a constant, masked to its array (context &1, prim
// kind &7, CLUT &511), bounded by a loop over the array, a mip level
// clamped to 6 (mxl), or the vertex queue count, which vertex checks
// itself because snapshots restore it.
package ps2_gs

import "core:math"
import "core:simd"

Vertex :: struct {
	x, y:    f32, // pixels, window-relative
	z:       f64,
	c:       [4]f32, // r, g, b, a
	s, t, q: f32,
	u, v:    f32, // texels (FST = 1)
	fog:     f32,
}

// Frames rerun after a netplay rollback are drawn but not shown.
skip_present: bool

@(private)
cur: Vertex // attributes from RGBAQ/ST/UV/FOG awaiting a vertex kick
@(private)
queue: [3]Vertex
@(private)
nq: int

@(private)
Tex :: struct {
	tbp, tbw, psm:      u32,
	w, h:               u32,
	tcc:                bool,
	tfx:                u32,
	cpsm, csa:          u32,
	bilinear:           bool,
	// LOD cannot change the sample (decode_ctx): every pixel takes level 0
	// with MMAG's filter.
	flat:               bool,
	wms, wmt:           u32,
	minu, maxu:         u32,
	minv, maxv:         u32,
	ta0, ta1:           u32,
	aem:                bool,
	// Mipmapping, from TEX1 and MIPTBP1/2: level n's base and width.
	lcm:                bool, // LOD is K alone
	mxl, mmin, l:       u32,
	k:                  i32, // 1/16ths
	mtbp, mtbw:         [7]u32,
	// Level n's wrap, set for levels 0..mxl (tex_wrap).
	wrap:               [7]Tex_Wrap,
	tc:                 ^Tc, // the texture cache sampled: tc_main, or a band worker's
}

// One level's wrap of the bilinear taps' coordinates (x0, x1, y0, y1),
// every mode as (min(max(i, lo), hi) & mask) | fix (wrap_axis).
@(private)
Tex_Wrap :: struct {
	lo, hi, mask, fix: #simd[4]i32,
}

// Drawing state for one primitive, decoded from PRIM and its context.
@(private)
Ctx :: struct {
	iip, tme, fge, abe, fst: bool,
	fbp, fbw, fpsm, fbmsk:   u32,
	zbp, zpsm:               u32,
	zmsk:                    bool,
	sx0, sx1, sy0, sy1:      i32,
	ate:                     bool,
	atst, aref, afail:       u32,
	date, datm:              bool,
	zte:                     bool,
	ztst:                    u32,
	a, b, c, d, fix:         u32,
	pabe, fba, colclamp:     bool,
	on_display:              bool, // FRAME FBP is a shown buffer
	// Whether pixel needs the stored frame pixel (DATE, FBMSK, a blend
	// reading Cd or Ad, or an alpha fail keeping Ad) and the stored Z
	// (GEQUAL or GREATER). Skipped reads are dead.
	dst_read, z_read:        bool,
	frow, zrow:              Row,
	px:                      Pixel_Proc, // pixel or a fast proc (px_pick)
	row:                     Tri_Row_Proc, // tri_row or a fast one (px_pick)
	srow:                    Sprite_Row_Proc, // spr_row or a fast one (px_pick)
	fogcol:                  [3]i32,
	tex:                     Tex,
	// A band worker draws the rows y of its band alone: (y >> 3) % nband
	// == band (band.odin). nband 0 or 1 draws every row.
	band, nband:             u32,
}

// Every GS register write lands here after gs_write stores it.
write :: proc(reg: u8, v: u64) #no_bounds_check {
	switch reg {
	case GS_PRIM: nq = 0
	case GS_RGBAQ:
		cur.c = {f32(v & 0xff), f32((v >> 8) & 0xff), f32((v >> 16) & 0xff), f32((v >> 24) & 0xff)}
		cur.q = transmute(f32)u32(v >> 32)
	case GS_ST:
		cur.s = transmute(f32)u32(v)
		cur.t = transmute(f32)u32(v >> 32)
	case GS_UV:
		cur.u = f32(v & 0x3fff) / 16
		cur.v = f32((v >> 16) & 0x3fff) / 16
	case GS_FOG: cur.fog = f32(v >> 56)
	case GS_XYZF2, GS_XYZF3:
		cur.fog = f32(v >> 56)
		vertex(v, f64((v >> 32) & 0xffffff), reg == GS_XYZF2)
	case GS_XYZ2, GS_XYZ3:
		vertex(v, f64(v >> 32), reg == GS_XYZ2)
	case 0x06, 0x07: clut_load(v) // TEX0_1/2
	case 0x16, 0x17: // TEX2_1/2: PSM and CLUT fields of TEX0
		MASK :: u64(0x3f) << 20 | 0xffff_ffe0_0000_0000
		t := &state.regs[reg - 0x10]
		t^ = (t^ &~ MASK) | (v & MASK)
		clut_load(t^)
	case GS_TRXDIR: xfer_start(u32(v))
	}
}

@(private)
prim_attrs :: proc() -> u64 {
	prim := state.regs[GS_PRIM]
	if state.regs[0x1a] & 1 == 0 {prim = (prim & 7) | (state.regs[0x1b] &~ 7)} // PRMODECONT
	return prim
}

@(private)
vertex :: proc(xyz: u64, z: f64, kick: bool) #no_bounds_check {
	prim := prim_attrs()
	ctx := u32(prim >> 9) & 1
	off := state.regs[0x18 + ctx]
	v := cur
	v.x = (f32(xyz & 0xffff) - f32(off & 0xffff)) / 16
	v.y = (f32((xyz >> 16) & 0xffff) - f32((off >> 32) & 0xffff)) / 16
	v.z = z
	if nq >= len(queue) {panic("gs: vertex queue overrun")}
	queue[nq] = v
	nq += 1
	kind := prim & 7
	@(static, rodata) need := [8]int{1, 2, 2, 3, 3, 3, 2, 1}
	if nq < need[kind] {return}
	if kick && kind != 7 {draw(kind, prim)}
	switch kind {
	case 2: // line strip
		queue[0] = queue[1]
		nq = 1
	case 4: // triangle strip
		queue[0], queue[1] = queue[1], queue[2]
		nq = 2
	case 5: // triangle fan
		queue[1] = queue[2]
		nq = 2
	case:
		nq = 0
	}
}

@(private)
decode_ctx :: proc(prim: u64) -> (c: Ctx) #no_bounds_check {
	r := &state.regs
	n := u32(prim >> 9) & 1
	c.iip = prim & (1 << 3) != 0
	c.tme = prim & (1 << 4) != 0
	c.fge = prim & (1 << 5) != 0
	c.abe = prim & (1 << 6) != 0
	c.fst = prim & (1 << 8) != 0

	frame := r[0x4c + n]
	c.fbp = u32(frame & 0x1ff) * 32
	c.fbw = u32(frame >> 16) & 0x3f
	c.fpsm = u32(frame >> 24) & 0x3f
	c.fbmsk = u32(frame >> 32)
	for e in shown[:n_shown] {c.on_display = c.on_display || e.fbp == c.fbp}
	zbuf := r[0x4e + n]
	c.zbp = u32(zbuf & 0x1ff) * 32
	c.zpsm = (u32(zbuf >> 24) & 0xf) | 0x30
	c.zmsk = zbuf & (1 << 32) != 0
	sc := r[0x40 + n]
	c.sx0, c.sx1 = i32(sc & 0x7ff), i32((sc >> 16) & 0x7ff)
	c.sy0, c.sy1 = i32((sc >> 32) & 0x7ff), i32((sc >> 48) & 0x7ff)
	test := r[0x47 + n]
	c.ate = test & 1 != 0
	c.atst = u32(test >> 1) & 7
	c.aref = u32(test >> 4) & 0xff
	c.afail = u32(test >> 12) & 3
	c.date = test & (1 << 14) != 0
	c.datm = test & (1 << 15) != 0
	c.zte = test & (1 << 16) != 0
	c.ztst = u32(test >> 17) & 3
	al := r[0x42 + n]
	c.a, c.b, c.c, c.d = u32(al) & 3, u32(al >> 2) & 3, u32(al >> 4) & 3, u32(al >> 6) & 3
	c.fix = u32(al >> 32) & 0xff
	c.pabe = r[0x49] & 1 != 0
	c.fba = r[0x4a + n] & 1 != 0
	c.colclamp = r[0x46] & 1 != 0
	fc := r[0x3d]
	c.fogcol = {i32(fc & 0xff), i32((fc >> 8) & 0xff), i32((fc >> 16) & 0xff)}
	blend_dst := c.a == 1 || c.b == 1 || c.c == 1 || c.d == 1
	c.dst_read = c.date || c.fbmsk != 0 || (c.abe && blend_dst) || (c.ate && c.afail == 3)
	c.z_read = c.zte && c.ztst >= 2
	c.frow, c.zrow = row_init(c.fpsm), row_init(c.zpsm)

	if c.tme {
		t0 := r[0x06 + n]
		t1 := r[0x14 + n]
		cl := r[0x08 + n]
		ta := r[0x3b]
		mip := [2]u64{r[0x34 + n], r[0x36 + n]}
		c.tex = {
			tbp      = u32(t0) & 0x3fff,
			tbw      = u32(t0 >> 14) & 0x3f,
			psm      = u32(t0 >> 20) & 0x3f,
			w        = 1 << min(u32(t0 >> 26) & 0xf, 10),
			h        = 1 << min(u32(t0 >> 30) & 0xf, 10),
			tcc      = t0 & (1 << 34) != 0,
			tfx      = u32(t0 >> 35) & 3,
			cpsm     = u32(t0 >> 51) & 0xf,
			csa      = u32(t0 >> 56) & 0x1f,
			bilinear = t1 & (1 << 5) != 0,
			wms      = u32(cl) & 3,
			wmt      = u32(cl >> 2) & 3,
			minu     = u32(cl >> 4) & 0x3ff,
			maxu     = u32(cl >> 14) & 0x3ff,
			minv     = u32(cl >> 24) & 0x3ff,
			maxv     = u32(cl >> 34) & 0x3ff,
			ta0      = u32(ta) & 0xff,
			ta1      = u32(ta >> 32) & 0xff,
			aem      = ta & (1 << 15) != 0,
			lcm      = t1 & 1 != 0,
			mxl      = min(u32(t1 >> 2) & 7, 6),
			mmin     = u32(t1 >> 6) & 7,
			l        = u32(t1 >> 19) & 3,
			k        = i32(u32(t1 >> 32) << 20) >> 20,
		}
		// MMIN 0, 1, 6 and 7 sample level 0 at any LOD, and so does a
		// mipmap filter with MXL 0 (sample_min). When MMIN's filter there is
		// MMAG's too, the sample is the same at every LOD.
		level0 := c.tex.mmin < 2 || c.tex.mmin > 5 || c.tex.mxl == 0
		c.tex.flat = level0 && (c.tex.mmin == 1 || c.tex.mmin >= 4) == c.tex.bilinear && !tex_fold_off
		c.tex.mtbp[0], c.tex.mtbw[0] = c.tex.tbp, c.tex.tbw
		for i in u32(1) ..= 6 {
			m := mip[(i - 1) / 3] >> (((i - 1) % 3) * 20)
			c.tex.mtbp[i], c.tex.mtbw[i] = u32(m) & 0x3fff, u32(m >> 14) & 0x3f
		}
		for i in u32(0) ..= c.tex.mxl {
			shown_read(c.tex.mtbp[i], c.tex.mtbw[i], c.tex.psm, 0, c.tex.h >> i)
		}
		tex_wrap(&c.tex)
	}
	c.px, c.row, c.srow = px_pick(&c)
	c.tex.tc = &tc_main
	return
}

// No texture is flat in a context decoded from now on (probe_fold).
@(private)
tex_fold_off: bool

// PRIM's bits decode_ctx reads: IIP, TME, FGE, ABE, FST, CTXT.
@(private)
CTX_PRIM :: 0x378

// The last context decoded, and the ctx_gen and PRIM bits it was decoded
// at. Primitives only read it.
@(private)
ctx_cur: Ctx
@(private)
ctx_key: [2]u64

@(private)
draw :: proc(kind, prim: u64) {
	key := [2]u64{ctx_gen, prim & CTX_PRIM}
	if key != ctx_key {
		ctx_cur, ctx_key = decode_ctx(prim), key
		tc_ctx(&tc_main, &ctx_cur)
		band_ctx_new()
	}
	c := &ctx_cur
	if skip_on && c.on_display {return} // headless: a shown buffer, redrawn before it is read
	if c.zte && c.ztst == 0 {return} // NEVER
	if haz_on {haz_draw(c, kind)}
	if hw_on {
		hw_draw(c, kind)
		return
	}
	if band.n > 0 {
		band_draw(c, kind)
		return
	}
	tc_draw(&tc_main, c, kind, &queue)
	raster(c, kind, &queue)
}

// Rasterises primitive `kind` of vertices q in context c.
@(private)
raster :: proc(c: ^Ctx, kind: u64, q: ^[3]Vertex) {
	switch kind {
	case 0: draw_point(c, &q[0])
	case 1, 2: draw_line(c, &q[0], &q[1])
	case 3, 4, 5: draw_tri(c, &q[0], &q[1], &q[2])
	case 6: draw_sprite(c, &q[0], &q[1])
	}
}

// Whether row y belongs to another band than c's (Ctx.band).
@(private)
band_skip :: #force_inline proc "contextless" (c: ^Ctx, y: i32) -> bool {
	return c.nband > 1 && (u32(y) >> 3) % c.nband != c.band
}

// ------------------------------------------------------------ rasteriser

@(private)
draw_point :: proc(c: ^Ctx, v: ^Vertex) {
	x, y := i32(math.floor(v.x)), i32(math.floor(v.y))
	if x < c.sx0 || x > c.sx1 || y < c.sy0 || y > c.sy1 || band_skip(c, y) {return}
	u, tv, lod := tex_coord(c, {v.s, v.t, v.u, v.v}, v.q)
	ctx_seek(c, y)
	c.px(c, x, y, v.z, v.c, u, tv, lod, v.fog)
}

@(private)
draw_line :: proc(c: ^Ctx, a, b: ^Vertex) {
	dx, dy := b.x - a.x, b.y - a.y
	n := int(max(abs(dx), abs(dy)))
	for i in 0 ..< n {
		f := f32(i) / f32(n)
		v := lerp_vertex(a, b, f)
		if !c.iip {v.c = b.c}
		x, y := i32(math.floor(v.x)), i32(math.floor(v.y))
		if x < c.sx0 || x > c.sx1 || y < c.sy0 || y > c.sy1 || band_skip(c, y) {continue}
		u, tv, lod := tex_coord(c, {v.s, v.t, v.u, v.v}, v.q)
		ctx_seek(c, y)
		c.px(c, x, y, v.z, v.c, u, tv, lod, v.fog)
	}
}

@(private)
lerp_vertex :: proc(a, b: ^Vertex, f: f32) -> (v: Vertex) {
	v.x = a.x + (b.x - a.x) * f
	v.y = a.y + (b.y - a.y) * f
	v.z = a.z + (b.z - a.z) * f64(f)
	v.c = a.c + (b.c - a.c) * f
	v.s = a.s + (b.s - a.s) * f
	v.t = a.t + (b.t - a.t) * f
	v.q = a.q + (b.q - a.q) * f
	v.u = a.u + (b.u - a.u) * f
	v.v = a.v + (b.v - a.v) * f
	v.fog = a.fog + (b.fog - a.fog) * f
	return
}

// Texel-space coordinates from stuv = {S, T, U, V} and Q, and the level of
// detail. All four lanes take part in the divide and the scale (U and V
// as /1*1, exact), so no lane holds leftover data. Do not narrow this to
// two-lane scalar math: LLVM then packs s/q and t/q into a vector divide
// whose undefined upper lanes hold the sampler's leftover integers, which
// read as denormal floats, and the denormal assist on undefined lanes costs
// a microcode assist per pixel (over 20% of the software GS's wall time).
@(private)
tex_coord :: #force_inline proc(c: ^Ctx, stuv: #simd[4]f32, q: f32) -> (f32, f32, i32) {
	if !c.tme {return 0, 0, 0}
	return tex_at(tex_map(c), stuv, q)
}

// What tex_coord takes from the context, the same for every pixel of a
// primitive.
@(private)
Tex_Map :: struct {
	sc:       #simd[4]f32, // S and T to texels; ones for U and V
	fst, lcm: bool,
	l:        u32,
	k:        i32, // K as tex_lod adds it
}

// A flat texture's LOD is 0, as under LCM with K 0: its pixels compute no
// LOD and `sample` takes level 0 inline, with no call of sample_min.

@(private)
tex_map :: #force_inline proc(c: ^Ctx) -> (m: Tex_Map) {
	m.sc = {1, 1, 1, 1}
	if !c.fst {m.sc = {f32(c.tex.w), f32(c.tex.h), 1, 1}}
	m.fst, m.lcm, m.l, m.k = c.fst, c.tex.lcm, c.tex.l, c.tex.k << 19
	if c.tex.flat {m.lcm, m.k = true, 0}
	return
}

// tex_coord of a texture-mapped context, its part of the context taken
// beforehand. The four-lane divide tex_coord's comment speaks of is here.
@(private)
tex_at :: #force_inline proc(m: Tex_Map, stuv: #simd[4]f32, q: f32) -> (f32, f32, i32) {
	d := f32(1)
	lod: i32
	if m.fst {
		lod = tex_lod(m, 1)
	} else {
		lod = tex_lod(m, q)
		if q != 0 {d = q}
	}
	r := stuv / #simd[4]f32{d, d, 1, 1} * m.sc
	if m.fst {return simd.extract(r, 2), simd.extract(r, 3), lod}
	return simd.extract(r, 0), simd.extract(r, 1), lod
}

// LOD = log2(1/|Q|) * 2^L + K in 1/2^23ths, the log taken as the float's
// exponent plus its mantissa read linearly: integer arithmetic, so the
// GPU's shaders/prim.frag `tex_lod` gets the same levels. UV primitives
// take Q as 1.
@(private)
tex_lod :: #force_inline proc(m: Tex_Map, q: f32) -> i32 {
	x: i32
	if !m.lcm {
		x = clamp(127 << 23 - i32(transmute(u32)abs(q)), -16 << 23, 16 << 23) << m.l
	}
	return x + m.k
}

// A sprite's box and its attributes from the left/top corner to the
// right/bottom one; pixels px0..px1 x py0..py1, scissored. draw_sprite and
// the hazard tracker (haz.odin) take a pixel's texel coordinates from it the
// same way, so both see the same texels.
@(private)
Sprite :: struct {
	x0, x1, y0, y1:                 f32,
	ua, ub, va, vb, sa, sb, ta, tb: f32,
	px0, px1, py0, py1:             i32,
}

// False when the sprite has no area.
@(private)
sprite_span :: #force_inline proc(c: ^Ctx, a, b: ^Vertex) -> (s: Sprite, ok: bool) {
	s.x0, s.x1 = min(a.x, b.x), max(a.x, b.x)
	s.y0, s.y1 = min(a.y, b.y), max(a.y, b.y)
	if s.x1 <= s.x0 || s.y1 <= s.y0 {return}
	// Attributes run from a to b; flip if b is the left/top corner.
	s.ua, s.ub = a.u, b.u
	s.va, s.vb = a.v, b.v
	s.sa, s.sb = a.s, b.s
	s.ta, s.tb = a.t, b.t
	if a.x > b.x {s.ua, s.ub, s.sa, s.sb = s.ub, s.ua, s.sb, s.sa}
	if a.y > b.y {s.va, s.vb, s.ta, s.tb = s.vb, s.va, s.tb, s.ta}
	s.px0 = max(i32(math.ceil(s.x0)), c.sx0)
	s.px1 = min(i32(math.ceil(s.x1)) - 1, c.sx1)
	s.py0 = max(i32(math.ceil(s.y0)), c.sy0)
	s.py1 = min(i32(math.ceil(s.y1)) - 1, c.sy1)
	return s, true
}

// Row y's V and T.
@(private)
sprite_row :: #force_inline proc "contextless" (s: ^Sprite, y: i32) -> (vv, tt: f32) {
	fy := (f32(y) - s.y0) / (s.y1 - s.y0)
	return s.va + (s.vb - s.va) * fy, s.ta + (s.tb - s.ta) * fy
}

// Pixel x's texel coordinates and LOD on the row sprite_row gave vv, tt
// for; q is the second vertex's.
@(private)
sprite_tex :: #force_inline proc(c: ^Ctx, s: ^Sprite, x: i32, vv, tt, q: f32) -> (f32, f32, i32) {
	return tex_coord(c, sprite_stuv(s, x, vv, tt), q)
}

// Pixel x's S, T, U and V on the row sprite_row gave vv, tt for.
@(private)
sprite_stuv :: #force_inline proc "contextless" (s: ^Sprite, x: i32, vv, tt: f32) -> #simd[4]f32 {
	fx := (f32(x) - s.x0) / (s.x1 - s.x0)
	return {s.sa + (s.sb - s.sa) * fx, tt, s.ua + (s.ub - s.ua) * fx, vv}
}

@(private)
draw_sprite :: proc(c: ^Ctx, a, b: ^Vertex) {
	s, ok := sprite_span(c, a, b)
	if !ok {return}
	for y in s.py0 ..= s.py1 {
		if band_skip(c, y) {continue}
		vv, tt := sprite_row(&s, y)
		ctx_seek(c, y)
		c.srow(c, &s, b, y, vv, tt)
	}
}

// Draws row y of a sprite, vv and tt its V and T (sprite_row), b the
// vertex whose Z, color, Q and fog every pixel takes.
@(private)
Sprite_Row_Proc :: #type proc(c: ^Ctx, s: ^Sprite, b: ^Vertex, y: i32, vv, tt: f32)

// The sprite row proc of a context with the generic pixel proc, or with
// one a probe put in its place: each pixel through c.px.
@(private)
spr_row :: proc(c: ^Ctx, s: ^Sprite, b: ^Vertex, y: i32, vv, tt: f32) {spr_span(c, s, b, y, vv, tt, false, 0)}

// The pixels of one sprite row. FAST draws them with PX_FAST[N] inline,
// whose texture mapping is then a constant; else each goes through c.px.
// Every pixel gets the arguments draw_sprite gave it.
@(private)
spr_span :: #force_inline proc(c: ^Ctx, s: ^Sprite, b: ^Vertex, y: i32, vv, tt: f32, $FAST: bool, $N: int) #no_bounds_check {
	// Local copies: a pixel writes memory, and nothing behind a pointer is
	// known to outlive that.
	s := s^
	z, col, fog := b.z, b.c, b.fog
	when FAST {
		TME :: PX_FAST[N].tfx >= 0 // as c.tme (px_pick)
		when TME {tm, q := tex_map(c), b.q}
	} else {
		q := b.q
	}
	for x in s.px0 ..= s.px1 {
		u, v: f32
		lod: i32
		when FAST {
			zok, zv, za := px_zinst(c, x, z, N)
			if !zok {continue}
			when TME {u, v, lod = tex_at(tm, sprite_stuv(&s, x, vv, tt), q)}
			px_shade_inst(c, x, zv, za, col, u, v, lod, fog, N)
		} else {
			u, v, lod = sprite_tex(c, &s, x, vv, tt, q)
			c.px(c, x, y, z, col, u, v, lod, fog)
		}
	}
}

@(private)
draw_tri :: proc(c: ^Ctx, v0, v1, v2: ^Vertex) {
	a, b, d := v0, v1, v2
	area := f64(b.x - a.x) * f64(d.y - a.y) - f64(b.y - a.y) * f64(d.x - a.x)
	if area == 0 {return}
	if area < 0 {
		b, d = d, b
		area = -area
	}
	minx := max(i32(math.ceil(min(a.x, b.x, d.x))), c.sx0)
	maxx := min(i32(math.floor(max(a.x, b.x, d.x))), c.sx1)
	miny := max(i32(math.ceil(min(a.y, b.y, d.y))), c.sy0)
	maxy := min(i32(math.floor(max(a.y, b.y, d.y))), c.sy1)
	if minx > maxx || miny > maxy {return}

	// Edge e(p) = (q.x - p0.x)(p.y - p0.y) - (q.y - p0.y)(p.x - p0.x), positive
	// inside. Pixels on an edge belong to it only for top or left edges.
	Edge :: struct {dx, dy, w: f64, bias: bool}
	mk :: proc(p, q: ^Vertex, x, y: f64) -> Edge {
		dx, dy := f64(q.x - p.x), f64(q.y - p.y)
		w := dx * (y - f64(p.y)) - dy * (x - f64(p.x))
		top_left := dy < 0 || (dy == 0 && dx > 0)
		return {dx, dy, w, top_left}
	}
	fx, fy := f64(minx), f64(miny)
	e0 := mk(b, d, fx, fy) // weight of a
	e1 := mk(d, a, fx, fy) // weight of b
	e2 := mk(a, b, fx, fy) // weight of d
	inv := 1 / area
	flat := a.c
	if !c.iip {flat = v2.c}
	sa := #simd[4]f32{a.s, a.t, a.u, a.v}
	sb := #simd[4]f32{b.s, b.t, b.u, b.v}
	sd := #simd[4]f32{d.s, d.t, d.u, d.v}
	t := Tri_Setup {
		inv  = inv,
		dy   = {e0.dy, e1.dy, e2.dy},
		z    = {a.z, b.z, d.z},
		c    = {a.c, b.c, d.c},
		flat = flat,
		s    = {sa, sb, sd},
		q    = {a.q, b.q, d.q},
		fog  = {a.fog, b.fog, d.fog},
		iip  = c.iip,
		tme  = c.tme,
		fge  = c.fge,
		tm   = tex_map(c),
	}
	// Every step of an edge is exact. A vertex's x and y are sixteenths
	// below 4096 in magnitude (vertex; lerp_vertex's output goes to draw_line
	// only), so dx and dy are sixteenths below 8192, and the box lies in the
	// scissor's 11 bits: w is a count of 1/256ths below 2^35, far inside a
	// double's 53 bits, and no sum or difference of w with dx or dy rounds.
	// So at minx + k an edge is exactly w - k * dy, its test passes on one
	// run of k, and the three pass together on one run [ks, ke], found here
	// from the 1/256ths as integers: w - k * dy >= 0, with w one lower for
	// an edge that does not own its pixels.
	Run :: struct {w, dx, dy: i64}
	run :: proc(e: Edge) -> Run {
		return {i64(e.w * 256) - i64(!e.bias), i64(e.dx * 256), i64(e.dy * 256)}
	}
	// a / b rounded down, for b > 0.
	floor_div :: #force_inline proc(a, b: i64) -> i64 {
		q := a / b
		if a % b < 0 {q -= 1}
		return q
	}
	runs := [3]Run{run(e0), run(e1), run(e2)}
	last := i64(maxx - minx)
	for y in miny ..= maxy {
		defer {
			e0.w += e0.dx
			e1.w += e1.dx
			e2.w += e2.dx
		}
		ks, ke := i64(0), last
		for &r in runs {
			switch {
			case r.dy > 0: ke = min(ke, floor_div(r.w, r.dy))
			case r.dy < 0: ks = max(ks, -floor_div(r.w, -r.dy))
			case r.w < 0: ke = -1 // a level edge: the whole row, or none of it
			}
			r.w += r.dx
		}
		if ks > ke || band_skip(c, y) {continue}
		// The weights at ks, exact, then stepped pixel by pixel as a walk
		// from minx would have stepped them.
		k := f64(ks)
		w0, w1, w2 := e0.w - k * e0.dy, e1.w - k * e1.dy, e2.w - k * e2.dy
		ctx_seek(c, y)
		c.row(c, &t, minx + i32(ks), minx + i32(ke), y, {w0, w1, w2})
	}
}

// What the pixels of one triangle read of its vertices and its context,
// taken once, with b and d swapped as draw_tri wound them: vertex i's
// fields at index i of a, b, d.
@(private)
Tri_Setup :: struct {
	inv:           f64, // 1 / the doubled area
	dy, z:         [3]f64, // dy: an edge's weight step per pixel of x
	c:             [3][4]f32,
	flat:          [4]f32, // the color when IIP is off
	s:             [3]#simd[4]f32, // S, T, U and V
	q, fog:        [3]f32,
	iip, tme, fge: bool,
	tm:            Tex_Map,
}

// Draws pixels x0 ..= x1 of row y of a triangle, w the edge weights at x0.
@(private)
Tri_Row_Proc :: #type proc(c: ^Ctx, t: ^Tri_Setup, x0, x1, y: i32, w: [3]f64)

// The row proc of a context with the generic pixel proc, or with one a
// probe put in its place: each pixel through c.px.
@(private)
tri_row :: proc(c: ^Ctx, t: ^Tri_Setup, x0, x1, y: i32, w: [3]f64) {tri_span(c, t, x0, x1, y, w, false, 0)}

// The pixels of one row. FAST draws them with PX_FAST[N] inline, whose
// texture mapping and FGE are then constants; else each goes through
// c.px. The weights step pixel by pixel as a walk from the box's left
// edge would have stepped them, so every pixel gets the same arguments
// either way.
@(private)
tri_span :: #force_inline proc(c: ^Ctx, t: ^Tri_Setup, x0, x1, y: i32, w: [3]f64, $FAST: bool, $N: int) #no_bounds_check {
	// A local copy: a pixel writes memory, and nothing behind a pointer is
	// known to outlive that.
	t := t^
	TME :: !FAST || PX_FAST[N].tfx >= 0
	FGE :: !FAST || PX_FAST[N].fge
	w0, w1, w2 := w[0], w[1], w[2]
	for x in x0 ..= x1 {
		defer {w0 -= t.dy[0]; w1 -= t.dy[1]; w2 -= t.dy[2]}
		l0, l1, l2 := w0 * t.inv, w1 * t.inv, w2 * t.inv
		z := t.z[0] * l0 + t.z[1] * l1 + t.z[2] * l2
		// A fast context tests depth before it interpolates the rest: a
		// pixel failing the test needs no color, texture or fog.
		when FAST {
			zok, zv, za := px_zinst(c, x, z, N)
			if !zok {continue}
		}
		f0, f1, f2 := f32(l0), f32(l1), f32(l2)
		col := t.flat
		if t.iip {col = t.c[0] * f0 + t.c[1] * f1 + t.c[2] * f2}
		u, v: f32
		lod: i32
		// A fast context maps a texture when its row's tfx is one (px_pick).
		if TME && (FAST || t.tme) {
			u, v, lod = tex_at(t.tm,
				t.s[0] * f0 + t.s[1] * f1 + t.s[2] * f2,
				t.q[0] * f0 + t.q[1] * f1 + t.q[2] * f2)
		}
		// Pixel procs read fogf only under FGE (pixel, pixel_fast).
		fog: f32
		if FGE && (FAST || t.fge) {fog = t.fog[0] * f0 + t.fog[1] * f1 + t.fog[2] * f2}
		when FAST {
			px_shade_inst(c, x, zv, za, col, u, v, lod, fog, N)
		} else {
			c.px(c, x, y, z, col, u, v, lod, fog)
		}
	}
}

// --------------------------------------------------------------- texture

// One axis's wrap at level n as (lo, hi, mask, fix), for a level-0 size
// and CLAMP's MIN and MAX: REPEAT masks with the level's size, CLAMP and
// REGION_CLAMP clamp (the region scaled to the level), and REGION_REPEAT
// masks with MIN and sets MAX unscaled at every level. The clamp is
// max then min, as `clamp`, so a region with MIN > MAX gives MAX.
@(private)
wrap_axis :: proc(mode, size, lo, hi, n: u32) -> [4]i32 {
	switch mode {
	case 0: return {min(i32), max(i32), i32(max(size >> n, 1) - 1), 0}
	case 1: return {0, i32(max(size >> n, 1)) - 1, -1, 0}
	case 2: return {i32(lo >> n), i32(hi >> n), -1, 0}
	}
	return {min(i32), max(i32), i32(lo), i32(hi)}
}

// The texels [a, b] one axis's wrap (wrap_axis) reaches at level n: the
// level for REPEAT and CLAMP, MIN..MAX scaled for REGION_CLAMP (MAX alone
// when MIN > MAX), FIX..FIX | MASK for REGION_REPEAT.
@(private)
wrap_span :: proc(mode, size, lo, hi, n: u32) -> (a, b: u32) {
	switch mode {
	case 2: return min(lo >> n, hi >> n), hi >> n
	case 3: return hi, hi | lo
	}
	return 0, max(size >> n, 1) - 1
}

// Fills t.wrap for levels 0..mxl from WMS, WMT, the size and CLAMP.
@(private)
tex_wrap :: proc(t: ^Tex) {
	for n in u32(0) ..= t.mxl {
		a := wrap_axis(t.wms, t.w, t.minu, t.maxu, n)
		b := wrap_axis(t.wmt, t.h, t.minv, t.maxv, n)
		t.wrap[n] = {
			lo   = {a[0], a[0], b[0], b[0]},
			hi   = {a[1], a[1], b[1], b[1]},
			mask = {a[2], a[2], b[2], b[2]},
			fix  = {a[3], a[3], b[3], b[3]},
		}
	}
}

// Texel coordinates (x0, x1, y0, y1) wrapped by one level's Tex_Wrap.
@(private)
wrap :: #force_inline proc "contextless" (i: #simd[4]i32, w: ^Tex_Wrap) -> #simd[4]i32 {
	return (simd.min(simd.max(i, w.lo), w.hi) & w.mask) | w.fix
}

// Texel as RGBA8888 (R in the low byte).
@(private)
fetch :: proc(t: ^Tex, n, x, y: u32) -> u32 #no_bounds_check {
	raw := read_raw(t.psm, t.mtbp[n], t.mtbw[n], x, y)
	switch t.psm {
	case PSMCT32: return raw
	case PSMCT24:
		a := t.aem && raw == 0 ? 0 : t.ta0
		return raw | a << 24
	case PSMCT16, PSMCT16S: return expand16(t, raw)
	}
	e := t.tc.clut[(t.csa * 16 + raw) & 511]
	if t.cpsm == PSMCT32 {return e}
	return expand16(t, e & 0xffff)
}

// fetch, inlined for the formats a bypassed level samples most (a level
// the context also draws to, as render-to-texture feedback does): CT32 and
// T8. Every other format calls fetch.
@(private)
fetch_direct :: #force_inline proc(t: ^Tex, n, x, y: u32) -> u32 #no_bounds_check {
	switch t.psm {
	case PSMCT32: return vram[addr32(PSMCT32, t.mtbp[n], t.mtbw[n], x, y)]
	case PSMT8:
		e := t.tc.clut[(t.csa * 16 + u32(vram8()[addr8(t.mtbp[n], t.mtbw[n], x, y)])) & 511]
		if t.cpsm == PSMCT32 {return e}
		return expand16(t, e & 0xffff)
	}
	return fetch(t, n, x, y)
}

@(private)
expand16 :: #force_inline proc(t: ^Tex, c: u32) -> u32 {
	rgb := (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9
	a: u32
	if c & 0x8000 != 0 {
		a = t.ta1
	} else if !t.aem || c & 0x7fff != 0 {
		a = t.ta0
	}
	return rgb | a << 24
}

// The texel colour at level-0 texel coordinates (u, v) and level of
// detail `lod`: LOD <= 0 magnifies level 0 with MMAG, otherwise MMIN picks
// the filter and how levels 0..MXL are used. RGBA in lanes 0..3. Level 0
// is inlined into the pixel loop, which then saves no registers per pixel;
// the mipmap filters stay a call. A flat texture's pixels come with LOD 0
// (tex_map).
@(private)
sample :: #force_inline proc(t: ^Tex, u, v: f32, lod: i32) -> #simd[4]i32 {
	if lod <= 0 {return sample_level(t, 0, u, v, t.bilinear)}
	return sample_min(t, u, v, lod)
}

// `sample` for LOD > 0: MMIN's filter.
@(private)
sample_min :: proc(t: ^Tex, u, v: f32, lod: i32) -> #simd[4]i32 {
	bil := t.mmin == 1 || t.mmin >= 4
	switch t.mmin {
	case 2, 4: // MIPMAP_NEAREST: the nearest level
		n := min(u32((lod + 1 << 22) >> 23), t.mxl)
		return sample_level(t, n, u, v, bil)
	case 3, 5: // MIPMAP_LINEAR: between the two nearest levels
		n := min(u32(lod >> 23), t.mxl)
		c := sample_level(t, n, u, v, bil)
		if n == t.mxl {return c}
		f := (lod >> 15) & 0xff
		return c + div256((sample_level(t, n + 1, u, v, bil) - c) * #simd[4]i32{f, f, f, f})
	}
	return sample_level(t, 0, u, v, bil)
}

// 2^-n for level n: multiplying by it gives the same correctly rounded
// value as dividing by 2^n.
@(private, rodata)
level_scale := [7]f32{1, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625}

// A sample of level n, nearest or bilinear, through the texture cache. The
// two taps of each axis run as one vector (u, u, v, v) from the floor on.
// Inlined into `sample`, so the colour stays in a vector register.
@(private)
sample_level :: #force_inline proc(t: ^Tex, n: u32, tu, tv: f32, bilinear: bool) -> #simd[4]i32 #no_bounds_check {
	u, v := tu * level_scale[n], tv * level_scale[n]
	if !bilinear {
		xy := wrap(cast(#simd[4]i32)simd.floor(#simd[4]f32{u, u, v, v}), &t.wrap[n])
		return expand(texel(t, n, u32(simd.extract(xy, 0)), u32(simd.extract(xy, 2))))
	}
	// Round the 1/256 weights rather than truncate: the GPU's float
	// barycentrics land a hair under exact texel positions, and rounding on
	// both sides keeps the two renderers equal (shaders/prim.frag).
	// haz_taps (haz.odin) copies these taps: change both.
	UV_EPS :: 1.0 / 512
	u, v = u - 0.5 + UV_EPS, v - 0.5 + UV_EPS
	uv := #simd[4]f32{u, u, v, v}
	fl := simd.floor(uv)
	// Weights (au, au, av, av); taps (x0, x1, y0, y1).
	a := cast(#simd[4]i32)((uv - fl) * 256)
	xy := wrap(cast(#simd[4]i32)fl + {0, 1, 0, 1}, &t.wrap[n])
	x0, x1 := u32(simd.extract(xy, 0)), u32(simd.extract(xy, 1))
	y0, y1 := u32(simd.extract(xy, 2)), u32(simd.extract(xy, 3))
	// The four taps in one decoded tile (most of them): one tile lookup.
	// Tested on the wrapped coordinates, as wrap can split or join them.
	c00, c10, c01, c11: u32
	if p := x0 >> 4 == x1 >> 4 && y0 >> 4 == y1 >> 4 ? tile_at(t, n, x0, y0, max(x0, x1), max(y0, y1)) : nil; p != nil {
		r0, r1 := (y0 & 15) << 4, (y1 & 15) << 4
		c00, c10 = p[r0 | (x0 & 15)], p[r0 | (x1 & 15)]
		c01, c11 = p[r1 | (x0 & 15)], p[r1 | (x1 & 15)]
	} else if t.psm == PSMCT32 && t.tc.lvl[n] == TC_BYPASS && x0 >> 3 == x1 >> 3 && y0 >> 3 == y1 >> 3 {
		// A bypassed CT32 level (render-to-texture feedback) with the four
		// taps in one 8x8 block: one block address, four column offsets,
		// as addr32 computes each.
		blk := t.mtbp[n] + ((y0 >> 5) * t.mtbw[n] + (x0 >> 6)) * 32 + block32[(y0 >> 3) & 3][(x0 >> 3) & 7]
		base := blk << 6
		M :: VRAM_WORDS - 1
		r0, r1 := &col32[y0 & 7], &col32[y1 & 7]
		c00, c10 = vram[(base + r0[x0 & 7]) & M], vram[(base + r0[x1 & 7]) & M]
		c01, c11 = vram[(base + r1[x0 & 7]) & M], vram[(base + r1[x1 & 7]) & M]
	} else {
		c00, c10 = texel(t, n, x0, y0), texel(t, n, x1, y0)
		c01, c11 = texel(t, n, x0, y1), texel(t, n, x1, y1)
	}
	// Rows y0 and y1 in one vector of eight channels, then the two rows.
	w := cast(#simd[4]u16)a
	tb := lerp8(expand2(c00, c01), expand2(c10, c11), simd.swizzle(w, 0, 0, 0, 0, 0, 0, 0, 0))
	c := lerp8(simd.swizzle(tb, 0, 1, 2, 3, 0, 1, 2, 3), simd.swizzle(tb, 4, 5, 6, 7, 4, 5, 6, 7), simd.swizzle(w, 2, 2, 2, 2, 2, 2, 2, 2))
	return cast(#simd[4]i32)simd.swizzle(c, 0, 1, 2, 3)
}

// c0 + (c1 - c0) * w / 256 lane by lane, the quotient rounded toward 0 as
// div256 rounds it, for channels c0, c1 and weights w in 0..255: as
// (256 c0 + (c1 - c0) w + (c1 < c0 ? 255 : 0)) >> 8, whose true value lies
// in 0..65535, so 16-bit lanes wrapping on the way hold it exactly. Equal
// to the i32 form for all 2^24 inputs (checked exhaustively), at a 16-bit
// multiply where i32 lanes take pmulld. Bilinear weights come from a
// fraction in [0, 1), so lie in 0..255, except two edge cases. A fraction
// that rounds up to 1.0 gives 256: the true value 256 c1 + 255 at most
// still fits 16 bits, so the result is c1 exactly, as in the i32 form. A
// non-finite coordinate (Q = 0 in STQ) gives a NaN fraction, which the
// conversion turns into 0x80000000, whose low 16 bits are weight 0: the
// result is c0, a valid channel, where the i32 form wraps out of 0..255.
@(private)
lerp8 :: #force_inline proc "contextless" (c0, c1, w: #simd[8]u16) -> #simd[8]u16 {
	return simd.shr(simd.shl(c0, 8) + (c1 - c0) * w + (simd.lanes_lt(c1, c0) & 255), 8)
}

// Two RGBA8888 texels as eight 16-bit channels, a's in lanes 0..3.
@(private)
expand2 :: #force_inline proc "contextless" (a, b: u32) -> #simd[8]u16 {
	return cast(#simd[8]u16)transmute(#simd[8]u8)(u64(a) | u64(b) << 32)
}

// x / 256 lane by lane, rounded toward 0 as i32 division is: a negative x
// adds 255 before the arithmetic shift.
@(private)
div256 :: #force_inline proc "contextless" (x: #simd[4]i32) -> #simd[4]i32 {
	return simd.shr(x + (simd.shr(x, 31) & 255), 8)
}

// An RGBA8888 texel as its four channels, R in lane 0.
@(private)
expand :: #force_inline proc "contextless" (c: u32) -> #simd[4]i32 {
	return cast(#simd[4]i32)transmute(#simd[4]u8)c
}

@(private)
unpack :: #force_inline proc(c: u32) -> [4]i32 {
	return {i32(c & 0xff), i32((c >> 8) & 0xff), i32((c >> 16) & 0xff), i32(c >> 24)}
}

// ---------------------------------------------------------------- pixels

// An interpolated color to integers, all four lanes in one truncation
// (cvttps2dq, wasm's i32x4.trunc_sat_f32x4_s).
// The GS interpolates colors in fixed point, so equal vertex colors stay
// exact. Float barycentrics can land just below (128 -> 127.99999); the
// small bias keeps truncation from dropping a whole step, which breaks
// alpha tests against the vertex value.
@(private)
col_int :: #force_inline proc "contextless" (col: [4]f32) -> [4]i32 {
	COL_EPS :: 1.0 / 256
	v := transmute(#simd[4]f32)col + #simd[4]f32{COL_EPS, COL_EPS, COL_EPS, COL_EPS}
	return transmute([4]i32)cast(#simd[4]i32)v
}

@(private)
pixel :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) #no_bounds_check {
	px, py := u32(x), u32(y)
	src := col_int(col)

	if c.tme {
		t := transmute([4]i32)sample(&c.tex, u, v, lod)
		switch c.tex.tfx {
		case 0: // MODULATE
			for k in 0 ..< 3 {src[k] = min((t[k] * src[k]) >> 7, 255)}
			if c.tex.tcc {src.a = min((t.a * src.a) >> 7, 255)}
		case 1: // DECAL
			src.rgb = t.rgb
			if c.tex.tcc {src.a = t.a}
		case 2, 3: // HIGHLIGHT, HIGHLIGHT2
			for k in 0 ..< 3 {src[k] = min(((t[k] * src[k]) >> 7) + src.a, 255)}
			if c.tex.tcc {src.a = c.tex.tfx == 2 ? min(t.a + src.a, 255) : t.a}
		}
	}
	if c.fge {
		f := i32(fogf)
		for k in 0 ..< 3 {src[k] = (f * src[k] + (255 - f) * c.fogcol[k]) >> 8}
	}

	write_fb, write_z := true, !c.zmsk
	write_alpha := true
	if c.ate {
		a := u32(src.a)
		pass: bool
		switch c.atst {
		case 0: pass = false
		case 1: pass = true
		case 2: pass = a < c.aref
		case 3: pass = a <= c.aref
		case 4: pass = a == c.aref
		case 5: pass = a >= c.aref
		case 6: pass = a > c.aref
		case 7: pass = a != c.aref
		}
		if !pass {
			switch c.afail {
			case 0: return
			case 1: write_z = false
			case 2: write_fb = false
			case 3:
				write_z = false
				write_alpha = false
			}
		}
	}

	fb32 := c.fpsm == PSMCT32 || c.fpsm == PSMCT24 || c.fpsm == PSMZ32 || c.fpsm == PSMZ24
	// The frame pixel's index, taken once for the read and the write.
	fr := &c.frow
	fa: u32
	if fr.ok {
		row_seek(fr, c.fbp, c.fbw, py)
		fa = row_addr(fr, px)
	}
	dst_raw: u32
	if c.dst_read {
		dst_raw = fr.ok ? row_read(fr, fa) : read_raw(c.fpsm, c.fbp, c.fbw, px, py)
	}
	if c.date {
		bit := fb32 ? dst_raw & 0x80000000 != 0 : dst_raw & 0x8000 != 0
		if bit != c.datm {return}
	}

	z := u32(min(zf, 4294967295.0))
	if c.zte {
		zmax: u32 = 0xffffffff
		switch c.zpsm {
		case PSMZ24: zmax = 0xffffff
		case PSMZ16, PSMZ16S: zmax = 0xffff
		}
		z = min(z, zmax)
		zr := &c.zrow
		za: u32
		if zr.ok {
			row_seek(zr, c.zbp, c.fbw, py)
			za = row_addr(zr, px)
		}
		if c.z_read {
			dz := zr.ok ? row_read(zr, za) : read_raw(c.zpsm, c.zbp, c.fbw, px, py)
			switch c.ztst {
			case 2: if z < dz {return}
			case 3: if z <= dz {return}
			}
		}
		if write_z {
			if zr.ok {row_write(zr, za, z)} else {write_raw(c.zpsm, c.zbp, c.fbw, px, py, z)}
		}
	}
	if !write_fb {return}

	dst: [4]i32
	if fb32 {
		dst = unpack(dst_raw)
		if c.fpsm == PSMCT24 || c.fpsm == PSMZ24 {dst.a = 0x80}
	} else {
		dst = {i32(dst_raw & 0x1f) << 3, i32((dst_raw >> 5) & 0x1f) << 3, i32((dst_raw >> 10) & 0x1f) << 3, dst_raw & 0x8000 != 0 ? 0x80 : 0}
	}

	if c.abe && !(c.pabe && src.a < 0x80) {
		sel :: #force_inline proc(n: u32, s, d: [4]i32) -> [3]i32 {
			switch n {
			case 0: return s.rgb
			case 1: return d.rgb
			}
			return {}
		}
		ca := sel(c.a, src, dst)
		cb := sel(c.b, src, dst)
		cd := sel(c.d, src, dst)
		alpha: i32
		switch c.c {
		case 0: alpha = src.a
		case 1: alpha = dst.a
		case: alpha = i32(c.fix)
		}
		#no_bounds_check for k in 0 ..< 3 {src[k] = (((ca[k] - cb[k]) * alpha) >> 7) + cd[k]}
	}
	#no_bounds_check for k in 0 ..< 3 {
		src[k] = c.colclamp ? clamp(src[k], 0, 255) : src[k] & 0xff
	}
	if c.fba {src.a |= 0x80}
	if !write_alpha {src.a = dst.a}

	out: u32
	if fb32 {
		out = u32(src.r) | u32(src.g) << 8 | u32(src.b) << 16 | u32(src.a & 0xff) << 24
	} else {
		out = u32(src.r >> 3) | u32(src.g >> 3) << 5 | u32(src.b >> 3) << 10 | (src.a & 0x80 != 0 ? 0x8000 : 0)
		dst_raw &= 0xffff
	}
	msk := c.fbmsk
	if !fb32 {
		msk = (msk >> 3) & 0x1f | (msk >> 6) & 0x3e0 | (msk >> 9) & 0x7c00 | (msk >> 16) & 0x8000
	}
	v := (out &~ msk) | (dst_raw & msk)
	if fr.ok {row_write(fr, fa, v)} else {write_raw(c.fpsm, c.fbp, c.fbw, px, py, v)}
}
