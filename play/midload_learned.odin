// The mid-run load of a PS1 game's learned functions, or a PS2 game's EE's
// (midload.odin has the policy).
//
// A PS1 run records the code it interprets (core/learn.odin); the next run
// compiles the records to a learned blob and runs them native
// (learned_blob). Until then that code runs in the interpreter. So while the
// game runs, once its records have stopped growing, the records no loaded
// blob was compiled from (a new body at an entry one covers among them) are
// compiled away from the play thread, and the run loads the blob that comes
// back. Where the compile runs is the host's half: a wasm32 build's host
// compiles in a worker of its own (`play --learned psx <records> <out>
// <interp>`, through the "system:ps_learn" imports: web/learn.js,
// midload_learned_wasi.odin); a native build in a child of this executable
// (`play --learned-midload <psx | ee> <records> <out> <parent pid>`,
// midload_learned_native.odin). Nothing is stored: the next run compiles its
// own set, by its own key (learned_blob), as it would have.
//
// A compile takes at most MIDLEARN_RECORDS records, so a load costs this
// thread no more than the largest measured; the rest go in another, after
// MIDLOAD_FRAMES more vblanks. A blob over the host's size is not compiled
// again until the records grow. Each load's code stays loaded (in a wasm32
// build with the wasm instance and table range it was linked into:
// psx/native): one per load, which never repeats a record, so they are
// bounded by the records.
//
// A wasm32 build's blob is for the code the snapshot's interp list
// (psx_interp) left to the interpreter. A thread switch this run makes known
// (native_switched) changes that list, and a blob compiled before it would
// run the switch's code native: one whose key (learned_set), from the
// snapshot's records and the list as it is now, is not the one it started
// with is dropped as stale. A native build leaves nothing to the interpreter
// (learned_interp), so its loads are never stale.
//
// A PS2 game's EE's go the same way, in a native build only: a wasm32 build
// records no EE runs. The EE's blob is loaded at a vblank, on the EE thread
// (ps2.Boot.vblank), the only thread that looks learned EE functions up.
// The IOP's are not loaded mid-run: the IOP runs on a thread of its own.
//
// On only in a build that runs the game's learned code and records its runs
// (play), unless MIDLOAD=0; the host has the say on whether it can compile
// (one that cannot says so once, and none starts).
package play

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "ps:core"
import "ps:recomp/native"
import psxnative "ps:psx/native"
import "ps:ps2"

// The most records one compile takes: the lod set the first measured load
// had (480 records, 14.5 ms on the play thread; bof4's 28 took 3.7 ms,
// ff7's 23 took 3.5 ms).
MIDLEARN_RECORDS :: 480

@(private)
Midload_Learned :: struct {
	cpu:     core.Learn_Cpu, // .Psx, or a PS2 game's .Ee
	dir:     string,
	records:   string, // the LEARN file
	stored:    []native.Blob_Interp, // the stored blob's interp list (psx_stored_interp)
	covered:   map[core.Learn_Key]bool, // the records a loaded blob was compiled from
	// The compile in flight: its records, as a LEARN stream, their keys,
	// the interp list it leaves out, its key and whether records were left
	// for another (its host's state: midlearn_host).
	stream:    [dynamic]u8,
	keys:      [dynamic]core.Learn_Key,
	interp:    []native.Blob_Interp,
	set:       string,
	more:      bool,
	rounds:    u64, // loads that left records for another (midlearn_grown)
	oversized: u64, // the record count when a blob was over the host's size (0 none)
	loads:     int, // blobs loaded
	recs:      int, // the records they were compiled from
	stale:     int, // blobs dropped as stale
}

@(private)
mlrn: Midload_Learned

// Set up loading cpu's learned functions of the records file records (in
// the disc directory dir) mid-run; startup: whether a stored learned blob
// was loaded at the boot, compiled from the file as it is now. False when
// it is off (the comment above), and the boot then hooks nothing for it.
midlearn_init :: proc(dir, records: string, cpu: core.Learn_Cpu, startup: bool) -> bool {
	assert(cpu == .Psx || cpu == .Ee, "play: mid-run learned loading is for the PS1 or the EE")
	if midload_off() {return false}
	when core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32 {
		if cpu != .Psx {return false}
	}
	job := Midload_Job {
		what    = "learned" if cpu == .Psx else "learned EE",
		noun    = "compile",
		grown   = midlearn_grown,
		start   = midlearn_start,
		poll    = midlearn_host_poll,
		stop    = midlearn_host_stop,
		cleanup = midlearn_cleanup,
		report  = midlearn_report,
	}
	// A wasm32 build's stored blob's interp list, read once
	// (psx_stored_interp): no compile can start without it.
	stored: []native.Blob_Interp
	when core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32 {
		ok: bool
		stored, ok = psx_stored_interp(dir, context.allocator)
		if !ok {
			fmt.eprintln("play: mid-run learned loading off: no interp list")
			return false
		}
	}
	if !midlearn_host_init() || !midload_begin(job) {
		delete(stored)
		return false
	}
	// Both live for the run; the boot frees the temporary memory they may
	// be in.
	mlrn = {
		cpu     = cpu,
		dir     = strings.clone(dir),
		records = strings.clone(records),
		stored  = stored,
	}
	if startup {
		data, err := os.read_entire_file(records, context.temp_allocator)
		if err == nil {
			recs, _ := core.learn_read(data, context.temp_allocator)
			for r in recs {
				if r.cpu == cpu {mlrn.covered[core.learn_key(r)] = true}
			}
		}
	}
	return true
}

