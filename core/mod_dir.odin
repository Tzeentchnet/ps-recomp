// A game's mods directory, read: each subdirectory of it that has a
// mod.tsv is a mod, its code in mod.elf beside it. An optional mods.tsv in
// the mods directory lists mod ids, one a line, in the order the user wants
// them (mod_order keeps it where dependencies allow), and an optional
// settings.tsv the values the user gave the mods' settings (mod_values_read).
// The console loads the set (psx/mods.odin) and writes the values into the
// mods' variables (mod_values_write); play compiles its functions and keys
// the blob by mod_set_hash.
package core

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// The mods of a directory, k indexing each in directory order: the
// manifests (in the default allocator, as they outlive the machine), the
// load order (indices into mods), and each mod's mod.tsv and mod.elf bytes
// and image, temp allocated. hooks holds every image's, the mod of each
// its k. values[k][i] is the value of images[k].settings[i] this run uses,
// and settings the path of the settings.tsv they are from (temp too).
Mod_Set :: struct {
	mods:      []Mod_Manifest,
	order:     []int,
	tsv, elf:  [][]u8,
	images:    []Mod_Image,
	hooks:     []Mod_Hook,
	values:    [][]i32,
	settings:  string,
}

// The mods in dir, each image inside [lo, hi) (physical). disc is the
// running disc's id: a mod whose `disc` is neither it nor its serial (the
// id up to the first `.`) gets a warning, and is read all the same; ""
// warns of none. A missing dir is no mods. err is in the temp allocator.
mods_read :: proc(dir, disc: string, lo, hi: u32) -> (set: Mod_Set, err: string) {
	if dir == "" || !os.is_dir(dir) {return}
	entries, derr := read_dir(dir, context.temp_allocator)
	if derr != nil {return {}, fmt.tprintf("mod: cannot read %s: %v", dir, derr)}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	mods := make([dynamic]Mod_Manifest)
	// Freed here until set holds them.
	defer if set.mods == nil {
		for m in mods {mod_manifest_delete(m)}
		delete(mods)
	}
	tsv := make([dynamic][]u8, context.temp_allocator)
	where_ := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type != .Directory {continue}
		path, _ := filepath.join({e.fullpath, "mod.tsv"}, context.temp_allocator)
		text, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr == .Not_Exist {continue}
		if rerr != nil {return {}, fmt.tprintf("mod: cannot read %s: %v", path, rerr)}
		m, merr := mod_manifest_parse(string(text))
		if merr != "" {return {}, fmt.tprintf("%s: %s", path, merr)}
		if disc != "" && m.disc != "" && m.disc != disc && m.disc != strings.split_n(disc, ".", 2, context.temp_allocator)[0] {
			fmt.eprintfln("mod %s: made for disc %s, this is %s", m.id, m.disc, disc)
		}
		append(&mods, m)
		append(&tsv, text)
		append(&where_, e.fullpath)
	}
	if len(mods) == 0 {return}
	set.mods, set.tsv = mods[:], tsv[:]

	user: []string
	list, _ := filepath.join({dir, "mods.tsv"}, context.temp_allocator)
	if text, rerr := os.read_entire_file(list, context.temp_allocator); rerr == nil {
		ids := make([dynamic]string, context.temp_allocator)
		rest := string(text)
		for line in strings.split_lines_iterator(&rest) {
			l := strings.trim_space(line)
			if l != "" && l[0] != '#' {append(&ids, l)}
		}
		user = ids[:]
	} else if rerr != .Not_Exist {
		return set, fmt.tprintf("mod: cannot read %s: %v", list, rerr)
	}
	oerr: string
	set.order, oerr = mod_order(set.mods, user, context.temp_allocator)
	if oerr != "" {return set, oerr}

	set.elf = make([][]u8, len(mods), context.temp_allocator)
	set.images = make([]Mod_Image, len(mods), context.temp_allocator)
	hooks := make([dynamic]Mod_Hook, context.temp_allocator)
	for m, k in set.mods {
		path, _ := filepath.join({where_[k], "mod.elf"}, context.temp_allocator)
		elf, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {return set, fmt.tprintf("mod %s: cannot read %s: %v", m.id, path, rerr)}
		img, ierr := mod_elf_read(elf, lo, hi, k, context.temp_allocator)
		if ierr != "" {return set, fmt.tprintf("mod %s: %s: %s", m.id, path, ierr)}
		set.elf[k], set.images[k] = elf, img
		append(&hooks, ..img.hooks)
	}
	set.hooks = hooks[:]
	set.settings, _ = filepath.join({dir, "settings.tsv"}, context.temp_allocator)
	set.values, err = mod_values_read(set.settings, set.mods, set.images)
	return set, err
}

