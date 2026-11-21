// Native code from the recompiler (its native_arch and native_out options)
// in place of the recompiled Odin: the same functions, as machine code built
// apart from the game. This names every runtime procedure and variable the
// code imports and puts its functions in the call table.
//
// A game calls load_native after registering its recompiled functions, so
// the native ones replace them. Setting NATIVE=0 keeps the Odin functions,
// for comparing the two. A host with no recompiled functions calls it with
// none registered: the blob then stands alone and sizes the call table.
package ps2

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import "ps:core"
import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"
import vu "vu"

// The native code addresses cpu.state by these offsets
// (recomp/r5900/native.odin).
#assert(offset_of(cpu.Cpu, r) == 0)
#assert(size_of(cpu.Gpr) == 16)
#assert(offset_of(cpu.Cpu, hi) == 512)
#assert(offset_of(cpu.Cpu, lo) == 528)
#assert(offset_of(cpu.Cpu, sa) == 544)
#assert(offset_of(cpu.Cpu, f) == 548 && size_of(cpu.Fpr) == 4)
#assert(offset_of(cpu.Cpu, acc) == 676)
#assert(offset_of(cpu.Cpu, fcr31) == 680)
#assert(offset_of(cpu.Cpu, cop0) == 684)
#assert(offset_of(cpu.Cpu, cycles) == 816)
// wasm32 native code's exit record, and its reasons' values.
#assert(offset_of(cpu.Native_Exit, reason) == 0 && offset_of(cpu.Native_Exit, pc) == 4)
#assert(offset_of(cpu.Native_Exit, arg) == 8 && offset_of(cpu.Native_Exit, back) == 12)
#assert(int(cpu.Native_Exit_Reason.None) == 0 && int(cpu.Native_Exit_Reason.Events) == 1 && int(cpu.Native_Exit_Reason.Call) == 2 && int(cpu.Native_Exit_Reason.Return) == 3)
#assert(int(cpu.Native_Exit_Reason.Sys) == 4 && int(cpu.Native_Exit_Reason.Eret) == 5)
// And a VU's VI and other registers by these offsets from import vu.vf or
// vu1.vf; acc at a multiple of 16 for arm64's scaled ldr q.
#assert(offset_of(vu.Vu, vi) - offset_of(vu.Vu, vf) == 512)
#assert(offset_of(vu.Vu, acc) - offset_of(vu.Vu, vf) == 544 && offset_of(vu.Vu, acc) % 16 == 0)
#assert(offset_of(vu.Vu, q) - offset_of(vu.Vu, vf) == 560)
#assert(offset_of(vu.Vu, p) - offset_of(vu.Vu, vf) == 564)
#assert(offset_of(vu.Vu, i) - offset_of(vu.Vu, vf) == 568)
#assert(offset_of(vu.Vu, clip) - offset_of(vu.Vu, vf) == 576)
#assert(offset_of(vu.Vu, status) - offset_of(vu.Vu, vf) == 580)
#assert(offset_of(vu.Vu, mac) - offset_of(vu.Vu, vf) == 584)
#assert(offset_of(vu.Vu, old_mac) - offset_of(vu.Vu, vf) == 588)
#assert(offset_of(vu.Vu, old_status) - offset_of(vu.Vu, vf) == 600)
#assert(offset_of(vu.Vu, old_clip) - offset_of(vu.Vu, vf) == 612)
#assert(offset_of(vu.Vu, q_next) - offset_of(vu.Vu, vf) == 624)
#assert(offset_of(vu.Vu, q_wait) - offset_of(vu.Vu, vf) == 628)
#assert(offset_of(vu.Vu, p_next) - offset_of(vu.Vu, vf) == 632)
#assert(offset_of(vu.Vu, p_wait) - offset_of(vu.Vu, vf) == 636)
#assert(offset_of(vu.Vu, q_flags) - offset_of(vu.Vu, vf) == 640)
#assert(offset_of(vu.Vu, q_due) - offset_of(vu.Vu, vf) == 644)
#assert(offset_of(vu.Vu, vih) - offset_of(vu.Vu, vf) == 648)
#assert(offset_of(vu.Vu, cycle) - offset_of(vu.Vu, vf) == 664)
#assert(offset_of(vu.Vu, kick) - offset_of(vu.Vu, vf) == 668)

// bc_cond for native code, which reads a 32-bit result.
@(private = "file")
native_bc_cond :: proc(w: u32) -> u32 {return bc_cond(w) ? 1 : 0}

