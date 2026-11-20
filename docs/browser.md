# Play in your browser

The project's web page also works without building anything. Nothing you
give it is uploaded: the disc is read in your browser.

- <https://plaught-armor.github.io/ps-recomp/> converts a disc. Use what it
  makes with a player built from the commit the page shows (see
  [how it works](how-it-works.md)).
- <https://plaught-armor.github.io/ps-recomp/play.html> plays a disc in
  the browser tab. It can use the game's code converted for the browser
  (wasm32) when that code is in the page's storage, but the page has no
  way to add it yet, so for now a game's code is worked out as it runs.

The play page keeps the disc, settings and memory cards in your browser's
storage for this site. Nothing is sent anywhere. Settings and memory cards
are written back when the game stops, so closing the tab while a game runs
loses what changed in that session.

The page needs a feature that browsers only allow on an isolated page. The
page sets this up by itself and reloads once the first time you open it.

What has been tested: Brave and Firefox, both on Linux and without a
window. PS2 games draw in software in the browser. Some games may be slow.
Other browsers and phones have not been tried. Playing over the network is
not yet in the browser page.
