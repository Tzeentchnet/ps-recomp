// GAMEDATA test (core/gamedata.odin).
//
// With no arguments, on files in the OS temp directory: a run's loads,
// flushes, interpreter entries, learn records and IOP modules are written
// as the schema says. A load read twice is one row of n 2; a load of fewer
// than GAMEDATA_SHORT_BYTES bytes, and a learn record of fewer than
// GAMEDATA_SHORT_WORDS words, hash 0; a flush hashes RAM over each EE load
// not flushed before, and an IOP load never; loads past GAMEDATA_LOADS
// count in end's load_other; an interp row takes the record RAM holds, else
// the one of lowest hash, and an IOP entry is an iop row; disc paths lose
// their device and version; text is cut and made of its charset; rows of a
// kind are sorted; a write before the end says running, and nothing is
// written after the end. A registered kind (core.gamedata_kinds) keeps the
// first cap rows its provider gives, sorted, and a cap row counts the cut;
// the perf row's percentiles, longest frame and over counts are those of
// the frames noted (gamedata_frame).
//
// With <gamedata.tsv> <learn file> <disc image>, a real run's file: every
// load of a named disc file hashes to the disc's bytes there (or 0 when
// short), every interp and smc row names a learn record with its hash (or
// 0 when short), every learned row names a learn record with its hash,
// every row of ps2's kinds (learned, refused, call, thread, sema) and
// the perf and cap rows have their columns, and every text field is of
// the charset and cut.
//
// Both ways, no 4 numeric words of a row in a row are 4 consecutive words
// of the game's bytes (RAM, the loads' bytes and the learn records' words)
// at any byte alignment: windows of one word repeated, or with at most one
// word not within 0x10000 of 0 (an address beside counts and -1), are left
// out as carrying nothing of the game.
package main

import "base:intrinsics"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import "ps:core/learnfile"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL gamedata: %s (line %d)", what, loc.line)
		failed += 1
	}
}

@(private = "file")
rng: u64 = 0x9e3779b97f4a7c15

@(private = "file")
fill :: proc(b: []u8) {
	for &c in b {
		rng ~= rng << 13
		rng ~= rng >> 7
		rng ~= rng << 17
		c = u8(rng >> 32)
	}
}

// The rows of a file, each its columns.
@(private = "file")
rows_of :: proc(data: string) -> [][]string {
	rows := make([dynamic][]string)
	for line in strings.split_lines(strings.trim_right(data, "\n")) {
		append(&rows, strings.split(line, "\t"))
	}
	return rows[:]
}

// The row of kind whose first columns are key.
@(private = "file")
find_row :: proc(rows: [][]string, kind: string, key: ..string) -> []string {
	next: for r in rows {
		if r[0] != kind || len(r) < len(key) + 1 {continue}
		for k, i in key {
			if r[i + 1] != k {continue next}
		}
		return r
	}
	return nil
}

@(private = "file")
hex16 :: proc(h: u64) -> string {
	return fmt.tprintf("%016x", h)
}

@(private = "file")
TEXT_SET :: " _.,:;()/%+-=?" // and ? for any other

// Whether s parses as a numeric field: its words in w (a 16-digit hash
// two, an address one, a decimal one or two).
@(private = "file")
numeric :: proc(s: string, w: ^[dynamic]u32) -> bool {
	hex := len(s) > 0
	for c in transmute([]u8)s {
		hex &&= c >= '0' && c <= '9' || c >= 'a' && c <= 'f'
	}
	if hex && (len(s) == 16 || len(s) == 8) {
		v, _ := strconv.parse_u64(s, 16)
		append(w, u32(v))
		if len(s) == 16 {append(w, u32(v >> 32))}
		return true
	}
	v, ok := strconv.parse_i64(s, 10)
	if !ok {return false}
	append(w, u32(u64(v)))
	if v >> 32 != 0 && v >> 32 != -1 {append(w, u32(u64(v) >> 32))}
	return true
}