// cpu.fpu_slow for native code, which passes the f32 bits and the
// operation in integer registers.
@(private = "file")
native_fpu_slow :: proc(x, y, op: u32) -> u32 {
	return transmute(u32)cpu.fpu_slow(cpu.Fpu_Op(op), transmute(f32)x, transmute(f32)y)
}

// The EFU's sin, atan and exp for native microprograms (recomp/vu/native.odin
// efu), from x, the clamped lane or EATANxy's and EATANxz's quotient, as
// vu.vu_op computes P.
@(private = "file")
native_efu :: proc(key, x: u32) -> u32 {
	f := transmute(f32)x
	switch key {
	case 0x7c: return transmute(u32)math.sin(f) // ESIN
	case 0x7e: return transmute(u32)cpu.fclamp(math.exp(-f)) // EEXP
	}
	return transmute(u32)math.atan(f) // EATANxy, EATANxz, EATAN
}

// Scratch for native QFSRV, which puts its two registers side by side here.
@(private = "file")
funnel: [32]u8

// Bus accesses for native code, which passes and reads 32-bit words; the s
// loads sign-extend.
@(private = "file")
rd8 :: proc(a: u32) -> u32 {return u32(mem.rd8(a))}
@(private = "file")
rd8s :: proc(a: u32) -> u32 {return u32(i32(i8(mem.rd8(a))))}
@(private = "file")
rd16 :: proc(a: u32) -> u32 {return u32(mem.rd16(a))}
@(private = "file")
rd16s :: proc(a: u32) -> u32 {return u32(i32(i16(mem.rd16(a))))}
@(private = "file")
rd32 :: proc(a: u32) -> u32 {return mem.rd32(a)}
@(private = "file")
wr8 :: proc(a, v: u32) {mem.wr8(a, u8(v))}
@(private = "file")
wr16 :: proc(a, v: u32) {mem.wr16(a, u16(v))}
@(private = "file")
wr32 :: proc(a, v: u32) {mem.wr32(a, v)}

// Host pointer for a plain RAM or scratchpad address, else nil: the fast
// path of recompiled code (recomp/r5900/gen.odin FAST_HELPERS fast), as a
// call into package mem is not inlined here either. No bounds check, as
// there. With fast_lim 0 (WATCH, or the spin probe armed) the scratchpad
// takes the mem path too, so its stores reach the checks there.
@(private = "file")
fast :: #force_inline proc "contextless" (a: u32) -> rawptr #no_bounds_check {
	if a < mem.fast_lim {return &mem.ram_base[a]}
	if a - mem.SPR_BASE < mem.SPR_SIZE && mem.fast_lim != 0 {return &mem.spr[a - mem.SPR_BASE]}
	return nil
}

// fast for a store: nil for a code page too (mem.code_pages), so the store
// goes through mem, which marks it.
@(private = "file")
fast_store :: #force_inline proc "contextless" (a: u32) -> rawptr #no_bounds_check {
	if a < mem.fast_lim {return mem.code_pages[a >> mem.CODE_PAGE_SHIFT] == 0 ? &mem.ram_base[a] : nil}
	if a - mem.SPR_BASE < mem.SPR_SIZE && mem.fast_lim != 0 {return &mem.spr[a - mem.SPR_BASE]}
	return nil
}

// The doubleword and quadword accesses, with guest register n; the loads
// have n not zero.
@(private = "file")
ld :: proc(a, n: u32) {
	p := fast(a)
	cpu.state.r[n].d[0] = p != nil ? intrinsics.unaligned_load((^u64)(p)) : mem.rd64(a)
}
@(private = "file")
sd :: proc(a, n: u32) {
	if p := fast_store(a); p != nil {
		intrinsics.unaligned_store((^u64)(p), cpu.state.r[n].d[0])
	} else {
		mem.wr64(a, cpu.state.r[n].d[0])
	}
}
@(private = "file")
lq :: proc(a, n: u32) {
	p := fast(a &~ 15)
	cpu.state.r[n].q = p != nil ? intrinsics.unaligned_load((^u128)(p)) : mem.rd128(a)
}
@(private = "file")
sq :: proc(a, n: u32) {
	v := n == 0 ? 0 : cpu.state.r[n].q
	if p := fast_store(a &~ 15); p != nil {
		intrinsics.unaligned_store((^u128)(p), v)
	} else {
		mem.wr128(a, v)
	}
}
@(private = "file")
lqc2 :: proc(a, n: u32) {
	p := fast(a &~ 15)
	vu.vu0_set_vf(u8(n), p != nil ? intrinsics.unaligned_load((^u128)(p)) : mem.rd128(a))
}
@(private = "file")
sqc2 :: proc(a, n: u32) {
	v := vu.vu0.vf[n].q
	if p := fast_store(a &~ 15); p != nil {
		intrinsics.unaligned_store((^u128)(p), v)
	} else {
		mem.wr128(a, v)
	}
}

