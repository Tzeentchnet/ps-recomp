#+build !wasm32
package ps2_gs

import "core:thread"

// A band worker's thread on a native host.
@(private)
Band_Thread :: struct {
	t: ^thread.Thread,
}

// Start w's thread, running band_run(w).
@(private)
band_spawn :: proc(w: ^Band_Worker) -> bool {
	w.th.t = thread.create_and_start_with_poly_data(w, band_run)
	return w.th.t != nil
}

// Wait for w's thread, which band_run has left, to end, and free it.
@(private)
band_reap :: proc(w: ^Band_Worker) {
	thread.join(w.th.t)
	thread.destroy(w.th.t)
}
