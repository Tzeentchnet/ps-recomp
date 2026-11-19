// Learned EE functions: native code compiled from runs the EE interpreter
// learned (recomp/r5900/learned.odin). One is never put in the call table:
// only a call the table misses looks it up (interp_call), and it runs only
// while RAM holds its words, compared on a call after a write to one of
// their pages (mem.code_pages) and skipped otherwise. Code loaded over them
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
// entry, as on a call above (a version whose compare missed is skipped,
// its pages armed too, until a write to them), and elsewhere in it only
// when they were not since cpu.learned_epoch last moved (an
// instruction-cache flush, a snapshot load): a function big enough to call
// often would compare its words again at every return.
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
	// mem.code_writes when its words were last found in RAM, its
	// pages armed then (mem.code_arm); while it is current no armed page
	// was written, so RAM holds them still. 0: not since loaded.
	clean: u32,
}

// By entry. Host state: a snapshot never holds it, and every call checks
// the words, so none needs restoring.
@(private = "file")
learned_fns: map[u32][dynamic]Learned_Fn

// learned_fns by entry, direct mapped, for learned_find: a hit skips the
// map's hash and probe. tag is entry | 1 (entries are word aligned), 0
// empty; fns is empty for an entry with none. Registration, the only
// change to learned_fns, clears it, so fns never outlives its array.
@(private = "file")
LEARNED_CACHE :: 4096
@(private = "file")
Learned_Hit :: struct {
	tag: u32,
	fns: []Learned_Fn,
}
@(private = "file")
learned_cache: [LEARNED_CACHE]Learned_Hit

