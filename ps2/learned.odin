// Learned EE functions: native code compiled from runs the EE interpreter
// learned (recomp/r5900/learned.odin). One is never put in the call table:
// only a call the table misses looks it up (interp_call), and it runs only
// while RAM holds its words, compared on every call. Code loaded over them
// (an overlay a game copies in, a DMA, a snapshot load) is interpreted
// instead, and runs native again once the words are back. An entry can
// have several, one per code loaded there. The words are compared on entry
// only; a run whose code changed while it ran (a loader patching its
// caller's calls) is recorded .Smc (core/learn.odin) and never compiled.
//
// On wasm32 each function's code is a step of the FLAT runner
// (interp_flat.odin), which looks it up at every pc it goes on at
// (learned_at), not only at an entry: a step leaves at each call, and the
// function goes on at the return address. The words are compared at its
// entry, as on a call above, and elsewhere in it only when they were not
// since cpu.learned_epoch last moved (an instruction-cache flush, a
// snapshot load): a function big enough to call often would compare its
// words again at every return.
package ps2

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"

import "ps:core"
import cpu "cpu"
import mem "mem"

@(private = "file")
Learned_Fn :: struct {
	lo:    u32,
	words: []u32,
	fn:    cpu.Func_Proc,
}

// By entry. Host state: a snapshot never holds it, and every call checks
// the words, so none needs restoring.
@(private = "file")
learned_fns: map[u32][dynamic]Learned_Fn

// The learned function at entry whose words RAM holds now, else nil.
learned_find :: proc(entry: u32) -> cpu.Func_Proc #no_bounds_check {
	fns, ok := learned_fns[entry]
	if !ok {return nil}
	for &l in fns {
		n := len(l.words)
		cpu.learned_words += u64(n)
		if string(mem.ram[l.lo:][:4 * n]) == string(([^]u8)(raw_data(l.words))[:4 * n]) {
			cpu.learned_calls += 1
			return l.fn
		}
	}
	cpu.learned_stale += 1
	return nil
}

// Register the learned functions in the blob at path: its spans, each a
// function valid while RAM holds its words. False, with the reason printed,
// when the blob cannot be used; none of it is then registered. Its code and
// pool are never freed.
load_learned :: proc(path: string) -> bool {
	if mem.ram_base == nil {
		fmt.eprintln("learned: load_learned comes after init, which maps RAM")
		return false
	}
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("learned: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	code, msg := core.native_load(blob, native_imports())
	if msg == "" && (len(code.funcs) != 0 || len(code.ovls) != 0) {
		msg = "not a learned blob"
	}
	for s in code.spans {
		if msg != "" {break}
		if s.kind != .Ee || s.n_ranges != 1 {
			msg = "a span that is not a learned EE function"
			break
		}
		r := code.ranges[s.range_first]
		if r.pc & 3 != 0 || r.n_words == 0 || r.pc >= mem.RAM_SIZE || r.n_words > (mem.RAM_SIZE - r.pc) / 4 || s.entry < r.pc || s.entry >= r.pc + 4 * r.n_words {
			msg = "a learned function outside RAM"
		}
	}
	if msg != "" {
		fmt.eprintfln("learned: %s: %s", path, msg)
		if code.base != 0 {core.native_free(&code)}
		return false
	}
	when ODIN_ARCH == .wasm32 {
		learned_steps_add(&code)
	} else {
		if learned_fns == nil {learned_fns = make(map[u32][dynamic]Learned_Fn, core.long_allocator())}
		for s in code.spans {
			r := code.ranges[s.range_first]
			fns := learned_fns[s.entry]
			if fns == nil {fns = make([dynamic]Learned_Fn, core.long_allocator())}
			append(&fns, Learned_Fn{r.pc, code.pool[r.at:][:r.n_words], cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))})
			learned_fns[s.entry] = fns
		}
	}
	cpu.learned_loaded += len(code.spans)
	fmt.eprintfln("learned: %d EE functions from %s", len(code.spans), path)
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	return true
}

// wasm32: the learned functions, by their first word, and the RAM words
// any of them holds (a bit each), which most pcs the runner looks up miss
// at once. Host state, as learned_fns.
@(private = "file")
Learned_Step :: struct {
	using f:  Learned_Fn,
	entry:    u32,
	epoch:    u32, // cpu.learned_epoch when RAM last held its words; 0 never
}
@(private = "file")
learned_steps: [dynamic]Learned_Step
@(private = "file")
learned_marks: []u64
@(private = "file")
learned_most: u32 // the most words of any
// The entry whose words were compared since the runner last ran native
// code (learned_ran), and its function: a taken jump looks up the code it
// goes on in (flat_native_at), then the runner looks it up again to run
// it, which would compare them twice and count the call twice.
@(private = "file")
learned_checked: struct {
	pc, epoch: u32,
	fn:        cpu.Func_Proc,
} = {pc = ~u32(0)}