// Check every field of rows: text of the charset and cut, and the windows
// of 4 numeric words in a row (but those carrying nothing) none of refs':
// the count of rows found in refs.
@(private = "file")
check_fields :: proc(rows: [][]string, refs: [][]u8) -> (hits: int) {
	wins := make(map[[4]u32]string)
	for r in rows {
		w := make([dynamic]u32, context.temp_allocator)
		for f in r[1:] {
			if numeric(f, &w) {continue}
			ok := len(f) <= core.GAMEDATA_TEXT
			for c in transmute([]u8)f {
				ok &&= c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.index_byte(TEXT_SET, c) >= 0
			}
			check(ok, fmt.tprintf("text field %q of a %s row", f, r[0]))
		}
		for i := 0; i + 4 <= len(w); i += 1 {
			k := [4]u32{w[i], w[i + 1], w[i + 2], w[i + 3]}
			same := k[0] == k[1] && k[1] == k[2] && k[2] == k[3]
			big := 0
			for x in k {big += int(x >= 0x10000 && x < 0xffff0000)}
			if !same && big >= 2 {wins[k] = strings.join(r, " ")}
		}
	}
	for ref in refs {
		for i := 0; i + 16 <= len(ref); i += 1 {
			k := intrinsics.unaligned_load((^[4]u32)(&ref[i]))
			if row, hit := wins[k]; hit {
				fmt.eprintfln("gamedata: fields of row %q are game bytes: %08x at %d of a %d-byte ref", row, k, i, len(ref))
				delete_key(&wins, k)
				hits += 1
			}
		}
	}
	return
}

@(private = "file")
record :: proc(b: ^[dynamic]u8, cpu: learnfile.Learn_Cpu, flags: learnfile.Learn_Flags, entry, lo: u32, words: []u32) -> u64 {
	empty: [1]u8
	bytes := len(words) > 0 ? slice.to_bytes(words) : empty[:0] // XXH3 takes no nil
	h: [learnfile.LEARN_HEADER]u8
	hash := xxhash.XXH3_64_default(bytes)
	learnfile.learn_header(h[:], cpu, flags, entry, lo, u32(len(words)), hash)
	append(b, ..h[:])
	append(b, ..bytes)
	return hash
}

