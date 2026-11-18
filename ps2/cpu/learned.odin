package ps2_cpu

import "core:fmt"

// Learned EE functions (ps2/learned.odin): how many are loaded, the calls
// that ran one, the words compared with RAM to choose, and the calls none
// matched (interpreted). Host state.
learned_loaded: int
learned_calls, learned_words, learned_stale: u64

// Bumped where code may have changed with no call to see it: an
// instruction-cache flush (FlushCache), a snapshot load. A wasm32 learned
// function compared since is taken as RAM holds it when the FLAT runner
// goes on inside it (ps2/learned.odin learned_at). Host state.
learned_epoch: u32 = 1

// One line on stderr, when any are loaded.
learned_print :: proc() {
	if learned_loaded == 0 {return}
	fmt.eprintfln("ee learned: %d functions, %d calls, %d words compared, %d interpreted", learned_loaded, learned_calls, learned_words, learned_stale)
}