// The values of each mod's settings (values[k][i] for images[k].settings[i])
// from the settings file at path: lines of a mod id, a setting's name and a
// decimal value, tab separated; `#` starts a comment line. A missing file
// sets none. A setting the file does not set has its default. A line for a
// mod not loaded is kept for when it is; a malformed line, an unknown
// setting of a loaded mod or a value out of its range gets a warning and is
// skipped. All in the temp allocator.
mod_values_read :: proc(path: string, mods: []Mod_Manifest, images: []Mod_Image) -> (values: [][]i32, err: string) {
	values = make([][]i32, len(mods), context.temp_allocator)
	index := make(map[string]int, len(mods), context.temp_allocator)
	for m, k in mods {
		index[m.id] = k
		values[k] = make([]i32, len(images[k].settings), context.temp_allocator)
		for s, i in images[k].settings {values[k][i] = s.def}
	}
	text, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr == .Not_Exist {return values, ""}
	if rerr != nil {return values, fmt.tprintf("mod: cannot read %s: %v", path, rerr)}
	rest := string(text)
	line_no := 0
	lines: for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		l := strings.trim_right(line, "\r")
		if strings.trim_space(l) == "" || l[0] == '#' {continue}
		f := strings.split(l, "\t", context.temp_allocator)
		v, vok := i64(0), false
		if len(f) == 3 {v, vok = strconv.parse_i64_of_base(f[2], 10)}
		if !vok {
			fmt.eprintfln("%s:%d: not a mod id, setting and value", path, line_no)
			continue
		}
		k, loaded := index[f[0]]
		if !loaded {continue}
		for s, i in images[k].settings {
			if s.name != f[1] {continue}
			if v < i64(s.min) || v > i64(s.max) {
				fmt.eprintfln("%s:%d: mod %s setting %s: %d is outside %d..%d", path, line_no, f[0], f[1], v, s.min, s.max)
			} else {
				values[k][i] = i32(v)
			}
			continue lines
		}
		fmt.eprintfln("%s:%d: mod %s has no setting %s", path, line_no, f[0], f[1])
	}
	return values, ""
}

// Write set's setting values into its mods' variables in the mod region:
// ram, which starts at base (physical), as the console loaded the images.
mod_values_write :: proc(set: Mod_Set, ram: []u8, base: u32) {
	for img, k in set.images {
		if k >= len(set.values) {break}
		for s, i in img.settings {
			(^u32le)(&ram[(s.addr & 0x1fff_ffff) - base])^ = u32le(u32(set.values[k][i]))
		}
	}
}

// The mod_run_hash of the mods this run loads, 0 for none. The console
// sets it before its input record opens: record_open writes it and
// replay_load checks it, and the compat line's build column and a netplay
// HELLO carry it, so runs with different mods are never taken for the same.
run_mods: u64
// How many mods this run loads.
run_mods_n: int

// A setting of a mod this run loads, for a port's menu: value is what the
// run uses, saved what settings.tsv now holds, which the next run uses.
Run_Setting :: struct {
	mod, name, label:    string,
	def, min, max, step: i32,
	value, saved:        i32,
}

// The settings of the mods this run loads, in load order and each mod's
// declaration order, and the settings.tsv mod_setting_save writes. Set by
// mods_note; in the default allocator.
run_settings: []Run_Setting
run_settings_path: string

// Note set as this run's mods (run_mods, 0 for none) and their settings
// (run_settings) and, when it has any, say which set it is, as who ("psx",
// "ps2").
mods_note :: proc(set: Mod_Set, who: string) {
	run_mods, run_mods_n = 0, 0
	run_settings_free()
	if len(set.mods) == 0 {return}
	run_mods, run_mods_n = mod_run_hash(set), len(set.mods)
	fmt.eprintfln("%s: mod set %016x (%d mods)", who, run_mods, len(set.mods))
	list := make([dynamic]Run_Setting)
	for k in set.order {
		if k >= len(set.images) {continue}
		for s, i in set.images[k].settings {
			v := set.values[k][i] if k < len(set.values) else s.def
			append(&list, Run_Setting {
				mod = strings.clone(set.mods[k].id),
				name = strings.clone(s.name),
				label = strings.clone(s.label),
				def = s.def, min = s.min, max = s.max, step = s.step,
				value = v, saved = v,
			})
		}
	}
	run_settings = list[:]
	run_settings_path = strings.clone(set.settings)
}

@(private = "file")
run_settings_free :: proc() {
	for s in run_settings {
		delete(s.mod)
		delete(s.name)
		delete(s.label)
	}
	delete(run_settings)
	delete(run_settings_path)
	run_settings, run_settings_path = nil, ""
}

