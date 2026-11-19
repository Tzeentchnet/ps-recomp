// Specialised pixel procs: `pixel` with the context's texture function,
// depth test, blend and formats fixed at compile time, for the contexts
// that draw most pixels. decode_ctx picks one per Ctx (px_pick); every
// other context takes the generic `pixel`.
//
// A fast proc covers a context with no PABE, no FBA, COLCLAMP on, and a
// frame format with rows (row_init), and a Z format with rows where it
// reads or writes Z. It takes the rows already at y: the
// rasteriser seeks them once per row (ctx_seek), where `pixel` seeks them
// itself.
package ps2_gs

import "core:simd"

@(private)
Pixel_Proc :: #type proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32)

// One fast context. tfx is -1 for no texture mapping; bl is ALPHA's
// A, B, C and D (its low byte), 0xff for no blending; fbmsk is FBMSK != 0;
// atst is TEST's ATST, tested against the context's AREF, and afail its
// AFAIL (0 KEEP, 1 FB_ONLY, 2 ZB_ONLY, 3 RGB_ONLY); no alpha test, or ATST ALWAYS, is
// atst 1 with afail 0. fge is PRIM's FGE; date is 0 for no destination
// alpha test, 1 for DATM 0, 2 for DATM 1. A context that neither reads nor
// writes Z (the depth test off, or ZTST ALWAYS with ZMSK) is ztst 1 with
// zmsk, and its zpsm is not compared (px_pick).
Px_Fast :: struct {
	tfx:   i32,
	tcc:   bool,
	ztst:  u32,
	zmsk:  bool,
	zpsm:  u32,
	bl:    u32,
	fpsm:  u32,
	fbmsk: bool,
	atst:  u32,
	afail: u32,
	fge:   bool,
	date:  u32,
}

// The contexts, by the pixels each drew in a profiled title (SHOT-PERF F):
// 99.5% of its pixels between them. Then the generic contexts drawing
// most pixels in three more titles (gh, sp, then bk), by a pixel tally.
// Then the generic contexts drawing most pixels of two more titles' scenes
// (SWGS-PX-1): seven of one, eight of the other, and the first's
// destination alpha test. The last nine cover another title's full-screen
// menu layers and star field. The last four are another title's scene
// passes, 99.3 % of its generic pixels (SWGS-PX-2): a Z-only pass (ATST
// NEVER to ZB_ONLY), two frame-only passes (ATST NEVER to FB_ONLY) and a
// CT24 textured layer. The rest are the generic contexts drawing most
// pixels over 30 s of each of seven more titles (SWGS-PX-3). The last
// nineteen are the generic contexts drawing 93 % of another title's
// generic pixels over its menus, a race and its replay (SWGS-PX-4).
PX_FAST :: [?]Px_Fast {
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x68, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x29, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ16S, bl = 0x48, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 3, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 1, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ32, bl = 0xff, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x64, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 2},
	{tfx = 1, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x64, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x48, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x58, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ32, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 2, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 7, afail = 1, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ32, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 7, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 7, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 3, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 3, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 3, zmsk = false, zpsm = PSMZ32, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 2, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 1, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x00, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x48, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 3, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 3, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 3, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 7, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 7, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x00, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 0, fge = true, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x49, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x62, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = true, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 2, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT24, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT24, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT24, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = true, atst = 7, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x58, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0xa9, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x68, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 3, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x64, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT24, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x64, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x64, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT24, fbmsk = true, atst = 1, afail = 0, fge = true, date = 0},
}

// PX_FAST's procs, in its order.
@(private, rodata)
px_procs := [len(PX_FAST)]Pixel_Proc {
	px_0, px_1, px_2, px_3, px_4, px_5, px_6, px_7, px_8, px_9, px_10, px_11, px_12, px_13, px_14, px_15, px_16,
	px_17, px_18, px_19, px_20, px_21, px_22, px_23, px_24, px_25, px_26, px_27, px_28, px_29, px_30, px_31,
	px_32, px_33, px_34, px_35, px_36, px_37, px_38, px_39, px_40, px_41, px_42, px_43, px_44,
	px_45, px_46, px_47, px_48, px_49, px_50, px_51, px_52, px_53, px_54, px_55, px_56, px_57, px_58, px_59, px_60, px_61, px_62, px_63, px_64, px_65,
	px_66, px_67, px_68, px_69, px_70, px_71, px_72, px_73, px_74, px_75, px_76, px_77, px_78, px_79, px_80, px_81, px_82, px_83, px_84,
}

