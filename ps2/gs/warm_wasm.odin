#+build wasm32
package ps2_gs

import "base:runtime"

// The idle warm of the sprite row procs Okami first uses all at once (OKAMI-60
// STEP 18: its frame 254 runs them in Liftoff and queues nine TurboFan
// compiles of 4-7 ms each). The host calls gs_warm in its pace sleeps
// (web/play-worker.js) until it returns 0, so V8 has tiered them up before
// the game draws with them. TurboFan code belongs to the module, so the band
// Workers' instances run it too.
//
// A call draws an empty row (px1 < px0): it runs the proc's setup and
// returns without a pixel, so it reads and writes no VRAM, CLUT, texture
// cache or GS register, and the Ctx it gets can be all zeros (no texture
// filter: the nearest path, whose pixel loop runs no times).

// PX_FAST indices of the procs warmed, in the order Okami's frame 254
// compiles them.
@(private, rodata)
WARM_SPR := [?]int{102, 100, 106, 101, 22, 107, 65, 99, 64}

// Calls per proc. V8 tiers a Liftoff function up once it has spent
// --wasm-tiering-budget, 13,000,000 (a "rough approximation of bytes
// executed"). Each return spends the Liftoff code offset of the return plus
// 60 (liftoff-compiler.cc ReturnImpl and TierupCheck), and a backward
// branch its distance. These procs' Liftoff code is 19 KB each (Brave 157,
// --trace-wasm-compilation-times codesize 18800-19364), so 8192 empty
// calls spend the budget while the early return lies past byte 1587.
@(private)
WARM_CALLS :: 8192

// Calls made so far, over all of WARM_SPR in order.
@(private)
warm_done: int

// Makes up to n more warm calls and returns how many are left; 0 once
// every proc in WARM_SPR has had WARM_CALLS. Play thread only.
@(export, link_name = "gs_warm")
gs_warm :: proc "c" (n: i32) -> i32 {
	context = runtime.default_context()
	TOTAL :: len(WARM_SPR) * WARM_CALLS
	c: Ctx
	s := Sprite {
		x1  = 1,
		px0 = 1,
	}
	b := Vertex {
		q = 1,
	}
	end := min(warm_done + int(max(n, 0)), TOTAL)
	for ; warm_done < end; warm_done += 1 {
		spr_procs[WARM_SPR[warm_done / WARM_CALLS]](&c, &s, &b, 0, 0, 0)
	}
	return i32(TOTAL - warm_done)
}
