// A setting whose default is outside its range: the build fails.
#include "mod_api.h"

MOD_SETTING(level, 5, 0, 4, 1, "Level");