// The unaligned accesses, with guest register n, through the mem
// procedures as the Odin code calls them; the loads have n not zero.
@(private = "file")
lwl :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LWL(a, cpu.state.r[n].d[0])}
@(private = "file")
lwr :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LWR(a, cpu.state.r[n].d[0])}
@(private = "file")
ldl :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LDL(a, cpu.state.r[n].d[0])}
@(private = "file")
ldr :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LDR(a, cpu.state.r[n].d[0])}
@(private = "file")
swl :: proc(a, n: u32) {mem.SWL(a, cpu.state.r[n].d[0])}
@(private = "file")
swr :: proc(a, n: u32) {mem.SWR(a, cpu.state.r[n].d[0])}
@(private = "file")
sdl :: proc(a, n: u32) {mem.SDL(a, cpu.state.r[n].d[0])}
@(private = "file")
sdr :: proc(a, n: u32) {mem.SDR(a, cpu.state.r[n].d[0])}

// exec for an instruction the recompiler decoded, which passes its op; the
// fields come straight from the word, without decoding it again.
@(private = "file")
exec_op :: proc(pc, w, op: u32) {
	cpu.spin_dirty |= cpu.SPIN_SIDE
	exec_insn(
		{
			pc = pc,
			w = w,
			op = r5900.Op(op),
			rs = u8((w >> 21) & 31),
			rt = u8((w >> 16) & 31),
			rd = u8((w >> 11) & 31),
			sa = u8((w >> 6) & 31),
			fn = u8(w & 63),
			imm = u16(w),
		},
	)
}

// Lane masks for inline VU0 ops, at the offsets r5900's native code uses:
// the exponent, the sign, the largest finite value, the magnitude, zero,
// then the lanes of each dest field, the ITOF4/12/15 and FTOI4/12/15
// scales, the bits of the largest f32 below 2^31, and those of the
// smallest normal f32; then for the PS2 add and multiply, 23, the bits of
// 1.0, and in f64 lanes the mask of the bits above the low 29, the
// magnitude and the bits of 2^-126.
@(private = "file")
vu_k: [5 + 16 + 13][4]u32

