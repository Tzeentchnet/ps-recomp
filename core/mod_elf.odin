// A mod's code, as data: the ELF a mod is built as (mod.elf), read into
// the segments that go into the console's mod region and the hooks its
// .mod_hooks section lists.
//
// The ELF is 32-bit little-endian MIPS, an executable linked inside the mod
// region, its loadable segments not overlapping. A .mod_hooks record is nine words: the kind (0 before, 1 after,
// 2 replace), the hooked function's key (slot, id, addr, sig[4]) and the
// mod function's address, which must be in one of the ELF's segments.
//
// .mod_settings is loaded with the image, word aligned. Its record is six
// words: the setting's value (the default as the ELF gives it; the runtime
// writes the user's over it), its least and greatest values, its step, and
// its name and label, each the address of a NUL-terminated string in a
// segment's file bytes. Names are unique in a mod.
//
// The ELF's .symtab names the mod's functions: each STT_FUNC symbol with a
// size, word aligned, in an executable segment's file bytes. They are what
// play compiles to native code (psx/native/mods.odin); an ELF without a
// .symtab has none, and its code is interpreted.
package core

import "core:fmt"
import "core:slice"

// One loadable segment: bytes at addr, then zeros up to size. exec: the
// segment is executable (PF_X).
Mod_Segment :: struct {
	addr, size: u32,
	bytes:      []u8,
	exec:       bool,
}

// One function from .symtab: its code at addr (as linked, not masked to
// physical), bytes slicing the ELF.
Mod_Func :: struct {
	addr:  u32,
	bytes: []u8,
}

// A setting from .mod_settings: an int at addr (its record's value word)
// the user picks, def until set, in [min, max], step apart in a menu. name
// and label slice the ELF.
Mod_Setting :: struct {
	addr:                u32,
	def, min, max, step: i32,
	name, label:         string,
}

// A mod's code. lo and hi bound its segments, physical addresses (the low
// 29 bits); segments and hooks are in the read's allocator, and bytes slice
// the ELF, as do the funcs, sorted by address, one per address.
Mod_Image :: struct {
	lo, hi:   u32,
	segments: []Mod_Segment,
	hooks:    []Mod_Hook,
	funcs:    []Mod_Func,
	settings: []Mod_Setting,
}

MOD_HOOK_WORDS :: 9
MOD_SETTING_WORDS :: 6
// Longest setting name and label, in bytes.
MOD_SETTING_NAME_MAX :: 64
MOD_SETTING_LABEL_MAX :: 128

@(private = "file")
ELF_LOAD :: 1
@(private = "file")
ELF_PF_X :: 1
@(private = "file")
ELF_SYMTAB :: 2
@(private = "file")
ELF_STT_FUNC :: 2

