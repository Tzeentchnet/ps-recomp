// A program's mod API, for either console: the header (mod_api.h) and
// linker script (mod.ld) a mod's C is built against (mods/build.sh), and for
// a console that has Odin mods the Odin package (game/game.odin) they import
// in its place. The
// backends give the spaces their game code is in, the rows naming its
// functions and their console's Mod_Api_Target (recomp/r3000/mod_api.odin,
// recomp/r5900/mod_api.odin).
//
// Each function gets a name, a prototype and a key: the .mod_hooks record
// fields (core.Mod_Key) that name it to the runtime. The name is
// `<space>_<entry>` (ram_80012345, ov_xxx_80123456); the row's `name`, when
// it is a usable C name, is an alias for it, and in the Odin package too
// when it is not a name Odin or the package has (odin_reserved).
package mips

import "core:fmt"
import "core:slice"
import "core:strings"

// Where game code may be: a space's image, and the slot and id its keys
// name it by (a PS1 executable slot = id = 0, an overlay its slot and first
// word; the EE's boot program slot 0 and its ELF's id).
Mod_Api_Space :: struct {
	name:     string,
	img:      Image,
	slot, id: u32,
}

// A function to declare; name "" for none.
Mod_Api_Row :: struct {
	space: string,
	entry: u32,
	name:  string,
}

// What mod_api left out: rows whose entry is not in its image with its
// four signature words, and names not made aliases.
Mod_Api_Skips :: struct {
	outside, names: int,
}

// A console's part of the API: its header's opening text (through the
// include guard) and closing declarations (mod_call_original), the
// attributes after each game function's declarator, and its mod region:
// where mods link, the end an image may reach, and mod_call_original's
// address. odin: the console has Odin mods (mods/build.sh builds them only
// for the PS1).
Mod_Api_Target :: struct {
	top, tail, call:                 string,
	version, base, image_end, original: u32,
	odin:                            bool,
}