// The runtime procedures and variables native code imports, by name; with
// types, each procedure's type too, for the signatures wasm32 calls with.
native_imports :: proc(types: ^map[string]typeid = nil) -> map[string]u64 {
	p :: proc(v: rawptr) -> u64 {return u64(uintptr(v))}
	f :: proc(m: ^map[string]u64, types: ^map[string]typeid, name: string, v: $T) {
		m[name] = u64(uintptr(rawptr(v)))
		if types != nil {types[name] = T}
	}
	m := make(map[string]u64, context.temp_allocator)
	vu_k[0], vu_k[1], vu_k[2], vu_k[3] = 0x7f800000, 0x80000000, 0x7f7fffff, 0x7fffffff
	for d in u32(0) ..< 16 {
		for k in u32(0) ..< 4 {vu_k[5 + d][k] = d & (8 >> k) != 0 ? max(u32) : 0}
	}
	for x, n in ([6]f32{1.0 / 16, 1.0 / 4096, 1.0 / 32768, 16, 4096, 32768}) {
		u := transmute(u32)x
		vu_k[21 + n] = {u, u, u, u}
	}
	vu_k[27] = {0x4effffff, 0x4effffff, 0x4effffff, 0x4effffff}
	vu_k[28] = {0x00800000, 0x00800000, 0x00800000, 0x00800000}
	vu_k[29] = {23, 23, 23, 23}
	vu_k[30] = {0x3f800000, 0x3f800000, 0x3f800000, 0x3f800000}
	vu_k[31] = {0xe0000000, 0xffffffff, 0xe0000000, 0xffffffff}
	vu_k[32] = {0xffffffff, 0x7fffffff, 0xffffffff, 0x7fffffff}
	vu_k[33] = {0, 0x38100000, 0, 0x38100000}
	m["mem.ram"] = p(mem.ram_base)
	m["mem.code_pages"] = p(&mem.code_pages)
	m["mem.spr"] = p(&mem.spr)
	m["ps2.funnel"] = p(&funnel)
	m["mem.watch_on"] = p(&mem.watch_on)
	f(&m, types, "ps2.rd8", rd8)
	f(&m, types, "ps2.rd8s", rd8s)
	f(&m, types, "ps2.rd16", rd16)
	f(&m, types, "ps2.rd16s", rd16s)
	f(&m, types, "ps2.rd32", rd32)
	f(&m, types, "ps2.wr8", wr8)
	f(&m, types, "ps2.wr16", wr16)
	f(&m, types, "ps2.wr32", wr32)
	m["cpu.state"] = p(&cpu.state)
	m["cpu.next_event"] = p(&cpu.next_event)
	m["cpu.native_exit"] = p(&cpu.native_exit)
	m["cpu.fn_table"] = p(cpu.fn_table_at())
	m["cpu.text_lo"] = p(&cpu.text_lo)
	m["cpu.mod_on"] = p(&cpu.mod_on)
	m["cpu.wasm_depth"] = p(&cpu.wasm_depth)
	m["cpu.wasm_fast_calls"] = p(&cpu.wasm_fast_calls)
	m["cpu.wasm_fast_jumps"] = p(&cpu.wasm_fast_jumps)
	m["cpu.wasm_npending"] = p(&cpu.wasm_npending)
	m["cpu.wasm_fall_events"] = p(&cpu.wasm_fall_events)
	m["cpu.wasm_fall_mod"] = p(&cpu.wasm_fall_mod)
	m["cpu.wasm_fall_nil"] = p(&cpu.wasm_fall_nil)
	m["cpu.wasm_fall_depth"] = p(&cpu.wasm_fall_depth)
	m["cpu.flat_returns"] = p(&cpu.flat_returns)
	f(&m, types, "cpu.wasm_pend", cpu.wasm_pend)
	m["cpu.unwinding"] = p(&cpu.unwinding)
	f(&m, types, "cpu.call", cpu.call)
	f(&m, types, "ps2.mod_call_original", mod_call_original)
	f(&m, types, "ps2.learned_jr", learned_jr)
	f(&m, types, "ps2.learned_jr_to", learned_jr_to)
	f(&m, types, "ps2.learned_left", learned_left)
	f(&m, types, "ps2.learned_goto", learned_goto)
	f(&m, types, "ps2.learned_entry", learned_entry)
	f(&m, types, "cpu.jump_unknown", cpu.jump_unknown)
	f(&m, types, "cpu.bad_insn", cpu.bad_insn)
	f(&m, types, "cpu.brk", cpu.brk)
	f(&m, types, "cpu.trap", cpu.trap)
	f(&m, types, "cpu.div", cpu.div)
	f(&m, types, "cpu.divu", cpu.divu)
	f(&m, types, "cpu.plzcw", cpu.plzcw)
	f(&m, types, "cpu.pmultw", cpu.pmultw)
	f(&m, types, "cpu.pmultuw", cpu.pmultuw)
	f(&m, types, "cpu.pmaddw", cpu.pmaddw)
	f(&m, types, "cpu.pmadduw", cpu.pmadduw)
	f(&m, types, "cpu.pmsubw", cpu.pmsubw)
	f(&m, types, "cpu.pmulth", cpu.pmulth)
	f(&m, types, "cpu.pmaddh", cpu.pmaddh)
	f(&m, types, "cpu.pmsubh", cpu.pmsubh)
	f(&m, types, "cpu.phmsbh", cpu.phmsbh)
	f(&m, types, "cpu.pdivbw", cpu.pdivbw)
	f(&m, types, "cpu.pmfhl", cpu.pmfhl)
	f(&m, types, "kernel.ei", kernel.ei)
	f(&m, types, "kernel.syscall", kernel.syscall)
	m["kernel.trace_on"] = p(&kernel.trace_on)
	f(&m, types, "kernel.trace_call", kernel.trace_call)
	f(&m, types, "kernel.run_events", kernel.run_events)
	f(&m, types, "kernel.events_in_place", kernel.events_in_place)
	f(&m, types, "kernel.sys_in_place", kernel.sys_in_place)
	m["cpu.spin_dirty"] = p(&cpu.spin_dirty)
	m["ps2.spin_tick"] = p(&spin_tick)
	f(&m, types, "ps2.spin_probe", spin_probe)
	f(&m, types, "ps2.exec_op", exec_op)
	f(&m, types, "ps2.ld", ld)
	f(&m, types, "ps2.sd", sd)
	f(&m, types, "ps2.lq", lq)
	f(&m, types, "ps2.sq", sq)
	f(&m, types, "ps2.lqc2", lqc2)
	f(&m, types, "ps2.sqc2", sqc2)
	f(&m, types, "ps2.lwl", lwl)
	f(&m, types, "ps2.lwr", lwr)
	f(&m, types, "ps2.ldl", ldl)
	f(&m, types, "ps2.ldr", ldr)
	f(&m, types, "ps2.swl", swl)
	f(&m, types, "ps2.swr", swr)
	f(&m, types, "ps2.sdl", sdl)
	f(&m, types, "ps2.sdr", sdr)
	m["vu.vf"] = p(&vu.vu0.vf)
	// CFC2/CTC2's control registers.
	m["vu.q"] = p(&vu.vu0.q)
	m["vu.i"] = p(&vu.vu0.i)
	m["vu.mac"] = p(&vu.vu0.mac)
	m["vu.status"] = p(&vu.vu0.status)
	m["vu.clip"] = p(&vu.vu0.clip)
	m["vu.r"] = p(&vu.vu0.r)
	m["vu.tpc"] = p(&vu.vu0.tpc)
	m["vu.fbrst"] = p(&vu.vu0.fbrst)
	m["vu.k"] = p(&vu_k)
	f(&m, types, "vu.macro", vu.vu0_macro)
	f(&m, types, "vu.call_micro", vu.vu0_call_micro)
	m["vu.cmsar"] = p(&vu.vu0.cmsar)
	m["vu.cmsar1"] = p(&vu.vu1.cmsar)
	m["vu.mem"] = p(&vu.vu0_mem)
	f(&m, types, "vu.ctrl_read", vu.vu0_ctrl_read)
	f(&m, types, "vu.ctrl_write", vu.vu0_ctrl_write)
	// The microprograms' (recomp/vu/native.odin): VU0's vu.*, VU1's vu1.*.
	f(&m, types, "vu.upper", vu.vu0_upper)
	f(&m, types, "vu.lower", vu.vu0_lower)
	f(&m, types, "vu.pair", vu.vu0_pair)
	f(&m, types, "vu.wait", vu.vu0_wait)
	m["vu.itop"] = p(&vu.vifs[0].itop)
	m["vu.run_pc"] = p(&vu.native_run[0].pc)
	m["vu.run_budget"] = p(&vu.native_run[0].budget)
	m["vu.scratch"] = p(&vu.native_run[0].scratch)
	f(&m, types, "vu.branch_vi", vu.vu0_branch_vi)
	m["vu1.vf"] = p(&vu.vu1.vf)
	m["vu1.mem"] = p(&vu.vu1_mem)
	f(&m, types, "vu1.upper", vu.vu1_upper)
	f(&m, types, "vu1.lower", vu.vu1_lower)
	f(&m, types, "vu1.pair", vu.vu1_pair)
	f(&m, types, "vu1.wait", vu.vu1_wait)
	f(&m, types, "vu1.xgkick", vu.vu1_xgkick)
	f(&m, types, "vu1.kick_store", vu.vu1_kick_store)
	m["vu1.top"] = p(&vu.vifs[1].top)
	m["vu1.itop"] = p(&vu.vifs[1].itop)
	m["vu1.run_pc"] = p(&vu.native_run[1].pc)
	m["vu1.run_budget"] = p(&vu.native_run[1].budget)
	m["vu1.scratch"] = p(&vu.native_run[1].scratch)
	f(&m, types, "vu1.branch_vi", vu.vu1_branch_vi)
	f(&m, types, "ps2.bc_cond", native_bc_cond)
	f(&m, types, "cpu.fpu_slow", native_fpu_slow)
	f(&m, types, "vu.efu", native_efu)
	return m
}

