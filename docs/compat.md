# Check which of your games run

`play` has a compatibility mode. It runs games without a window and
reports how far each one got:

```sh
./play-bin --compat path/to/discs [frames]
```

You can give it one disc image, or a folder. For a folder, it runs every
`.cue`, `.iso` and `.bin` file in it.

Each game runs in its own process, with no window and no speed limit. It
runs for a set number of vblanks. A vblank is the console's signal that
comes once per screen refresh. The count is the `frames` argument. Without
it, the count is `PS_FRAMES`, or else 3600.

In this mode, unknown BIOS calls and system calls are skipped, so that a
run can keep going.

Each game gets one row in `compat.tsv`, in the user data folder. The row
holds the game's latest run. It says how the run ended, how much of it
went through the interpreter, and which calls were skipped. The result is
one of these:

| Result | Meaning |
|---|---|
| `ok` | Reached the vblank count. |
| `stalled` | Reached the count, but showed no picture, or main memory stopped changing over the second half. |
| `fallback` | Reached the count and made progress, but a module on the emulated I/O processor failed to load, and the built-in stand-in took over. |
| `exit` | The game ended. |
| `fatal` | The program stopped on a fatal error. |
| `watch` | A condition in the press script was not met in time; the `fatal` column says which. |
| `crash` | The run crashed. It ended without writing its result. |
| `hang` | Stopped because no new vblank came for `PS_COMPAT_WAIT` seconds (default 120), or for 5 times that before the first vblank. A slow game that keeps going is never stopped. |
| `spawn` | The game's process could not be started. |

Each game's output goes to `compat.log`, in its `discs/<disc id>/` folder.
If a `press.txt` file is in that folder, it is used as the game's scripted
button presses (`PS_PRESS`).
`PS_SHOT=<vblank>,...` saves the picture at those vblanks on a PS2 disc;
on a PS1 disc, `PS_DUMP=<dir>` saves frames. [testing.md](testing.md) has the
details.

Each game starts on blank memory cards, so a save left by an earlier run
does not change what the game does. They are kept in `compat-cards` in the
disc's folder and emptied before each run; the disc's own `cards` are not
touched. Set `PS_COMPAT_CARDS=keep` to run on the disc's own cards
instead, as a normal run does, for example to check that a save loads.
The `cards` column says which: `fresh`, `kept`, or `kept-empty` (kept, but
the disc's cards held no files). Run one compatibility run of a disc at a
time: two at once in the same data folder share its `compat-cards`.

A PS2 run also checks whether the game still answers its controller.
Once it has been quiet for a minute (no new module loaded, and no code
run through the interpreter for the first time), it saves its state and
tries a few buttons from it, one at a time: Start, Cross, Circle, Up and
Down, each against pressing nothing. It then loads the state back and
goes on as if nothing happened. If no button changed more than 64 bytes
of main memory, the game ignored it. Two such checks in a row are listed
as a `stuck` stretch in the game's compat line. `PS_COMPAT_PROBE` sets
the vblanks of quiet before each check (default 3600, a minute); `0`
turns the check off. A run of a game that already has learned code for everything
it runs is quiet whenever it loads nothing.

A press script is a comma-separated list of `<name>@<frame>` entries, for
example `Start@600,Cross@900+10,LUp&LRight@1200+300:2`:

- `<name>` is a button (`Cross`, `Circle`, `Square`, `Triangle`, `Start`,
  `Select`, `Up`, `Down`, `Left`, `Right`, `L1`, `L2`, `L3`, `R1`, `R2`,
  `R3`) or a stick pushed fully one way (`LUp`, `LDown`, `LLeft`, `LRight`
  for the left stick, `RUp`, `RDown`, `RLeft`, `RRight` for the right), in
  any case. `&` joins several names into one entry, so `LUp&LRight` is a
  diagonal and `Cross&LRight` presses a button while moving. Entries that
  overlap in time combine too.
- `+<n>` after the frame holds the entry for `n` frames instead of a short
  tap.
- `:<n>` at the end presses on player `n` instead of player 1.
- `?<condition>~<n>` after the frame makes the entry wait for a value in
  the game's memory, for at most `n` frames, as in
  `Cross@900?u8[801f2a40]==3~600`. [testing.md](testing.md) has the details and
  `play --ramdiff`, which helps find the address.