// The header, linker script and Odin package (game, "" when t has no Odin
// mods) for rows, in (space, entry) order whatever the rows' order. err
// (temp allocated) names a row of an unknown space, an unaligned entry, or
// a space that is not a C name.
mod_api :: proc(t: Mod_Api_Target, spaces: []Mod_Api_Space, rows: []Mod_Api_Row) -> (header, script, game: string, skips: Mod_Api_Skips, err: string) {
	Fn :: struct {
		space: int,
		entry: u32,
		sig:   [4]u32,
	}
	for s in spaces {
		if !c_name(s.name) {return "", "", "", {}, fmt.tprintf("space %s is not a C name", s.name)}
	}
	sorted := slice.clone(rows, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Mod_Api_Row) -> bool {
		if a.space != b.space {return a.space < b.space}
		if a.entry != b.entry {return a.entry < b.entry}
		return a.name < b.name
	})

	fns := make([dynamic]Fn, context.temp_allocator)
	// Per sorted row: its function's index in fns, -1 none.
	of := make([]int, len(sorted), context.temp_allocator)
	for r, k in sorted {
		of[k] = -1
		sp := -1
		for s, i in spaces {
			if s.name == r.space {sp = i}
		}
		if sp < 0 {return "", "", "", {}, fmt.tprintf("%s %08x: unknown space %s", r.space, r.entry, r.space)}
		if r.entry & 3 != 0 {return "", "", "", {}, fmt.tprintf("%s %08x: entry not word aligned", r.space, r.entry)}
		if n := len(fns); n > 0 && fns[n - 1].space == sp && fns[n - 1].entry == r.entry {
			of[k] = n - 1
			continue
		}
		f := Fn{sp, r.entry, {}}
		ok := true
		for &w, i in f.sig {
			w, ok = word(spaces[sp].img, r.entry + u32(i) * 4)
			if !ok {break}
		}
		if !ok {
			skips.outside += 1
			continue
		}
		of[k] = len(fns)
		append(&fns, f)
	}

	// A name is an alias when it is a C name of its own (no keyword, no
	// reserved name, not shaped like a canonical one) used by one function.
	users := make(map[string]int, context.temp_allocator)
	for r, k in sorted {
		if r.name == "" || of[k] < 0 {continue}
		if u, seen := users[r.name]; seen && u != of[k] {
			users[r.name] = -1
		} else if !seen {
			users[r.name] = of[k]
		}
	}
	aliases := make([][]string, len(fns), context.temp_allocator)
	for r, k in sorted {
		if r.name == "" || of[k] < 0 {continue}
		f := fns[of[k]]
		own := fmt.tprintf("%s_%08x", spaces[f.space].name, f.entry)
		if r.name == own {continue}
		if users[r.name] != of[k] || !c_name(r.name) || reserved(r.name) || canonical_shaped(spaces, r.name) {
			skips.names += 1
			continue
		}
		list := slice.clone_to_dynamic(aliases[of[k]], context.temp_allocator)
		if !slice.contains(list[:], r.name) {append(&list, r.name)}
		aliases[of[k]] = list[:]
	}

	h, ld, od: strings.Builder
	strings.builder_init(&h)
	strings.builder_init(&ld)
	strings.builder_init(&od)
	fmt.sbprint(&h, t.top)
	fmt.sbprint(&od, ODIN_TOP)
	fmt.sbprintf(&od, "MOD_API :: %d\nMOD_BASE :: 0x%08x\nORIGINAL :: 0x%08x\n", t.version, t.base, t.original)
	fmt.sbprint(&od, ODIN_TYPES)
	fmt.sbprintf(&h, "#define MOD_API %d\n#define MOD_BASE 0x%08x\n", t.version, t.base)
	fmt.sbprint(&h, HEADER_HOOKS)
	fmt.sbprint(&h, t.tail)
	fmt.sbprint(&ld, SCRIPT_TOP)
	fmt.sbprintf(&ld, "mod_call_original = 0x%08x;\n", t.original)
	for f, i in fns {
		s := spaces[f.space]
		own := fmt.tprintf("%s_%08x", s.name, f.entry)
		key := fmt.tprintf("0x%08x, 0x%08x, 0x%08x, {{0x%08x, 0x%08x, 0x%08x, 0x%08x}}", s.slot, s.id, f.entry, f.sig[0], f.sig[1], f.sig[2], f.sig[3])
		fmt.sbprintf(&h, "\n")
		fmt.sbprintf(&od, "\n%s :: Fn{{%s}}\n", own, key)
		for n in aliases[i] {
			if !odin_reserved(n) {fmt.sbprintf(&od, "%s :: %s\n", n, own)}
		}
		names := make([dynamic]string, context.temp_allocator)
		append(&names, own)
		append(&names, ..aliases[i])
		for n in names {
			fmt.sbprintf(&h, "unsigned %s()%s;\n#define MOD_KEY_%s %s\n", n, t.call, n, key)
			fmt.sbprintf(&ld, "%s = 0x%08x;\n", n, f.entry)
		}
	}
	fmt.sbprint(&h, "\n#endif\n")
	fmt.sbprintf(&ld, SCRIPT_SECTIONS, t.base, t.base, t.image_end, t.image_end)
	if !t.odin {
		strings.builder_destroy(&od)
		return strings.to_string(h), strings.to_string(ld), "", skips, ""
	}
	return strings.to_string(h), strings.to_string(ld), strings.to_string(od), skips, ""
}

// Write header and script as out/mod_api.h and out/mod.ld, and game, when
// not "", as out/game/game.odin.
mod_api_files :: proc(out, header, script, game: string) {
	make_dirs(out)
	write_file(join(out, "mod_api.h"), transmute([]u8)header)
	write_file(join(out, "mod.ld"), transmute([]u8)script)
	if game == "" {return}
	dir := join(out, "game")
	make_dirs(dir)
	write_file(join(dir, "game.odin"), transmute([]u8)game)
}