// The import slot naming the hooked set with hash h a blob was built for
// (recomp/r5900/gen.odin); a blob built for none has no such slot.
@(private = "file")
native_hooked_slot :: proc(h: u64) -> string {
	return fmt.tprintf("mod_hooks:%016x", h)
}

// Why blob, built for the hooked set its slot names, cannot run with mods
// hooking the set with hash want, or "". A header native_load would refuse
// is left to it.
@(private = "file")
native_hooked_check :: proc(blob: []u8, want: u64) -> string {
	_, slots, _, err := core.native_slots(blob)
	if err != "" {return ""}
	have := ""
	for s in slots {
		if strings.has_prefix(s, "mod_hooks:") {have = s}
	}
	if have == (want != 0 ? native_hooked_slot(want) : "") {return ""}
	built := have != "" ? fmt.tprintf("hooked set %s", have[len("mod_hooks:"):]) : "no hooked set"
	mods := want != 0 ? fmt.tprintf("hooked set %016x", want) : "none"
	return fmt.tprintf("built for %s, the mods hook %s: convert or build it again for this mod set (the recomp option mod_hooks)", built, mods)
}

// Replace the registered functions with the native code in the file at
// path, or with no call table yet, register the blob's functions alone.
// False, with the reason printed, when it cannot be used; the Odin
// functions then stay. hooked is the hash of the hooked set of the mods
// to load (core.mod_hooks_hash, 0 none): the blob must have been built for
// it (the recomp option mod_hooks; its import slot mod_hooks:<hash>). On
// wasm32 the functions are steps of the FLAT runner (interp_flat.odin),
// which flat_native_on lets it take.
load_native :: proc(path: string, hooked: u64 = 0) -> bool {
	if core.env("NATIVE") == "0" {
		if cpu.text_hi == 0 {fmt.eprintln("native: NATIVE=0, and there are no recompiled functions to keep")}
		return false
	}
	spin_on = core.env("SPIN") != "0"
	if mem.ram_base == nil {
		fmt.eprintln("native: load_native comes after init, which maps RAM")
		return false
	}
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("native: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	if e := native_hooked_check(blob, hooked); e != "" {
		fmt.eprintfln("native: %s: %s", path, e)
		return false
	}
	imports := native_imports()
	if hooked != 0 {imports[native_hooked_slot(hooked)] = 0}
	code, msg := core.native_load(blob, imports, warm = .After)
	if msg != "" {
		fmt.eprintfln("native: %s: %s", path, msg)
		return false
	}
	defer delete(code.funcs)
	defer delete(code.ovls)
	// wasm32 code is EE functions and VU microprograms only: an overlay
	// needs the dispatch x64 and arm64 code does itself, a span of another
	// kind its own backend.
	when ODIN_ARCH == .wasm32 {
		other := 0
		for s in code.spans {
			if s.kind != .Vu0 && s.kind != .Vu1 {other += 1}
		}
		if len(code.ovls) != 0 || other != 0 {
			fmt.eprintfln("native: %s: %d overlay functions and %d spans not of a VU, which wasm32 code cannot have", path, len(code.ovls), other)
			core.native_free(&code)
			return false
		}
	}
	if cpu.text_hi == 0 {
		// Standalone: the table spans the blob's functions.
		if len(code.funcs) == 0 {
			fmt.eprintfln("native: %s: no functions", path)
			core.native_free(&code)
			return false
		}
		lo, hi := max(u32), u32(0)
		for f in code.funcs {
			lo, hi = min(lo, f.addr), max(hi, f.addr)
		}
		cpu.text_range(lo, hi + 4)
		for f in code.funcs {
			cpu.register(f.addr, cast(cpu.Func_Proc)rawptr(code.base + uintptr(f.off)))
		}
		fmt.eprintfln("native: %d functions from %s, standalone (%08x-%08x)", len(code.funcs), path, lo, hi + 4)
		register_vus(&code)
		when ODIN_ARCH == .wasm32 {flat_native_on = true}
		return true
	}
	// A function the build does not have means the blob is from other code:
	// use none of it rather than a mix.
	missing := 0
	for f in code.funcs {
		if cpu.lookup(f.addr) == nil {missing += 1}
	}
	if missing != 0 {
		fmt.eprintfln("native: %s: %d functions are not registered (built from other code?)", path, missing)
		core.native_free(&code)
		return false
	}
	for f in code.funcs {
		cpu.register(f.addr, cast(cpu.Func_Proc)rawptr(code.base + uintptr(f.off)))
	}
	fmt.eprintfln("native: %d functions from %s", len(code.funcs), path)
	register_vus(&code)
	when ODIN_ARCH == .wasm32 {flat_native_on = true}
	return true
}

