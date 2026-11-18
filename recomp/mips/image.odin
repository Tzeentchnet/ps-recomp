package mips

import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:fmt"
import "core:strings"
import "ps:core/disc"

Section :: struct {
	name:  string,
	addr:  u32,
	size:  u32,
	data:  []u8, // nil for NOBITS
	flags: u32,
}

SHF_WRITE :: 1
SHF_ALLOC :: 2
SHF_EXEC :: 4
SHT_NOBITS :: 8

// Code and data as loaded: data[0] sits at base.
Image :: struct {
	base:     u32,
	data:     []u8,
	entry:    u32,
	// The executable's name in messages: its path, or on a disc image
	// `image:path`; "" for an overlay.
	name:     string,
	// ELF sections; none for a PS-X EXE or an overlay, which do not tell
	// code from data.
	sections: []Section,
	// The entry of the code a packed executable inflates (".unpacked",
	// load_elf); 0 when it has none.
	unpacked_entry: u32,
}

word :: proc(img: Image, addr: u32) -> (u32, bool) {
	o := i64(addr) - i64(img.base)
	if o < 0 || o + 4 > i64(len(img.data)) || addr & 3 != 0 {
		return 0, false
	}
	return u32le(img.data, int(o)), true
}

// The options for a disc image alone: the backend SYSTEM.CNF's executable
// needs (with no SYSTEM.CNF, PSX.EXE, as the PS1 BIOS boots it), machine
// code for arch (a native_arch, this host's by default) into
// <serial>.<arch>.bin (the executable's name when it has no serial) and,
// given source, Odin source there; the backends default the rest.
disc_options :: proc(image, source: string, arch := HOST_ARCH) -> Options {
	d, ok := disc.open(image)
	if !ok {
		fail("%s: not a disc image", image)
	}
	defer disc.close(&d)
	o := Options {
		path = image,
	}
	cnf, found := disc.system_cnf(&d)
	if !found {
		if _, has_cnf := disc.find(&d, "SYSTEM.CNF", context.temp_allocator); has_cnf {
			fail("%s: no SYSTEM.CNF naming the executable", image)
		}
		if _, has_exe := disc.find(&d, "PSX.EXE", context.temp_allocator); !has_exe {
			fail("%s: no SYSTEM.CNF and no PSX.EXE", image)
		}
		cnf = {boot = "PSX.EXE"}
		o.values["exe"] = cnf.boot
	}
	o.values["backend"] = cnf.ps2 ? "r5900" : "r3000"
	o.values["disc"] = image
	o.values["quiet"] = "true"
	o.values["native_arch"] = arch
	name := cnf.serial
	if name == "" {
		name = cnf.boot[strings.last_index_byte(cnf.boot, '/') + 1:]
	}
	o.values["native_out"] = fmt.aprintf("%s.%s.bin", name, arch)
	if source != "" {
		o.values["out"] = source
	}
	return o
}

// The native_arch of the machine recomp runs on: a wasm build's is wasm32,
// whose blobs only an EE (r5900) program has yet.
HOST_ARCH :: "wasm32" when ODIN_ARCH == .wasm32 else ("arm64" when ODIN_ARCH == .arm64 else ("x64_win" when ODIN_OS == .Windows else "x64_sysv"))

// The executable's bytes and its name: option `exe`, a file; or, with
// option `disc` (a .cue sheet, or a single-track .bin or .iso), the file at
// disc path `exe` on that image, by default the one SYSTEM.CNF names.
read_exe :: proc(o: Options) -> (raw: []u8, name: string) {
	image := option_or(o, "disc", "")
	if image == "" {
		name = option(o, "exe")
		return read_file(name), name
	}
	d, ok := disc.open(image)
	if !ok {
		fail("%s: not a disc image", image)
	}
	defer disc.close(&d)
	path := option_or(o, "exe", "")
	if path == "" {
		cnf, found := disc.system_cnf(&d)
		if !found {
			fail("%s: no SYSTEM.CNF naming the executable", image)
		}
		path = cnf.boot
	}
	name = fmt.aprintf("%s:%s", image, path)
	raw, ok = disc.read_file(&d, path)
	if !ok {
		fail("%s: not found", name)
	}
	return raw, name
}

// A PS-X EXE: the text segment, loaded at its address.
load_psx_exe :: proc(o: Options) -> Image {
	raw, name := read_exe(o)
	if len(raw) < 0x800 || string(raw[:8]) != "PS-X EXE" {
		fail("%s: not a PS-X EXE", name)
	}
	text, size := u32le(raw, 0x18), int(u32le(raw, 0x1c))
	return {base = text, data = raw[0x800:min(0x800 + size, len(raw))], entry = u32le(raw, 0x10), name = name}
}

