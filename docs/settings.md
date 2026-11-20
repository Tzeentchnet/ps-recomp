# Settings

Settings are environment variables. Each name starts with `PS_`. Put the
setting before the command, like this:

```sh
PS_GPU=sw ./play-bin path/to/game.cue
```

| Setting | What it does |
|---|---|
| `PS_DATA` | The folder where your files go. See [Where your files go](#where-your-files-go). |
| `PS_GPU` | PS1 only. `vk` draws with Vulkan (the default). `sw` draws in software. |
| `PS_SW` | PS2 only. `1` draws in software. Otherwise PS2 games draw with Vulkan, except in the wasm build, which always draws in software. |
| `PS_BANDS` | PS2 only, software drawing. The number of threads that draw, each a band of rows (1 to 16). The default, 1, draws on the emulator's own thread. The play page's default is one fewer than the CPUs, at most 8, each a Worker. |
| `PS_SCALE` | PS2 only. The window size, as a multiple of the console's resolution. 1 to 8. The default is 3. |
| `PS_IRX` | PS2 only. By default, a game's own sound and input/output modules run on an emulated copy of the console's I/O processor. `0` turns that off: each module is answered as loaded, without running it. |
| `PS_NATIVE` | `0` runs the game through the interpreter instead of as native code. Slower; for checking a bug. |
| `PS_LEARN` | By default, the code a game loads as it runs and the converter never saw (a PS1 game's interpreted code, such as its overlays; a PS2 game's I/O processor modules and interpreted EE code) is recorded in the disc's folder as it runs, and later runs use native code compiled from it. `1` records the code every processor interprets. `0` records nothing and uses no learned code. |
| `PS_VU_CAPTURE` | PS2 only. By default, the game's vector unit microcode that has no native code yet is recorded in the disc's folder as it runs; it runs as native code later in the same run (once the recording has been quiet for a while) and in later runs, and a [port](porting.md#vu-microcode) compiles it too. Each run adds to the record. `1` records all of it, with the vector units run through the interpreter, so the game is slower. `0` records nothing. |

`PS_GPU`, `PS_SW`, `PS_SCALE`, `PS_IRX` and `PS_NATIVE` can also be set
in the [launcher](launcher.md). It keeps them in `settings.tsv` files:
one for all discs in the data folder, and one in each disc's folder. An
environment variable always wins over both.

Other settings exist, mostly for debugging. They are described in the code
where each one is read. See [how-it-works.md](how-it-works.md#settings-in-the-code).
`PS_TTY` is not a setting: the launcher sets it for the games it starts.

## Where your files go

Saves, memory cards and converted code are kept for each disc in a user
data folder, under `discs/<disc id>/`. So are the disc's launcher
settings (`settings.tsv`), its picture (`thumb.ppm`) and the output of
its last launcher run (`play.log`). The launcher's list of discs is
`library.tsv`, and the settings for all discs are `settings.tsv`, both in
the data folder itself.

| System | Default location |
|---|---|
| Linux | `~/.local/share/ps-recomp` |
| macOS | `~/Library/Application Support/ps-recomp` |
| Windows | `%APPDATA%\ps-recomp` |

Set `PS_DATA` to use a different folder.