// Register the blob's VU microprograms beside the Odin ones, unless
// VUNATIVE=0; same-size candidates then run native. Their ranges keep the
// pool, so it is never freed.
@(private = "file")
register_vus :: proc(code: ^core.Native_Code) {
	if len(code.spans) == 0 || core.env("VUNATIVE") == "0" {return}
	vu1, kept := blob_vu1_kept(code)
	vu1_kept = vu1 ? kept : vu.VU_STATUS_ALL
	n := 0
	for s in code.spans {
		if s.kind != .Vu0 && s.kind != .Vu1 {continue} // not this runtime's
		vu.vu_register_native(s.kind == .Vu0 ? 0 : 1, span_ranges(code, s), span_native(code, s), kept)
		n += 1
	}
	fmt.eprintfln("native: %d VU microprograms", n)
}

// Whether code has VU1 programs, and the status bits its VU1 code surely
// keeps: recomp keeps, for every VU1 program of a blob, the bits
// status_kept gives for what the programs it read read; those of the
// blob's programs give a floor (a program read but not compiled, or
// status_all, can have made it keep more). A floor leaves more bits stale
// and compares fewer, never the reverse. The blob does not record the
// bits itself.
@(private = "file")
blob_vu1_kept :: proc(code: ^core.Native_Code) -> (vu1: bool, kept: u32) {
	reads: u32
	for s in code.spans {
		if s.kind != .Vu1 {continue}
		vu1 = true
		reads |= vu.vu_status_reads(span_ranges(code, s))
	}
	return vu1, vu.vu_status_kept(reads)
}