// A 32-bit little-endian MIPS ELF: every allocated section in the entry's
// 16 MB of the address space in one flat view, NOBITS reading as zero. An
// executable linked low keeps out the sections at 0x01000000 and up (the
// EE's .vudata, in VU memory, and some games' extra data); one linked at
// 0x01000000 (Gran Turismo 4) has all of its sections there. in_view says
// which sections the view holds.
load_elf :: proc(o: Options) -> Image {
	raw, name := read_exe(o)
	if len(raw) < 52 || string(raw[:4]) != "\x7fELF" {
		fail("%s: not an ELF file", name)
	}
	u16le :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8}
	img: Image
	img.entry = u32le(raw, 24)
	img.name = name
	shoff := int(u32le(raw, 32))
	shentsize := int(u16le(raw, 46))
	shnum := int(u16le(raw, 48))
	shstrndx := int(u16le(raw, 50))
	str_off := int(u32le(raw, shoff + shstrndx * shentsize + 16))
	sections: [dynamic]Section
	lo, hi := u32(0xffffffff), u32(0)
	for i in 0 ..< shnum {
		h := shoff + i * shentsize
		name_off := int(u32le(raw, h))
		typ := u32le(raw, h + 4)
		flags := u32le(raw, h + 8)
		addr := u32le(raw, h + 12)
		off := int(u32le(raw, h + 16))
		size := u32le(raw, h + 20)
		if flags & SHF_ALLOC == 0 || size == 0 {
			continue
		}
		s := Section {
			name  = strings.clone_from_cstring(cstring(&raw[str_off + name_off])),
			addr  = addr,
			size  = size,
			flags = flags,
		}
		if typ != SHT_NOBITS {
			s.data = raw[off:off + int(size)]
		}
		append(&sections, s)
		if addr >> 24 == img.entry >> 24 {
			lo = min(lo, addr)
			hi = max(hi, addr + size)
		}
	}
	if u, at, ok := unpacked(sections[:], img.entry); ok {
		append(&sections, u)
		img.unpacked_entry = at
		lo = min(lo, u.addr)
		hi = max(hi, u.addr + u.size)
	}
	img.base = lo
	img.data = make([]u8, hi - lo)
	for s in sections {
		if s.data != nil && in_view(img, s) {
			copy(img.data[s.addr - lo:], s.data)
		}
	}
	img.sections = sections[:]
	return img
}

// The code a packed executable (Metal Gear Solid 3) inflates: an executable
// section that starts [u32 size][zlib stream][u32 dest][u32 entry], {dest,
// entry} right after the stream, is a stub that inflates size bytes to dest
// and jumps to entry. That code as the section ".unpacked" (writable, so its
// words count as mixed_words) and its entry. ok is false unless every check
// passes: a zlib header, a clean inflate of exactly size bytes, dest aligned
// and in RAM, entry inside the code, the code in the ELF entry's 16 MB (the
// flat view) and clear of every section.
unpacked :: proc(sections: []Section, elf_entry: u32) -> (u: Section, entry: u32, ok: bool) {
	for s in sections {
		t := s.data
		if s.flags & SHF_EXEC == 0 || len(t) < 16 || t[4] != 0x78 || (u32(t[4]) << 8 | u32(t[5])) % 31 != 0 {
			continue
		}
		size := u32le(t, 0)
		if size == 0 || size >= 0x02000000 {
			continue
		}
		buf: bytes.Buffer
		ctx := compress.Context_Memory_Input {
			input_data = t[4:],
			output     = &buf,
		}
		if zlib.inflate_from_context(&ctx, false, int(size)) != nil || bytes.buffer_length(&buf) != int(size) {
			bytes.buffer_destroy(&buf)
			continue
		}
		end := len(t) - len(ctx.input_data) - int(ctx.num_bits / 8)
		if end + 8 > len(t) {
			bytes.buffer_destroy(&buf)
			continue
		}
		dest, at := u32le(t, end), u32le(t, end + 4)
		fits := dest & 3 == 0 && u64(dest) + u64(size) <= 0x02000000 && dest <= at && at < dest + size
		fits &&= dest >> 24 == elf_entry >> 24 && (dest + size - 1) >> 24 == elf_entry >> 24
		for o in sections {
			fits &&= dest + size <= o.addr || o.addr + o.size <= dest
		}
		if !fits {
			bytes.buffer_destroy(&buf)
			continue
		}
		u = {".unpacked", dest, size, bytes.buffer_to_bytes(&buf), SHF_ALLOC | SHF_EXEC | SHF_WRITE}
		return u, at, true
	}
	return
}

// True when s is in img's flat view (load_elf's rule: the entry's 16 MB).
in_view :: proc(img: Image, s: Section) -> bool {
	return s.addr >> 24 == img.entry >> 24
}

find_section :: proc(img: Image, name: string) -> ^Section {
	for &s in img.sections {
		if s.name == name {
			return &s
		}
	}
	return nil
}
