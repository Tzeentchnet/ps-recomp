// Banded software rasterisation: K worker threads each draw every
// primitive's rows y with (y >> 3) % K == their band, while the producer
// (the GS write path) decodes and queues primitives.
//
// One writer per local memory word: every frame and Z format (CT32/24/
// 16/16S, Z32/24/16/16S) has blocks 8 rows tall (8x8 for 32/24-bit, 16x8
// for 16-bit) and pages 32 or 64 rows tall, and FBP/ZBP are page-aligned,
// so each block covers rows 8k..8k+7 of its buffer. A word, and a 64-byte
// line (one column: 8x2 pixels at 32 bits, 16x2 at 16), lies in one
// 256-byte-aligned block, so in one band. That holds while (x, y) maps
// one-to-one to words under one buffer mapping (psm, bp, bw): a context
// whose scissor reaches past the buffer width, or wraps local memory,
// reaches one page from two cells and draws serially (band_ctx_new).
//
// Ordering between bands is kept by joins (every worker idle, its writes
// visible) at hazard edges, found with page sets, conservatively: a false
// positive costs a join, never a pixel.
// - A context that samples or reads a page it also writes, or whose frame
//   and Z pages meet, draws serially on the producer after a join.
// - A primitive joins first when its texture pages meet pages outstanding
//   jobs write (RAW), its written pages meet pages they read (WAR), or a
//   buffer mapping it uses meets pages an outstanding job reaches under
//   another mapping (alias: one word, two rows, two bands).
// - Transfers, CLUT loads, readback, scanout and snapshots join when they
//   touch outstanding pages (band_write, band_read, band_join).
//
// Workers allocate nothing and use no context.temp_allocator, fmt or
// @(thread_local) (package-level thread locals are not thread-local on
// wasm). Their asserts (tc_victim, tc_alloc) go through the runtime's
// default assertion_failure_proc, which prints without allocating and
// traps. A worker's thread is a core:thread thread, and on wasm a Worker
// of the host's pool running this module on the shared memory
// (band_wasm.odin).
package ps2_gs

import "base:intrinsics"
import "core:math/bits"
import "core:fmt"
import "core:sync"
import "ps:core"

BAND_MAX :: 16
@(private)
BAND_JOBS :: 1024
@(private)
BAND_CTXS :: 64
@(private)
BAND_CLUTS :: 16
@(private)
BAND_MAPS :: 8
// Job kinds past the primitive kinds (0..6).
@(private)
BAND_PAGES :: 8 // pages written outside the workers: they validate again
@(private)
BAND_FLUSH :: 9 // drop every cache entry (tc_flush)
// Idle spins before a thread sleeps on a futex.
@(private)
BAND_SPIN :: 4000

@(private)
Band_Job :: struct {
	kind:      u64,
	ctx, clut: u64, // snapshot sequence numbers
	using u:   struct #raw_union {
		v:     [3]Vertex,
		pages: Page_Set,
	},
}

@(private)
Band_Worker :: struct {
	tc:                Tc,
	ctx:               Ctx,
	clut:              [512]u32,
	clut_gen:          u64,
	ctx_seq, clut_seq: u64, // the snapshots ctx and clut hold
	id:                u32,
	th:                Band_Thread,
	_:                 [64]u8,
	done:              u64, // jobs finished (atomic, the worker's own line)
	_:                 [56]u8,
}

// A buffer mapping outstanding jobs reach, and the pages they reach with it.
@(private)
Band_Map :: struct {
	psm, bp, bw: u32,
	pages:       Page_Set,
}