// The status bits the startup blob's VU1 code surely keeps
// (blob_vu1_kept).
@(private = "file")
vu1_kept: u32 = vu.VU_STATUS_ALL

// The VU ranges of span s, its words in code's pool (which they keep).
@(private = "file")
span_ranges :: proc(code: ^core.Native_Code, s: core.Native_Span) -> []vu.Vu_Range {
	ranges := make([]vu.Vu_Range, s.n_ranges, context.temp_allocator)
	for &r, k in ranges {
		nr := code.ranges[int(s.range_first) + k]
		r = {nr.pc, code.pool[nr.at:][:nr.n_words]}
	}
	return ranges
}

@(private = "file")
span_native :: proc(code: ^core.Native_Code, s: core.Native_Span) -> vu.Vu_Native {
	return cast(vu.Vu_Native)rawptr(code.base + uintptr(s.off))
}

// Register the VU microprograms of blob (`play --convert-vu`; name, its
// name in a message) beside those registered, while the game runs. Call it
// only where no microprogram runs: between the EE's instructions, as at a
// vblank (kernel.run_events), since a VU runs each microprogram to its end
// within the EE instruction that starts it. Programs already registered
// (the same addresses and words) are left, and counted in known; added
// counts the rest. When those VU1 programs read status bits the startup
// blob's VU1 code may not keep (vu1_kept), none is registered (skipped):
// code that does not keep them would then run beside code that reads them. The blob's code stays mapped while a program
// of it is registered; blob itself may be freed after. False, with the
// reason printed, when the blob cannot be loaded.
load_native_vus :: proc(blob: []u8, name: string) -> (added, known: int, skipped, ok: bool) {
	code, msg := core.native_load(blob, native_imports())
	if msg != "" {
		fmt.eprintfln("native: %s: %s", name, msg)
		return
	}
	ok = true
	news := make([dynamic]core.Native_Span, 0, len(code.spans), context.temp_allocator)
	reads: u32
	for s in code.spans {
		if s.kind != .Vu0 && s.kind != .Vu1 {continue} // not this runtime's
		ranges := span_ranges(&code, s)
		if vu.vu_registered(s.kind == .Vu0 ? 0 : 1, ranges) {
			known += 1
			continue
		}
		append(&news, s)
		if s.kind == .Vu1 {reads |= vu.vu_status_reads(ranges)}
	}
	skipped = vu.vu_status_kept(reads) & ~vu1_kept != 0
	if skipped || len(news) == 0 {
		core.native_free(&code)
		return
	}
	_, kept := blob_vu1_kept(&code)
	for s in news {
		vu.vu_register_native(s.kind == .Vu0 ? 0 : 1, span_ranges(&code, s), span_native(&code, s), kept)
	}
	added = len(news)
	// The ranges keep the pool and the mapping; the rest goes.
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	return
}
