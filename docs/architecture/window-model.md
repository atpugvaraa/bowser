# Window / Space / Tab model — DECIDED (autorun, 2026-10-12)

Research: Chrome binds tabs to windows; Arc binds tabs to Spaces and uses windows as views (web sources confirm Spaces as the unit; exact multi-window behavior not documented in the sources found, so this is our own design, labelled as such).

**Rules (all enforced by `BrowserState.validate()` and tested):**
1. A **tab belongs to exactly one Space**, never to a window. Closing a window never closes tabs. Windows are views.
2. A **window shows one Space** and has its own selected tab (+ remembers last selection per Space it visited).
3. A tab is selected in **at most one window** (a WKWebView can live in only one window). Selecting a tab that is already selected elsewhere returns `.focusWindow(other)`; we focus that window instead of cloning.
4. **Detach** (tear off) = new window on the same Space selecting that tab; the old window picks a neighbour.
5. **Move tab to another Space**: allowed freely within one profile; across profiles requires explicit confirmation (never leak authenticated context).
6. Deleting a Space requires another Space; windows on it switch to the first remaining Space.
7. Hibernation `isActive` = tab is selected in any window (visible). Selected-but-hidden windows keep audio/video alive (spike hidden-media).
8. Persisted transactionally (SQLite); session restore reopens windows with their Space and selection.
Later: ephemeral "little" window (tab not in any Space until saved), Space-per-window pinning, favorites shared across Spaces.
