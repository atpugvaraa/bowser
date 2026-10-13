# UI issues and work needed (sidebar, command bar)

Written 2026-10-13 after the sidebar/command-bar pass. Verified by rendering the real views offscreen
(`bitmapImageRepForCachingDisplay`), because screen capture is not permitted for the tooling here.
Light mode has not been looked at yet; everything below was judged in dark mode.

## Fixed in this pass
- Space tint painted over the whole sidebar (elements invisible but clickable): `TintView` now clamps to its bounds.
- ⌘T no longer creates a blank tab; it only opens the command bar. A tab is made when you pick a URL or search.
- Command bar: first row was pushed down and clipped (table inset style); bar now sizes to its results (max 8 rows);
  shadow was clipped by the layer mask; dead info button removed; subtitle host, "Switch to Tab ↵" badge; typed URL sorts first.
- Command bar open animation: fade plus a 16pt settle; dim reduced to 30%.
- Back/forward/reload now share one line with the traffic lights and slide away with the sidebar; the toggle stays beside the lights.
- Light/dark: layer colours (chip border, dock active space, badge, command bar border) re-resolve on appearance change.
- Pinned tabs vanished when the empty favorites tray had been dismissed; non-web schemes no longer show "Not Secure"; copy shows a checkmark only when something was copied.

## Still bad / needs work
### Sidebar
1. ~~Sidebar was flat charcoal~~ — fixed: sidebar and page frame are now one space-tinted surface. Row/selection/hover colours were tuned for charcoal and still need checking on bright tints and in light mode.
2. When hidden, there is no hover-to-reveal edge; only the toggle or its shortcut brings it back. The toggle overlaps the page card's corner.
3. Empty favorites tray ("Drag to add Favorites") takes ~70pt of prime space. Make it collapse to a thin drop target.
4. Favorites tray rebuilds all tiles on every refresh (hover state lost, wasted layout). Diff against the previous tile data.
5. Tray height numbers (48/44/8) are duplicated between controller and tray view; the tray should report its own height. Audio indicator is dead code (nothing passes `isPlayingAudio: true`).
6. Tab rows: empty rounded squares as favicon fallback look like missing content; no section headings (Pinned / Today); no drag-reorder affordance.
7. Space popup row ("Main · Personal") is a bare popup; no colour dot for the space.
8. Resize handle is an invisible 6pt strip with no hover feedback; width is not persisted per window.
9. Omnibox: clicking the text edits inline, so the "open command bar" launcher only fires on the padding. Decide which behaviour is wanted.
10. Spaces dock scroll view is now constrained, but with many spaces there is no overflow cue.

### Command bar
1. Lists every open tab unranked on an empty query; no recents, bookmarks, history or frecency.
2. Fallback row says "Search Google" regardless of the configured search engine.
3. No keyboard hints (↑↓ ↵ esc), no way to close a tab from the results, no "new tab" action row.
4. Clicking outside dismisses, but there is no exit animation beyond the fade.
5. ⌘L (open in current tab) and ⌘T (open in new tab) share the same selection code; both open a new tab unless the current one is blank.
6. Reduce Motion is not honoured by any of the new animations.

### Process
- The UI self-test cannot cover the ⌘T command bar (it still uses the old new-tab behaviour so its assertions hold); there is no pixel/regression check for any of the above.
