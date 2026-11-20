# ps-recomp

Play PlayStation and PlayStation 2 games from your own discs as native
programs on your computer.

## What this is

Most emulators work out each console instruction while the game runs.
ps-recomp works differently. It converts the game's code to native code for
your computer ahead of time. This is called "static recompilation". The
converted game then runs on a built-in stand-in for the rest of the
console: graphics, sound, controllers, memory cards and the console's
system software.

**You bring the game.** This project contains no game code or data. It
also needs no console BIOS file, and it ships none. The console's system
software is rewritten as part of this project. This is known as high-level
emulation, or HLE. All you need is a disc image made from a disc you own.

There are no prebuilt downloads. You build the program yourself with the
Odin compiler. The steps are in [Build and play](docs/install.md).

## Quick start

Build, then play a disc image (`.cue`, `.iso` or `.bin`) made from your own
disc:

```sh
odin build play -collection:ps=. -o:speed -out:play-bin
./play-bin path/to/game.cue
```

Run `./play-bin` with no disc to open the launcher. You need Odin
`dev-2026-10`, SDL2 and Vulkan 1.3; no BIOS file.

Or skip the build: <https://plaught-armor.github.io/ps-recomp/play.html>
plays a disc in a browser tab.

## Project status

ps-recomp is a work in progress. Not every game runs. A game that starts
may still have bugs.

| System | Status |
|---|---|
| Linux | The only system games have been played on. Automated tests run on x86-64 and arm64. |
| Windows | Untested with games. Only the automated tests have run here. |
| macOS | Untested. The code is type-checked for macOS, but neither games nor the automated tests run there. |

## Guides

- [Build and play](docs/install.md): what you need, building `play-bin`,
  and running a disc.
- [Play in your browser](docs/browser.md): the web pages, and what they
  keep in your browser.
- [The launcher](docs/launcher.md): your disc library, per-disc settings,
  and exporting a disc.
- [Controls](docs/controls.md): controller and keyboard layouts.
- [Settings](docs/settings.md): the `PS_` settings, and where your saves
  and files go.
- [Check which of your games run](docs/compat.md): the compatibility mode,
  its results, and press scripts.
- [Report a problem](docs/reporting.md): what to put in an issue.

## For developers

These pages cover the internals:

- [How it works](docs/how-it-works.md): the recompiler, the runtime, the
  repository layout, and how to use `recomp` directly.
- [Making a port](docs/porting.md): turning one game into its own native
  program, with its own fixes and features.
- [Tests](docs/testing.md): the test list, what CI runs, and how to check a
  change before sending it.

## License

GPL-3.0; see [LICENSE](LICENSE).
