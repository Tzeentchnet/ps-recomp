// hook.c and settings.c's first two settings, in Odin: a hook of each kind
// on the fixture's functions, by name and by alias, with a game call, a call
// of its own and a call of the function it replaces.
package fixture

import "api:game"

@(export, link_section = ".mod_settings")
on := game.Setting{1, 0, 1, 1, "on", "Enabled"}

@(export, link_section = ".mod_settings")
rate := game.Setting{128, 0, 1024, 16, "rate", "Rate (1/256ths)"}

calls: u32

twice :: proc "contextless" (x: u32) -> u32 {return x * 2}

before :: proc "c" () {
	if on.value != 0 {calls = twice(calls) + u32(rate.value)}
}

after :: proc "c" () {
	calls += game.call(proc "c" () -> u32, game.ram_80010000)()
}

replace :: proc "c" (a: u32) -> u32 {
	return game.original(proc "c" (a: u32) -> u32)(a + calls) + game.call(proc "c" (a: u32) -> u32, game.ram_80010008)(a)
}

@(export, link_section = ".mod_hooks")
hook_before := game.Hook(type_of(before)){.Before, game.start, before}

@(export, link_section = ".mod_hooks")
hook_after := game.Hook(type_of(after)){.After, game.ov_a_80100004, after}

@(export, link_section = ".mod_hooks")
hook_replace := game.Hook(type_of(replace)){.Replace, game.b_fn, replace}