@(private = "file")
HEADER_HOOKS :: `
typedef unsigned u32;

// A .mod_hooks record (core/mod_elf.odin): the kind (0 before, 1 after, 2
// replace), the hooked function's key (slot, id, addr, its first four
// words) and the mod's function.
struct mod_hook {
	u32 kind, slot, id, addr, sig[4];
	void (*fn)();
};

#define MOD_CAT_(a, b) a##b
#define MOD_CAT(a, b) MOD_CAT_(a, b)
#define MOD_HOOK_(kind, target, fn) \
	__attribute__((section(".mod_hooks"), used, aligned(4))) \
	static const struct mod_hook MOD_CAT(mod_hook_, __COUNTER__) = {kind, MOD_KEY_##target, (void (*)())(fn)}

// Run fn before, after or in place of the game function target.
#define MOD_BEFORE(target, fn) MOD_HOOK_(0, target, fn)
#define MOD_AFTER(target, fn) MOD_HOOK_(1, target, fn)
#define MOD_REPLACE(target, fn) MOD_HOOK_(2, target, fn)

// A .mod_settings record (core/mod_elf.odin), loaded with the mod: the
// setting's value, least and greatest values and step, its name and its
// label. The value the ELF gives is the default.
struct mod_setting {
	int value, min, max, step;
	const char *name, *label;
};

// Define var, a setting the user picks: var.value is def until the mods
// directory's settings.tsv gives another value in min..max, which the
// runtime writes into it before the game starts. A port's menu shows label
// and moves the value by step; a 0..1 setting is a switch. var is the
// setting's name.
#define MOD_SETTING(var, def, min, max, step, label) \
	_Static_assert((min) <= (def) && (def) <= (max) && (step) >= 1, \
		"mod: setting " #var ": def outside min..max, or step below 1"); \
	__attribute__((section(".mod_settings"), used, aligned(4))) \
	struct mod_setting var = {def, min, max, step, #var, label}
`

@(private = "file")
SCRIPT_TOP :: `/* A mod's link: generated by recomp --mod-api; do not edit.
 *
 * The image goes at MOD_ORIGIN (mods/build.sh --origin; the mod region's
 * base by default) and must end before the region's guard word and stack.
 * .mod_settings is loaded, as the runtime writes the settings' values into
 * it; .mod_hooks is not, the runtime reads it from the ELF. Each game
 * function is a symbol at its address, and mod_call_original is the
 * runtime's. */

ENTRY(mod_entry_none)
mod_entry_none = 0;

`

// A format: braces doubled.
@(private = "file")
SCRIPT_SECTIONS :: `
mod_origin = DEFINED(MOD_ORIGIN) ? MOD_ORIGIN : 0x%08x;

SECTIONS {{
	. = mod_origin;
	.text : {{ *(.text .text.*) }}
	.rodata : {{ *(.rodata .rodata.*) }}
	.data : {{ *(.data .data.* .sdata .sdata.*) }}
	.got : {{ *(.got) }}
	.mod_settings : {{ KEEP(*(.mod_settings)) }}
	.bss : {{ *(.bss .bss.* .sbss .sbss.* COMMON) }}
	mod_end = .;
	.mod_hooks 0 (INFO) : {{ KEEP(*(.mod_hooks)) }}
	.symtab 0 : {{ *(.symtab) }}
	.strtab 0 : {{ *(.strtab) }}
	.shstrtab 0 : {{ *(.shstrtab) }}
	/DISCARD/ : {{ *(.eh_frame*) *(.MIPS.*) *(.reginfo) *(.pdr) *(.comment) *(.gnu.attributes) *(.mdebug.*) }}
}}

/* build.sh links with --orphan-handling=error: every loaded section is one
 * of the above, so mod_end is the image's end. */
ASSERT(mod_origin >= 0x%08x && mod_origin < 0x%08x, "mod: the origin is outside the mod region")
ASSERT(mod_origin %% 16 == 0, "mod: the origin is not 16-byte aligned")
ASSERT(mod_end <= 0x%08x, "mod: the image runs past the mod region (its stack and guard)")
`

@(private = "file")
ODIN_TOP :: `// A game's functions, for Odin mods: generated by recomp --mod-api; do
// not edit.
//
// A mod imports it as "api:game" (mods/build.sh). Each game function is an
// Fn named as mod_api.h names it: call it through the proc type you give
// it, game.call(proc "c" (u32) -> u32, game.ram_80012345)(x), and hook it
// with a Hook. Settings are Setting records.
//
// A mod's code runs on no Odin runtime: no context, no allocator, no
// startup code. So a hook is a proc "c" that passes and returns integers
// and pointers only; and a global whose initializer Odin cannot place at
// link time (inside a struct, a rawptr of a proc or the address of a
// variable) would stay zero, so mods/build.sh refuses it.
package game

import "base:intrinsics"

`

