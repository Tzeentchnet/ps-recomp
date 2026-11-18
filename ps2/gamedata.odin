// Game data's rows of the EE (core/gamedata.odin, whose header has their
// columns): learned and refused (learned.odin), call, thread and sema. No
// per-call or per-syscall path checks game data: rows read what the run
// already holds when written, and the only hooks are at thread and sema
// creation and the interpreter's call-table miss (interp_call.odin), each
// behind core.gamedata.on. A frame a rollback runs again counts again.
package ps2

import "core:fmt"
import "core:slice"

import "ps:core"
import kernel "kernel"

// Each kind's cap: rows past it are cut, the most telling kept.
GAMEDATA_LEARNED :: core.LEARN_RECORDS_MAX
GAMEDATA_REFUSED :: core.LEARN_RECORDS_MAX
GAMEDATA_CALLS :: 2048
GAMEDATA_THREADS :: 256
GAMEDATA_SEMAS :: 256

@(private = "file")
gd: struct {
	calls: map[[2]u32]u64, // by $ra at the call and target
}

// Register the rows with core, once.
@(private)
gamedata_register :: proc() {
	@(static) done: bool
	if done {return}
	done = true
	append(&core.gamedata_kinds,
		core.Gamedata_Kind{"learned", GAMEDATA_LEARNED, gamedata_learned_rows},
		core.Gamedata_Kind{"refused", GAMEDATA_REFUSED, gamedata_refused_rows},
		core.Gamedata_Kind{"call", GAMEDATA_CALLS, call_rows},
		core.Gamedata_Kind{"thread", GAMEDATA_THREADS, thread_rows},
		core.Gamedata_Kind{"sema", GAMEDATA_SEMAS, sema_rows},
	)
}

// A call to target with no function in the call table, $ra ra.
@(private)
gamedata_call :: proc(ra, target: u32) {
	if gd.calls == nil {gd.calls = make(map[[2]u32]u64, core.long_allocator())}
	gd.calls[{ra, target}] += 1
}

@(private = "file")
call_rows :: proc(rows: ^[dynamic]string) {
	Call :: struct {
		key: [2]u32,
		n:   u64,
	}
	all := make([dynamic]Call, 0, len(gd.calls), context.temp_allocator)
	for k, n in gd.calls {append(&all, Call{k, n})}
	slice.sort_by(all[:], proc(a, b: Call) -> bool {
		if a.n != b.n {return a.n > b.n}
		return a.key[1] < b.key[1] || a.key[1] == b.key[1] && a.key[0] < b.key[0]
	})
	for c in all {append(rows, fmt.tprintf("call\tee\t%08x\t%08x\t%d", c.key[0], c.key[1], c.n))}
}

@(private = "file")
thread_rows :: proc(rows: ^[dynamic]string) {
	status :: proc(t: ^kernel.Thread) -> string {
		if t == nil {return "deleted"}
		#partial switch t.status {
		case .Run: return "run"
		case .Ready: return "ready"
		case .Wait: return "wait"
		case .Suspend: return "suspend"
		case .Wait_Suspend: return "wait_suspend"
		case .Dormant: return "dormant"
		}
		return "?"
	}
	for &g in kernel.gamedata_threads {
		append(rows, fmt.tprintf("thread\t%d\t%08x\t%d\t%d\t%s", g.id, g.entry, g.prio, g.stack_size, status(kernel.gamedata_thread_live(&g))))
	}
}

@(private = "file")
sema_rows :: proc(rows: ^[dynamic]string) {
	for &g in kernel.gamedata_semas {
		if s := kernel.gamedata_sema_live(&g); s != nil {
			append(rows, fmt.tprintf("sema\t%d\t%d\t%d\tlive\t%d\t%d", g.id, g.init, g.max, s.count, s.waiters))
		} else {
			append(rows, fmt.tprintf("sema\t%d\t%d\t%d\tdeleted\t0\t0", g.id, g.init, g.max))
		}
	}
}
