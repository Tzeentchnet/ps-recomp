#!/bin/sh
# Build a mod's C or Odin into <mod dir>/mod.elf, against a game's mod API
# (the directory `recomp --mod-api` wrote: mod_api.h, mod.ld and, for the
# PS1, game/game.odin). The console is the one mod_api.h names:
# `#define MOD_ARCH r5900` an EE mod, none a PS1 mod.
#
#   mods/build.sh <api dir> <mod dir> [--origin <hex>]
#
# Every *.c in the mod dir is compiled, with mods/rt.c (memcpy, memset,
# memmove, memcmp, which clang may call for struct copies: they must be the
# mod's own, not the game's). Needs clang, ld.lld and llvm-nm, and for the
# EE llvm-objdump.
#
# When the mod dir has *.odin files they are one package, built with the
# API's game package as "api:game" (PS1 only; needs odin and llc too).
# Odin has no MIPS target: the package is compiled to LLVM IR for 32-bit
# ARM, little endian with 32-bit pointers as the R3000, with no runtime
# (no entry point, context or allocator), retargeted to mipsel and
# compiled with llc, and linked with --gc-sections, which drops what the
# runtime adds and the mod does not use (.mod_hooks and .mod_settings are
# kept, and what they reach). The IR is the ARM ABI's, so at the game's
# boundary (hooks, game.call) pass and return integers and pointers only,
# no struct by value. A global whose initializer Odin cannot place at link
# time is set by its startup code, which a mod does not run: the build
# fails, naming it (build.sh compiles once unoptimized to see that code).
# The string literals Odin puts in a global's link_section go to .rodata.
#
# The mod is linked at the mod region's base, or at --origin (hex, 16-byte
# aligned, in the region; mod.ld checks it): two mods loaded together must
# not overlap, so give the second its own origin.
#
# A mod must not define a name mod_api.h gives a game function or the
# runtime (mod_call_original): mod.ld's assignment would win over the mod's own definition without a word from
# ld.lld, so build.sh fails instead. Every loaded section must be one mod.ld
# places (--orphan-handling=error), so its end check covers the whole image.
#
# No -mlong-calls: a PS1 mod_api.h makes each game function long_call
# itself, as a jal from the mod region cannot reach the game's code and
# ld.lld links a wrong target without an error. The mod's own calls stay
# plain jal, and so do an EE mod's calls into the game, whose code is in
# the mod region's 256 MiB segment.
#
# An EE mod is MIPS III code for the n32 ABI (the game's integer calls),
# with single floats only, as the R5900's FPU has. The R5900 has no 64-bit
# multiply or divide, no LL/SC, no double floats and only some of MIPS
# III's float operations, so the build fails, naming the function and the
# instruction, when the linked code has another (and a source file when it
# needs the compiler's double or 64-bit float routines): use 32-bit
# operands for * / %, float, not double, and mod_f2i, not (int)f. No
# division-by-zero trap (teq): a division by zero gives what the R5900's
# does.
set -eu

