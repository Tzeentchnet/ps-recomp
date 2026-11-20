# Play in your browser

No build needed. The disc is read inside your browser; nothing you give
the page is uploaded.

## The pages

| Page | What it does |
|---|---|
| [Convert](https://plaught-armor.github.io/ps-recomp/) | Converts a disc's code to native code. Use the result with a `play-bin` built from the commit the page shows (see [how it works](how-it-works.md)). |
| [Play](https://plaught-armor.github.io/ps-recomp/play.html) | Plays a disc in the browser tab. |

The play page can run a game's code converted for the browser (wasm32),
but only when that code is already in the page's storage, and the page has
no way to add it yet. For now, a game's code is worked out as it runs.

## What the play page keeps

- The disc, settings and memory cards stay in your browser's storage for
  this site, so a disc can be played again without picking it. **Forget**
  removes it.
- Settings and memory cards are written back **when the game stops**.
  Closing the tab while a game runs loses what changed in that session.
- The first time you open the page, it reloads once. It needs a browser
  feature that only works on an "isolated" page, and sets that up itself.

## Reports and game data

- **Save a report** opens a new GitHub issue with the run's state filled
  in (frame rate each second, silent audio, the first errors, the end of
  the log), and saves the full report as a file. Say what went wrong at
  the top; see [Report a problem](reporting.md).
- **Send game data** opens a new, **public** GitHub issue under your
  account, with a file to drag into it. The file holds what the run saw of
  the game (addresses, counts, hashes, system calls), never the game's own
  bytes, your file names or your browser. Nothing is sent until you submit
  the issue.

## What has been tested

- Brave and Firefox on Linux, run without a visible window.
- PS2 games draw in software in the browser. Some games may be slow.
- Not tried: other browsers, and phones.
- Not yet in the browser: playing over the network.
