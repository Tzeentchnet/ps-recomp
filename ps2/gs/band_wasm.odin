#+build wasm32
package ps2_gs

import "base:intrinsics"
import "base:runtime"
import "core:sync"

// A band worker's thread on wasm, which has no threads of its own: an idle
// Worker of the host's pool (web/band.js), which runs another instance of
// this module on the same shared memory, enters band_entry with its stack
// pointer at the top of stack and its TLS block (__wasm_init_tls) at the
// bottom, and sets done to 1 once band_entry has returned. A package-level
// @(thread_local) is a plain global on wasm, so band.odin uses none, and
// its workers use nothing of the runtime's that one would hold.
@(private)
Band_Thread :: struct {
	stack: []u8,
	done:  sync.Futex,
}

// Bytes of a worker's stack, and of its TLS block below the stack.
@(private)
BAND_STACK :: 1 << 20
@(private)
BAND_TLS :: 4096

foreign import ps_band "system:ps_band"

@(default_calling_convention = "c")
foreign ps_band {
	// Run band_entry(w) on an idle pool Worker, its stack pointer at
	// stack_top and its TLS at tls (tls_size bytes there), then store 1 at
	// done and notify it. false when no Worker is idle (or the host has no
	// pool).
	@(link_name = "spawn")
	band_host_spawn :: proc(w: ^Band_Worker, stack_top, tls, tls_size: uintptr, done: ^sync.Futex) -> b32 ---
}

// A pool Worker's entry (web/band.js).
@(export, link_name = "band_entry")
band_entry :: proc "c" (w: ^Band_Worker) {
	context = runtime.default_context()
	band_run(w)
}

// Start w's thread, running band_run(w).
@(private)
band_spawn :: proc(w: ^Band_Worker) -> bool {
	w.th.stack = make([]u8, BAND_TLS + BAND_STACK)
	if w.th.stack == nil {return false}
	base := uintptr(raw_data(w.th.stack))
	// TLS aligned to 64, the stack's top to 16 (the wasm C ABI).
	tls := (base + 63) &~ 63
	top := (base + BAND_TLS + BAND_STACK) &~ 15
	w.th.done = 0
	if band_host_spawn(w, top, tls, base + BAND_TLS - tls, &w.th.done) {return true}
	delete(w.th.stack)
	return false
}

// Wait for w's Worker to return from band_entry, and free its stack.
@(private)
band_reap :: proc(w: ^Band_Worker) {
	for intrinsics.atomic_load(&w.th.done) == 0 {sync.futex_wait(&w.th.done, 0)}
	delete(w.th.stack)
}
