# STATE

- Engine: 4.7.2.stable.official.ed1daf0bf. Tests not run on this exact version do not count.
- Milestone: M0 — Light + dither spike (acceptance not passed)
- Verified: runtime LIGHT_LEVEL table at distances 1–15 for air, mycelium, and pale bloom, using Godot 4.7.2. The Compatibility renderer opened on an AMD Radeon RX 6600 and reported no shader compile errors. A 854×480 rendered frame shows repeated Bayer patterns across lit wall faces.
- Works, not yet verified: sealed 32³ voxel test scene; free camera; L key moves/places one light; per-chunk 16³ light buffers use copied 15-block padded neighborhoods and bucket propagation; chunk meshes bake light into vertex color; patched world Bayer shader; crosshair readout.
- Timing: Five runs, median and max. PASS when median <3 ms and max <4 ms. The relevant budget is amortized frame cost: two chunks may update in a frame, and their combined work must fit in the worst-case 20 ms frame budget; isolated per-chunk timing alone does not show whether that frame budget is met. Earlier 4.7.2 headless results were 1.620, 1.641, 1.661, 1.783, and 2.356 ms (median 1.661 ms, max 2.356 ms), but these do not count because the project pins 4.3.x.
- Broken / known bugs: screenshot has patterned wall surfaces but band count has not been confirmed as four distinct bands; HUD center sample is `LIGHT_LEVEL 0` against the opaque test wall. Three-angle chunk seam and manual light movement remain unchecked. Project pins Godot 4.3.x, but only 4.7.2 is installed; pause visual verification pending the user's engine decision. Godot reports environment-only write failures for user:// logs/cache and a certificate-store error. Git writes are handled by the user outside the sandbox.
- Files changed this session: `STATE.md`; `DEVLOG.md`; `debug/m0_review00000000.png` (854×480 review capture). Godot-generated `.godot/` and `.uid` files are present.
- Next: user decides whether to install 4.3.x or change the project pin to 4.7.2. Then run valid timing and complete visual evidence checks. Do not start M1 until M0 acceptance passes.
- Decisions locked (don't revisit): internal resolution=854x480; integer scaling with keep aspect; default window=1708x960; dither=patched world ShaderMaterial using baked vertex light.

## M0 acceptance checklist

- [x] Godot 4.7.2 Compatibility launches the scene without GDScript or shader errors.
- [x] Verify internal capture is 854x480; integer-scaled live-window behavior remains unverified.
- [ ] Manually move/place the light with L; no player or enemies are present.
- [x] Runtime table matches air `max(0, 15-d)`, mycelium `max(0, 15-4d)`, and pale bloom `0` for d=1..15.
- [ ] Screenshot at 854x480 shows at least four distinguishable Bayer bands; HUD remains undithered; fog remains visible. Capture exists; this visual criterion is not yet confirmed.
- [ ] Light at the chunk border has no seam from three viewing angles.
- [ ] Five full 16³ chunk updates: median <3 ms and max <4 ms; report two-chunk amortized cost against a 20 ms frame budget.
- [ ] Visually confirm crosshair readout shows `LIGHT_LEVEL` and `GLOOM_LEVEL`.

- Proposed commit message: `Add isolated M0 voxel light and dither spike`

