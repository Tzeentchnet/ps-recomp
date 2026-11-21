// The VIFs: DMA'd command streams unpacked into VU memory, with VIF1
// starting VU1 microprograms and passing packets on to the GIF.
package ps2_vu

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import gif "../gif"
import mem "../mem"

Vif :: struct {
	id:          int,
	vu:          ^Vu,
	cl, wl:      u32,
	mode, mask:  u32,
	row, col:    [4]u32,
	base, ofst:  u32,
	tops, top:   u32,
	itops, itop: u32,
	dbf:         bool,
	// Stalled by a code's i-bit until FBRST.STC (vif_fbrst).
	stalled:     bool,
	// VIF1 stalled on a DIRECT until the GIF is free (vif1_gif_resume).
	gif_wait:    bool,
	// Words the VIF holds outside guest memory, run ahead of the next span:
	// the rest of the quadword a DMA stall stopped in (at most 3 words), a
	// command split across spans, and what FIFO writes and the MFIFO drain
	// hand over while it is stalled. Empty in the steady state: DMA spans
	// run in place from guest RAM (vif_span).
	hold:        [dynamic]u8,
}

// The VIFs' registers, VIF1's 0x400 after VIF0's.
VIF0_STAT :: 0x3800
VIF0_ERR :: 0x3820
VIF0_CODE :: 0x3880 // the VIFcode most recently processed, read-only
VIF_FBRST :: 0x10 // from STAT
VIF_STAT_VIS :: 0x400 // stalled by an i-bit
VIF_STAT_INT :: 0x800 // an i-bit's interrupt
VIF_STAT_STALL :: 0x3f00 // VSS, VFS, VIS, INT, ER0, ER1: what STC clears
VIF_ERR_MII :: 1 // i-bits raise no interrupt and stall nothing

vifs: [2]Vif

// The DMA side of a stall (dma.vif_dma): a channel a VIF stalled keeps STR
// set with its registers at the first quadword not taken. Called with
// reset false once the VIF runs again (STC, or the GIF free for a DIRECT),
// to walk the channel on from its registers; with reset true on FBRST.RST.
vif_dma_hook: proc(id: int, reset: bool)

// Spans whose last command ran from hold after more than its code word was
// copied there: the slow path vif_span avoids for a code alone.
vif_hold_copies: u64

vif_init :: proc() {
	vifs[0] = {id = 0, vu = &vu0, cl = 1, wl = 1}
	vifs[1] = {id = 1, vu = &vu1, cl = 1, wl = 1}
	gif.gif_init(vif1_gif_resume)
}

// The GIF is free for the DIRECT VIF1 stalled on: run on unless an i-bit
// stall still holds it.
@(private)
vif1_gif_resume :: proc() {
	v := &vifs[1]
	v.gif_wait = false
	if !v.stalled {vif_resume(v)}
}

// Run what the VIF holds; once it has all run, the stalled channel walks on.
@(private)
vif_resume :: proc(v: ^Vif) {
	vif_feed(v, nil)
	if !vif_busy(v) && vif_dma_hook != nil {vif_dma_hook(v.id, false)}
}

// Stalled on an i-bit or waiting for the GIF: nothing runs.
vif_busy :: #force_inline proc(v: ^Vif) -> bool {return v.stalled || v.gif_wait}

@(private)
vif_warned: map[u32]bool

// Feed words to a VIF that cannot be held back: a FIFO write, an MFIFO
// drain, a test. What does not run, at a stall or as an incomplete last
// command, waits in hold.
vif_feed :: proc(v: ^Vif, data: []u8) {
	n := vif_span(v, data)
	if n < len(data) {append(&v.hold, ..data[n:])}
}

// Run a span of guest words in place, after what the VIF holds; returns the
// bytes taken. Short of len(data) only when the VIF stalled (vif_busy), and
// then at the first word not run. An incomplete last command is taken into
// hold, to finish with the next span. len(data) is a multiple of 4.
vif_span :: proc(v: ^Vif, data: []u8) -> int {
	if vif_busy(v) {return 0}
	t := cpu.prof_start()
	defer cpu.prof_end(.VIF, t)
	off := 0
	if len(v.hold) != 0 {
		off = vif_hold_run(v, data)
		if len(v.hold) != 0 || vif_busy(v) {return off}
	}
	rest := data[off:]
	used := vif_run(v, ([^]u32)(raw_data(rest))[:len(rest) / 4]) * 4
	if used < len(rest) && !vif_busy(v) {
		append(&v.hold, ..rest[used:])
		used = len(rest)
	}
	return off + used
}