@(private)
band: struct {
	n:            u32, // workers; 0 draws on the producer
	w:            [BAND_MAX]^Band_Worker,
	jobs:         [BAND_JOBS]Band_Job,
	ctxs:         [BAND_CTXS]Ctx,
	cluts:        [BAND_CLUTS][512]u32,
	// The job after the last each snapshot slot serves.
	ctx_last:     [BAND_CTXS]u64,
	clut_last:    [BAND_CLUTS]u64,
	pub:          u64, // jobs published (atomic)
	base:         u64, // pub at the last join
	low:          u64, // every worker has finished this many jobs
	nctx, nclut:  u64, // snapshots pushed
	clut_src:     u64, // the clut_gen the last CLUT snapshot copied
	ctx_dirty:    bool, // ctx_cur differs from the last snapshot
	// Since the last join: pages written, pages read, and mappings reached.
	wout, rout:   Page_Set,
	maps:         [BAND_MAPS]Band_Map,
	nmaps:        int,
	// Pages the producer wrote drawing serially, not yet sent to workers.
	spages:       Page_Set,
	spend:        bool,
	// The current context: drawn serially, its texture's pages, and its
	// frame and Z scissor pages.
	serial:       bool,
	cr:           Page_Set,
	wake:         sync.Futex, // bumped when a sleeping worker has work
	sleepers:     u32,
	pfut:         sync.Futex, // bumped when a worker finishes while the producer waits
	pwaiting:     u32,
	quit:         bool,
	registered:   bool,
	next:         u64, // jobs band_slot has handed out
}

// Primitives queued for the workers, primitives drawn serially, and joins
// by cause (tests/gs_band). Under the hazard tracker (haz.odin): batches
// ended, by cause, transfers hoisted, and snapshot and ordered primitives.
band_stats: struct {
	jobs, serial, raw, war, alias, xfer, read:                            u64,
	batches, haz_raw, haz_xfer, haz_read, haz_hoist, haz_snap, haz_ordered: u64,
}

// Test knobs (tests/gs_band). Lazy: publish jobs only when a join or a
// full ring needs them done, so workers fall far behind the producer.
// Skew: odd workers spin this long before each job, so they fall behind
// the even ones.
band_lazy: bool
band_skew: int

// Draw with n band workers; n <= 1 draws on the GS write path. Joins and
// stops the workers running first.
band_set :: proc(want: int) {
	band_stop()
	if want <= 1 {return}
	n := min(want, BAND_MAX)
	// Workers are host memory: the emulated heap is snapshotted.
	if core.host_allocator.procedure != nil {context.allocator = core.host_allocator}
	if !band.registered {
		append(&core.snap_quiesce, band_join)
		band.registered = true
	}
	band.n = u32(n)
	band.quit = false
	band.base, band.low, band.next = band.pub, band.pub, band.pub
	band.ctx_dirty = true
	band.clut_src = 0
	band.wout, band.rout, band.nmaps, band.spend = {}, {}, 0, false
	for i in 0 ..< n {
		w := new(Band_Worker)
		w.tc = {gen = 1, clut = &w.clut, clut_gen = &w.clut_gen, last_key = TC_NO_TILE}
		w.clut_gen = 1
		w.ctx_seq, w.clut_seq = max(u64), max(u64)
		w.id = u32(i)
		w.done = band.pub
		band.w[i] = w
	}
	for i in 0 ..< n {
		if band_spawn(band.w[i]) {continue}
		// No thread for this worker (on wasm: no pool, or fewer Workers
		// than asked): the ones started stop, and the producer draws.
		fmt.eprintfln("gs: BANDS=%d: worker %d has no thread, drawing on one", want, i)
		band.n = u32(i)
		band_stop()
		for j in i ..< n {
			free(band.w[j])
			band.w[j] = nil
		}
		return
	}
	band_ctx_new()
}

// Join and stop the workers.
@(private)
band_stop :: proc() {
	if band.n == 0 {return}
	band_join()
	intrinsics.atomic_store(&band.quit, true)
	intrinsics.atomic_add(&band.wake, 1)
	sync.futex_broadcast(&band.wake)
	if core.host_allocator.procedure != nil {context.allocator = core.host_allocator}
	for i in 0 ..< band.n {
		band_reap(band.w[i])
		free(band.w[i])
		band.w[i] = nil
	}
	band.n = 0
}

