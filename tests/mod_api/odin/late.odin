// A global only Odin's startup code sets (the address of a variable inside
// a struct), which a mod does not run, read by a hook: the build fails,
// naming it.
package fixture

import "api:game"

count: u32

Counter :: struct {
	at: ^u32,
}

late := Counter{&count}

check :: proc "c" () {
	late.at^ += 1
}

@(export, link_section = ".mod_hooks")
hook := game.Hook(type_of(check)){.Before, game.start, check}
