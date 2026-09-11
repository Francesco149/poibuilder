"""Showcase video assembly pipeline for PoiBuilder.

The editor is captured frame-by-frame by ``project/showcase/showcase_director.gd``
(one PNG per rendered frame plus cursor/event sidecars); everything else — the
crop, the captions, the cursor, the transitions, the encoding — happens here.
That split is deliberate: re-editing a beat must never require re-rendering the
editor.

Submodules:
  edl      — the edit decision list (the timeline) and its validation
  capture  — reading what a session recorded (manifest, shots, cursor)
  draw     — Pillow rendering of captions, cursor, cards and annotations
  ffmpeg   — filtergraph construction for one clip and for the whole build
  build    — the CLI: bake segments, concat, encode the deliverables, verify
"""

__all__ = ["edl", "capture", "draw", "ffmpeg", "build"]
