package core

// Game data: what a run learned about its game, for a player to send if
// they choose to (PS_GAMEDATA). It goes to the disc directory's
// gamedata.tsv, rewritten every GAMEDATA_EVERY vblanks and when the run
// ends, and never leaves the machine from here.
//
// It holds no bytes of the game: no instruction words, data, pictures or
// sound. Only addresses, sizes, counts, XXH3-64 hashes, disc paths and the
// names of IOP modules and unimplemented calls, every text field cut to
// GAMEDATA_TEXT characters of a small set (gamedata_text). A hash over
// fewer than GAMEDATA_SHORT_WORDS words, or of a load of fewer than
// GAMEDATA_SHORT_BYTES bytes, is written as 0: a short one could be
// reversed into the bytes it hashes.
//
// The file is TSV, one row a line, its kind the first column; addresses are
// 8 hex digits, hashes 16, counts and byte offsets and lengths decimal. Rows
// of each kind are sorted. The kinds, in file order, and their columns:
//   gamedata  version (GAMEDATA_VERSION)
//   id        disc (play's disc id), serial (SYSTEM.CNF; "" for none),
//             system, build (COMMIT), mods (count), mods_hash (run_mods),
//             frames
//   host      arch, cores (1, 2, 4, 8 or 16: the host's cores, rounded
//             down to one of those; 0 not known)
//   load      cpu (ee, iop), path, offset, len, dest, n, first (vblank),
//             hash_in (what the read put at dest), flush (the vblank of the
//             first FlushCache that invalidates the instruction cache after
//             the first such read; 0 for none, and for an IOP read) and
//             hash_flush (RAM at [dest, dest+len) then); one row for every
//             read alike in cpu, path, offset, len and dest, with n of them
//   interp    cpu (ee, iop), pc, calls (interpreter entries), then the
//             learn record of the run entered there: lo, words, hash,
//             variants (records with that entry; the one EE RAM holds now,
//             else the one of lowest hash); 0s for none
//   smc       cpu, entry, lo, words, hash, flags: learn records of code
//             that stored into itself (smc), whose stores were not all
//             checked (smc_unknown) or too large to keep (large)
//   sys       name, n, pc, ra, client: calls the HLE does not implement
//   irx       name, base, size, hash: IOP modules loaded
//   stretch   kind, from, to: the compat line's stretches
//   learned   cpu (ee), entry, lo, words, hash, flags (the learn record's
//             with that code: open, or none): the learned functions loaded,
//             by entry and lo
//   refused   cpu (ee), entry, reason: an entry of the learn records the
//             loaded learned code has no function for, as large, smc,
//             smc_unknown (core/learnfile learn_compilable) or not_lowered
//             (left to the interpreter by the compiler)
//   call      cpu (ee), ra, target, n: calls to code with no function in
//             the call table, the interpreter's, by return address ($ra at the call, 8 past a jal's
//             site) and target; most made first
//   thread    id, entry, prio (initial), stack_size, status (run, ready,
//             wait, suspend, wait_suspend, dormant, or deleted): the EE
//             threads the run created, by id and entry
//   sema      id, init, max, status (live, deleted), count, waiters (0s
//             once deleted): the EE semaphores the run created, in order
//   perf      frames, p50, p95, max (microseconds of host work, pacing left out, of
//             a presented frame; p50 and p95 to GAMEDATA_PERF_STEP_US),
//             worst (the frame of max), over_16ms, over_100ms, over_300ms
//             (frames over 16.7, 100 and 300 ms)
//   cap       kind, kept, n: a kind of row cut to its cap, kept of n
//   end       result ("running" for a write before the end), frames,
//             cycles, idle_cycles, cycles_per_insn, interp_insns,
//             interp_other, load_other, shown, lit, ram_still_since,
//             fallback (0, 1), fatal
//   verdict   reserved for the player's rating, written by the page, never
//             here
// A disc path is the game's own (`/DIR/FILE.EXT`), never a host path, or
// `lsn:<8 hex digits>` for a read of sectors no search or open named.

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

GAMEDATA_VERSION :: 2
// The load rows kept; the rest count in end's load_other.
GAMEDATA_LOADS :: 2048
GAMEDATA_SHORT_WORDS :: 4
GAMEDATA_SHORT_BYTES :: 64
GAMEDATA_TEXT :: 160
// Vblanks between writes, so a run the player closes keeps what it saw.
GAMEDATA_EVERY :: 600
// perf's buckets: a frame's work to GAMEDATA_PERF_STEP_US, up to
// GAMEDATA_PERF_BUCKETS of them, longer ones in the last.
GAMEDATA_PERF_STEP_US :: 100
GAMEDATA_PERF_BUCKETS :: 10000