// Wait until every worker has finished jobs [0, seq).
@(private)
band_wait :: proc "contextless" (seq: u64) {
	if band.low >= seq {return}
	if band.pub != band.next {band_publish(true)}
	for i in 0 ..< band.n {
		w := band.w[i]
		for spin := 0; intrinsics.atomic_load(&w.done) < seq; spin += 1 {
			if spin < BAND_SPIN {
				intrinsics.cpu_relax()
				continue
			}
			intrinsics.atomic_store(&band.pwaiting, 1)
			v := intrinsics.atomic_load(&band.pfut)
			if intrinsics.atomic_load(&w.done) < seq {sync.futex_wait(&band.pfut, u32(v))}
		}
	}
	intrinsics.atomic_store(&band.pwaiting, 0)
	band.low = seq
}

// Every published job finished and its writes visible; nothing outstanding.
band_join :: proc() {
	if band.n == 0 || band.base == band.next {return}
	band_wait(band.next)
	band.base = band.next
	band.wout, band.rout, band.nmaps = {}, {}, 0
}

// The context changed (draw): its snapshot is pushed with its next job.
@(private)
band_ctx_new :: proc() {
	if band.n == 0 {return}
	band.ctx_dirty = true
	c := &ctx_cur
	band.cr = {}
	fw, zw: Page_Set
	x0, y0 := u32(max(c.sx0, 0)), u32(max(c.sy0, 0))
	x1, y1 := u32(max(c.sx1, 0)) + 1, u32(max(c.sy1, 0)) + 1
	ok := band_onto(c.fpsm, c.fbp, c.fbw, x0, y0, x1, y1, &fw)
	if c.zte && !band_onto(c.zpsm, c.zbp, c.fbw, x0, y0, x1, y1, &zw) {ok = false}
	if c.tme {
		t := &c.tex
		for n in 0 ..= min(t.mxl, 6) {
			// Region modes reach any texel under 1024; the others stay in the level.
			w := t.wms >= 2 ? 1024 : max(t.w >> n, 1)
			h := t.wmt >= 2 ? 1024 : max(t.h >> n, 1)
			page_rect(t.psm, t.mtbp[n], t.mtbw[n], 0, 0, w, h, &band.cr)
		}
	}
	band.serial = !ok || pages_meet(&band.cr, &fw) || pages_meet(&band.cr, &zw) || pages_meet(&fw, &zw)
}

// Adds the pages of [x0, x1) x [y0, y1) of a frame or Z buffer to out;
// false when two of its page cells are one page (past the buffer width,
// or wrapping local memory), where two rows share words.
@(private)
band_onto :: proc(psm, bp, bw, x0, y0, x1, y1: u32, out: ^Page_Set) -> bool {
	if x1 <= x0 || y1 <= y0 {return true}
	if x1 > 2048 || y1 > 2048 {return false}
	page_rect(psm, bp, bw, x0, y0, x1, y1, out)
	pw, ph, _ := page_geom(psm, bw)
	cells := ((x1 - 1) / pw - x0 / pw + 1) * ((y1 - 1) / ph - y0 / ph + 1)
	n: u32
	for w in out {n += u32(bits.count_ones(w))}
	return n == cells
}