@(private = "file")
ODIN_TYPES :: `
// A game function's key (core.Mod_Key): its space's slot and id, its
// address and its first four words.
Fn :: struct {
	slot, id, addr: u32,
	sig:            [4]u32,
}

Hook_Kind :: enum u32 {
	Before,
	After,
	Replace,
}

// A .mod_hooks record: run fn, a proc "c", before, after or in place of
// target. T is fn's type:
//
//	@(export, link_section = ".mod_hooks")
//	hook_check := game.Hook(type_of(check)){.Replace, game.ram_80012345, check}
Hook :: struct($T: typeid) where intrinsics.type_is_proc(T) {
	kind:   Hook_Kind,
	target: Fn,
	fn:     T,
}

// A .mod_settings record, loaded with the mod: value is the default until
// the mods directory's settings.tsv gives another in min..max, which the
// runtime writes into it before the game starts. A port's menu shows label
// and moves the value by step; a 0..1 setting is a switch. name, a C name,
// is what settings.tsv keys it by. Exported, so it is read where it is,
// not folded to its default:
//
//	@(export, link_section = ".mod_settings")
//	rate := game.Setting{128, 0, 1024, 16, "rate", "Encounter rate"}
Setting :: struct {
	value, min, max, step: i32,
	name, label:           cstring,
}

// The game function f, as the proc type T.
call :: #force_inline proc "contextless" ($T: typeid, f: Fn) -> T where intrinsics.type_is_proc(T) {
	return transmute(T)uintptr(f.addr)
}

// From a replacement: the function it replaces, without its hooks, as the
// proc type T. It is the innermost running replacement's; a call from a
// before or after hook, or with no replacement running, is fatal.
original :: #force_inline proc "contextless" ($T: typeid) -> T where intrinsics.type_is_proc(T) {
	return transmute(T)uintptr(ORIGINAL)
}

// The T at addr in the game's memory, and a store of v there.
load :: #force_inline proc "contextless" ($T: typeid, addr: uintptr) -> T {
	return intrinsics.volatile_load((^T)(addr))
}

store :: #force_inline proc "contextless" (addr: uintptr, v: $T) {
	intrinsics.volatile_store((^T)(addr), v)
}
`

// Whether an alias must stay out of the Odin package: an Odin keyword or
// builtin, or a name the package has.
@(private = "file")
odin_reserved :: proc(s: string) -> bool {
	@(static, rodata)
	words := [?]string {
		"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer",
		"distinct", "do", "dynamic", "else", "enum", "fallthrough", "false", "for", "foreign", "if", "import",
		"in", "map", "matrix", "nil", "not_in", "or_break", "or_continue", "or_else", "or_return", "package",
		"proc", "return", "struct", "switch", "transmute", "true", "typeid", "union", "using", "when", "where",
		"bool", "b8", "b16", "b32", "b64", "int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32",
		"u64", "u128", "uintptr", "f16", "f32", "f64", "rune", "string", "cstring", "rawptr", "any", "byte",
		"len", "cap", "size_of", "align_of", "offset_of", "type_of", "type_info_of", "typeid_of", "min", "max",
		"abs", "clamp", "swizzle", "complex", "quaternion", "real", "imag", "jmag", "kmag", "conj", "expand_values",
		"raw_data",
		"intrinsics", "Fn", "Hook_Kind", "Hook", "Setting", "call", "original", "load", "store", "MOD_API",
		"MOD_BASE", "ORIGINAL",
	}
	return slice.contains(words[:], s)
}

// Whether s starts as a canonical name does, with a space's name and `_`.
@(private = "file")
canonical_shaped :: proc(spaces: []Mod_Api_Space, s: string) -> bool {
	for sp in spaces {
		if len(s) > len(sp.name) && strings.has_prefix(s, sp.name) && s[len(sp.name)] == '_' {return true}
	}
	return false
}

// Whether s is a C identifier.
@(private = "file")
c_name :: proc(s: string) -> bool {
	if s == "" || (s[0] >= '0' && s[0] <= '9') {return false}
	for c in transmute([]u8)s {
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {return false}
	}
	return true
}

// A name no alias may take: a C keyword, a name the header or a mod's own
// code needs, or one C reserves (a leading underscore).
@(private = "file")
reserved :: proc(s: string) -> bool {
	@(static, rodata)
	words := [?]string {
		"auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
		"float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
		"sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
		"alignas", "alignof", "bool", "constexpr", "false", "nullptr", "static_assert", "thread_local", "true",
		"typeof", "typeof_unqual", "asm", "u32", "u64", "main", "memcpy", "memset", "memmove", "memcmp",
		// Macros clang predefines for the targets outside C's reserved
		// names (-std=gnu17 does; build.sh's -std=c17 does not).
		"mips", "MIPSEL",
	}
	if s[0] == '_' || strings.has_prefix(s, "mod_") || strings.has_prefix(s, "MOD_") {return true}
	return slice.contains(words[:], s)
}
