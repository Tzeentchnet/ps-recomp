package ps2_ipu

// Test hook: colour conversion of one macroblock, for tests/ipu.
csc_probe :: proc(y: [16][16]u8, cb, cr: [8][8]u8, th0, th1: i32, sgn: bool) -> [256]u32 {
	ipu.mb8 = {y, cb, cr}
	ipu.th0, ipu.th1 = th0, th1
	ipu_csc(sgn)
	return ipu.rgb32
}
