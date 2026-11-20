#+build !wasi
// A native build's mid-run VU conversion (midload_vu.odin): a child of this
// executable (`play --convert-vu <disc image> <out> <vu0> <vu1> <parent
// pid>`). Its blob goes to a temporary file (ps-vu-<run pid>-*.bin),
// removed once loaded, at exit and on a fatal error (core.fatal_cleanup).
// On Linux the child dies with the run (PR_SET_PDEATHSIG) and exits at once
// if the run is already gone, and a run removes the temporary files of
// runs that ended without removing theirs (killed, or a panic).
package play

import "core:fmt"
import "core:os"
import "core:time"

// The prefix of the child's temporary blob (midload_tmp).
@(private = "file")
MIDLOAD_VU_TMP :: "ps-vu-"

@(private = "file")
mvn: struct {
	self:  string, // this executable
	child: os.Process,
	tmp:   string, // the child's blob
}

// Find this executable and remove what runs that ended left; false, after
// a message, when there is no executable to start.
@(private)
midvu_host_init :: proc() -> bool {
	self, err := os.get_executable_path(context.allocator)
	if err != nil {
		fmt.eprintln("play: mid-run VU load off, cannot find this executable:", err)
		return false
	}
	mvn.self = self
	midload_tmp_sweep(MIDLOAD_VU_TMP)
	return true
}

// Start the child converting the captures into a new temporary file.
@(private)
midvu_host_start :: proc() -> Midload_Start {
	tmp, ok := midload_tmp(MIDLOAD_VU_TMP, ".bin", "VU conversion")
	if !ok {return .Not}
	mvn.tmp = tmp
	caps := midload_vu_captures()
	ppid := fmt.tprint(os.get_pid())
	err: os.Error
	mvn.child, err = os.process_start({command = {mvn.self, "--convert-vu", mv.image, mvn.tmp, caps[0], caps[1], ppid}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintln("play: mid-run VU conversion: cannot start the child:", err)
		midvu_host_cleanup()
		return .Not
	}
	return .Started
}

// Wait up to timeout for the child, taking its blob when it has ended.
@(private)
midvu_host_poll :: proc(timeout: time.Duration) -> Midload_Poll {
	state, err := os.process_wait(mvn.child, timeout)
	switch {
	case err == nil:
		return midvu_native_take(state)
	case err == os.General_Error.Timeout:
		return .Running
	}
	fmt.eprintln("play: mid-run VU conversion: cannot wait for the child:", err)
	return .Lost
}

// Kill the child and wait for it to end; false when it cannot be waited
// for, and may still run.
@(private)
midvu_host_stop :: proc(_: bool) -> bool {
	_ = os.process_kill(mvn.child)
	if _, err := os.process_wait(mvn.child); err != nil {
		fmt.eprintln("play: mid-run VU loading off: a conversion child cannot be waited for:", err)
		return false
	}
	return true
}

@(private)
midvu_host_cleanup :: proc() {
	midload_tmp_remove(&mvn.tmp)
}

// The child has ended in state: load its blob when it succeeded.
@(private = "file")
midvu_native_take :: proc(state: os.Process_State) -> Midload_Poll {
	defer midvu_host_cleanup()
	if !state.exited || state.exit_code != 0 {
		fmt.eprintfln("play: mid-run VU conversion failed (%s)", midload_ended(state))
		return .Failed
	}
	start := time.tick_now()
	blob, err := os.read_entire_file(mvn.tmp, context.allocator)
	if err != nil {
		fmt.eprintfln("native: %s: %v", mvn.tmp, err)
		return .Done
	}
	defer delete(blob)
	return midload_vu_take(blob, mvn.tmp, start)
}
