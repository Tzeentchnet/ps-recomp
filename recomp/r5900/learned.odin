package r5900

import "../mips"
import "../native"

// A run the EE interpreter learned (core/learn.odin): entered at entry,
// its code the words from lo.
Learned :: struct {
	entry, lo: u32,
	words:     []u32,
}

// The learned runs compiled to machine code for arch: a blob
// (recomp/native/blob.odin) with no functions, an Ee span per run, valid
// while RAM holds the words at lo (ps2/learned.odin). Each run's code is
// found from its entry within its words; a branch or jump out of them (a
// path the run never took) goes through cpu.jump_unknown, and every call
// through cpu.call, so code outside the words is looked up as it is then;
// each `jr $ra` calls ps2.learned_jr before it returns (native_func).
// Two runs at one entry with other words are two spans. A run native_func
// cannot lower for arch (nil: wasm32's exact lowering), or one with a delay
// slot past its words (slot_past_words), gets no span and stays
// interpreted; skipped counts them. On wasm32 the blob's functions are
// every span's blocks, each at its span's offset: the runner enters a span
// at any of its blocks (native_func), and ps2's learned_search passes over
// a span with none at the pc. In context.allocator.
learned_blob :: proc(runs: []Learned, arch: native.Arch) -> (blob: []u8, skipped: int) {
	return learned_spans(runs, arch, arch == .Wasm32)
}

// learned_blob, with the spans' blocks as the blob's functions or not.
@(private = "file")
learned_spans :: proc(runs: []Learned, arch: native.Arch, blocks: bool) -> (blob: []u8, skipped: int) {
	a := native_asm(arch)
	spans := make([dynamic]native.Blob_Span, 0, len(runs))
	defer delete(spans)
	funcs: [dynamic]native.Blob_Func
	defer delete(funcs)
	slow: map[string]int
	defer delete(slow)
	for r in runs {
		f := learned_func(r)
		fs := slot_past_words(f) ? nil : native_func(&a, f, nil, CYCLES_PER_INSN, &slow, learned = true)
		if fs == nil {
			skipped += 1
		} else {
			ranges := make([]native.Blob_Range, 1)
			ranges[0] = {r.lo, r.words}
			append(&spans, native.Blob_Span{.Ee, r.entry, fs[0].off, ranges})
			if blocks {append(&funcs, ..fs)}
		}
		free_all(context.temp_allocator)
	}
	blob = native.make_blob(&a, funcs[:], nil, spans[:])
	for s in spans {delete(s.ranges)}
	return blob, skipped
}

// The function run r is, discovered from its entry. A run's words are all
// those between the lowest and highest pc it fetched, often other
// functions' too (a jump table's case can be a tail jump away), so a
// computed `jr` (not `$ra`) is not left to discover's Duff rule, which
// would walk and label every word of them (Okami's run at 0x01454290: 68
// words of its own in 5895, 560 KB of wasm32). Its cases are taken to lie
// in [jr + 8, the first `jr $ra` after it + 8), each one where a jump table
// can land: a leader, the word after an unconditional jump's delay slot
// (`j`, `jr`, `b`). A case elsewhere is no label and goes out through
// cpu.jump_unknown (go): interpreted, not wrong. In context.allocator.
learned_func :: proc(r: Learned) -> ^Func {
	img := mips.Image {
		base  = r.lo,
		data  = ([^]u8)(raw_data(r.words))[:4 * len(r.words)],
		entry = r.entry,
	}
	end := r.lo + 4 * u32(len(r.words))
	// The entry as an extra label turns the Duff rule off (discover).
	seeds := make([dynamic]u32, 0, 16, context.temp_allocator)
	append(&seeds, r.entry)
	f := mips.func_make(r.entry, end, r.lo)
	mips.discover(RULES, img, f, seeds[:])
	if !f.computed {return f}
	jr := end
	for pc, i in f.insns {
		if i.kind == .Jr && i.rs != 31 {jr = min(jr, pc)}
	}
	assert(jr < end)
	word := proc(r: Learned, pc: u32) -> u32 {return r.words[(pc - r.lo) / 4]}
	hi := end
	for pc := jr + 8; pc < end; pc += 4 {
		if word(r, pc) == JR_RA {
			hi = min(end, pc + 8)
			break
		}
	}
	for pc := jr + 8; pc < hi; pc += 4 {
		if ends_flow(word(r, pc - 8)) {append(&seeds, pc)}
	}
	if len(seeds) == 1 {return f}
	mips.func_free(f)
	f = mips.func_make(r.entry, end, r.lo)
	mips.discover(RULES, img, f, seeds[:])
	return f
}