@(private = "file")
learned_steps_add :: proc(code: ^core.Native_Code) {
	if learned_marks == nil {
		learned_marks = make([]u64, mem.RAM_SIZE / 4 / 64, core.long_allocator())
		learned_steps = make([dynamic]Learned_Step, core.long_allocator())
		append(&core.snap_hooks, core.Snap_Hook{save = proc(_: int) {}, load = proc(_: int) {cpu.learned_epoch += 1}})
	}
	for s in code.spans {
		r := code.ranges[s.range_first]
		fn := Learned_Fn{r.pc, code.pool[r.at:][:r.n_words], cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))}
		append(&learned_steps, Learned_Step{f = fn, entry = s.entry})
		learned_most = max(learned_most, r.n_words)
		for w in r.pc / 4 ..< r.pc / 4 + r.n_words {learned_marks[w / 64] |= 1 << (w % 64)}
	}
	slice.sort_by(learned_steps[:], proc(a, b: Learned_Step) -> bool {return a.lo < b.lo})
	learned_entry_cache = {}
	flat_native_on = true
}

// wasm32: the learned function holding the words RAM holds at pc and
// around it now, else nil (also with none loaded). The one starting
// nearest below pc first.
learned_at :: #force_inline proc(pc: u32) -> cpu.Func_Proc #no_bounds_check {
	w := pc / 4
	if learned_marks == nil || pc >= mem.RAM_SIZE || pc & 3 != 0 || learned_marks[w / 64] & (1 << (w % 64)) == 0 {return nil}
	return learned_search(pc)
}

// The entries of the loaded blob's records that it holds no function for:
// the compiler left them to the interpreter (code stored into, too large,
// not lowered). Sorted; host state. Game data's refused rows name them
// (natively made only with game data on). On wasm32 the FLAT runner opens
// no LEARN run at one (interp_flat.odin): recording it again every run
// would be all cost, since the next compile refuses it again. Made only at
// load, so code loaded there later, which the compiler might take, is not
// recorded either until a load finds no record of it.
@(private = "file")
learned_refused: []u32

// Keep entries (a blob's records', in any order, repeats too) that no
// loaded learned function starts at, as learned_refused.
learned_refuse :: proc(entries: []u32) {
	has := make(map[u32]struct{}, context.temp_allocator)
	when ODIN_ARCH == .wasm32 {
		for &l in learned_steps {has[l.entry] = {}}
	} else {
		for e in learned_fns {has[e] = {}}
	}
	out := make([dynamic]u32, core.long_allocator())
	for e in entries {
		if e not_in has {append(&out, e)}
	}
	slice.sort(out[:])
	delete(learned_refused, core.long_allocator())
	learned_refused = slice.unique(out[:])
	fmt.eprintfln("learned: %d EE entries left to the interpreter open no LEARN run", len(learned_refused))
}

// wasm32: whether pc is an entry of learned_refused.
learned_refused_at :: proc(pc: u32) -> bool {
	_, found := slice.binary_search(learned_refused, pc)
	return found
}

// wasm32: the runner runs the native code it looked up last; the next
// lookup of an entry compares its words again.
learned_ran :: #force_inline proc() {learned_checked.pc = ~u32(0)}

@(private = "file")
learned_search :: proc(pc: u32) -> cpu.Func_Proc #no_bounds_check {
	if pc == learned_checked.pc && learned_checked.epoch == cpu.learned_epoch {return learned_checked.fn}
	// The first function starting above pc.
	k, _ := slice.binary_search_by(learned_steps[:], pc + 1, proc(l: Learned_Step, t: u32) -> slice.Ordering {
		return l.lo < t ? .Less : .Greater
	})
	for k -= 1; k >= 0; k -= 1 {
		l := &learned_steps[k]
		if pc - l.lo >= 4 * learned_most {break}
		n := len(l.words)
		if pc - l.lo >= 4 * u32(n) {continue}
		if pc != l.entry && l.epoch == cpu.learned_epoch {return l.fn}
		cpu.learned_words += u64(n)
		if string(mem.ram[l.lo:][:4 * n]) == string(([^]u8)(raw_data(l.words))[:4 * n]) {
			l.epoch = cpu.learned_epoch
			if pc == l.entry {
				cpu.learned_calls += 1
				learned_checked = {pc, l.epoch, l.fn}
			}
			return l.fn
		}
		l.epoch = 0
	}
	cpu.learned_stale += 1
	return nil
}