// The learned function at entry whose words RAM holds now, else nil.
learned_find :: proc(entry: u32) -> cpu.Func_Proc #no_bounds_check {
	hit := &learned_cache[(entry >> 2) & (LEARNED_CACHE - 1)]
	if hit.tag != entry | 1 {
		hit^ = {entry | 1, learned_fns[entry][:]}
	}
	if len(hit.fns) == 0 {return nil}
	for &l, i in hit.fns {
		if l.clean == mem.code_writes {
			cpu.learned_calls += 1
			return l.fn
		}
		n := len(l.words)
		cpu.learned_words += u64(n)
		if string(mem.ram[l.lo:][:4 * n]) == string(([^]u8)(raw_data(l.words))[:4 * n]) {
			mem.code_arm(l.lo, 4 * u32(n))
			l.clean = mem.code_writes
			cpu.learned_calls += 1
			fn := l.fn
			// The version RAM holds goes first, so the next call takes it
			// on the clean test without comparing the others.
			if i != 0 {hit.fns[0], hit.fns[i] = hit.fns[i], hit.fns[0]}
			return fn
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
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("learned: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	return load_learned_blob(blob, path)
}

// load_learned of a blob in memory, which it does not keep; name stands
// for it in the messages. On the EE thread only: learned_find reads the
// table it adds to without a lock (play's mid-run load is at a vblank).
load_learned_blob :: proc(blob: []u8, name: string) -> bool {
	if mem.ram_base == nil {
		fmt.eprintln("learned: load_learned comes after init, which maps RAM")
		return false
	}
	code, msg := core.native_load(blob, native_imports())
	// wasm32's functions are its spans' blocks (r5900.learned_blob).
	if msg == "" && ((ODIN_ARCH != .wasm32 && len(code.funcs) != 0) || len(code.ovls) != 0) {
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
		fmt.eprintfln("learned: %s: %s", name, msg)
		if code.base != 0 {core.native_free(&code)}
		return false
	}
	when ODIN_ARCH == .wasm32 {
		learned_steps_add(&code)
	} else {
		if learned_fns == nil {
			learned_fns = make(map[u32][dynamic]Learned_Fn, core.long_allocator())
			learned_epoch_hook()
		}
		for s in code.spans {
			r := code.ranges[s.range_first]
			fns := learned_fns[s.entry]
			if fns == nil {fns = make([dynamic]Learned_Fn, core.long_allocator())}
			append(&fns, Learned_Fn{lo = r.pc, words = code.pool[r.at:][:r.n_words], fn = cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))})
			learned_fns[s.entry] = fns
		}
		learned_cache = {}
	}
	cpu.learned_loaded += len(code.spans)
	fmt.eprintfln("learned: %d EE functions from %s", len(code.spans), name)
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
	// mem.code_writes when its words last compared unequal, its pages
	// armed: while the count stays, RAM still does not hold them. 0 never.
	miss:     u32,
	// The pcs of its blocks, sorted: where the runner can enter its code
	// (r5900.learned_blob). nil from a blob without them: any pc in its
	// words.
	blocks:   []u32,
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

// Moves cpu.learned_epoch on every snapshot load, once registered: a
// load puts other code in RAM under the words compared (learned_search) and
// the verdicts kept (learned_refused_at), and under the armed pages
// (mem.code_write_all).
@(private = "file")
learned_epoch_hook :: proc() {
	@(static) on: bool
	if on {return}
	on = true
	append(&core.snap_hooks, core.Snap_Hook{save = proc(_: int) {}, load = proc(_: int) {
			cpu.learned_epoch += 1
			mem.code_write_all()
		}})
}

@(private = "file")
learned_steps_add :: proc(code: ^core.Native_Code) {
	if learned_marks == nil {
		learned_marks = make([]u64, mem.RAM_SIZE / 4 / 64, core.long_allocator())
		learned_steps = make([dynamic]Learned_Step, core.long_allocator())
		learned_epoch_hook()
	}
	// The blocks, by span offset then pc: each span's are one run.
	blocks := slice.clone(code.funcs)
	defer delete(blocks)
	slice.sort_by(blocks, proc(a, b: core.Native_Func) -> bool {return a.off < b.off || (a.off == b.off && a.addr < b.addr)})
	pcs := make([]u32, len(blocks), core.long_allocator())
	for b, k in blocks {pcs[k] = b.addr}
	for s in code.spans {
		r := code.ranges[s.range_first]
		fn := Learned_Fn{lo = r.pc, words = code.pool[r.at:][:r.n_words], fn = cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))}
		first, _ := slice.binary_search_by(blocks, s.off, proc(b: core.Native_Func, off: u32) -> slice.Ordering {return b.off < off ? .Less : .Greater})
		end := first
		for end < len(blocks) && blocks[end].off == s.off {end += 1}
		append(&learned_steps, Learned_Step{f = fn, entry = s.entry, blocks = end > first ? pcs[first:end] : nil})
		learned_most = max(learned_most, r.n_words)
		for w in r.pc / 4 ..< r.pc / 4 + r.n_words {learned_marks[w / 64] |= 1 << (w % 64)}
	}
	slice.sort_by(learned_steps[:], proc(a, b: Learned_Step) -> bool {return a.lo < b.lo})
	learned_entry_cache = {}
	learned_pc_cache = {}
	// A load mid-run (play/midload_learned.odin) may hold a function for
	// the pc last checked.
	learned_ran()
	flat_native_on = true
}

// wasm32: the learned function holding the words RAM holds at pc and
// around it now, with a block at pc, else nil (also with none loaded). The
// one starting nearest below pc first. One with no block at pc would leave
// at once with nothing run (r5900.native_func), so pc is interpreted, and
// the miss begins a run there (flat_resume).
learned_at :: #force_inline proc(pc: u32) -> cpu.Func_Proc #no_bounds_check {
	w := pc / 4
	if learned_marks == nil || pc >= mem.RAM_SIZE || pc & 3 != 0 || learned_marks[w / 64] & (1 << (w % 64)) == 0 {return nil}
	return learned_search(pc)
}