@(private)
px_0 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 0)}
@(private)
px_1 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 1)}
@(private)
px_2 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 2)}
@(private)
px_3 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 3)}
@(private)
px_4 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 4)}
@(private)
px_5 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 5)}
@(private)
px_6 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 6)}
@(private)
px_7 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 7)}

@(private)
px_8 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 8)}
@(private)
px_9 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 9)}
@(private)
px_10 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 10)}
@(private)
px_11 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 11)}
@(private)
px_12 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 12)}
@(private)
px_13 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 13)}
@(private)
px_14 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 14)}
@(private)
px_15 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 15)}
@(private)
px_16 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 16)}
@(private)
px_17 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 17)}
@(private)
px_18 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 18)}
@(private)
px_19 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 19)}
@(private)
px_20 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 20)}
@(private)
px_21 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 21)}
@(private)
px_22 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 22)}
@(private)
px_23 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 23)}
@(private)
px_24 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 24)}
@(private)
px_25 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 25)}
@(private)
px_26 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 26)}
@(private)
px_27 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 27)}
@(private)
px_28 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 28)}
@(private)
px_29 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 29)}
@(private)
px_30 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 30)}
@(private)
px_31 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 31)}
@(private)
px_32 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 32)}
@(private)
px_33 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 33)}
@(private)
px_34 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 34)}
@(private)
px_35 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 35)}
@(private)
px_36 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 36)}
@(private)
px_37 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 37)}
@(private)
px_38 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 38)}
@(private)
px_39 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 39)}
@(private)
px_40 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 40)}

@(private)
px_41 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 41)}
@(private)
px_42 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 42)}
@(private)
px_43 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 43)}
@(private)
px_44 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 44)}

@(private)
px_45 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 45)}
@(private)
px_46 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 46)}
@(private)
px_47 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 47)}
@(private)
px_48 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 48)}
@(private)
px_49 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 49)}
@(private)
px_50 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 50)}
@(private)
px_51 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 51)}
@(private)
px_52 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 52)}
@(private)
px_53 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 53)}
@(private)
px_54 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 54)}
@(private)
px_55 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 55)}
@(private)
px_56 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 56)}
@(private)
px_57 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 57)}
@(private)
px_58 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 58)}
@(private)
px_59 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 59)}
@(private)
px_60 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 60)}
@(private)
px_61 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 61)}
@(private)
px_62 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 62)}
@(private)
px_63 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 63)}
@(private)
px_64 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 64)}
@(private)
px_65 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 65)}
@(private)
px_66 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 66)}
@(private)
px_67 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 67)}
@(private)
px_68 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 68)}
@(private)
px_69 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 69)}
@(private)
px_70 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 70)}
@(private)
px_71 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 71)}
@(private)
px_72 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 72)}
@(private)
px_73 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 73)}
@(private)
px_74 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 74)}
@(private)
px_75 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 75)}
@(private)
px_76 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 76)}
@(private)
px_77 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 77)}
@(private)
px_78 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 78)}
@(private)
px_79 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 79)}
@(private)
px_80 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 80)}
@(private)
px_81 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 81)}
@(private)
px_82 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 82)}
@(private)
px_83 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 83)}
@(private)
px_84 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 84)}

@(private)
px_inst :: #force_inline proc(c: ^Ctx, x: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32, $N: int) {
	F :: PX_FAST
	pixel_fast(c, x, zf, col, u, v, lod, fogf,
		F[N].tfx, F[N].tcc, F[N].ztst, F[N].zmsk, F[N].zpsm, F[N].bl, F[N].fpsm, F[N].fbmsk, F[N].atst, F[N].afail, F[N].fge, F[N].date)
}

// The pixel proc of every context decoded from now on, when not nil: the
// generic `pixel`, or one that tallies (probe_generic, probe_tally).
@(private)
px_force: Pixel_Proc