@(private = "file")
synthetic :: proc() {
	check(core.gamedata_text(strings.repeat("a", 200, context.temp_allocator)) == strings.repeat("a", core.GAMEDATA_TEXT, context.temp_allocator), "text cut")
	check(core.gamedata_text("a\tb\xc3\xa9(1/2)=x%") == "a?b??(1/2)=x%", "text charset")
	check(core.gamedata_disc_path("cdrom0:\\DATA\\A.BIN;1") == "/DATA/A.BIN", "disc path")
	check(core.gamedata_disc_path("lsn:0000abcd") == "lsn:0000abcd", "lsn path")
	check(core.gamedata_disc_path("A.BIN") == "/A.BIN", "bare path")

	tmp, err := os.make_directory_temp("", "ps_gamedata_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL gamedata: no temp directory:", err)
		failed += 1
		return
	}
	defer os.remove_all(tmp)
	path, _ := filepath.join({tmp, "gamedata.tsv"}, context.allocator)
	learn, _ := filepath.join({tmp, "learn.bin"}, context.allocator)

	RAM :: 2 << 20
	ram := make([]u8, RAM)
	fill(ram)
	ram_words := slice.reinterpret([]u32, ram)
	other := make([]u32, 8)
	fill(slice.to_bytes(other))
	b2 := make([]u32, 8)
	fill(slice.to_bytes(b2))
	b3 := make([]u32, 8)
	fill(slice.to_bytes(b3))
	short := []u32{1, 2, 3}
	smc := make([]u32, 5)
	fill(slice.to_bytes(smc))
	iop := make([]u32, 4)
	fill(slice.to_bytes(iop))

	lf := make([dynamic]u8)
	held := record(&lf, .Ee, {}, 0x100000, 0x100000, ram_words[0x100000 / 4:][:8])
	record(&lf, .Ee, {}, 0x100000, 0x100000, other)
	hb2 := record(&lf, .Ee, {}, 0x180000, 0x180000, b2)
	hb3 := record(&lf, .Ee, {}, 0x180000, 0x180000, b3)
	record(&lf, .Ee, {}, 0x200000, 0x200000, short)
	hsmc := record(&lf, .Ee, {.Smc}, 0x300000, 0x2fff00, smc)
	record(&lf, .Ee, {.Smc_Unknown, .Large}, 0x310000, 0x310000, nil)
	hiop := record(&lf, .Iop, {}, 0x1000, 0x1000, iop)
	check(os.write_entire_file(learn, lf[:]) == nil, "learn file written")

	cycles: u64
	core.compat_init("ps2", &cycles, 1)
	core.compat_vblank(1, true, ram)
	core.gamedata_init(path, learn, "TEST.0123", "SLUS-0000\x01")
	for pc in ([]u32{0x100000, 0x100000, 0x180000, 0x200000, 0x400000}) {core.compat_entry(pc)}
	core.compat_entry(0x1000, .Iop)

	core.vblank = 3
	d1 := make([]u8, 128)
	fill(d1)
	d2 := make([]u8, 10)
	fill(d2)
	d3 := make([]u8, 64)
	fill(d3)
	di := make([]u8, 100)
	fill(di)
	core.gamedata_load(.Ee, "cdrom0:\\DATA\\A.BIN;1", 0, 0x1000, d1)
	core.gamedata_load(.Ee, "cdrom0:\\DATA\\A.BIN;1", 0, 0x1000, d1)
	core.gamedata_load(.Ee, "cdrom0:\\B.BIN;1", 2048, 0x2000, d2)
	core.gamedata_load(.Iop, "lsn:00001234", 0, 0x3000, di)
	copy(ram[0x1000:], d1)
	ram[0x1000] ~= 0xff // unpacked in place before the flush
	core.vblank = 7
	core.gamedata_flush(ram)
	flushed := xxhash.XXH3_64_default(ram[0x1000:][:128])
	core.vblank = 9
	core.gamedata_load(.Ee, "cdrom0:\\C.BIN;1", 0, 0x4000, d3)
	copy(ram[0x4000:], d3)
	core.vblank = 11
	core.gamedata_flush(ram)
	small := make([]u8, 16)
	loads := make([dynamic][]u8)
	for i in 0 ..< core.GAMEDATA_LOADS + 5 {
		fill(small)
		core.gamedata_load(.Ee, "cdrom0:\\D.BIN;1", 0, u32(0x10000 + i * 16), small)
		append(&loads, slice.clone(small))
	}
	core.gamedata_irx("LIB\tSD", 0x40000, 0x100, 0x1234)
	core.gamedata_irx("LIB\tSD", 0x40000, 0x100, 0x1234)
	append(&core.gamedata_kinds, core.Gamedata_Kind{"test", 2, proc(rows: ^[dynamic]string) {
		append(rows, "test\t00200000\ta\t1\t9\t5", "test\t00100000\tb\t2\t7\t3", "test\t00300000\tc\t3\t0\t0")
	}})
	// 8 frames of 4.95 ms, then 20, 150 and 400 ms: p50 to its 100 us
	// bucket's top, p95 the longest.
	for ms, i in ([]f64{4.95, 4.95, 4.95, 4.95, 4.95, 4.95, 4.95, 4.95, 20, 150, 400}) {core.gamedata_frame(u64(100 + i), ms)}

	core.gamedata_vblank(core.GAMEDATA_EVERY)
	data, rerr := os.read_entire_file(path, context.allocator)
	check(rerr == nil, "written every GAMEDATA_EVERY vblanks")
	rows := rows_of(string(data))
	end := find_row(rows, "end")
	check(end != nil && end[1] == "running", "a write before the end is running")

	core.gamedata_write("boom\n")
	data, rerr = os.read_entire_file(path, context.allocator)
	check(rerr == nil, "written at the end")
	rows = rows_of(string(data))
	check(rows[0][0] == "gamedata" && rows[0][1] == fmt.tprint(core.GAMEDATA_VERSION), "version row first")
	id := find_row(rows, "id")
	check(id != nil && id[1] == "TEST.0123" && id[2] == "SLUS-0000?" && id[3] == "ps2" && id[5] == "0" && id[6] == hex16(0) && id[7] == "11", "id row")
	host := find_row(rows, "host")
	check(host != nil && len(host) == 3, "host row: arch and cores only")
	r := find_row(rows, "load", "ee", "/DATA/A.BIN", "0", "128", "00001000")
	check(r != nil && r[6] == "2" && r[7] == "3" && r[8] == hex16(xxhash.XXH3_64_default(d1)) && r[9] == "7" && r[10] == hex16(flushed), "a load read twice, flushed")
	r = find_row(rows, "load", "ee", "/B.BIN", "2048", "10", "00002000")
	check(r != nil && r[8] == hex16(0) && r[9] == "7" && r[10] == hex16(0), "a short load hashes 0")
	r = find_row(rows, "load", "iop", "lsn:00001234", "0", "100", "00003000")
	check(r != nil && r[8] == hex16(xxhash.XXH3_64_default(di)) && r[9] == "0" && r[10] == hex16(0), "an IOP load is never flushed")
	r = find_row(rows, "load", "ee", "/C.BIN", "0", "64", "00004000")
	check(r != nil && r[7] == "9" && r[9] == "11" && r[10] == hex16(xxhash.XXH3_64_default(d3)), "a later load flushed by a later flush")
	n := 0
	for row in rows {
		if row[0] == "load" {n += 1}
	}
	check(n == core.GAMEDATA_LOADS, "load rows capped")
	check(end_field(rows, 8) == "9", "loads past the cap counted")
	check(end_field(rows, 13) == "boom?", "fatal as text")
	check(end_field(rows, 1) != "running", "the end's result")

	r = find_row(rows, "interp", "ee", "00100000")
	check(r != nil && r[3] == "2" && r[4] == "00100000" && r[5] == "8" && r[6] == hex16(held) && r[7] == "2", "interp takes the record RAM holds")
	r = find_row(rows, "interp", "ee", "00180000")
	check(r != nil && r[3] == "1" && r[6] == hex16(min(hb2, hb3)) && r[7] == "2", "else the lowest hash")
	r = find_row(rows, "interp", "ee", "00200000")
	check(r != nil && r[5] == "3" && r[6] == hex16(0) && r[7] == "1", "a short record hashes 0")
	r = find_row(rows, "interp", "ee", "00400000")
	check(r != nil && r[4] == "00000000" && r[5] == "0" && r[6] == hex16(0) && r[7] == "0", "no record")
	r = find_row(rows, "interp", "iop", "00001000")
	check(r != nil && r[3] == "1" && r[6] == hex16(hiop), "an IOP entry")
	r = find_row(rows, "smc", "ee", "00300000", "002fff00", "5")
	check(r != nil && r[5] == hex16(hsmc) && r[6] == "smc", "smc row")
	r = find_row(rows, "smc", "ee", "00310000", "00310000", "0")
	check(r != nil && r[5] == hex16(0) && r[6] == "smc_unknown,large", "smc_unknown and large row")
	n = 0
	for row in rows {
		if row[0] == "irx" {n += 1}
	}
	r = find_row(rows, "irx", "LIB?SD", "00040000", "00000100", hex16(0x1234))
	check(r != nil && n == 1, "irx row once")
	n = 0
	for row in rows {
		if row[0] == "test" {n += 1}
	}
	check(n == 2 && find_row(rows, "test", "00100000", "b") != nil && find_row(rows, "test", "00200000", "a") != nil, "a registered kind keeps its first cap rows")
	r = find_row(rows, "cap", "test")
	check(r != nil && r[2] == "2" && r[3] == "3", "a cap row counts the cut")
	r = find_row(rows, "perf")
	check(r != nil && strings.join(r[1:], " ") == "11 5000 400000 400000 110 3 2 1", fmt.tprintf("perf row %v", r))
	for i in 1 ..< len(rows) {
		if rows[i][0] == rows[i - 1][0] {
			check(strings.join(rows[i - 1], "\t") <= strings.join(rows[i], "\t"), fmt.tprintf("%s rows sorted", rows[i][0]))
		}
	}

	core.gamedata_load(.Ee, "cdrom0:\\E.BIN;1", 0, 0x5000, d1)
	core.gamedata_write("")
	again, _ := os.read_entire_file(path, context.allocator)
	check(string(again) == string(data), "nothing written after the end")

	refs := make([dynamic][]u8)
	append(&refs, ram, d1, d2, d3, di, slice.to_bytes(other), slice.to_bytes(b2), slice.to_bytes(b3), slice.to_bytes(smc), slice.to_bytes(iop))
	append(&refs, ..loads[:])
	check(check_fields(rows, refs[:]) == 0, "no field is game bytes")
	rw := ram_words[0x100000 / 4:]
	leak := []string{"interp", "ee", fmt.tprintf("%08x", rw[0]), fmt.tprintf("%08x", rw[1]), fmt.tprintf("%08x%08x", rw[3], rw[2])}
	check(check_fields({leak}, refs[:]) == 1, "a row of 4 RAM words is found")
}

