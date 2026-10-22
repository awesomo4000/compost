# Window-management core

`src/core.zig` exports `Scene`, `Rect`, `Id`, and window options. It has no
terminal or process dependencies. `src/geometry.zig` implements half-open
rectangle intersection, subtraction, containment, and constraint calculations.

## Host contract

- Construct valid bounds with `Rect.init`. Public scene mutations validate their
  bounds and reject negative extents and overflowing endpoints. Rectangle helper
  methods expect validated rectangles.
- Keep content keyed by the stable ID returned by `add` or `splitTile`. IDs are
  never reused during a scene's lifetime. `configure` changes presentation while
  preserving the ID, focus, and pointer capture where the resulting area permits.
- Use `get` to read a copy of window state. Scene fields are exposed for inspection;
  mutate through methods to preserve tree and layout invariants.
- Decode input in the host. `hitTest` finds the topmost opaque window;
  `pointerTarget` honors capture even outside the root. Focus, raising, and capture
  are explicit actions. Hiding or removing a window releases its focus and capture.
- Compare `revision` after mutations and repaint the full root when it changes.
  On root changes the host must also clear the old coverage. This conservative
  invalidation contract will later permit more selective damage tracking.
- Use `visibleRegion` to obtain disjoint visible rectangles. The caller supplies
  the allocator and frees the returned list with that allocator. Content rendering
  and image clipping must use these same regions.
- Compare old and new bounds to notify content of resizes. Zero-area windows
  remain in the model, but the host must not request a zero-sized PTY.

## Layout policy

The scene begins with one root rectangle. Visible docks consume edge strips in
insertion order. Raising a dock changes stacking, not docking order. Nonreserving
docks overlay the current available rectangle. Hidden docks release their space.
Topmost ordering is independent of reservation.

Tiling uses a binary split tree with horizontal or vertical splits. Ratios use
basis points from 0 through 10000. The first child receives the rounded-down
share and the second receives the remainder. Removing a tile collapses its
branch. Hidden tiles release their share without losing their tree position.
Adding a tile splits the whole tiled area; `splitTile` targets a particular leaf.

Floats retain requested bounds and receive actual bounds constrained to the
remaining usable rectangle. Shrinking the display can shrink a float; enlarging
it restores the requested bounds where possible. All floats currently respect
reserved space, including always-on-top floats.

## Initial limits

- At most 32 windows per scene. Capacity errors leave existing windows intact.
- Integral abstract coordinates, opaque rectangles, and a single root dock list.
  Nested tiling is implemented; nested docking containers are still planned.
- Minimum sizes are reported through `constraints_unmet`. They do not yet
  redistribute tile ratios or enlarge requested floats. Docks report unmet
  requested extents when space runs out. No negative dimensions are generated.
- Full-root invalidation rather than incremental damage rectangles.
- The separate terminal adapter is documented in [terminal adapter notes](terminal-adapter.md).
  A [two-shell host](shell-host.md) and initial renderer now exercise docking,
  per-window focus, and mouse capture. Floating-window controls and attachment
  transport remain pending.
  The layout demo is still a static textual projection of IDs.

The tests exercise odd split sizes, negative origins, dock ordering after slot
reuse, hidden tiles, presentation changes, root shrink/grow, stale IDs, capacity,
focus/capture cleanup, and clipping against a per-point hit-testing reference.