// The image in elf, which must lie in [lo, hi) (physical). Each hook's mod
// is `mod`. err is in the temp allocator.
mod_elf_read :: proc(elf: []u8, lo, hi: u32, mod: int, allocator := context.allocator) -> (img: Mod_Image, err: string) {
	u16_at :: proc(b: []u8, at: u32) -> u32 {return u32(b[at]) | u32(b[at + 1]) << 8}
	u32_at :: proc(b: []u8, at: u32) -> u32 {return u16_at(b, at) | u16_at(b, at + 2) << 16}
	n := u32(len(elf))
	if n < 52 || string(elf[:4]) != "\x7fELF" || elf[4] != 1 || elf[5] != 1 {
		return {}, "not a 32-bit little-endian ELF"
	}
	if u16_at(elf, 16) != 2 || u16_at(elf, 18) != 8 {
		return {}, "not a MIPS executable"
	}
	phoff, shoff := u32_at(elf, 28), u32_at(elf, 32)
	phsize, phnum := u16_at(elf, 42), u16_at(elf, 44)
	shsize, shnum, shstr := u16_at(elf, 46), u16_at(elf, 48), u16_at(elf, 50)
	if phnum == 0 || phsize < 32 || u64(phoff) + u64(phsize) * u64(phnum) > u64(n) {
		return {}, "bad program headers"
	}
	if shnum != 0 && (shsize < 40 || shstr >= shnum || u64(shoff) + u64(shsize) * u64(shnum) > u64(n)) {
		return {}, "bad section headers"
	}

	segs := make([dynamic]Mod_Segment, allocator)
	img.lo, img.hi = max(u32), 0
	for k in 0 ..< phnum {
		ph := phoff + k * phsize
		if u32_at(elf, ph) != ELF_LOAD {continue}
		off, addr, file, mem := u32_at(elf, ph + 4), u32_at(elf, ph + 8), u32_at(elf, ph + 16), u32_at(elf, ph + 20)
		flags := u32_at(elf, ph + 24)
		p := addr & 0x1fff_ffff
		if file > mem || u64(off) + u64(file) > u64(n) {
			delete(segs)
			return {}, fmt.tprintf("bad segment at %08x", addr)
		}
		if mem == 0 {continue}
		if p < lo || u64(p) + u64(mem) > u64(hi) {
			delete(segs)
			return {}, fmt.tprintf("segment %08x-%08x is outside the mod region %08x-%08x", p, u64(p) + u64(mem), lo, hi)
		}
		for o in segs {
			if p < o.addr + o.size && o.addr < p + mem {
				delete(segs)
				return {}, fmt.tprintf("segments %08x-%08x and %08x-%08x overlap", o.addr, o.addr + o.size, p, p + mem)
			}
		}
		append(&segs, Mod_Segment{p, mem, elf[off:][:file], flags & ELF_PF_X != 0})
		img.lo, img.hi = min(img.lo, p), max(img.hi, p + mem)
	}
	if len(segs) == 0 {
		delete(segs)
		return {}, "no segment to load"
	}
	img.segments = segs[:]

	// .mod_hooks and .mod_settings, found by name, and the symbol table.
	hooks, settings, syms: []u8
	settings_addr: u32
	if shnum != 0 {
		names_at := shoff + shstr * shsize
		names_off, names_size := u32_at(elf, names_at + 16), u32_at(elf, names_at + 20)
		if u64(names_off) + u64(names_size) > u64(n) {
			mod_image_delete(img, allocator)
			return {}, "bad section names"
		}
		names := elf[names_off:][:names_size]
		named :: proc(names: []u8, at: u32, want: string) -> bool {
			return u64(at) + u64(len(want)) < u64(len(names)) && string(names[at:][:len(want)]) == want && names[at + u32(len(want))] == 0
		}
		for k in 0 ..< shnum {
			sh := shoff + k * shsize
			if u32_at(elf, sh + 4) == ELF_SYMTAB && syms == nil {
				off, size, ent := u32_at(elf, sh + 16), u32_at(elf, sh + 20), u32_at(elf, sh + 36)
				if u64(off) + u64(size) > u64(n) || ent != 16 || size % 16 != 0 {
					mod_image_delete(img, allocator)
					return {}, "bad .symtab section"
				}
				syms = elf[off:][:size]
				continue
			}
			name := u32_at(elf, sh)
			off, size := u32_at(elf, sh + 16), u32_at(elf, sh + 20)
			if named(names, name, ".mod_hooks") {
				if u64(off) + u64(size) > u64(n) || size % (MOD_HOOK_WORDS * 4) != 0 {
					mod_image_delete(img, allocator)
					return {}, "bad .mod_hooks section"
				}
				hooks = elf[off:][:size]
			} else if named(names, name, ".mod_settings") {
				if u64(off) + u64(size) > u64(n) || size % (MOD_SETTING_WORDS * 4) != 0 {
					mod_image_delete(img, allocator)
					return {}, "bad .mod_settings section"
				}
				settings = elf[off:][:size]
				settings_addr = u32_at(elf, sh + 12)
			}
		}
	}
	img.funcs = mod_elf_funcs(img.segments, syms, allocator)
	out := make([]Mod_Hook, len(hooks) / (MOD_HOOK_WORDS * 4), allocator)
	img.hooks = out
	for &h, k in out {
		r := u32(k) * MOD_HOOK_WORDS * 4
		kind := u32_at(hooks, r)
		if kind > u32(Mod_Hook_Kind.Replace) {
			mod_image_delete(img, allocator)
			return {}, fmt.tprintf("hook %d: kind %d", k, kind)
		}
		h = {
			key = {slot = u32_at(hooks, r + 4), id = u32_at(hooks, r + 8), addr = u32_at(hooks, r + 12)},
			kind = Mod_Hook_Kind(kind),
			mod = mod,
			fn = u32_at(hooks, r + 32),
		}
		for &w, i in h.key.sig {w = u32_at(hooks, r + 16 + u32(i) * 4)}
		if !mod_image_has(img, h.fn) {
			e := fmt.tprintf("hook %d on %08x: mod function %08x is not in the image", k, h.key.addr, h.fn)
			mod_image_delete(img, allocator)
			return {}, e
		}
	}
	if e := mod_elf_settings(&img, settings, settings_addr, allocator); e != "" {
		mod_image_delete(img, allocator)
		return {}, e
	}
	return img, ""
}