// One EE record of a blob's: its entry and the words it ran, the RAM words
// [lo, lo+4n) whose bytes hash to hash (XXH3-64, as core/learn.odin writes
// it). n is 0 when the words do not tell its code apart: a .Large record
// holds none, and code that stores into itself (.Smc, .Smc_Unknown) leaves
// other words in RAM than it ran.
Learned_Row :: struct {
	entry, lo, n: u32,
	hash:         u64,
}

// r's row (an EE record's, as core.learn_read gives it).
learned_row :: proc(r: core.Learn_Record) -> Learned_Row {
	n := r.flags & {.Smc, .Smc_Unknown, .Large} == {} ? u32(len(r.words)) : 0
	return {r.entry, r.lo, n, r.hash}
}

// An entry of the loaded blob's records that it holds no function for: the
// compiler left it to the interpreter (code stored into, too large, not
// lowered). Its rows are learned_refused_rows[first:][:count]. refused is
// whether RAM held one of their code at epoch (cpu.learned_epoch; 0 never
// checked): RAM holding other code there, a later overlay's, is code the
// compiler has not seen, so its run is recorded.
@(private = "file")
Learned_Refused :: struct {
	first, count, epoch: u32,
	refused:             bool,
}

// The entries, sorted, and each one's Learned_Refused at the same index;
// host state. Game data's refused rows name them
// (natively made only with game data on). On wasm32 the FLAT runner opens
// no LEARN run at one whose code RAM holds (interp_flat.odin): recording it
// again every run would be all cost, since the next compile refuses it
// again. Made only at load.
@(private = "file")
learned_refused: []u32
@(private = "file")
learned_refused_of: []Learned_Refused
@(private = "file")
learned_refused_rows: []Learned_Row

// Keep the rows (a blob's records', in any order, repeats too) of entries
// no loaded learned function starts at, as learned_refused.
learned_refuse :: proc(rows: []Learned_Row) {
	has := make(map[u32]struct{}, context.temp_allocator)
	when ODIN_ARCH == .wasm32 {
		for &l in learned_steps {has[l.entry] = {}}
	} else {
		for e in learned_fns {has[e] = {}}
	}
	kept := make([dynamic]Learned_Row, core.long_allocator())
	for r in rows {
		if r.entry not_in has {append(&kept, r)}
	}
	slice.sort_by(kept[:], proc(a, b: Learned_Row) -> bool {return a.entry < b.entry})
	entries := make([dynamic]u32, core.long_allocator())
	of := make([dynamic]Learned_Refused, core.long_allocator())
	for r, i in kept {
		if len(entries) == 0 || entries[len(entries) - 1] != r.entry {
			append(&entries, r.entry)
			append(&of, Learned_Refused{first = u32(i)})
		}
		of[len(of) - 1].count += 1
	}
	if len(kept) > 0 {learned_epoch_hook()}
	delete(learned_refused, core.long_allocator())
	delete(learned_refused_of, core.long_allocator())
	delete(learned_refused_rows, core.long_allocator())
	learned_refused = entries[:]
	learned_refused_of = of[:]
	learned_refused_rows = kept[:]
	fmt.eprintfln("learned: %d EE entries left to the interpreter open no LEARN run", len(learned_refused))
}

// wasm32: whether pc is an entry of learned_refused and RAM holds the code
// of one of its rows. The answer is kept until cpu.learned_epoch moves (an
// instruction-cache flush, a snapshot load), since a refused entry is
// looked up on every call: the words are hashed once per overlay load. The
// check inlines into the FLAT runner; the rehash is its own proc.
learned_refused_at :: #force_inline proc(pc: u32) -> bool {
	i, found := slice.binary_search(learned_refused, pc)
	if !found {return false}
	r := &learned_refused_of[i]
	if r.epoch == cpu.learned_epoch {return r.refused}
	return learned_refused_redo(r)
}

// Hash r's rows again under the current epoch and keep the answer.
@(private = "file")
learned_refused_redo :: #force_no_inline proc(r: ^Learned_Refused) -> bool {
	r.epoch = cpu.learned_epoch
	r.refused = false
	for row in learned_refused_rows[r.first:][:r.count] {
		if learned_row_held(row) {
			r.refused = true
			break
		}
	}
	return r.refused
}

