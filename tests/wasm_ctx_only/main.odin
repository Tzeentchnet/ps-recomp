// A wasm32 function's type follows the Asm.ctx_only it began with, not the
// one set when it is laid out: the layout comes at the next func_begin or at
// finish, after a caller (recomp/vu native_program) may have changed the
// flag for the next function. Two functions each way, laid out by the
// other's func_begin and by finish: (ctx) has one i32 parameter, (pc, ctx)
// two.
package wasm_ctx_only

import "core:fmt"
import "core:os"
import "ps:recomp/native"

main :: proc() {
	a := native.make_asm(.Wasm32)
	flags := [4]bool{true, false, false, true}
	for f in flags {
		a.ctx_only = f
		native.func_begin(&a, "cpu.state")
		native.func_end(&a)
	}
	a.ctx_only = false
	native.finish(&a)
	failed := 0
	for f, k in flags {
		want := 1 if f else 2
		got := int(a.wa.types[a.wa.bodies[k].type].n)
		if got != want {
			fmt.eprintfln("wasm_ctx_only: function %d (ctx_only %v) has %d parameters, not %d", k, f, got, want)
			failed += 1
		}
	}
	if failed != 0 {os.exit(1)}
	fmt.println("wasm_ctx_only: 4 functions, each typed by the ctx_only it began with")
}