// Run hold's whole commands, then finish its incomplete last one with the
// head of data; returns the bytes of data taken. A code held alone runs with
// its arguments read in place from data; a command split after its code is
// copied whole into hold (vif_hold_copies). Hold is left with words only
// when the VIF stalled or data was too short (then all of data is taken).
@(private)
vif_hold_run :: proc(v: ^Vif, data: []u8) -> int {
	ran := vif_run(v, ([^]u32)(raw_data(v.hold))[:len(v.hold) / 4])
	remove_range(&v.hold, 0, ran * 4)
	if len(v.hold) == 0 || vif_busy(v) {return 0}
	code := (^u32)(raw_data(v.hold))^
	have := len(v.hold) / 4
	take := (vif_need(v, code) - have) * 4
	if take > len(data) {
		append(&v.hold, ..data)
		return len(data)
	}
	if have == 1 {
		if !vif_cmd(v, code, ([^]u32)(raw_data(data))[:take / 4]) {return 0} // a DIRECT waits for the GIF
		clear(&v.hold)
		return take
	}
	append(&v.hold, ..data[:take])
	vif_hold_copies += 1
	// A DIRECT that waits for the GIF stays in hold, whole: data is taken.
	ran = vif_run(v, ([^]u32)(raw_data(v.hold))[:len(v.hold) / 4])
	remove_range(&v.hold, 0, ran * 4)
	return take
}

// Execute VIF codes; returns the words consumed. No bounds checks: i stays
// below len(w), a code runs only when its `need` words are all in w, arg
// holds the need - 1 after the code (DIRECT and MPG always have one, MASK
// one, ROW and COL four), and MPG wraps its destination in micro memory.
@(private)
vif_run :: proc(v: ^Vif, w: []u32) -> int #no_bounds_check {
	i := 0
	for i < len(w) {
		code := w[i]
		need := vif_need(v, code)
		if i + need > len(w) {return i}
		if !vif_cmd(v, code, w[i + 1:][:need - 1]) {return i}
		i += need
		if v.stalled {return i}
	}
	return i
}

// Words a code takes, itself included, under the VIF's cycle setting.
@(private)
vif_need :: #force_inline proc(v: ^Vif, code: u32) -> int {
	cmd := (code >> 24) & 0x7f
	imm := code & 0xffff
	num := (code >> 16) & 0xff
	switch {
	case cmd == 0x20: return 2
	case cmd == 0x30 || cmd == 0x31: return 5
	case cmd == 0x4a: return 1 + 2 * int(num == 0 ? 256 : num)
	case cmd == 0x50 || cmd == 0x51: return 1 + 4 * int(imm == 0 ? 0x10000 : imm)
	case cmd >= 0x60: return 1 + vif_unpack_words(v, cmd, num)
	}
	return 1
}

// Run one code with its vif_need - 1 argument words. False when a DIRECT
// waits for the GIF: the code has not run (gif_wait). The i-bit stalls the
// VIF after the code (v.stalled).
@(private)
vif_cmd :: #force_inline proc(v: ^Vif, code: u32, arg: []u32) -> bool #no_bounds_check {
	cmd := (code >> 24) & 0x7f
	imm := code & 0xffff
	num := (code >> 16) & 0xff
	mem.hw_reg(VIF0_CODE + 0x400 * u32(v.id))^ = code
	switch cmd {
	case 0x00: // NOP
	case 0x01: // STCYCL
		v.cl, v.wl = imm & 0xff, imm >> 8
	case 0x02: // OFFSET
		v.ofst = imm & 0x3ff
		v.dbf = false
		v.tops = v.base
	case 0x03: v.base = imm & 0x3ff
	case 0x04: v.itops = imm & 0x3ff
	case 0x05: v.mode = imm & 3
	case 0x06: gif.gif_mskpath3(imm & 0x8000 != 0) // MSKPATH3
	case 0x07: // MARK
	case 0x10, 0x11, 0x13: // FLUSHE/FLUSH/FLUSHA: the VU runs synchronously
	case 0x14, 0x15: vif_mscal(v, imm * 8)
	case 0x17: vif_mscal(v, v.vu.tpc)
	case 0x20: v.mask = arg[0]
	case 0x30: v.row = {arg[0], arg[1], arg[2], arg[3]}
	case 0x31: v.col = {arg[0], arg[1], arg[2], arg[3]}
	case 0x4a: // MPG
		dst := (imm * 8) % u32(len(v.vu.micro))
		src := ([^]u8)(&arg[0])[:len(arg) * 4]
		for b, j in src {v.vu.micro[(dst + u32(j)) % u32(len(v.vu.micro))] = b}
		if v.vu == &vu1 {vu1_micro_touch()} else {vu0_micro_touch()}
	case 0x50, 0x51: // DIRECT, DIRECTHL: stall before the code while another path holds the GIF
		if !gif.gif_feed(1, ([^]u8)(&arg[0])[:len(arg) * 4], cmd == 0x51) {
			v.gif_wait = true
			return false
		}
	case 0x60 ..= 0x7f:
		vif_unpack(v, cmd, imm, num, arg)
	case:
		if !vif_warned[cmd] {
			vif_warned[cmd] = true
			fmt.eprintfln("vif%d: unknown code %08x", v.id, code)
		}
	}
	// The i-bit: retail interrupts once the code is done, data and all,
	// and stalls before the next code.
	if code & 0x80000000 != 0 && mem.hw_reg(VIF0_ERR + 0x400 * u32(v.id))^ & VIF_ERR_MII == 0 {
		mem.hw_reg(VIF0_STAT + 0x400 * u32(v.id))^ |= VIF_STAT_VIS | VIF_STAT_INT
		v.stalled = true
		mem.intc_raise(mem.INTC_VIF0 + u32(v.id))
	}
	return true
}