// Queue primitive `kind` of the vertex queue in context c.
@(private)
band_draw :: proc(c: ^Ctx, kind: u64) #no_bounds_check {
	fp, zp: Page_Set
	x0, y0, x1, y1, any := prim_rect(c, kind, &queue)
	if any {
		page_rect(c.fpsm, c.fbp, c.fbw, x0, y0, x1, y1, &fp)
		if c.zte {page_rect(c.zpsm, c.zbp, c.fbw, x0, y0, x1, y1, &zp)}
	}
	zwrite := c.zte && !c.zmsk
	wp := fp
	if zwrite {for &w, i in wp {w |= zp[i]}}
	for w, i in wp {tc_main.pending[i] |= w}
	if band.serial || px_force != nil {
		band_stats.serial += 1
		band_join()
		for w, i in wp {band.spages[i] |= w}
		band.spend = true
		raster(c, kind, &queue)
		return
	}
	if band.base != band.next {
		if pages_meet(&band.cr, &band.wout) {
			band_stats.raw += 1
			band_join()
		} else if pages_meet(&wp, &band.rout) {
			band_stats.war += 1
			band_join()
		} else if any && (band_alias(c.fpsm, c.fbp, c.fbw, &fp) || c.zte && band_alias(c.zpsm, c.zbp, c.fbw, &zp)) {
			band_stats.alias += 1
			band_join()
		}
	}
	if any {
		band_map(c.fpsm, c.fbp, c.fbw, &fp)
		if c.zte {band_map(c.zpsm, c.zbp, c.fbw, &zp)}
	}
	for w, i in band.cr {band.rout[i] |= w}
	if c.zte && !zwrite {for w, i in zp {band.rout[i] |= w}}
	for w, i in wp {band.wout[i] |= w}
	if band.spend {
		j := band_slot(BAND_PAGES)
		j.pages = band.spages
		band.spages, band.spend = {}, false
	}
	band_stats.jobs += 1
	j := band_slot(kind)
	j.v = queue
	band_publish()
}

// Whether a buffer mapping meets pages an outstanding job reaches under
// another mapping, or the mapping table lacks room for a primitive's two.
@(private)
band_alias :: proc(psm, bp, bw: u32, p: ^Page_Set) -> bool {
	same := false
	for &m in band.maps[:band.nmaps] {
		if m.psm == psm && m.bp == bp && m.bw == bw {
			same = true
		} else if pages_meet(&m.pages, p) {return true}
	}
	return !same && band.nmaps >= BAND_MAPS - 1
}

@(private)
band_map :: proc(psm, bp, bw: u32, p: ^Page_Set) {
	for &m in band.maps[:band.nmaps] {
		if m.psm == psm && m.bp == bp && m.bw == bw {
			for w, i in p {m.pages[i] |= w}
			return
		}
	}
	band.maps[band.nmaps] = {psm, bp, bw, p^}
	band.nmaps += 1
}

// The next job, its context and CLUT snapshots pushed when they changed.
// band_publish hands it to the workers.
@(private)
band_slot :: proc(kind: u64) -> ^Band_Job #no_bounds_check {
	seq := band.next
	if seq >= BAND_JOBS {band_wait(seq - BAND_JOBS + 1)}
	if band.ctx_dirty {
		band_wait(band.ctx_last[band.nctx % BAND_CTXS])
		band.ctxs[band.nctx % BAND_CTXS] = ctx_cur
		band.nctx += 1
		band.ctx_dirty = false
	}
	if band.clut_src != clut_gen {
		band_wait(band.clut_last[band.nclut % BAND_CLUTS])
		band.cluts[band.nclut % BAND_CLUTS] = clut
		band.nclut += 1
		band.clut_src = clut_gen
	}
	cs, ls := band.nctx - 1, band.nclut - 1
	band.ctx_last[cs % BAND_CTXS] = seq + 1
	band.clut_last[ls % BAND_CLUTS] = seq + 1
	band.next = seq + 1
	j := &band.jobs[seq % BAND_JOBS]
	j.kind, j.ctx, j.clut = kind, cs, ls
	return j
}

// Hand the jobs band_slot filled to the workers, waking sleeping ones.
@(private)
band_publish :: proc "contextless" (force := false) {
	if band_lazy && !force {return}
	intrinsics.atomic_store(&band.pub, band.next)
	if intrinsics.atomic_load(&band.sleepers) > 0 {
		intrinsics.atomic_add(&band.wake, 1)
		sync.futex_broadcast(&band.wake)
	}
}

// A transfer about to write pages p (tc_write_rect): joins when
// outstanding jobs reach them, then tells the workers' caches.
@(private)
band_write :: proc(p: ^Page_Set) {
	if band.base != band.next && (pages_meet(p, &band.wout) || pages_meet(p, &band.rout)) {
		band_stats.xfer += 1
		band_join()
	}
	j := band_slot(BAND_PAGES)
	j.pages = p^
	band_publish()
}

