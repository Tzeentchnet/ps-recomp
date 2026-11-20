// The mid-run load of the VU microprograms a PS2 run captures while it runs
// (midload.odin has the policy).
//
// With VU_CAPTURE=miss a run records the microprograms no compiled one runs
// (ps2/vu/capture.odin); the next run's conversion compiles them. Until then
// they run in the interpreter, for the whole of a first run. So while the
// game runs, once its captures have stopped growing, `play --convert-vu
// <disc image | executable> <out> <vu0> <vu1> <parent pid>` compiles the VU
// microprograms of the captures as they are, and the run loads the programs
// it has not (ps2.load_native_vus). A native build runs it in a child of
// this executable (midload_vu_native.odin); a wasm32 build, in the host's
// worker (midload_vu_wasi.odin).
//
// The conversion takes no capture lock and writes nothing to the disc
// directory. It compiles status for every program (gen.odin
// vu_status=all), so a program a later load brings never needs it kept by
// one of these. The startup blob may not keep status
// (ps2.load_native_vus), and a load that would bring a program reading
// status beside it is skipped, said once.
//
// On only for a PS2 disc with native code, capturing with VU_CAPTURE=miss
// (so never in a compat child, nor in a FLAT build but a wasm32 one),
// unless VUNATIVE=0 or MIDLOAD=0.
package play

import "core:fmt"
import "core:os"
import "core:time"
import "ps:core"
@(require) import "ps:ps2" // used only without FLAT, or in a wasm32 build
@(require) import vu "ps:ps2/vu" // used only without FLAT, or in a wasm32 build

@(private)
Midload_Vu :: struct {
	image: string,
	loads: int, // blobs that brought programs
	added: int, // programs they brought
	skips: int, // loads skipped for status
}

@(private)
mv: Midload_Vu

// Set up loading the captured programs mid-run for the disc image, given
// what play chose: the native blob ("" none) and VU_CAPTURE. False when it
// is off (the comment above), and the boot then hooks nothing.
midload_init :: proc(image, native, capture: string) -> bool {
	when core.FLAT && core.NATIVE_ARCH != core.NATIVE_ARCH_WASM32 {
		return false
	} else {
		if native == "" || capture != "miss" || compat_child() {return false}
		if core.env("VUNATIVE") == "0" || midload_off() {return false}
		if !midvu_host_init() {return false}
		job := Midload_Job {
			what    = "VU",
			noun    = "conversion",
			grown   = vu.vu_capture_records,
			start   = midvu_host_start,
			poll    = midvu_host_poll,
			stop    = midvu_host_stop,
			cleanup = midvu_host_cleanup,
			report  = midload_vu_report,
		}
		if !midload_begin(job) {return false}
		mv = {image = image}
		return true
	}
}

@(private = "file")
midload_vu_report :: proc(fails: int) {
	fmt.eprintfln("play: mid-run VU loads: %d (%d microprograms), %d skipped for status, %d failed", mv.loads, mv.added, mv.skips, fails)
}

// The VU capture files that exist, VU0's then VU1's ("" for none).
@(private)
midload_vu_captures :: proc() -> (caps: [2]string) {
	for &c, unit in caps {
		c = core.env(fmt.tprintf("VU%d_CAPTURE", unit))
		if !os.exists(c) {c = ""}
	}
	return
}

// Load the blob of a conversion that succeeded (name, its name in a
// message); start: when the blob was in hand, for the time on this thread.
@(private)
midload_vu_take :: proc(blob: []u8, name: string, start: time.Tick) -> Midload_Poll {
	when core.FLAT && core.NATIVE_ARCH != core.NATIVE_ARCH_WASM32 {
		return .Lost
	} else {
		added, known, skipped, ok := ps2.load_native_vus(blob, name)
		switch {
		case !ok:
		case skipped:
			if mv.skips == 0 {
				fmt.eprintln("play: mid-run VU load skipped: a new program reads status, which the stored blob's VU1 code may not keep; the next run's conversion has it")
			}
			mv.skips += 1
		case added > 0:
			mv.loads += 1
			mv.added += added
			fmt.eprintfln("play: mid-run VU load: %d microprograms (%d already loaded), %.1f ms", added, known, time.duration_milliseconds(time.tick_since(start)))
		}
		return .Done
	}
}
