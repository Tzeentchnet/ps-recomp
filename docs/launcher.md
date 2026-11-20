# The launcher

Run `play-bin` with no disc to open it:

```sh
./play-bin
```

## Your library

- **Add a disc:** drag a disc image (`.cue`, `.iso` or `.bin`) onto the
  window. Drag a folder to add every image in it.
- The launcher remembers where each image is. It never copies or moves
  the file.
- **A moved or deleted image** shows as missing, in red. You can take it
  off the list; its saves are kept.
- **The selected disc** shows its picture from the last time you quit it,
  and its result from [the compatibility check](compat.md).

## Playing

Start a disc and the launcher hides until the game ends. If the game
fails, the launcher shows the last line it printed. Everything it printed
is kept in `play.log` (see [Where your files go](settings.md#where-your-files-go)).

## Settings screen

Changes [settings](settings.md) for the selected disc, or, after a switch,
for all discs. A change is saved at once. Each row says where its value
comes from:

| Shown | Where the value comes from |
|---|---|
| `(set by PS_...)` | An environment variable. It wins over everything, and the launcher cannot change it. |
| `(this disc)` | This disc's own setting. It wins over all discs. |
| `(all discs)` | The setting for all discs. |
| nothing | The default. |

Clearing a row removes the setting from the screen you are on, so the next
one down holds.

## Export

Export makes a new git-ready folder for the selected disc, to study the
game and tune it by hand.

- It goes in `ps-recomp-ports` in your home folder, named after the disc
  (with ` 2`, ` 3` and so on if the name is taken). The launcher says where.
- It holds notes, the disc's settings, its last picture and a port of the
  game to build. See [Start from an export](porting.md#start-from-an-export).
- The disc image stays where it is and is never copied.

From the command line, `./play-bin --export <disc image> <folder>` does the
same into a folder you name. The folder must be missing or empty.

## Keys

| Action | Keyboard | Controller | Mouse |
|---|---|---|---|
| Move up or down | Up / Down | D-pad or left stick | Wheel |
| Move a page | Page Up / Page Down | L1 / R1 (LB / RB) | |
| Play the disc (list) | Return | A | Double-click |
| Play the disc (either screen) | | Start | |
| Open the settings (list) | Tab | X | |
| Switch this disc / all discs (settings) | Tab | X | |
| Change a setting | Left / Right, or Return for the next choice | D-pad or left stick left / right, or A | Double-click the row |
| Clear a setting (settings) | Delete | Y | |
| Export the disc (list) | X | Y | |
| Take a missing disc off the list | Delete | Y | |
| Back to the list | Esc or Backspace | B | |

## Not yet tested

- The controller column is read from the code; it has not been tried with
  a controller.
- Dropping a folder has been tested only by the automated tests.
- The launcher has only been run on Linux. On Windows and macOS it is
  untested, and so are exports and the ports they hold.
