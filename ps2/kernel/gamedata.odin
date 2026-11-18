// Game data (core/gamedata.odin): the threads and semaphores the run
// created, as create recorded them, for ps2/gamedata.odin's thread and
// sema rows. Kept only with game data on (core.gamedata.on), the create
// hooks behind that check; nothing past creation counts. Host state: no
// snapshot holds it, and a frame a rollback runs again records again.
package ps2_kernel

import "ps:core"

Gamedata_Thread :: struct {
	id:         i32,
	prio:       i32, // initial
	entry:      u32,
	stack_size: u32,
}

Gamedata_Sema :: struct {
	id, init, max: i32,
}

// In creation order; the main thread first.
gamedata_threads: [dynamic]Gamedata_Thread
gamedata_semas: [dynamic]Gamedata_Sema
// By id, the index of its latest in them plus 1; 0 for none.
@(private = "file")
thread_at: [len(k.threads)]int
@(private = "file")
sema_at: [len(k.semas)]int

@(private)
gamedata_thread_new :: proc(t: ^Thread) {
	if gamedata_threads == nil {gamedata_threads = make([dynamic]Gamedata_Thread, core.long_allocator())}
	append(&gamedata_threads, Gamedata_Thread{id = t.id, prio = t.init_prio, entry = t.entry, stack_size = t.stack_size})
	thread_at[t.id] = len(gamedata_threads)
}

// The thread of id's record, nil for none.
@(private = "file")
gamedata_thread :: proc(id: i32) -> ^Gamedata_Thread {
	if id < 0 || int(id) >= len(thread_at) || thread_at[id] == 0 {return nil}
	return &gamedata_threads[thread_at[id] - 1]
}

// Whether g is the record of the thread now at its id.
gamedata_thread_live :: proc(g: ^Gamedata_Thread) -> ^Thread {
	if gamedata_thread(g.id) != g {return nil}
	return k.threads[g.id]
}

@(private)
gamedata_sema_new :: proc(s: ^Sema) {
	if gamedata_semas == nil {gamedata_semas = make([dynamic]Gamedata_Sema, core.long_allocator())}
	append(&gamedata_semas, Gamedata_Sema{id = s.id, init = s.init, max = s.max})
	sema_at[s.id] = len(gamedata_semas)
}

// The semaphore g records, while it is the one now at its id; nil once
// deleted.
gamedata_sema_live :: proc(g: ^Gamedata_Sema) -> ^Sema {
	if g.id <= 0 || int(g.id) >= len(sema_at) || sema_at[g.id] == 0 || &gamedata_semas[sema_at[g.id] - 1] != g {return nil}
	return k.semas[g.id]
}