// img.settings from the .mod_settings records in b, linked at at. err is in
// the temp allocator.
@(private = "file")
mod_elf_settings :: proc(img: ^Mod_Image, b: []u8, at: u32, allocator := context.allocator) -> (err: string) {
	u32_at :: proc(b: []u8, at: u32) -> u32 {
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	out := make([]Mod_Setting, len(b) / (MOD_SETTING_WORDS * 4), allocator)
	img.settings = out
	for &s, k in out {
		r := u32(k) * MOD_SETTING_WORDS * 4
		s = {
			addr = at + r,
			def  = i32(u32_at(b, r)),
			min  = i32(u32_at(b, r + 4)),
			max  = i32(u32_at(b, r + 8)),
			step = i32(u32_at(b, r + 12)),
		}
		ok: bool
		s.name, ok = mod_image_string(img^, u32_at(b, r + 16), MOD_SETTING_NAME_MAX)
		if !ok || !mod_setting_name_ok(s.name) {
			return fmt.tprintf("setting %d: its name is not a C name of at most %d bytes in the image", k, MOD_SETTING_NAME_MAX)
		}
		if s.label, ok = mod_image_string(img^, u32_at(b, r + 20), MOD_SETTING_LABEL_MAX); !ok {
			return fmt.tprintf("setting %s: its label is not a string of at most %d bytes in the image", s.name, MOD_SETTING_LABEL_MAX)
		}
		if s.addr % 4 != 0 || !mod_image_has(img^, s.addr) || !mod_image_has(img^, s.addr + MOD_SETTING_WORDS * 4 - 1) {
			return fmt.tprintf("setting %s: its record %08x is not word aligned in the image (.mod_settings not loaded?)", s.name, s.addr)
		}
		if s.min > s.max || s.def < s.min || s.def > s.max || s.step < 1 {
			return fmt.tprintf("setting %s: default %d, range %d..%d, step %d", s.name, s.def, s.min, s.max, s.step)
		}
		for o in out[:k] {
			if o.name == s.name {return fmt.tprintf("setting %s twice", s.name)}
		}
	}
	return ""
}

// The NUL-terminated string at addr in a segment's file bytes: at most max
// bytes before its NUL, none a control character.
@(private = "file")
mod_image_string :: proc(img: Mod_Image, addr: u32, max: int) -> (s: string, ok: bool) {
	p := addr & 0x1fff_ffff
	for seg in img.segments {
		if p < seg.addr || p - seg.addr >= u32(len(seg.bytes)) {continue}
		b := seg.bytes[p - seg.addr:]
		for c, i in b {
			if c == 0 {return string(b[:i]), true}
			if i >= max || c < 0x20 || c == 0x7f {return "", false}
		}
		return "", false
	}
	return "", false
}

// Whether s is a setting's name: a C identifier of at most
// MOD_SETTING_NAME_MAX bytes, which settings.tsv keys a value by.
mod_setting_name_ok :: proc(s: string) -> bool {
	if s == "" || len(s) > MOD_SETTING_NAME_MAX || (s[0] >= '0' && s[0] <= '9') {return false}
	for c in transmute([]u8)s {
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {return false}
	}
	return true
}

// Whether addr is in a segment of img.
mod_image_has :: proc(img: Mod_Image, addr: u32) -> bool {
	p := addr & 0x1fff_ffff
	for s in img.segments {
		if p >= s.addr && p - s.addr < s.size {return true}
	}
	return false
}

mod_image_delete :: proc(img: Mod_Image, allocator := context.allocator) {
	delete(img.segments, allocator)
	delete(img.hooks, allocator)
	delete(img.funcs, allocator)
	delete(img.settings, allocator)
}

// The functions syms (.symtab's entries) names in segs: STT_FUNC, sized,
// word aligned and inside an executable segment's file bytes. Others are
// skipped, and their code is interpreted. Sorted by address; of symbols at
// one address (aliases) the longest is kept.
@(private = "file")
mod_elf_funcs :: proc(segs: []Mod_Segment, syms: []u8, allocator := context.allocator) -> []Mod_Func {
	u32_at :: proc(b: []u8, at: u32) -> u32 {
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	funcs := make([dynamic]Mod_Func, allocator)
	for at := u32(0); at < u32(len(syms)); at += 16 {
		value, size, info := u32_at(syms, at + 4), u32_at(syms, at + 8), syms[at + 12]
		if info & 0xf != ELF_STT_FUNC || size == 0 || value % 4 != 0 || size % 4 != 0 {continue}
		p := value & 0x1fff_ffff
		for s in segs {
			if !s.exec || p < s.addr || u64(p - s.addr) + u64(size) > u64(len(s.bytes)) {continue}
			append(&funcs, Mod_Func{value, s.bytes[p - s.addr:][:size]})
			break
		}
	}
	slice.sort_by(funcs[:], proc(a, b: Mod_Func) -> bool {
		return a.addr < b.addr || a.addr == b.addr && len(a.bytes) > len(b.bytes)
	})
	keep := 0
	for f, k in funcs {
		if k > 0 && f.addr == funcs[keep - 1].addr {continue}
		funcs[keep] = f
		keep += 1
	}
	resize(&funcs, keep)
	return funcs[:]
}
