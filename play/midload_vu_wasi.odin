#+build wasi
// A wasm32 build's mid-run VU conversion (midload_vu.odin): the host
// converts in a worker of its own (`play --convert-vu <executable> ...` in
// another instance of the same module), through the "system:ps_vu" imports
// (web/learn.js, as a mid-run learned compile's). That instance has no
// disc, as the run holds it open, so the run hands it the executable
// SYSTEM.CNF names and the capture files' bytes.
package play

import "core:fmt"
import "core:os"
import "core:time"
import "ps:core/disc"

foreign import ps_vu "system:ps_vu"

@(default_calling_convention = "contextless")
foreign ps_vu {
	// Start converting the VU microprograms of the executable exe and the
	// captures vu0 and vu1 (length 0: none) in the host's worker: the
	// conversion's generation (> 0), or -1 for a host that converts
	// nothing.
	@(link_name = "start")
	vu_host_start :: proc(exe: [^]u8, exe_len: i32, vu0: [^]u8, vu0_len: i32, vu1: [^]u8, vu1_len: i32) -> i32 ---
	// Wait up to timeout_ms for conversion gen, as ps_learn's poll
	// (midload_learned_wasi.odin): -1 still running, -2 failed, -3 over
	// the host's size; else the blob's size, copied to buf (and taken)
	// only when cap holds it.
	@(link_name = "poll")
	vu_host_poll :: proc(buf: [^]u8, cap: i32, timeout_ms: i32, gen: i32) -> i32 ---
}

@(private = "file")
VU_RUNNING :: -1
@(private = "file")
VU_FAILED :: -2
@(private = "file")
VU_OVERSIZED :: -3

// The host's conversion in flight: its generation (0 none). sent: each
// unit's capture length that conversion was given; done: the length a
// finished conversion covered, whose programs are loaded (or will not
// load).
@(private = "file")
mvw: struct {
	gen:  i32,
	sent: [2]int,
	done: [2]int,
}

// Nothing to set up: the host says at the first start whether it converts.
@(private)
midvu_host_init :: proc() -> bool {
	return true
}

// Hand the host the executable and the captures to convert; .Off for a host
// with no worker.
@(private)
midvu_host_start :: proc() -> Midload_Start {
	d, opened := disc.open(mv.image)
	if !opened {
		fmt.eprintln("play: mid-run VU conversion: cannot open", mv.image)
		return .Not
	}
	defer disc.close(&d)
	cnf, found := disc.system_cnf(&d, context.temp_allocator)
	if !found {
		fmt.eprintln("play: mid-run VU conversion: no SYSTEM.CNF in", mv.image)
		return .Not
	}
	exe, read := disc.read_file(&d, cnf.boot)
	if !read {
		fmt.eprintln("play: mid-run VU conversion: cannot read", cnf.boot)
		return .Not
	}
	defer delete(exe)
	caps: [2][]u8
	defer for c in caps {delete(c)}
	// Only what the loads before have not converted goes: a conversion of
	// the whole capture would bring every loaded program again, in a module
	// of its own, each with a table slot.
	for path, unit in midload_vu_captures() {
		if path == "" {continue}
		bytes, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintln("play: mid-run VU conversion: cannot read", path, err)
			return .Not
		}
		mvw.sent[unit] = len(bytes)
		caps[unit] = capture_delta(bytes, mvw.done[unit], unit)
	}
	mvw.gen = vu_host_start(raw_data(exe), i32(len(exe)), raw_data(caps[0]), i32(len(caps[0])), raw_data(caps[1]), i32(len(caps[1])))
	if mvw.gen <= 0 {
		fmt.eprintln("play: mid-run VU loading off: this host has no worker to convert in")
		mvw.gen = 0
		return .Off
	}
	return .Started
}

// Wait up to timeout for the host's conversion, loading its blob when it
// is done.
@(private)
midvu_host_poll :: proc(timeout: time.Duration) -> Midload_Poll {
	n := vu_host_poll(nil, 0, i32(time.duration_milliseconds(timeout)), mvw.gen)
	switch n {
	case VU_RUNNING:
		return .Running
	case VU_FAILED, 0, VU_OVERSIZED:
		fmt.eprintln("play: mid-run VU conversion failed")
		mvw.gen = 0
		return .Failed
	}
	if n < 0 {
		fmt.eprintln("play: mid-run VU conversion: the host answered", n)
		return .Lost
	}
	start := time.tick_now()
	blob := make([]u8, n)
	defer delete(blob)
	gen := mvw.gen
	mvw.gen = 0
	if vu_host_poll(raw_data(blob), n, 0, gen) != n {
		fmt.eprintln("play: mid-run VU conversion: the host's blob went away")
		return .Lost
	}
	mvw.done = mvw.sent
	return midload_vu_take(blob, "the mid-run VU blob", start)
}

// The records of a unit's capture data (ps2/vu/capture.odin) past from,
// and the image records before from that their entries need: what a
// conversion of data[:from] has not seen. Its entries compile as they would
// in the whole file, since the recompiler walks each entry on its own
// (recomp/vu capture_read). data itself when from is 0; else data is freed.
@(private = "file")
capture_delta :: proc(data: []u8, from: int, unit: int) -> []u8 {
	if from == 0 || from > len(data) {return data}
	image := unit == 0 ? 4096 : 16384 // micro memory: the format's 4 KiB for VU0, 16 KiB for VU1
	size :: proc(data: []u8, pos, image: int) -> int {
		return 9 + (data[pos] == 'I' ? image : 4)
	}
	need := make(map[u64]bool, context.temp_allocator)
	for pos := from; pos < len(data); pos += size(data, pos, image) {
		if pos + size(data, pos, image) > len(data) {break} // cut short: the converter drops it
		if data[pos] == 'E' {need[u64((^u64le)(&data[pos + 1])^)] = true}
	}
	out := make([dynamic]u8, 0, len(data) - from)
	for pos := 0; pos < from; pos += size(data, pos, image) {
		n := size(data, pos, image)
		if data[pos] == 'I' && u64((^u64le)(&data[pos + 1])^) in need {append(&out, ..data[pos:pos + n])}
	}
	append(&out, ..data[from:])
	delete(data)
	return out[:]
}

// The host's conversion cannot be stopped: it may still run, and none
// other starts.
@(private)
midvu_host_stop :: proc(quit: bool) -> bool {
	if !quit {
		fmt.eprintln("play: mid-run VU loading off: a conversion that cannot be stopped may still run")
	}
	return false
}

@(private)
midvu_host_cleanup :: proc() {
	mvw = {}
}