// A kind of row another package keeps (ps2's learned, refused, call,
// thread, sema), written after stretch in the order registered:
// rows appends them, the most telling first. The file keeps the first cap
// and sorts them; a cap row counts the cut.
Gamedata_Kind :: struct {
	name: string,
	cap:  int,
	rows: proc(rows: ^[dynamic]string),
}

// Registered by the packages that keep them as they start (ps2.init),
// before any write.
gamedata_kinds: [dynamic]Gamedata_Kind

Gamedata_Cpu :: enum u8 {
	Ee,
	Iop,
}

@(private = "file")
GAMEDATA_CPU_NAMES :: [Gamedata_Cpu]string {
	.Ee  = "ee",
	.Iop = "iop",
}

@(private = "file")
Gamedata_Load_Key :: struct #packed {
	cpu:    Gamedata_Cpu,
	path:   u32, // index in gamedata.paths
	offset: u64,
	len:    u32,
	dest:   u32,
}

@(private = "file")
Gamedata_Load :: struct {
	n, first, hash_in: u64,
	flush, hash_flush: u64,
	flushed:           bool,
}

@(private = "file")
Gamedata_Irx :: struct {
	name:       string,
	base, size: u32,
	hash:       u64,
}

gamedata: struct {
	on:         bool,
	// The file, the learn records it reads and the run's disc id and
	// serial, set by the host (gamedata_init).
	path:       string,
	learn:      string,
	disc:       string,
	serial:     string,
	cores:      int,
	paths:      [dynamic]string,
	loads:      map[Gamedata_Load_Key]Gamedata_Load,
	load_other: u64,
	// Load rows of the EE no flush has seen yet.
	pending:    int,
	irx:        [dynamic]Gamedata_Irx,
	written:    bool,
	// The learn records last read, and the file's size then.
	learn_data: []u8,
	learn_size: i64,
	// The presented frames' work, for perf: by GAMEDATA_PERF_STEP_US
	// bucket, and the longest and its frame.
	perf:       struct {
		frames:    u64,
		buckets:   []u32,
		max_us:    u64,
		worst:     u64,
		over:      [3]u64, // 16.7, 100 and 300 ms
	},
}

// Turn game data on for a run: write it to path, reading the learn records
// at learn; disc and serial name the game.
gamedata_init :: proc(path, learn, disc, serial: string) {
	context.allocator = long_allocator()
	gamedata.on = true
	gamedata.path = strings.clone(path)
	gamedata.learn = strings.clone(learn)
	gamedata.disc = strings.clone(disc)
	gamedata.serial = strings.clone(serial)
	gamedata.cores = os.get_processor_core_count()
	if v := env("CORES"); v != "" {
		gamedata.cores, _ = strconv.parse_int(v, 10)
	}
	gamedata.loads.allocator = long_allocator()
	gamedata.paths.allocator = long_allocator()
	gamedata.irx.allocator = long_allocator()
}

// The text s as the file may hold it: at most GAMEDATA_TEXT bytes, each
// outside `A-Za-z0-9 _.,:;()/%+-=` made '?'. Temp allocated.
gamedata_text :: proc(s: string) -> string {
	b := make([]u8, min(len(s), GAMEDATA_TEXT), context.temp_allocator)
	for &c, i in b {
		c = s[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
		if !ok && strings.index_byte(" _.,:;()/%+-=", c) < 0 {c = '?'}
	}
	return string(b)
}

// A disc file's IOP name (`cdrom0:\DIR\FILE.EXT;1`) as the file holds it:
// `/DIR/FILE.EXT`. Temp allocated.
gamedata_disc_path :: proc(name: string) -> string {
	s := name
	if i := strings.index_byte(s, ':'); i >= 0 && !strings.has_prefix(s, "lsn:") {s = s[i + 1:]}
	if i := strings.last_index_byte(s, ';'); i >= 0 {s = s[:i]}
	p, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
	if !strings.has_prefix(p, "/") && !strings.has_prefix(p, "lsn:") {p = strings.concatenate({"/", p}, context.temp_allocator)}
	return gamedata_text(p)
}

// A hash the file may hold of words 32-bit words hashing to h: 0 when they
// are too few.
gamedata_hash :: #force_inline proc(h: u64, words: int) -> u64 {
	return words < GAMEDATA_SHORT_WORDS ? 0 : h
}

