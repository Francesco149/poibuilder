- Stray-click creation leak root cause, order-independent palette dedupe (v0.9.147):
  * FIX: "clicking without dragging still breaks shape placement: the vertex overlay is persistent and it makes an errored shape that complains about a MeshInstance3D not having a mesh". Reproduced in a live editor and root-caused: arming a shape and PRESSING on a surface immediately creates the preview PBMesh in the scene (named Shape_Cube, owner set before first draw) and the BASE phase deliberately renders it MESHLESS (the outline-only stage). On release, `PBShapeCreator.end_base()` rejects an undersized base by calling its own `reset()` — which NULLS `preview_node` — and the plugin's `_creation_abort` then read the already-nulled reference and SKIPPED the node teardown. Every rejected release (a bare click, or a drag under the new step floor) therefore leaked exactly one meshless PBMesh WITH its live base-outline/vertex gizmo: the warning-icon "broken object" and the persistent overlay, stacking one per click (and each carried data + a name, so undo interactions around them corrupted further). Fix: `_creation_end_base` captures the preview BEFORE calling `end_base()` and tears it down explicitly when the base is rejected; the creator's rejection contract is unchanged. Verified in the editor: a bare click and a 1 px-drag click now leave the scene with zero new nodes, `preview_node` null, and the hover overlay cleared. Regression test added to the GUI harness (synthesized click, asserts no meshless PBMesh, no preview reference, no hover leak); headless tests cover the state contract.
  * FIX: "stock texture still appears twice". The v0.9.146 palette dedupe registered keys during the scans, so it was ORDER-DEPENDENT: a bundled/project texture wrapper scanned before the saved material referencing the same image kept both cards (the default material's checkerboard appeared as the starred .tres AND as a wrapper). `PBMaterialDock._collapse_duplicate_materials` now runs a post-scan collapse pass: saved materials (.tres) always win over wrappers of the same image, first wrapper wins among wrappers — order-independent. Test drives both orders plus the saved-vs-saved non-collapse.
- Version bump 0.9.146 -> 0.9.147.
- PSP particle correctness round (v0.9.150):
  * FIX: "the glow completely disappears every cycle (expands -> disappears ->
    expands (flipped) -> disappears)". Root cause: the animated-UV water plane
    leaves its scroll in the GE texture-offset registers and the emitter pass
    (drawn last) inherited it, so every particle quad sampled a sliding band of
    its own texture instead of all of it - the whole fire pulsed once per
    scroll wrap (period 1/1.75 s, matching the report). emitter_bind() now
    zeroes the texture offset; emitters own their full sampler state.
  * FIX: "a halo around the glow that cuts a circular transparent hole into
    other particles". Emitter textures exported as 5551: the art's soft RGB
    falloff quantized to 5 bits, truncating the dim outer gradient to a hard
    disc edge that sliced through overlapping particles. Emitter textures now
    export RGBA8888 (RGB precision is what additive art lives on), capped at
    256x256 for the device heap; mesh textures unchanged.
  * FIX: "elongated stick shapes attached to the flames" - same offset bug
    (the sliding window concatenated a sub-flame tail onto the next head in
    the 2x2 flame atlas). Verified steady in PPSSPPHeadless capture series
    over a full glow cycle; flame renders as authored.
  * Headless probe tooling (test build only): poi_cam.txt freezes the
    benchmark camera for capture series; poi_render.txt skip=/edbg= stage
    attribution; display-list guard canary + inline-alloc instrumentation.
- Version bump 0.9.149 -> 0.9.150.
