#+build !linux
package main

import "core:os"

// Only the Linux lock test calls this (main.odin, under ODIN_OS == .Linux).
flock_try :: proc(f: ^os.File) -> bool {
	unimplemented("flock_try is Linux only")
}
