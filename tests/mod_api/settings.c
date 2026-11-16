// A mod with three settings, a switch, a rate and one whose default is 0,
// read by a hook.
#include "mod_api.h"

MOD_SETTING(on, 1, 0, 1, 1, "Enabled");
MOD_SETTING(rate, 128, 0, 1024, 16, "Rate (1/256ths)");
MOD_SETTING(bias, 0, -8, 8, 1, "Bias");

unsigned seen;

static void before(void) {
	if (on.value) seen = rate.value + bias.value;
}

MOD_BEFORE(start, before);