// A write to VIF id's FBRST: RST drops the codes the VIF holds (a split
// command, what waits out a stall or for the GIF), clears the stall and its
// STAT bits, ends a DMA it stalled (vif_dma_hook), and for VIF1 lifts its
// MSKPATH3 mask. STC clears the stall and its STAT bits, and the codes that
// waited run on. FBK and STP are ignored, and the write is not stored:
// FBRST reads back 0.
vif_fbrst :: proc(id: int, w: u32) {
	v := &vifs[id]
	if w & 1 != 0 {
		clear(&v.hold)
		v.stalled, v.gif_wait = false, false
		if id == 1 {gif.gif_vif1_reset()}
		mem.hw_reg(VIF0_STAT + 0x400 * u32(id))^ &~= VIF_STAT_STALL
		if vif_dma_hook != nil {vif_dma_hook(id, true)}
		return
	}
	if w & 8 == 0 {return}
	mem.hw_reg(VIF0_STAT + 0x400 * u32(id))^ &~= VIF_STAT_STALL
	if !v.stalled {return}
	v.stalled = false
	if !v.gif_wait {vif_resume(v)} // held still while a DIRECT waits for the GIF
}

@(private)
vif_mscal :: proc(v: ^Vif, addr: u32) {
	v.itop = v.itops
	if v.id == 1 {
		v.top = v.tops
		v.dbf = !v.dbf
		v.tops = (v.base + (v.dbf ? v.ofst : 0)) & 0x3ff // TOPS is 10 bits: the sum wraps
		vu1_start(addr)
	} else {
		vu0_call_micro(addr)
	}
}

// Source vectors an UNPACK reads for `num` writes under the cycle setting.
@(private)
vif_unpack_srcs :: proc(v: ^Vif, num: u32) -> u32 {
	num := num == 0 ? 256 : num
	if v.wl <= v.cl {return num}
	return num / v.wl * v.cl + min(num % v.wl, v.cl)
}

@(private)
vif_unpack_bits :: proc(cmd: u32) -> u32 {
	vn, vl := (cmd >> 2) & 3, cmd & 3
	if vl == 3 {return 16} // V4-5
	return (32 >> vl) * (vn + 1)
}

@(private)
vif_unpack_words :: proc(v: ^Vif, cmd, num: u32) -> int {
	return int((vif_unpack_srcs(v, num) * vif_unpack_bits(cmd) + 31) / 32)
}