// Whether RAM holds row's words, or they cannot be told apart (n 0, or a
// span past RAM, which keeps the entry refused as before). An n 0 row so keeps
// its entry refused under every overlay, also one whose code there is clean.
@(private = "file")
learned_row_held :: proc(row: Learned_Row) -> bool {
	span := u64(row.n) * 4
	if row.n == 0 || u64(row.lo) + span > u64(len(mem.ram)) {return true}
	return u64(xxhash.XXH3_64_default(mem.ram[row.lo:][:span])) == row.hash
}

// wasm32: the runner runs the native code it looked up last; the next
// lookup of an entry compares its words again.
learned_ran :: #force_inline proc() {learned_checked.pc = ~u32(0)}

// learned_search's cache, by pc: pc | 1 (0 for none), and the index in
// learned_steps of the first function the search looks at there, the one
// with the highest lo whose words and blocks hold pc (-1: none holds it, so the search
// finds none). A return into a function, which no single-entry check
// keeps, so takes no search while that function's words stay clean (it is
// the search's answer then, as learned_entry's cache says). Host state,
// made again at a load.
@(private = "file")
learned_pc_cache: [4096]struct {
	key: u32,
	k:   i32,
}

@(private = "file")
learned_search :: proc(pc: u32) -> cpu.Func_Proc #no_bounds_check {
	if pc == learned_checked.pc && learned_checked.epoch == cpu.learned_epoch {return learned_checked.fn}
	c := &learned_pc_cache[pc >> 2 & (len(learned_pc_cache) - 1)]
	if c.key == pc | 1 {
		if c.k < 0 {
			cpu.learned_stale += 1
			return nil
		}
		// The search's first function, its words equal at this code_writes:
		// the search returns it, and changes what it would.
		l := &learned_steps[c.k]
		if l.clean == mem.code_writes {
			l.epoch = cpu.learned_epoch
			if pc == l.entry {
				cpu.learned_calls += 1
				learned_checked = {pc, l.epoch, l.fn}
			}
			return l.fn
		}
	}
	c^ = {pc | 1, -1}
	// The first function starting above pc.
	k, _ := slice.binary_search_by(learned_steps[:], pc + 1, proc(l: Learned_Step, t: u32) -> slice.Ordering {
		return l.lo < t ? .Less : .Greater
	})
	for k -= 1; k >= 0; k -= 1 {
		l := &learned_steps[k]
		if pc - l.lo >= 4 * learned_most {break}
		n := len(l.words)
		if pc - l.lo >= 4 * u32(n) {continue}
		// No block at pc: its code would leave at once, with nothing run.
		if l.blocks != nil {
			if _, ok := slice.binary_search(l.blocks, pc); !ok {continue}
		}
		if c.k < 0 {c.k = i32(k)}
		if pc != l.entry && l.epoch == cpu.learned_epoch {return l.fn}
		if l.miss == mem.code_writes {continue}
		if l.clean != mem.code_writes {
			cpu.learned_words += u64(n)
			mem.code_arm(l.lo, 4 * u32(n))
			if string(mem.ram[l.lo:][:4 * n]) != string(([^]u8)(raw_data(l.words))[:4 * n]) {
				l.epoch = 0
				l.miss = mem.code_writes
				continue
			}
			l.clean = mem.code_writes
		}
		l.epoch = cpu.learned_epoch
		if pc == l.entry {
			cpu.learned_calls += 1
			learned_checked = {pc, l.epoch, l.fn}
		}
		return l.fn
	}
	cpu.learned_stale += 1
	return nil
}

