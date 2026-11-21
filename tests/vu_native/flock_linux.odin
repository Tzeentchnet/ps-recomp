#+build linux
package main

import "core:os"
import "core:sys/linux"

// Take f's exclusive lock without waiting; false when another holds it.
flock_try :: proc(f: ^os.File) -> bool {
	return linux.flock(linux.Fd(os.fd(f)), {.EX, .NB}) == .NONE
}