// The pixel proc for a decoded context: a fast one when the context is one
// of PX_FAST's, else `pixel`.
@(private)
px_pick :: proc(c: ^Ctx) -> Pixel_Proc {
	if px_force != nil {return px_force}
	if c.pabe || c.fba || !c.colclamp {return pixel}
	// No Z read or write: `pixel` skips Z with the depth test off, as a
	// fast proc does for ZTST ALWAYS with ZMSK.
	z_off := !c.zte || (c.ztst == 1 && c.zmsk)
	if !c.frow.ok || (!z_off && !c.zrow.ok) {return pixel}
	atst, afail: u32 = 1, 0
	if c.ate && c.atst != 1 {
		atst, afail = c.atst, c.afail
	}
	k := Px_Fast {
		tfx   = c.tme ? i32(c.tex.tfx) : -1,
		tcc   = c.tme && c.tex.tcc,
		ztst  = z_off ? 1 : c.ztst,
		zmsk  = z_off || c.zmsk,
		zpsm  = z_off ? 0 : c.zpsm,
		bl    = c.abe ? c.a | c.b << 2 | c.c << 4 | c.d << 6 : 0xff,
		fpsm  = c.fpsm,
		fbmsk = c.fbmsk != 0,
		atst  = atst,
		afail = afail,
		fge   = c.fge,
		date  = c.date ? (c.datm ? 2 : 1) : 0,
	}
	for f, i in PX_FAST {
		g := f
		if g.ztst == 1 && g.zmsk {g.zpsm = 0}
		if g == k {return px_procs[i]}
	}
	return pixel
}

// Seeks the context's frame and Z rows to y, for the pixels of one row.
@(private)
ctx_seek :: #force_inline proc(c: ^Ctx, y: i32) {
	if c.frow.ok {row_seek(&c.frow, c.fbp, c.fbw, u32(y))}
	if c.zrow.ok {row_seek(&c.zrow, c.zbp, c.fbw, u32(y))}
}

// TEST's alpha test ATST of alpha a against AREF.
@(private)
px_atst :: #force_inline proc "contextless" ($ATST: u32, a, aref: u32) -> bool {
	when ATST == 0 {
		return false
	} else when ATST == 1 {
		return true
	} else when ATST == 2 {
		return a < aref
	} else when ATST == 3 {
		return a <= aref
	} else when ATST == 4 {
		return a == aref
	} else when ATST == 5 {
		return a >= aref
	} else when ATST == 6 {
		return a > aref
	} else {
		return a != aref
	}
}