usage() {
	echo "usage: mods/build.sh <api dir> <mod dir> [--origin <hex>]" >&2
	exit 2
}
[ $# -eq 2 ] || [ $# -eq 4 ] || usage
api=$1
dir=$2
origin=
if [ $# -eq 4 ]; then
	[ "$3" = --origin ] || usage
	origin=$4
	expr "$origin" : '0[xX][0-9a-fA-F]\{1,8\}$' >/dev/null || {
		echo "mods/build.sh: --origin $origin is not a hex address (0x...)" >&2
		exit 2
	}
fi
[ -f "$api/mod_api.h" ] && [ -f "$api/mod.ld" ] || {
	echo "mods/build.sh: $api has no mod_api.h and mod.ld (recomp --mod-api writes them)" >&2
	exit 1
}
odin=
for f in "$dir"/*.odin; do
	[ -f "$f" ] && odin=1
done
if grep -qx '#define MOD_ARCH r5900' "$api/mod_api.h"; then
	arch=r5900
	tools="clang ld.lld llvm-nm llvm-objdump"
	set -- --target=mips64el-elf -march=mips3 -mabi=n32 -msingle-float -mno-check-zero-division
	[ -z "$odin" ] || {
		echo "mods/build.sh: $dir has .odin files: Odin mods are PS1 only" >&2
		exit 1
	}
else
	arch=r3000
	tools="clang ld.lld llvm-nm"
	set -- --target=mipsel-elf -march=mips1 -mabi=32
fi
if [ -n "$odin" ]; then
	# llc makes soft-float code, so the R3000 gets no FPU instruction; the
	# C must have the same float ABI to link with it.
	set -- "$@" -msoft-float
	tools="$tools odin llc"
	[ -f "$api/game/game.odin" ] || {
		echo "mods/build.sh: $api has no game/game.odin (recomp --mod-api writes it)" >&2
		exit 1
	}
fi
for tool in $tools; do
	command -v $tool >/dev/null 2>&1 || {
		echo "mods/build.sh: $tool not found; install clang and lld" >&2
		exit 1
	}
done
here=$(cd "$(dirname "$0")" && pwd)
obj=$(mktemp -d)
trap 'rm -rf "$obj"' EXIT

n=0
for c in "$dir"/*.c "$here/rt.c"; do
	[ -f "$c" ] || continue
	n=$((n + 1))
	clang "$@" -mno-abicalls -fno-pic -G0 \
		-O2 -std=c17 -ffreestanding -fno-builtin -nostdlib \
		-I"$api" -c "$c" -o "$obj/$n.o"
	[ $arch = r5900 ] || continue
	soft=$(llvm-nm -u -j "$obj/$n.o" | grep -E '^__[a-z]*(sf|df)[a-z]*[0-9]*$' | head -1 || true)
	[ -z "$soft" ] || {
		echo "mods/build.sh: $(basename "$c") calls $soft, the compiler's routine for a double or a 64-bit integer to or from float, which the R5900 does not have: use float and 32-bit integers" >&2
		exit 1
	}
done
if [ -n "$odin" ]; then
	# odin_ir <-o: mode> [flag]: the package's IR in $obj/<mode>.
	odin_ir() {
		mkdir -p "$obj/$1"
		odin build "$dir" -collection:api="$api" -target:freestanding_arm32 -build-mode:llvm-ir \
			-no-entry-point -default-to-nil-allocator -no-rtti -no-thread-local \
			-o:"$1" -out:"$obj/$1" ${2:-} >&2 || exit 1
	}
	# One module per package, unoptimized: only that IR keeps a package's
	# startup code (a single module drops it, leaving the global zero).
	odin_ir none
	# Each global a package's startup code stores to; "?" when it has
	# startup code but no plain store to name.
	late=$(awk '
		/^define .*@"__\$startup_runtime\$[0-9]+"/ { on = 1; seen = 1; next }
		on && /^}/ { on = 0 }
		on && /store / && match($0, /, ptr @[^ ,]+/) {
			g = substr($0, RSTART + 7, RLENGTH - 7); gsub(/"/, "", g); print g; named = 1
		}
		END { if (seen && !named) print "?" }
	' "$obj"/none/*.ll | sort -u)
	[ -z "$late" ] || {
		for g in $late; do
			echo "mods/build.sh: global $g needs Odin's startup code, which a mod does not run, to be set: give it a constant initializer (a proc of its own type, not rawptr; no address of a variable inside a struct)" >&2
		done
		exit 1
	}
	odin_ir speed -use-single-module
	sed -e 's/^target datalayout = .*/target datalayout = "e-m:m-p:32:32-i8:8:32-i16:16:32-i64:64-n32-S64"/' \
		-e 's/^target triple = .*/target triple = "mipsel-unknown-none-elf"/' \
		-e 's/"target-cpu"="[^"]*"//g' -e 's/"target-features"="[^"]*"//g' \
		-e '/^@[^ ]* = private unnamed_addr constant \[/s/, section "[^"]*"//' \
		"$obj/speed/.ll" >"$obj/mod.ll"
	llc -O2 -mtriple=mipsel-unknown-none-elf -mcpu=mips1 -mattr=+soft-float,+noabicalls \
		-relocation-model=static -mips-ssection-threshold=0 -function-sections -data-sections \
		-filetype=obj "$obj/mod.ll" -o "$obj/odin.o"
elif [ $n -lt 2 ]; then
	echo "mods/build.sh: no .c or .odin files in $dir" >&2
	exit 1
fi
# The mod's own global names, against every name mod.ld gives an address.
LC_ALL=C
export LC_ALL
sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\) = 0x[0-9a-fA-F]*;$/\1/p' "$api/mod.ld" | sort -u >"$obj/game"
llvm-nm --defined-only -g -j "$obj"/*.o | grep -v -e '^$' -e ':$' | sort -u >"$obj/own"
clash=$(comm -12 "$obj/game" "$obj/own")
[ -z "$clash" ] || {
	for s in $clash; do
		echo "mods/build.sh: the mod defines $s, a name mod_api.h gives a game function or the runtime: rename it" >&2
	done
	exit 1
}
set -- -T "$api/mod.ld" --orphan-handling=error -o "$dir/mod.elf"
[ -z "$odin" ] || set -- "$@" --gc-sections
[ -z "$origin" ] || set -- "$@" --defsym=MOD_ORIGIN="$origin"
ld.lld "$@" "$obj"/*.o
[ $arch = r5900 ] || exit 0
# What the R5900 lacks, per function of the linked image: 64-bit multiply
# and divide, LL/SC, and every FPU instruction (a name with a dot, or with
# c1: mfc1, lwc1, bc1t ...) but the ones it has. fpu is those, as
# llvm-objdump names them for MIPS III: the decoder's (ps2/r5900) COP1,
# LWC1 and SWC1, which tests/mod_api checks this list against.
fpu='abs.s add.s bc1f bc1fl bc1t bc1tl c.eq.s c.f.s c.ole.s c.olt.s cfc1 ctc1 cvt.s.w cvt.w.s div.s lwc1 mfc1 mov.s mtc1 mul.s neg.s sqrt.s sub.s swc1'
bad=$(llvm-objdump -d --no-show-raw-insn --no-leading-addr "$dir/mod.elf" | awk -v fpu="$fpu" '
	BEGIN { n = split(fpu, f, " "); for (k = 1; k <= n; k++) ok[f[k]] = 1 }
	/^[^ \t].*>:$/ { fn = $0; sub(/^.*</, "", fn); sub(/>:$/, "", fn); next }
	/^[ \t]/ && fn != "" && $1 != "..." {
		op = $1
		if (op ~ /^(dmult|dmultu|ddiv|ddivu|ll|sc|lld|scd)$/ || ((op ~ /\./ || op ~ /c1/) && !(op in ok))) {
			print fn ": " op
		}
	}' | sort -u)
[ -z "$bad" ] || {
	echo "$bad" | while read -r f op; do
		echo "mods/build.sh: ${f%:} has $op, which the R5900 does not have (no 64-bit multiply or divide, LL/SC, double floats, or this float operation: for (int)f use mod_f2i)" >&2
	done
	rm -f "$dir/mod.elf"
	exit 1
}