// Save v as run_settings[k]'s value in settings.tsv, for the next run: the
// running one keeps its value, as its record and mod set hash name it.
// Other lines are kept; a value at the default has no line. err is in the
// temp allocator.
mod_setting_save :: proc(k: int, v: i32) -> (err: string) {
	if k < 0 || k >= len(run_settings) {return fmt.tprintf("mod: no setting %d", k)}
	s := &run_settings[k]
	if v < s.min || v > s.max {return fmt.tprintf("mod %s setting %s: %d is outside %d..%d", s.mod, s.name, v, s.min, s.max)}
	b := strings.builder_make(context.temp_allocator)
	text, rerr := os.read_entire_file(run_settings_path, context.temp_allocator)
	if rerr != nil && rerr != .Not_Exist {return fmt.tprintf("mod: cannot read %s: %v", run_settings_path, rerr)}
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split_n(strings.trim_right(line, "\r"), "\t", 3, context.temp_allocator)
		if len(f) == 3 && f[0] == s.mod && f[1] == s.name {continue}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	if v != s.def {fmt.sbprintf(&b, "%s\t%s\t%d\n", s.mod, s.name, v)}
	if werr := os.write_entire_file(run_settings_path, b.buf[:]); werr != nil {
		return fmt.tprintf("mod: cannot write %s: %v", run_settings_path, werr)
	}
	s.saved = v
	return ""
}

// The hash a run with set is known by: mod_set_hash when every setting has
// its default (the ELFs give those), otherwise XXH3-64 over it and each
// mod's settings off their defaults, in load order: the mod's id, the
// setting's name and its value, the strings length-prefixed and the value
// as i32 little endian.
mod_run_hash :: proc(set: Mod_Set) -> u64 {
	code := mod_set_hash(set)
	state: xxhash.XXH3_state
	xxhash.XXH3_init_state(&state)
	_ = xxhash.XXH3_64_reset(&state)
	put :: proc(state: ^xxhash.XXH3_state, b: []u8) {
		n := u32le(len(b))
		_ = xxhash.XXH3_64_update(state, ([^]u8)(&n)[:4])
		if len(b) > 0 {_ = xxhash.XXH3_64_update(state, b)}
	}
	c := u64le(code)
	_ = xxhash.XXH3_64_update(&state, ([^]u8)(&c)[:8])
	changed := false
	for k in set.order {
		if k >= len(set.values) || k >= len(set.images) {continue}
		for s, i in set.images[k].settings {
			v := i32le(set.values[k][i])
			if i32(v) == s.def {continue}
			changed = true
			put(&state, transmute([]u8)set.mods[k].id)
			put(&state, transmute([]u8)s.name)
			_ = xxhash.XXH3_64_update(&state, ([^]u8)(&v)[:4])
		}
	}
	return xxhash.XXH3_64_digest(&state) if changed else code
}

// The mod set's hash: XXH3-64 over MOD_API, then for each mod in load
// order its id, mod.tsv and mod.elf, each length-prefixed. The mods blob's
// key names it, so any edit, an added or removed mod, or another order
// compiles the blob again.
mod_set_hash :: proc(set: Mod_Set) -> u64 {
	state: xxhash.XXH3_state
	xxhash.XXH3_init_state(&state)
	_ = xxhash.XXH3_64_reset(&state)
	put :: proc(state: ^xxhash.XXH3_state, b: []u8) {
		n := u32le(len(b))
		_ = xxhash.XXH3_64_update(state, ([^]u8)(&n)[:4])
		if len(b) > 0 {_ = xxhash.XXH3_64_update(state, b)}
	}
	api := u32le(MOD_API)
	_ = xxhash.XXH3_64_update(&state, ([^]u8)(&api)[:4])
	for k in set.order {
		put(&state, transmute([]u8)set.mods[k].id)
		put(&state, set.tsv[k])
		put(&state, set.elf[k])
	}
	return xxhash.XXH3_64_digest(&state)
}

// The hooked set's hash: XXH3-64 over the sorted unique addresses the hooks
// name, as u32 little endian; 0 for none. Recompiled EE code built for a
// hooked set (recomp option mod_hooks) carries the same hash
// (recomp/mips/mod_hooks.odin: tests/mod pins both), and the runtime
// refuses code built for another set.
mod_hooks_hash :: proc(hooks: []Mod_Hook) -> u64 {
	addrs := make([]u32, len(hooks), context.temp_allocator)
	for h, k in hooks {addrs[k] = h.key.addr}
	slice.sort(addrs)
	n := len(slice.unique(addrs))
	if n == 0 {return 0}
	b := make([]u8, 4 * n, context.temp_allocator)
	for a, k in addrs[:n] {
		for i in 0 ..< 4 {b[4 * k + i] = u8(a >> (8 * uint(i)))}
	}
	return xxhash.XXH3_64_default(b)
}

// Free what mods_read gave set in the default allocator (its manifests),
// for a set not loaded.
mod_set_delete :: proc(set: Mod_Set) {
	for m in set.mods {mod_manifest_delete(m)}
	delete(set.mods)
}