// `jr $ra`.
@(private = "file")
JR_RA :: 0x03e00008

// Whether w never goes on to the word after its delay slot: `j`, `jr`, or
// `b` (`beq $0, $0`).
@(private = "file")
ends_flow :: proc(w: u32) -> bool {
	op := w >> 26
	return op == 0x02 || (op == 0 && w & 0x3f == 0x08) || w >> 16 == 0x1000
}

// Whether a delay slot f reaches is past its words: a run noted with its
// last branch or jump fetched but not the slot (a 1-word `jr $ra` record).
// lower would run no slot there, and the words checked before the code runs
// (ps2/learned.odin) leave that RAM unchecked, so the run stays interpreted.
@(private = "file")
slot_past_words :: proc(f: ^mips.Func) -> bool {
	for d in f.delay {
		if !mips.inside(f, d) {return true}
	}
	return false
}

// The mods' functions (each one run, entered at its first word) compiled to
// machine code for arch, as learned_blob, but with a jal from one to another
// a direct call (and a jal to MOD_ORIGINAL one to ps2.mod_call_original):
// their words cannot change once loaded (a store into mod
// code is fatal), so no lookup is needed to find the code standing for them.
// A function lower cannot lower gets no span and no label: calls to it go
// through cpu.call and the interpreter. skipped counts them. In
// context.allocator.
mods_blob :: proc(funcs: []Learned, arch: native.Arch) -> (blob: []u8, skipped: int) {
	// wasm32 code calls through the runner, never direct. The mods'
	// loader takes no functions (ps2/mods_native.odin): no blocks.
	if arch == .Wasm32 {return learned_spans(funcs, arch, false)}
	a := native_asm(arch)
	// A label only for what lowers, so every label is bound below.
	labels := make(map[u32]native.Label)
	defer delete(labels)
	for r in funcs {
		f := mods_func(r)
		if lower(f, CYCLES_PER_INSN, quiet = true) != nil {labels[r.entry] = native.new_label(&a)}
		free_all(context.temp_allocator)
	}
	spans := make([dynamic]native.Blob_Span, 0, len(funcs))
	defer delete(spans)
	slow: map[string]int
	defer delete(slow)
	for r in funcs {
		f := mods_func(r)
		fs := native_func(&a, f, nil, CYCLES_PER_INSN, &slow, labels, mods = true)
		assert((fs != nil) == (r.entry in labels))
		if fs == nil {
			skipped += 1
		} else {
			ranges := make([]native.Blob_Range, 1)
			ranges[0] = {r.lo, r.words}
			append(&spans, native.Blob_Span{.Ee, r.entry, fs[0].off, ranges})
		}
		free_all(context.temp_allocator)
	}
	blob = native.make_blob(&a, nil, nil, spans[:])
	for s in spans {delete(s.ranges)}
	return blob, skipped
}

// The function r is, discovered (temp allocator).
@(private = "file")
mods_func :: proc(r: Learned) -> ^Func {
	img := mips.Image {
		base  = r.lo,
		data  = ([^]u8)(raw_data(r.words))[:4 * len(r.words)],
		entry = r.entry,
	}
	f := mips.func_make(r.entry, r.lo + 4 * u32(len(r.words)), r.lo)
	mips.discover(RULES, img, f, nil)
	return f
}