// Note cpu's read of data from byte offset of the disc file name (an IOP
// name, or gamedata_disc_path's `lsn:` form) into its RAM at dest.
gamedata_load :: proc(cpu: Gamedata_Cpu, name: string, offset: u64, dest: u32, data: []u8) {
	if !gamedata.on {return}
	path := gamedata_disc_path(name)
	at := -1
	for p, i in gamedata.paths {
		if p == path {at = i; break}
	}
	if at < 0 {
		append(&gamedata.paths, strings.clone(path, long_allocator()))
		at = len(gamedata.paths) - 1
	}
	key := Gamedata_Load_Key{cpu, u32(at), offset, u32(len(data)), dest}
	if r, ok := &gamedata.loads[key]; ok {
		r.n += 1
		return
	}
	if len(gamedata.loads) >= GAMEDATA_LOADS {
		gamedata.load_other += 1
		return
	}
	h: u64
	if len(data) >= GAMEDATA_SHORT_BYTES {h = xxhash.XXH3_64_default(data)}
	gamedata.loads[key] = {n = 1, first = vblank, hash_in = h}
	if cpu == .Ee {gamedata.pending += 1}
}

// Note a FlushCache that invalidates the instruction cache, with EE main
// RAM ram: each EE load row's first.
gamedata_flush :: proc(ram: []u8) {
	if !gamedata.on || gamedata.pending == 0 {return}
	for k, &r in gamedata.loads {
		if k.cpu != .Ee || r.flushed {continue}
		r.flushed, r.flush = true, vblank
		a := int(k.dest & u32(len(ram) - 1))
		if int(k.len) >= GAMEDATA_SHORT_BYTES && a + int(k.len) <= len(ram) {
			r.hash_flush = xxhash.XXH3_64_default(ram[a:][:k.len])
		}
	}
	gamedata.pending = 0
}

// Note an IOP module loaded: its name, where and its hash.
gamedata_irx :: proc(name: string, base, size: u32, hash: u64) {
	if !gamedata.on {return}
	n := gamedata_text(name)
	for m in gamedata.irx {
		if m.name == n && m.base == base && m.size == size && m.hash == hash {return}
	}
	append(&gamedata.irx, Gamedata_Irx{strings.clone(n, long_allocator()), base, size, hash})
}

// Every GAMEDATA_EVERY vblanks, the file as it stands.
gamedata_vblank :: proc(n: u64) {
	if gamedata.on && n % GAMEDATA_EVERY == 0 {gamedata_write("", false)}
}

// The learn records in gamedata.learn, read again when the file changed.
// Note a presented frame's work: frame its index, ms its host work.
gamedata_frame :: proc(frame: u64, ms: f64) {
	if !gamedata.on {return}
	p := &gamedata.perf
	if p.buckets == nil {p.buckets = make([]u32, GAMEDATA_PERF_BUCKETS, long_allocator())}
	us := u64(max(ms, 0) * 1000)
	p.buckets[min(us / GAMEDATA_PERF_STEP_US, GAMEDATA_PERF_BUCKETS - 1)] += 1
	if p.frames == 0 || us > p.max_us {p.max_us, p.worst = us, frame}
	p.frames += 1
	for lim, i in ([3]f64{1000.0 / 60, 100, 300}) {
		if ms > lim {p.over[i] += 1}
	}
}

// The learn records at gamedata_init's learn, read again when the file's
// size changed. Temp allocated, the words the cache's.
gamedata_learn :: proc() -> []Learn_Record {
	fi, err := os.stat(gamedata.learn, context.temp_allocator)
	if size := fi.size; err == nil && size != gamedata.learn_size {
		delete(gamedata.learn_data, long_allocator())
		gamedata.learn_data = nil
		if data, rerr := os.read_entire_file(gamedata.learn, long_allocator()); rerr == nil {
			gamedata.learn_data = data
		}
		gamedata.learn_size = size
	}
	recs, _ := learn_read(gamedata.learn_data, context.temp_allocator)
	return recs[:]
}