// wasm32: the learned code the FLAT runner would run for a call to pc,
// else nil: the in-line call routine's lookup of a call the call table
// holds no code for (recomp/r5900 WASM_CALL), which runs it in place of a
// trip through the runner. The cache keeps, for a pc, the first function
// learned_search looks at there, when pc is its entry: the search returns
// it when RAM holds its words, whatever RAM holds elsewhere, so a hit that
// is clean (no write to its pages since its words last compared equal) is
// the search's answer, and takes neither the search nor a compare. Any
// other hit goes on to the search, which compares the words (learned_ran)
// and looks past it when they differ. Spans that hold other functions
// whole (a function learned again with more of its code, or one holding a
// callee in-line) cover many entries, so the search's first function is
// cached, not only a sole one. The
// function as the routine calls it: its table index, 0 for none.
learned_entry :: proc(pc: u32) -> uintptr #no_bounds_check {
	c := &learned_entry_cache[pc >> 2 & (len(learned_entry_cache) - 1)]
	if pc == c.pc && c.ok {
		l := &learned_steps[c.k]
		if l.clean == mem.code_writes {
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
learned_entry_cache: [1024]struct {
	pc: u32,
	k:  int,
	ok: bool,
}

// wasm32: the index of the first learned function learned_search looks at
// for pc (the one with the highest lo whose words and blocks hold pc), and whether pc
// is its entry.
@(private = "file")
learned_first :: proc(pc: u32) -> (int, bool) #no_bounds_check {
	k, _ := slice.binary_search_by(learned_steps[:], pc + 1, proc(l: Learned_Step, t: u32) -> slice.Ordering {
		return l.lo < t ? .Less : .Greater
	})
	for k -= 1; k >= 0; k -= 1 {
		l := &learned_steps[k]
		if pc - l.lo >= 4 * learned_most {break}
		if pc - l.lo >= 4 * u32(len(l.words)) {continue}
		if l.blocks != nil {
			if _, ok := slice.binary_search(l.blocks, pc); !ok {continue}
		}
		return k, l.entry == pc
	}
	return 0, false
}

// Game data's learned rows (core/gamedata.odin): each loaded function, by
// entry and lo. One map of the open records per write keeps it linear in
// functions and records, so the write frame does not stall.
@(private)
gamedata_learned_rows :: proc(rows: ^[dynamic]string) {
	Code :: struct {
		entry, lo: u32,
		n:         int,
		hash:      u64,
	}
	recs := core.gamedata_learn()
	open_at := make(map[Code]struct{}, context.temp_allocator)
	for r in recs {
		if r.cpu == .Ee && .Open in r.flags {open_at[{r.entry, r.lo, len(r.words), r.hash}] = {}}
	}
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
		open := Code{x.entry, l.lo, n, h} in open_at
		append(rows, fmt.tprintf("learned\tee\t%08x\t%08x\t%d\t%016x\t%s", x.entry, l.lo, n, core.gamedata_hash(h, n), open ? "open" : "-"))
	}
}

// Game data's refused rows: each entry of learned_refused, with the
// reasons its records give, by entry.
@(private)
gamedata_refused_rows :: proc(rows: ^[dynamic]string) {
	Why :: bit_set[enum {
		Smc,
		Smc_Unknown,
		Large,
		Not_Lowered,
	}]
	// Each EE entry's reasons over its records, one pass.
	whys := make(map[u32]Why, context.temp_allocator)
	for r in core.gamedata_learn() {
		if r.cpu != .Ee {continue}
		// map_entry inserts a zero set at a new key: &whys[k] does not.
		_, why, _, _ := map_entry(&whys, r.entry)
		if .Smc in r.flags {why^ += {.Smc}}
		if .Smc_Unknown in r.flags {why^ += {.Smc_Unknown}}
		if .Large in r.flags {why^ += {.Large}}
		if r.flags & {.Smc, .Smc_Unknown, .Large} == {} {why^ += {.Not_Lowered}}
	}
	for e in learned_refused {
		why := whys[e]
		names := [?]string{"smc", "smc_unknown", "large", "not_lowered"}
		for w in why {append(rows, fmt.tprintf("refused\tee\t%08x\t%s", e, names[int(w)]))}
	}
}
