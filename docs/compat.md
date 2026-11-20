# Check which of your games run

`play` has a compatibility mode. It runs games without a window and
reports how far each one got:

```sh
./play-bin --compat path/to/discs [frames]
```

Give it one disc image, or a folder: it then runs every `.cue`, `.iso` and
`.bin` file in it.

## How a run works

- Each game runs in its own process, with no window and no speed limit.
- It runs for a set number of **vblanks** (the console's once-per-screen-
  refresh signal): the `frames` argument, else `PS_FRAMES`, else 3600
  (about a minute).
- Unknown BIOS calls and system calls are skipped, so the run can keep
  going.
- Run one compatibility run of a disc at a time. Two at once in the same
  data folder share its memory cards.

## Results

Each game gets one row in `compat.tsv`, in the user data folder, holding
its latest run: how it ended, how much went through the interpreter, and
which calls were skipped. Its full output goes to `compat.log` in its
`discs/<disc id>/` folder.

| Result | Meaning |
|---|---|
| `ok` | Reached the vblank count. |
| `stalled` | Reached the count, but showed no picture, or main memory stopped changing over the second half. |
| `fallback` | Reached the count and made progress, but a module on the emulated I/O processor failed to load, and the built-in stand-in took over. |
| `exit` | The game ended. |
| `fatal` | The program stopped on a fatal error. |
| `watch` | A condition in the press script was not met in time; the `fatal` column says which. |
| `crash` | The run crashed. It ended without writing its result. |
| `hang` | No new vblank came for `PS_COMPAT_WAIT` seconds (default 120), or 5 times that before the first vblank. A slow game that keeps going is never stopped. |
| `spawn` | The game's process could not be started. |

## Memory cards

Each game starts on blank memory cards, so a save from an earlier run does
not change what it does. These cards live in `compat-cards` in the disc's
folder and are emptied before each run; the disc's own `cards` are not
touched.

Set `PS_COMPAT_CARDS=keep` to use the disc's own cards, as a normal run
does, for example to check that a save loads. The `cards` column says
which was used:

| `cards` | Meaning |
|---|---|
| `fresh` | Blank cards. |
| `kept` | The disc's own cards. |
| `kept-empty` | The disc's own cards, but they held no files. |

## Does the game answer its controller? (PS2)

Once a PS2 game has been quiet for a minute (no new module loaded, and no
code run through the interpreter for the first time), the run checks that
it still answers the controller:

1. It saves its state.
2. It tries Start, Cross, Circle, Up and Down, one at a time, each against
   pressing nothing. If no button changes more than 64 bytes of main
   memory, the game ignored them.
3. It loads the state back and goes on as if nothing happened.

Two ignored checks in a row show as a `stuck` stretch in the game's compat
line. `PS_COMPAT_PROBE` sets the vblanks of quiet before each check
(default 3600, a minute); `0` turns the check off. A game that already has
learned code for everything it runs is quiet whenever it loads nothing.

## Press scripts

A press script presses buttons at set times. Put one in `press.txt` in the
disc's folder, or set `PS_PRESS`. It is a comma-separated list of
`<name>@<frame>` entries:

```text
Start@600,Cross@900+10,LUp&LRight@1200+300:2
```

| Part | Meaning |
|---|---|
| `<name>` | A button: `Cross`, `Circle`, `Square`, `Triangle`, `Start`, `Select`, `Up`, `Down`, `Left`, `Right`, `L1`, `L2`, `L3`, `R1`, `R2`, `R3`. Or a stick pushed fully one way: `LUp`, `LDown`, `LLeft`, `LRight`, `RUp`, `RDown`, `RLeft`, `RRight`. Any case. |
| `&` | Joins names into one entry: `LUp&LRight` is a diagonal, `Cross&LRight` presses while moving. Entries that overlap in time combine too. |
| `@<frame>` | When to press. |
| `+<n>` | Hold for `n` frames instead of a short tap. |
| `:<n>` | Press on player `n` instead of player 1. |
| `?<condition>~<n>` | Wait for a value in the game's memory, for at most `n` frames, as in `Cross@900?u8[801f2a40]==3~600`. |

[testing.md](testing.md) has the details of conditions, and
`play --ramdiff`, which helps find the address.

## Pictures

- PS2: `PS_SHOT=<vblank>,...` saves the picture at those vblanks.
- PS1: `PS_DUMP=<dir>` saves frames.

[testing.md](testing.md) has the details.