// Write the file; fatal as compat_report's, end false for a write before
// the run ends. The run's last write is its end.
gamedata_write :: proc(fatal: string, end := true) {
	if !gamedata.on || gamedata.written {return}
	gamedata.written = end
	l := compat_line(fatal)
	recs := gamedata_learn()
	b := strings.builder_make(context.temp_allocator)
	rows := make([dynamic]string, context.temp_allocator)
	put :: proc(b: ^strings.Builder, rows: ^[dynamic]string) {
		slice.sort(rows[:])
		for r in rows {
			strings.write_string(b, r)
			strings.write_byte(b, '\n')
		}
		clear(rows)
	}
	fmt.sbprintf(&b, "gamedata\t%d\n", GAMEDATA_VERSION)
	fmt.sbprintf(&b, "id\t%s\t%s\t%s\t%s\t%d\t%016x\t%d\n", gamedata_text(gamedata.disc), gamedata_text(gamedata.serial), gamedata_text(compat.system), gamedata_text(COMMIT), run_mods_n, run_mods, vblank)
	cores := 0
	for c in ([]int{16, 8, 4, 2, 1}) {
		if gamedata.cores >= c {cores = c; break}
	}
	fmt.sbprintf(&b, "host\t%s\t%d\n", NATIVE_ARCH_NAME, cores)
	cpus := GAMEDATA_CPU_NAMES
	for k, r in gamedata.loads {
		append(&rows, fmt.tprintf("load\t%s\t%s\t%d\t%d\t%08x\t%d\t%d\t%016x\t%d\t%016x", cpus[k.cpu], gamedata.paths[k.path], k.offset, k.len, k.dest, r.n, r.first, r.hash_in, r.flush, r.hash_flush))
	}
	put(&b, &rows)
	learn_cpus := [Learn_Cpu]string {
		.Psx = "psx",
		.Ee  = "ee",
		.Iop = "iop",
	}
	for s in compat.entries {
		if s.pc1 == 0 {continue}
		pc := s.pc1 - 1
		best: Learn_Record
		variants, held := 0, false
		for r in recs {
			if r.cpu != s.cpu || r.entry != pc {continue}
			variants += 1
			now := r.cpu == .Ee && gamedata_holds(r)
			if variants == 1 || now && !held || now == held && r.hash < best.hash {best, held = r, now}
		}
		append(&rows, fmt.tprintf("interp\t%s\t%08x\t%d\t%08x\t%d\t%016x\t%d", learn_cpus[s.cpu], pc, s.n, best.lo, len(best.words), gamedata_hash(best.hash, len(best.words)), variants))
	}
	put(&b, &rows)
	for r in recs {
		if r.flags & {.Smc, .Smc_Unknown, .Large} == {} {continue}
		f := make([dynamic]string, context.temp_allocator)
		if .Smc in r.flags {append(&f, "smc")}
		if .Smc_Unknown in r.flags {append(&f, "smc_unknown")}
		if .Large in r.flags {append(&f, "large")}
		row := fmt.tprintf("smc\t%s\t%08x\t%08x\t%d\t%016x\t%s", learn_cpus[r.cpu], r.entry, r.lo, len(r.words), gamedata_hash(r.hash, len(r.words)), strings.join(f[:], ",", context.temp_allocator))
		if !slice.contains(rows[:], row) {append(&rows, row)}
	}
	put(&b, &rows)
	for k, h in compat.calls {
		append(&rows, fmt.tprintf("sys\t%s\t%d\t%08x\t%08x\t%08x", gamedata_text(compat_call_name(k)), h.n, h.pc, h.ra, h.client))
	}
	put(&b, &rows)
	for m in gamedata.irx {
		append(&rows, fmt.tprintf("irx\t%s\t%08x\t%08x\t%016x", m.name, m.base, m.size, m.hash))
	}
	put(&b, &rows)
	for s in l.stretches {
		append(&rows, fmt.tprintf("stretch\t%s\t%d\t%d", s.kind, s.from, s.to))
	}
	put(&b, &rows)
	caps := make([dynamic]string, context.temp_allocator)
	for k in gamedata_kinds {
		k.rows(&rows)
		if len(rows) > k.cap {
			append(&caps, fmt.tprintf("cap\t%s\t%d\t%d", k.name, k.cap, len(rows)))
			resize(&rows, k.cap)
		}
		put(&b, &rows)
	}
	if p := gamedata.perf; p.frames > 0 {
		// The frame at rank n (1 the fastest), to its bucket's top.
		at :: proc(buckets: []u32, n: u64) -> u64 {
			seen: u64
			for c, i in buckets {
				seen += u64(c)
				if seen >= n {return u64(i + 1) * GAMEDATA_PERF_STEP_US}
			}
			return 0
		}
		p50, p95 := at(p.buckets, (p.frames + 1) / 2), at(p.buckets, (p.frames * 95 + 99) / 100)
		fmt.sbprintf(&b, "perf\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", p.frames, min(p50, p.max_us), min(p95, p.max_us), p.max_us, p.worst, p.over[0], p.over[1], p.over[2])
	}
	append(&rows, ..caps[:])
	put(&b, &rows)
	fmt.sbprintf(&b, "end\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", end ? l.result : "running", l.frames, l.cycles, l.idle_cycles, l.cycles_per_insn, l.interp_insns, l.interp_entries_other, gamedata.load_other, l.shown, l.lit, l.ram_still_since, int(l.fallback), gamedata_text(l.fatal))
	if err := write_file_atomic(gamedata.path, b.buf[:]); err != nil {
		fmt.eprintln("gamedata: cannot write", gamedata.path, err)
	}
}

// Whether EE main RAM, as of the last vblank, holds r's words at its lo.
@(private = "file")
gamedata_holds :: proc(r: Learn_Record) -> bool {
	ram := compat.ram
	if len(ram) == 0 || len(r.words) == 0 {return false}
	a := int(r.lo & u32(len(ram) - 1))
	n := len(r.words) * 4
	return a + n <= len(ram) && string(ram[a:][:n]) == string(([^]u8)(raw_data(r.words))[:n])
}