// cpu's stored learned blob would not load (learned_failed): none of its
// records are covered.
midlearn_uncover :: proc(cpu: core.Learn_Cpu) {
	if mlrn.cpu == cpu {clear(&mlrn.covered)}
}

// What the compile leaves to the interpreter (learned_interp): in a wasm32
// build psx_interp, from the list read at init, with the known thread
// switches as they are now on it; none in a native build.
@(private = "file")
midlearn_interp :: proc() -> []native.Blob_Interp {
	when core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32 {
		return psx_interp_with(mlrn.dir, mlrn.stored)
	} else {
		return nil
	}
}

@(private = "file")
midlearn_grown :: proc() -> u64 {
	return core.learn_count(mlrn.cpu) + mlrn.rounds
}

@(private = "file")
midlearn_report :: proc(fails: int) {
	fmt.eprintfln("play: mid-run %s loads: %d (%d records), %d stale, %d failed", "learned" if mlrn.cpu == .Psx else "learned EE", mlrn.loads, mlrn.recs, mlrn.stale, fails)
}

// Start compiling the records no loaded blob covers, the first
// MIDLEARN_RECORDS of them.
@(private = "file")
midlearn_start :: proc() -> Midload_Start {
	count := core.learn_count(mlrn.cpu)
	if mlrn.oversized != 0 && count <= mlrn.oversized {return .Not}
	data, err := os.read_entire_file(mlrn.records, context.temp_allocator)
	if err != nil {
		fmt.eprintln("play: mid-run learned compile: cannot read", mlrn.records, err)
		return .Not
	}
	// Compacted, the records are in the order a load's compile has them.
	compact, _ := core.learn_compact(data)
	defer delete(compact)
	recs, _ := core.learn_read(compact, context.temp_allocator)
	kept := make([dynamic]core.Learn_Record, context.temp_allocator)
	more := false
	for r in recs {
		if r.cpu != mlrn.cpu || core.learn_key(r) in mlrn.covered {continue}
		if len(kept) == MIDLEARN_RECORDS {
			more = true
			break
		}
		append(&kept, r)
	}
	if len(kept) == 0 {return .Not}
	interp := midlearn_interp()
	set, _ := learned_set(kept[:], mlrn.cpu, interp)
	midlearn_cleanup()
	for r in kept {
		at := len(mlrn.stream)
		resize(&mlrn.stream, at + core.LEARN_HEADER + 4 * len(r.words))
		core.learn_header(mlrn.stream[at:][:core.LEARN_HEADER], r.cpu, r.flags, r.entry, r.lo, u32(len(r.words)), r.hash)
		copy(mlrn.stream[at + core.LEARN_HEADER:], ([^]u8)(raw_data(r.words))[:4 * len(r.words)])
		append(&mlrn.keys, core.learn_key(r))
	}
	mlrn.more = more
	mlrn.interp = make([]native.Blob_Interp, len(interp))
	copy(mlrn.interp, interp)
	mlrn.set = fmt.aprint(set)
	return midlearn_host_start()
}

// Load the compile's blob, unless it is stale (the comment above); start:
// when the blob was in hand, for the time on this thread.
@(private)
midlearn_take :: proc(blob: []u8, start: time.Tick) -> Midload_Poll {
	defer midlearn_cleanup()
	interp := midlearn_interp()
	when core.COMMIT == "test" {
		// MIDLEARN_STALE=1: as if a thread switch were made known while
		// the compile ran (tests/wasi).
		if core.env("MIDLEARN_STALE") == "1" {
			more := make([]native.Blob_Interp, len(interp) + 1, context.temp_allocator)
			copy(more, interp)
			more[len(interp)] = {1, 1, 1}
			interp = more
		}
	}
	recs, _ := core.learn_read(mlrn.stream[:], context.temp_allocator)
	if set, _ := learned_set(recs[:], mlrn.cpu, interp); set != mlrn.set {
		mlrn.stale += 1
		fmt.eprintln("play: mid-run learned load dropped: a thread switch made known since its compile started changes what it may run")
		return .Done
	}
	when core.COMMIT == "test" {
		// MIDLEARN_CHECK=1: the worker's blob against the same compile in
		// this process (tests/wasi).
		if core.env("MIDLEARN_CHECK") == "1" {
			here, ok := learned_compile_here(mlrn.cpu, mlrn.stream[:], mlrn.interp)
			fmt.eprintfln("play: mid-run learned check: worker blob %s (%d bytes, here %d)", "same" if ok && string(here) == string(blob) else "differs", len(blob), len(here))
			delete(here)
		}
	}
	loaded: bool
	if mlrn.cpu == .Psx {
		loaded = psxnative.load_learned_blob(blob, "the mid-run learned code")
	} else {
		loaded = ps2.load_learned_blob(blob, "the mid-run learned EE code")
	}
	if !loaded {return .Failed}
	for k in mlrn.keys {mlrn.covered[k] = true}
	if mlrn.more {mlrn.rounds += 1}
	mlrn.loads += 1
	mlrn.recs += len(recs)
	fmt.eprintfln("play: mid-run learned load: %d records, %.1f ms on this thread", len(recs), time.duration_milliseconds(time.tick_since(start)))
	return .Done
}

// Forget the compile in flight, and its host's state.
@(private)
midlearn_cleanup :: proc() {
	midlearn_host_cleanup()
	clear(&mlrn.stream)
	clear(&mlrn.keys)
	mlrn.more = false
	delete(mlrn.interp)
	mlrn.interp = nil
	delete(mlrn.set)
	mlrn.set = ""
}