// `pixel` for one PX_FAST context, its steps in the same order: the frame
// pixel is read before the Z buffer is written, as the two can overlap.
@(private)
pixel_fast :: #force_inline proc(c: ^Ctx, x: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32,
	$TFX: i32, $TCC: bool, $ZTST: u32, $ZMSK: bool, $ZPSM: u32, $BL: u32, $FPSM: u32, $FBMSK: bool,
	$ATST: u32, $AFAIL: u32, $FGE: bool, $DATE: u32) #no_bounds_check {
	#assert(FPSM == PSMCT32 || FPSM == PSMCT24)
	#assert(ZTST >= 1)
	#assert(ATST <= 7 && AFAIL <= 3)
	#assert(ATST != 1 || AFAIL == 0)
	#assert(DATE <= 2)
	px := u32(x)
	when ZMSK && ZTST >= 2 {
		ZWIDE :: ZPSM == PSMZ32 || ZPSM == PSMZ24
		ZMAX :: 0xffffffff when ZPSM == PSMZ32 else 0xffffff when ZPSM == PSMZ24 else 0xffff
		z := min(u32(min(zf, 4294967295.0)), u32(ZMAX))
		za := row_addr_w(&c.zrow, px, ZWIDE)
		when ZTST == 2 {
			if z < row_read_w(&c.zrow, za, ZWIDE) {return}
		} else {
			if z <= row_read_w(&c.zrow, za, ZWIDE) {return}
		}
	}
	// The color steps run on all four channels at once, each lane with the
	// integer operations `pixel` does on that channel: RGB selects lanes
	// 0..2, alpha is lane 3.
	RGB :: #simd[4]bool{true, true, true, false}
	B255 :: #simd[4]i32{255, 255, 255, 255}
	src := col_int(col)
	when TFX == 0 { // MODULATE
		sm := transmute(#simd[4]i32)src
		m := simd.min(simd.shr(sample(&c.tex, u, v, lod) * sm, 7), B255)
		src = transmute([4]i32)simd.select(#simd[4]bool{true, true, true, TCC}, m, sm)
	} else when TFX == 1 { // DECAL
		t := transmute([4]i32)sample(&c.tex, u, v, lod)
		src.rgb = t.rgb
		when TCC {src.a = t.a}
	} else {
		#assert(TFX == -1)
	}
	when FGE {
		f := i32(fogf)
		for k in 0 ..< 3 {src[k] = (f * src[k] + (255 - f) * c.fogcol[k]) >> 8}
	}

	A :: BL & 3
	B :: (BL >> 2) & 3
	C :: (BL >> 4) & 3
	D :: (BL >> 6) & 3
	BLEND :: BL != 0xff
	// A pixel failing the alpha test: KEEP writes neither frame nor Z,
	// FB_ONLY and RGB_ONLY no Z, ZB_ONLY no frame, and RGB_ONLY keeps the
	// frame's alpha. `pass` exists only where one of these reads it.
	ZWRITE :: !ZMSK && !(ATST == 0 && (AFAIL == 1 || AFAIL == 3)) // ATST NEVER always fails
	FAIL_Z :: ATST != 1 && (AFAIL == 1 || AFAIL == 3) && ZWRITE
	FAIL_F :: ATST != 1 && AFAIL == 2
	FAIL_A :: ATST != 1 && AFAIL == 3
	when ATST != 1 && (AFAIL == 0 || FAIL_Z || FAIL_F || FAIL_A) {
		pass := px_atst(ATST, u32(src.a), c.aref)
		when AFAIL == 0 {if !pass {return}}
	}

	UNPACK :: FAIL_A || (BLEND && (A == 1 || B == 1 || C == 1 || D == 1))
	DST :: FBMSK || DATE != 0 || UNPACK
	fa := row_addr_w(&c.frow, px, true)
	when DST {dst_raw := row_read_w(&c.frow, fa, true)} // `when` opens no scope
	when DATE != 0 {if (dst_raw & 0x80000000 != 0) != (DATE == 2) {return}}

	when !(ZMSK && ZTST >= 2) && (ZTST >= 2 || ZWRITE) {
		ZWIDE :: ZPSM == PSMZ32 || ZPSM == PSMZ24
		ZMAX :: 0xffffffff when ZPSM == PSMZ32 else 0xffffff when ZPSM == PSMZ24 else 0xffff
		z := min(u32(min(zf, 4294967295.0)), u32(ZMAX))
		za := row_addr_w(&c.zrow, px, ZWIDE)
		when ZTST == 2 {
			if z < row_read_w(&c.zrow, za, ZWIDE) {return}
		} else when ZTST == 3 {
			if z <= row_read_w(&c.zrow, za, ZWIDE) {return}
		}
		when FAIL_Z {
			if pass {row_write_w(&c.zrow, za, z, ZWIDE)}
		} else when ZWRITE {
			row_write_w(&c.zrow, za, z, ZWIDE)
		}
	}
	when FAIL_F {if !pass {return}}

	when UNPACK {
		dst := expand(dst_raw)
		when FPSM == PSMCT24 {dst = simd.replace(dst, 3, 0x80)}
	} else when BLEND {
		dst: #simd[4]i32 // not read
	}
	s := transmute(#simd[4]i32)src
	when BLEND {
		sel :: #force_inline proc($N: u32, s, d: #simd[4]i32) -> #simd[4]i32 {
			when N == 0 {return s} else when N == 1 {return d} else {return {}}
		}
		alpha: i32
		when C == 0 {
			alpha = src.a
		} else when C == 1 {
			alpha = simd.extract(dst, 3)
		} else {
			alpha = i32(c.fix)
		}
		ca, cb, cd := sel(A, s, dst), sel(B, s, dst), sel(D, s, dst)
		rgb := simd.shr((ca - cb) * #simd[4]i32{alpha, alpha, alpha, alpha}, 7) + cd
	} else {
		rgb := s
	}
	a := s
	when FAIL_A {if !pass {a = dst}}
	// RGB clamped to 0..255, alpha its low byte: each lane one byte of
	// the stored word.
	o := simd.select(RGB, simd.clamp(rgb, #simd[4]i32{}, B255), a & B255)
	out := transmute(u32)simd.swizzle(transmute(#simd[16]u8)o, 0, 4, 8, 12)
	when FBMSK {out = (out &~ c.fbmsk) | (dst_raw & c.fbmsk)}
	row_write_w(&c.frow, fa, out, true)
}
