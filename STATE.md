# STATE

- Engine: 4.7.2.stable.official.ed1daf0bf. Tests not run on this exact version do not count. BIBLE.md pins API docs to 4.7 and treats APIs newer than 4.7.2 as nonexistent.
- Viewport: project settings use the 854×480 root viewport, keep aspect, integer scaling, and a 1708×960 window override. No SubViewport was added.
- M1: ACCEPTED and committed by the user. User verified 60 FPS and 43 draw calls for the 1M-block world; generation, meshing, movement, break/place, and save/load accepted.
- M2: PASSED and accepted by the user. Dither, integer scaling, chunk seam, static light baking, block-edit propagation, and dynamic flashlight without remeshing were accepted.
- M2 isolated evidence: seven captures in `debug/m2_evidence/` plus `debug/m2_acceptance_test.gd`; latest AIR sample shows LIGHT_LEVEL 12. Human review confirmed five visible Bayer bands and no seam in three angles.
- M2 main-world screenshot: `debug/m2_evidence/main_world_torch_flashlight.png` (854×480), captured on Godot 4.7.2 with generated world, torch, shader flashlight, and debug HUD visible. Main-world capture log: 256/256 chunks lit and meshed; light update median 2.738 ms, max 19.154 ms with one chunk processed per frame. This is distinct from the accepted isolated five-run timing result.
- M2 isolated timing PASS: 1262, 1271, 1371, 1375, and 1677 µs; median 1371 µs <3 ms and max 1677 µs <4 ms.
- Decisions locked (don't revisit): viewport 854×480; integer scaling + keep aspect; window override 1708×960; dither uses patched world ShaderMaterial reading baked vertex light; static lights (torches/crystals) propagate into the 0–15 buffer and bake into vertex colors; the dynamic flashlight cone is evaluated in the Bayer shader from player/camera uniforms and never triggers chunk remeshing.
- Next: M3 plan proposed to user. No M3 code written; wait for plan approval before implementation.