@(private = "file")
end_field :: proc(rows: [][]string, i: int) -> string {
	r := find_row(rows, "end")
	return r != nil && i < len(r) ? r[i] : "<none>"
}

// The columns of ps2's kinds and of perf and cap, the kind's own counted.
@(private = "file")
columns :: proc(kind: string) -> (int, bool) {
	switch kind {
	case "learned": return 7, true
	case "perf": return 9, true
	case "refused", "cap": return 4, true
	case "call": return 5, true
	case "thread": return 6, true
	case "sema": return 7, true
	}
	return 0, false
}

@(private = "file")
real :: proc(tsv, learn, image: string) {
	data, err := os.read_entire_file(tsv, context.allocator)
	if err != nil {
		fmt.eprintln("FAIL gamedata: cannot read", tsv, err)
		failed += 1
		return
	}
	lb, lerr := os.read_entire_file(learn, context.allocator)
	check(lerr == nil, "learn file read")
	recs, _ := learnfile.learn_read(lb)
	d, ok := disc.open(image)
	if !ok {
		fmt.eprintln("FAIL gamedata: cannot open", image)
		failed += 1
		return
	}
	rows := rows_of(string(data))
	refs := make([dynamic][]u8)
	for r in recs {append(&refs, slice.to_bytes(r.words))}
	num :: proc(s: string, base := 10) -> u64 {
		v, _ := strconv.parse_u64(s, base)
		return v
	}
	named, matched := 0, 0
	counts := make(map[string]int)
	for r in rows {
		line := strings.join(r, " ")
		switch r[0] {
		case "load":
			off, n := num(r[3]), int(num(r[4]))
			if n < core.GAMEDATA_SHORT_BYTES {
				check(r[8] == hex16(0) && r[10] == hex16(0), fmt.tprintf("short load hashes 0: %s", line))
			}
			if strings.has_prefix(r[2], "lsn:") {continue}
			named += 1
			e, found := disc.find(&d, r[2])
			if !found {e, found = disc.find(&d, r[2], layer = 1)}
			check(found, fmt.tprintf("load of a file on the disc: %s", line))
			if !found {continue}
			buf := make([]u8, n)
			got := disc.read_at(&d, e.lba, i64(off), buf)
			want := n < core.GAMEDATA_SHORT_BYTES ? 0 : xxhash.XXH3_64_default(buf)
			check(got == n && r[8] == hex16(want), fmt.tprintf("load hashes the disc's bytes: %s", line))
			if got == n && r[8] == hex16(want) {matched += 1}
			append(&refs, buf)
		case "interp", "smc":
			cpu: learnfile.Learn_Cpu = r[1] == "iop" ? .Iop : r[1] == "psx" ? .Psx : .Ee
			entry := u32(num(r[2], 16))
			lo, words, hash := u32(num(r[3 if r[0] == "smc" else 4], 16)), int(num(r[4 if r[0] == "smc" else 5])), r[5 if r[0] == "smc" else 6]
			if r[0] == "interp" && r[7] == "0" {
				check(lo == 0 && words == 0 && hash == hex16(0), fmt.tprintf("interp row of no record: %s", line))
				continue
			}
			found, variants := false, 0
			for x in recs {
				if x.cpu != cpu || x.entry != entry {continue}
				variants += 1
				h := len(x.words) < core.GAMEDATA_SHORT_WORDS ? 0 : x.hash
				found ||= x.lo == lo && len(x.words) == words && hash == hex16(h)
			}
			check(found, fmt.tprintf("row names a learn record: %s", line))
			if r[0] == "interp" {check(int(num(r[7])) <= variants, fmt.tprintf("variants: %s", line))}
		}
		if cols, kind := columns(r[0]); kind {
			counts[r[0]] += 1
			check(len(r) == cols, fmt.tprintf("%d columns, want %d: %s", len(r), cols, line))
			if len(r) != cols {continue}
			switch r[0] {
			case "learned":
				entry, lo, words := u32(num(r[2], 16)), u32(num(r[3], 16)), int(num(r[4]))
				found := false
				for x in recs {
					h := len(x.words) < core.GAMEDATA_SHORT_WORDS ? 0 : x.hash
					found ||= x.cpu == .Ee && x.entry == entry && x.lo == lo && len(x.words) == words && r[5] == hex16(h)
				}
				check(found && (r[6] == "open" || r[6] == "-"), fmt.tprintf("learned row names a learn record: %s", line))
			case "refused":
				check(slice.contains([]string{"large", "smc", "smc_unknown", "not_lowered"}, r[3]), fmt.tprintf("refused reason: %s", line))
			case "thread":
				check(slice.contains([]string{"run", "ready", "wait", "suspend", "wait_suspend", "dormant", "deleted"}, r[5]), fmt.tprintf("thread status: %s", line))
			case "sema":
				check(r[4] == "live" || r[4] == "deleted", fmt.tprintf("sema status: %s", line))
			}
		}
	}
	for k in ([]string{"learned", "call", "thread", "sema", "perf"}) {
		check(counts[k] > 0, fmt.tprintf("no %s rows", k))
	}
	fmt.printfln("gamedata: %d rows, %d loads of named files, %d match the disc, %d learn records; learned %d refused %d call %d thread %d sema %d perf %d cap %d", len(rows), named, matched, len(recs), counts["learned"], counts["refused"], counts["call"], counts["thread"], counts["sema"], counts["perf"], counts["cap"])
	check(check_fields(rows, refs[:]) == 0, "no field is game bytes")
}

main :: proc() {
	args := os.args
	switch len(args) {
	case 1: synthetic()
	case 4: real(args[1], args[2], args[3])
	case:
		fmt.eprintln("usage: gamedata [<gamedata.tsv> <learn file> <disc image>]")
		os.exit(2)
	}
	if failed > 0 {
		fmt.eprintfln("gamedata: %d failed", failed)
		os.exit(1)
	}
	fmt.println("gamedata: ok")
}
