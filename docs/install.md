# Build and play

## What you need

| Need | Notes |
|---|---|
| [Odin](https://odin-lang.org) `dev-2026-10` | The compiler. Other versions may not build. |
| SDL2 | The window, input and sound. |
| Vulkan 1.3 | Graphics. Both consoles can draw in software instead; see [Settings](settings.md#graphics). |
| A disc image | Made from a PS1 or PS2 disc you own: a `.cue` sheet, or a single-track `.bin` or `.iso`. |

You do not need a BIOS file.

## Build

From the repository's top folder:

```sh
odin build play -collection:ps=. -o:speed -out:play-bin
```

This makes a program called `play-bin`.

That is a **development build**: it converts the game again every time you
start it. To keep the converted code between runs, build with the current
commit hash:

```sh
odin build play -collection:ps=. -o:speed -define:COMMIT=$(git rev-parse HEAD) -out:play-bin
```

## Play a game

```sh
./play-bin path/to/game.cue
```

- **First run of a disc:** `play` converts the game to native code and
  shows its progress. The result is saved.
- **Later runs** of the same build start at once.
- **If the conversion fails,** the game still runs, but slowly, through an
  interpreter that works out each instruction as it goes.

Run `./play-bin` with no disc to open the [launcher](launcher.md) instead.
