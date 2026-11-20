// The web page's display pace (OKAMI-60 STEP 14). The page's rAF tick shows
// the newest presented slot (web/present.js); a vblank paced at NTSC's
// 16.683 ms drifts 0.017 ms a frame against a 60 Hz tick, so every ~1000
// frames the present crosses a tick edge, and timing jitter near the edge
// shows images 3 and 1 ticks apart instead of 2 and 2. On the web,
// display_pace hands the pace block the tick's own period and nudges each
// deadline toward presenting half a period after a tick, as far from both
// edges as it can be. Native builds have no tick and keep NTSC's pace.
package ps2_host

import "core:slice"
import "core:time"

when ODIN_OS == .WASI {
	foreign import sdl2 "system:SDL2"

	@(default_calling_convention = "contextless")
	foreign sdl2 {
		// Not SDL's: web/sdl.js reads the page's last rAF tick from the
		// control buffer. The count of ticks so far (0 before the first),
		// its time in microseconds on the clock time.tick_now reads in at.
		@(link_name = "SDL_PsDisplayTick")
		display_tick :: proc(at: ^i64) -> i32 ---
	}
} else {
	@(private)
	display_tick :: proc(at: ^i64) -> i32 {return 0}
}

// Period estimates: the median of the last DISPLAY_GAPS tick intervals.
@(private)
DISPLAY_GAPS :: 15
// No tick for this long (a hidden tab stops rAF): NTSC's pace again.
@(private)
DISPLAY_STALE :: 100 * time.Millisecond
// At most this much phase correction a frame: content jitter in the present
// time moves the deadline little, and the lock holds its median phase.
@(private)
DISPLAY_NUDGE :: 200 * time.Microsecond

@(private)
Display :: struct {
	count: i32, // tick count at the last change seen
	at:    i64, // and that tick's time, microseconds
	gaps:  [DISPLAY_GAPS]time.Duration,
	n:     int, // gaps seen, in all
}

@(private)
display: Display

// The deadline step for a present made at now: the display's period (60 Hz:
// one tick; 120 Hz: two) and a phase nudge, or ok false for NTSC's pace (no
// tick, a stale one, too few gaps yet, or another display rate).
@(private)
display_pace :: proc(now: time.Tick) -> (length, nudge: time.Duration, ok: bool) {
	at_us: i64
	count := display_tick(&at_us)
	if count <= 0 {return}
	if count != display.count {
		if display.count > 0 && count > display.count {
			gap := time.Duration(at_us - display.at) * time.Microsecond
			display.gaps[display.n % DISPLAY_GAPS] = gap / time.Duration(count - display.count)
			display.n += 1
		}
		display.count, display.at = count, at_us
	}
	since := time.tick_diff(time.Tick{at_us * 1000}, now)
	if since > DISPLAY_STALE || display.n < DISPLAY_GAPS {return}
	gaps := display.gaps
	slice.sort(gaps[:])
	period := gaps[DISPLAY_GAPS / 2]
	step: time.Duration
	switch {
	case period >= 16_200 * time.Microsecond && period <= 17_200 * time.Microsecond:
		step = 1
	case period >= 8_100 * time.Microsecond && period <= 8_600 * time.Microsecond:
		step = 2
	case:
		return
	}
	// The present's phase after its tick, against half a period; wrapped
	// to -period/2..period/2 (main may tick between the present and now).
	err := since %% period - period / 2
	if err > period / 2 {err -= period}
	return period * step, clamp(-err, -DISPLAY_NUDGE, DISPLAY_NUDGE), true
}