// Unchecked: the destination quadword wraps by mask inside v.vu.mem, val
// and dst take lanes c <= vn <= 3, col takes mc <= 3, and src is read
// through a multi-pointer, sized by vif_unpack_words for exactly the source
// vectors this loop consumes.
@(private)
vif_unpack :: proc(v: ^Vif, cmd, imm, num: u32, src: []u32) #no_bounds_check {
	#assert(VU0_MEM & (VU0_MEM - 1) == 0 && VU1_MEM & (VU1_MEM - 1) == 0)
	vn, vl := (cmd >> 2) & 3, cmd & 3
	masked := cmd & 0x10 != 0
	unsigned := imm & 0x4000 != 0
	qmask := u32(len(v.vu.mem) / 16) - 1
	addr := imm & 0x3ff
	if v.id == 1 && imm & 0x8000 != 0 {addr += v.tops}
	num := num == 0 ? 256 : num
	bits := vif_unpack_bits(cmd)
	bytes := ([^]u8)(raw_data(src))
	if !masked && v.wl <= v.cl && v.mode < 2 {
		// The shapes games send most, keyed by VN, VL, unsigned and row add.
		fast := true
		switch cmd & 0xf | (unsigned ? 0x10 : 0) | (v.mode == 1 ? 0x20 : 0) {
		case 0x0c, 0x1c: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 0, false, false)
		case 0x2c, 0x3c: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 0, false, true)
		case 0x08, 0x18: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 2, 0, false, false)
		case 0x28, 0x38: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 2, 0, false, true)
		case 0x0d: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 1, true, false)
		case 0x1d: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 1, false, false)
		case 0x2d: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 1, true, true)
		case 0x3d: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 1, false, true)
		case 0x0e: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 2, true, false)
		case 0x1e: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 2, false, false)
		case 0x2e: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 2, true, true)
		case 0x3e: vif_unpack_fast(v, v.row, addr, num, qmask, bytes, 3, 2, false, true)
		case: fast = false
		}
		if fast {return}
	}
	elem := u32(32) >> vl
	sidx: u32 = 0 // source vector index
	cyc: u32 = 0
	for _ in 0 ..< num {
		dst := (^[4]u32)(&v.vu.mem[(addr & qmask) * 16])
		filling := v.wl > v.cl && cyc >= v.cl
		val: [4]u32
		if !filling {
			bit := sidx * bits
			if vl == 3 {
				h := u32((^u16)(&bytes[bit / 8])^)
				val = {(h & 0x1f) << 3, ((h >> 5) & 0x1f) << 3, ((h >> 10) & 0x1f) << 3, (h >> 15) << 7}
			} else {
				for c in 0 ..= vn {
					off := (bit + c * elem) / 8
					switch vl {
					case 0: val[c] = (^u32)(&bytes[off])^
					case 1:
						h := (^u16)(&bytes[off])^
						val[c] = unsigned ? u32(h) : u32(i32(i16(h)))
					case 2:
						b := bytes[off]
						val[c] = unsigned ? u32(b) : u32(i32(i8(b)))
					}
				}
				switch vn {
				case 0: val = {val[0], val[0], val[0], val[0]}
				case 1: val = {val[0], val[1], val[0], val[1]}
				}
			}
			sidx += 1
		}
		mc := min(cyc, 3)
		for c in 0 ..< 4 {
			sel: u32 = masked ? (v.mask >> (mc * 8 + u32(c) * 2)) & 3 : 0
			if filling && sel == 0 {sel = 1}
			switch sel {
			case 0:
				x := val[c]
				switch v.mode {
				case 1: x += v.row[c]
				case 2:
					x += v.row[c]
					v.row[c] = x
				}
				dst[c] = x
			case 1: dst[c] = v.row[c]
			case 2: dst[c] = v.col[mc]
			}
		}
		addr += 1
		cyc += 1
		if v.wl <= v.cl {
			if cyc == v.wl {
				addr += v.cl - v.wl
				cyc = 0
			}
		} else if cyc == v.wl {
			cyc = 0
		}
	}
}

// vif_unpack for one V4 or V3 shape with no write mask, no filling (wl <=
// cl) and mode 0 or 1: source vector i is the i-th write, each lane is
// read at its fixed offset, and the row adds without being written back.
// The destination steps as in vif_unpack's loop, skipping cl - wl
// quadwords after every wl writes. Unchecked for the same reasons as
// vif_unpack: the destination wraps by qmask and the source is sized by
// vif_unpack_words.
@(private)
vif_unpack_fast :: proc(v: ^Vif, row: [4]u32, addr, num, qmask: u32, bytes: [^]u8, $VN, $VL: u32, $SIGNED, $ROW: bool) #no_bounds_check {
	ELEM :: 4 >> VL // bytes a lane
	STRIDE :: ELEM * (VN + 1)
	// Locals and the row argument, so the stores into VU memory need not
	// reload them from v.
	vm := ([^]u8)(raw_data(v.vu.mem))
	wl, skip := v.wl, v.cl - v.wl
	addr := addr
	cyc: u32 = 0
	for i in 0 ..< num {
		s := bytes[i * STRIDE:]
		val: [4]u32
		#unroll for c in 0 ..= VN {
			when VL == 0 {
				val[c] = (^u32)(&s[c * ELEM])^
			} else when VL == 1 {
				h := (^u16)(&s[c * ELEM])^
				val[c] = SIGNED ? u32(i32(i16(h))) : u32(h)
			} else {
				val[c] = SIGNED ? u32(i32(i8(s[c]))) : u32(s[c])
			}
		}
		when ROW {val += row}
		(^[4]u32)(&vm[(addr & qmask) * 16])^ = val
		addr += 1
		cyc += 1
		if cyc == wl {
			addr += skip
			cyc = 0
		}
	}
}

// Emulated state, saved and restored by snapshots (snap.odin).
vif_snap :: proc() {
	core.snap_add(&vifs)
	core.snap_add(&vif_warned)
}