// About to read [x, x + w) x [y, y + h) of a buffer from the producer:
// joins when outstanding jobs write its pages.
@(private)
band_read :: proc(psm, bp, bw, x, y, w, h: u32) {
	if haz_on {haz_read(psm, bp, bw, x, y, w, h)}
	if band.n == 0 || band.base == band.next {return}
	p: Page_Set
	page_rect(psm, bp, bw, x, y, x + w, y + h, &p)
	if pages_meet(&p, &band.wout) {
		band_stats.read += 1
		band_join()
	}
}

// About to read blocks [b0, b1) from the producer (a CSM1 CLUT).
@(private)
band_read_blocks :: proc(b0, b1: u32) {
	if haz_on {haz_read_blocks(b0, b1)}
	if band.n == 0 || band.base == band.next {return}
	p: Page_Set
	for b in b0 ..< b1 {
		pg := (b >> 5) % PAGES
		p[pg / 64] |= 1 << (pg % 64)
	}
	if pages_meet(&p, &band.wout) {
		band_stats.read += 1
		band_join()
	}
}

// Every cache entry dropped (tc_flush): the workers' too, and the context
// and CLUT go to them again.
@(private)
band_flush :: proc() {
	if band.n == 0 {return}
	band_join()
	band_slot(BAND_FLUSH)
	band_publish()
	band.clut_src = 0
	band_ctx_new()
}

// A worker: runs every published job, drawing its band's rows.
@(private)
band_run :: proc(w: ^Band_Worker) {
	for {
		p := intrinsics.atomic_load(&band.pub)
		if w.done == p {
			if intrinsics.atomic_load(&band.quit) {return}
			band_idle(w)
			continue
		}
		for s in w.done ..< p {
			if w.id & 1 != 0 {for _ in 0 ..< band_skew {intrinsics.cpu_relax()}}
			band_job(w, &band.jobs[s % BAND_JOBS])
		}
		intrinsics.atomic_store(&w.done, p)
		if intrinsics.atomic_load(&band.pwaiting) != 0 {
			intrinsics.atomic_add(&band.pfut, 1)
			sync.futex_broadcast(&band.pfut)
		}
	}
}

// Spin, then sleep until the producer publishes or quits.
@(private)
band_idle :: proc "contextless" (w: ^Band_Worker) {
	for _ in 0 ..< BAND_SPIN {
		if intrinsics.atomic_load(&band.pub) != w.done {return}
		intrinsics.cpu_relax()
	}
	intrinsics.atomic_add(&band.sleepers, 1)
	v := intrinsics.atomic_load(&band.wake)
	if intrinsics.atomic_load(&band.pub) == w.done && !intrinsics.atomic_load(&band.quit) {
		sync.futex_wait(&band.wake, u32(v))
	}
	intrinsics.atomic_sub(&band.sleepers, 1)
}

@(private)
band_job :: proc(w: ^Band_Worker, j: ^Band_Job) #no_bounds_check {
	switch j.kind {
	case BAND_PAGES:
		tc := &w.tc
		for p, i in j.pages {tc.pending[i] |= p}
		for &l in tc.lvl {if l >= 0 {l = TC_UNRESOLVED}}
		tc.last_key = TC_NO_TILE
	case BAND_FLUSH:
		tc_drop_all(&w.tc)
	case:
		if j.ctx != w.ctx_seq {
			w.ctx = band.ctxs[j.ctx % BAND_CTXS]
			w.ctx.tex.tc = &w.tc
			w.ctx.band, w.ctx.nband = w.id, band.n
			w.ctx_seq = j.ctx
			tc_ctx(&w.tc, &w.ctx)
		}
		if j.clut != w.clut_seq {
			w.clut = band.cluts[j.clut % BAND_CLUTS]
			w.clut_gen += 1
			w.clut_seq = j.clut
		}
		tc_draw(&w.tc, &w.ctx, j.kind, &j.v)
		raster(&w.ctx, j.kind, &j.v)
	}
}