// wasm32: the learned code the FLAT runner would run for a call to pc,
// else nil: the in-line call routine's lookup of a call the call table
// holds no code for (recomp/r5900 WASM_CALL), which runs it in place of a
// trip through the runner. Its words are compared on every call, as the
// runner's lookup of an entry compares them (learned_ran). The cache keeps,
// for a pc, the first function learned_search looks at there, when pc is
// its entry: the search compares its words first and returns it when RAM
// holds them, whatever RAM holds elsewhere, so a hit whose words match is
// the search's answer, and the cache saves the search and not the compare.
// A hit whose words do not match goes on to the search, which looks past
// it. Spans that hold other functions whole (a function learned again with
// more of its code, or one holding a callee in-line) cover many entries,
// so the search's first function is cached, not only a sole one. The
// function as the routine calls it: its table index, 0 for none.
learned_entry :: proc(pc: u32) -> uintptr #no_bounds_check {
	c := &learned_entry_cache[pc >> 2 & (len(learned_entry_cache) - 1)]
	if pc == c.pc && c.ok {
		l := &learned_steps[c.k]
		n := len(l.words)
		cpu.learned_words += u64(n)
		if string(mem.ram[l.lo:][:4 * n]) == string(([^]u8)(raw_data(l.words))[:4 * n]) {
			l.epoch = cpu.learned_epoch
			cpu.learned_calls += 1
			return uintptr(rawptr(l.fn))
		}
	}
	// Compared now, and again at the runner's next lookup: code runs
	// between them.
	learned_ran()
	fn := learned_at(pc)
	learned_ran()
	k, ok := learned_first(pc)
	c^ = {pc, k, ok}
	return uintptr(rawptr(fn))
}

// wasm32: learned_entry's cache, by pc: the pc, and the index in
// learned_steps of the first function learned_search looks at there, ok
// when pc is its entry. Host state, made again at a load.
@(private = "file")
learned_entry_cache: [64]struct {
	pc: u32,
	k:  int,
	ok: bool,
}

// wasm32: the index of the first learned function learned_search looks at
// for pc (the one with the highest lo whose words hold pc), and whether pc
// is its entry.
@(private = "file")
learned_first :: proc(pc: u32) -> (int, bool) #no_bounds_check {
	k, _ := slice.binary_search_by(learned_steps[:], pc + 1, proc(l: Learned_Step, t: u32) -> slice.Ordering {
		return l.lo < t ? .Less : .Greater
	})
	for k -= 1; k >= 0; k -= 1 {
		l := &learned_steps[k]
		if pc - l.lo >= 4 * learned_most {break}
		if pc - l.lo < 4 * u32(len(l.words)) {return k, l.entry == pc}
	}
	return 0, false
}

// Game data's learned rows (core/gamedata.odin): each loaded function, by
// entry and lo.
@(private)
gamedata_learned_rows :: proc(rows: ^[dynamic]string) {
	recs := core.gamedata_learn()
	Fn :: struct {
		entry: u32,
		f:     ^Learned_Fn,
	}
	fns := make([dynamic]Fn, context.temp_allocator)
	when ODIN_ARCH == .wasm32 {
		for &l in learned_steps {append(&fns, Fn{l.entry, &l.f})}
	} else {
		for e, at in learned_fns {
			for &l in at {append(&fns, Fn{e, &l})}
		}
	}
	slice.sort_by(fns[:], proc(a, b: Fn) -> bool {
		return a.entry < b.entry || a.entry == b.entry && a.f.lo < b.f.lo
	})
	for x in fns {
		l := x.f
		n := len(l.words)
		h := xxhash.XXH3_64_default(slice.to_bytes(l.words))
		open := false
		for r in recs {
			if r.cpu == .Ee && r.entry == x.entry && r.lo == l.lo && len(r.words) == n && r.hash == h && .Open in r.flags {open = true; break}
		}
		append(rows, fmt.tprintf("learned\tee\t%08x\t%08x\t%d\t%016x\t%s", x.entry, l.lo, n, core.gamedata_hash(h, n), open ? "open" : "-"))
	}
}

// Game data's refused rows: each entry of learned_refused, with the
// reasons its records give, by entry.
@(private)
gamedata_refused_rows :: proc(rows: ^[dynamic]string) {
	recs := core.gamedata_learn()
	for e in learned_refused {
		why: bit_set[enum {Smc, Smc_Unknown, Large, Not_Lowered}]
		for r in recs {
			if r.cpu != .Ee || r.entry != e {continue}
			if .Smc in r.flags {why += {.Smc}}
			if .Smc_Unknown in r.flags {why += {.Smc_Unknown}}
			if .Large in r.flags {why += {.Large}}
			if r.flags & {.Smc, .Smc_Unknown, .Large} == {} {why += {.Not_Lowered}}
		}
		names := [?]string{"smc", "smc_unknown", "large", "not_lowered"}
		for w in why {append(rows, fmt.tprintf("refused\tee\t%08x\t%s", e, names[int(w)]))}
	}
}
