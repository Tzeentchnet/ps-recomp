# Build and play

## What you need

- [Odin](https://odin-lang.org), version `dev-2026-10`.
- SDL2. It provides the window, input and sound.
- Vulkan 1.3, for graphics. Both consoles can also draw in software
  instead; see [Settings](settings.md).
- A PS1 or PS2 disc image made from your own disc. This can be a `.cue`
  sheet, or a single-track `.bin` or `.iso` file.

You do not need a BIOS file.

## Install

Get this repository, then run this from its top folder:

```sh
odin build play -collection:ps=. -o:speed -out:play-bin
```

This builds a program called `play-bin`.

A build made this way counts as a development build. It converts the game
again every time you start it. To keep the converted code between runs,
add `-define:COMMIT=<hash>` with the current commit hash:

```sh
odin build play -collection:ps=. -o:speed -define:COMMIT=$(git rev-parse HEAD) -out:play-bin
```

## Play a game

```sh
./play-bin path/to/game.cue
```

The first time you run a disc, `play` converts the game to native code.
It shows its progress while it works. The result is saved, so later runs of
the same build start at once.

If the conversion fails, the game still runs, but slowly. It then runs
through an interpreter, which works out each instruction as it goes.
