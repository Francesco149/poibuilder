# Building levels for PoiRetro — Godot recipes, tuned for the PSP

How to author in Godot so the retro export gets the best out of the runtime.
Companion docs: `SPEC_RETRO_FORMAT.md` (what the file contains),
`psp/OPTIMIZATION.md` (why the runtime is fast, with measurements),
`psp/HARDWARE-TESTING.md` (how to measure a change on the device).

**The one thing to internalise:** the PSP runtime has no runtime lighting, no
shader, no texture streaming and no spare CPU. Everything the level needs is
*baked at export*: geometry, textures, lighting, atlas layout, mip chains. So
the authoring decisions below **are** the performance profile — nothing
downstream can fix them.

---

## 1. Setup

```bash
# plugin: copy project/addons/poibuilder/ into your project, enable PoiBuilder
# device: ./setup_psplink.sh once, then
./run_psp_hw.sh --app        # build + run the map on a real PSP
./run_viewer.sh              # Godot look-alike viewer (visuals only, not perf)
./run_psp_hw.sh              # the profiling battery (real numbers only)
```

In the editor: the PoiBuilder toolbar sits under the 3D toolbar. **New Shape**
creates geometry; the Material & UV, Texture Paint and Stamp docks do surfaces;
the **Export** button opens the retro/modern dialog.

---

## 2. The loop, in the order that avoids rework

1. **Grey-box with primitives** (`New Shape`: cube, stairs, ramp-ish prism,
   cylinder, pipe, cone, arch, door, sphere, torus, plane, sprite, n-gon) on the
   grid. Drag the base coplanar to any surface, then set the height along the
   normal; ESC aborts. Keep the grid step at the size the level actually uses —
   it is also the snapping step for elements.
2. **Cut and shape** with the element tools (Object/Vertex/Edge/Face), Shift+Move
   to extrude, Shift+Scale to inset, the knife and the n-gon tool for arbitrary
   polygons. All of it is ordinary mesh data by export time.
3. **Decide the surface budget** (section 4) — how many distinct materials, how
   much painted detail, how large the screen-filling surfaces are. This is the
   step that decides whether the map runs at 200 fps or 40.
4. **Assign base materials** per face, and set each material's **tiling so that
   one repeat is the size you want on screen**. This is the single most
   performance-relevant material setting (see §4.1).
5. **Paint variation** with the splat brush (up to 8 layers) and **stamps**
   for decals. Both are baked into 128x128 atlas tiles at export — see §3.
6. **Light it** with one DirectionalLight3D (the sun) plus a few OmniLights;
   set ambient colour and AO distance in the export dialog. Lighting is baked
   into vertex colours; the runtime cost is zero either way.
7. **Add life**: scrolling surfaces (material → Scrolling Texture), billboards
   (`is_billboard`), emitters (a GPUParticles3D), scripted entities via metadata.
8. **Colliders** per PBMesh: `Off` / `Accurate` (trimesh) / `Ramp` (stairs only).
9. **Export** (Retro mode) and put the `.pbm` next to the EBOOT, or run it over
   USB. **Then measure on hardware** if you changed anything structural.

---

## 3. What the export bakes (and the consequences)

| baked thing | what it means for you |
|---|---|
| **Quad subdivision on a `grid_size` lattice** (default 1 m) | geometry is cut along that grid so tiles line up. Smaller grid = more quads = more vertices and more per-primitive LOD steps; larger = coarser vertex lighting and AO |
| **Painted tiles baked into atlases** at `tile_resolution` px per grid cell (default 128) | a painted cell carries `tile_resolution` texels per metre. The *base* material keeps its own texture at its own repeat, so **match the two densities or the painted areas read as blurrier than the rest** (§4.1) |
| **Vertex colours** for sun + omni + shadows + AO | lighting resolution is *vertex* resolution: a wall lit by one vertex is a gradient, not a shadow. Subdivide where you need light detail |
| **One texture per material**, power-of-two, ≤ `max_texture_size` | texture switches and draw calls follow materials; the atlas packer only merges *baked tiles*, never base materials |
| **Mesh bounds + per-mesh chunks (≤384 vertices)** | nothing to author; just know a giant single surface is split for you |
| **Billboards / emitters / scroll / colliders / metadata** | from node metadata and materials — §5 |

---

## 4. Performance rules that actually bite (all measured on hardware)

### 4.1 Textures: the cache is the budget, not the VRAM

The GE's texture cache is ~8 KB. A fragment whose sampled mip level fits it
costs ~2 ns; one that misses costs ~37 ns (19x). The level the hardware picks is
"sharpest that averages ~1 texel per pixel", so **the sampled footprint is the
surface's on-screen area** — which means the expensive thing is a *big surface
seen close*, and the thing that fixes it is the renderer's LOD policy, not your
autoriring. What you control:

- **Match texel densities.** Splat/stamp tiles bake at `tile_resolution` px per
  `grid_size` metre (128 px/m by default). Set the base material's tiling so one
  repeat covers the same scale (e.g. a 512 px texture repeating every 4 m =
  128 px/m). Otherwise the painted areas are visibly softer than the rest of the
  floor — and it is that *difference* that reads as a seam.
- **Prefer painting over adding materials.** A painted cell rides the atlas (one
  texture, packed); a new material is a new texture, a new switch and another
  draw call.
- **Power-of-two, and not giant.** 256 or 512 is plenty; a 1024 texture on a
  close surface is a cache-miss per fragment unless the LOD policy is tuned for
  it. Emitter textures are the sharpest constraint: keep them small (64x64 is
  what the showcase uses).
- **Scrolling textures are free** (one register write per moving mesh) but the
  surface they sit on still costs its fill — keep them on walls/ribbons, not on
  a full-screen close-up.

### 4.2 Fill: count screens, not objects

A full screen of opaque fill is ~0.27 ms; 60 fps gives you 16.7 ms. The
showcase's worst view (the waterfall foot) spends ~10 screens of fill for 4.98 ms.
So:

- **Stack alpha layers deliberately.** Every blended surface re-shades the same
  pixels: sheet + core + pool + foam + spray over the wall is 5 passes over
  roughly the same area. It is affordable at the showcase's sizes; a
  full-screen stack of them is not.
- **Keep the layered floor coplanar but not identical.** The base material quad
  and the baked tile quads sit at the same height and resolve by draw order;
  that is by design (the runtime does not write depth). Do not stack a *third*
  surface there — you would be paying fill for nothing visible.
- **Close-up hero surfaces cost the most.** A wall that fills the screen near
  the camera is the one place where texel density, the LOD policy and fill all
  peak together. If a view is expensive, that is where it is.

### 4.3 Particles

- **Additive is the cheap default** (order-independent, no sorting) — fire,
  sparks, glows.
- **Blended** (smoke, mist) costs its fill like any surface and needs
  back-to-front sorting: keep those emitters small, off-centre, and out of the
  player's face.
- The format caps **256 particles per map**; the whole budget measured 0.72 ms
  gpu / 1.14 ms cpu, i.e. about a fifth of a frame. Particle *count* is cheap;
  particle *screen area* is not.
- Author them as ordinary `GPUParticles3D` nodes (a quad draw pass + a process
  material); the exporter maps the process material and the quad field by field.

### 4.4 Draw calls, materials, geometry

- ~0.94 µs per draw call and 2.2 M tris/s: at 25-30 draw calls and ~1500
  triangles the showcase is nowhere near a vertex bottleneck. **Do not optimize
  vertex counts; optimize screens of fill.**
- Backface culling is on — do not author double-sided surfaces as two coincident
  quads; the second one is invisible and costs nothing but is also confusing.
- A giant surface is fine (the exporter chunks it), but a giant surface *seen
  close* is the §4.1 case.

### 4.5 Colliders

- `Accurate` (trimesh) for anything walkable; `Ramp` for stairs (it emits a
  smooth ramp instead of steps); `Off` for decorative geometry. Colliders are
  exported as separate meshes and cost nothing to render.

---

## 5. Knobs quick reference

### Export dialog (retro mode)

| option | default | effect |
|---|---|---|
| Quad subdivision / grid size | on / 1.0 m | tile alignment, vertex lighting resolution, geometry count |
| Bake lighting / shadows / AO | on / on / 16 samples, 1.5 m, 0.4 | vertex colours; AO samples and distance are the cost (export time) and the look |
| Bake textures / tile resolution | on / 128 px | sharpness of painted areas vs atlas capacity (128 px tiles → 16 per 512 atlas; 256 px → 4) |
| Max texture size / POT | 512 / on | retro engines and this one want power-of-two; the cap is enforced by bilinear resize |
| Billboards / colliders / lights | on | whether those node types reach the file |
| Cleanup intermediate files | on | deletes the PNGs/rubbish a Godot GLB import would otherwise leave behind |

### Node metadata (the authoring surface for runtime features)

| metadata | on | meaning |
|---|---|---|
| `is_billboard = true` | MeshInstance3D | camera-facing quad, alpha-tested cutout |
| `is_lit = true` | billboard | lit by the bake (unlit billboards stay pure white unshaded) |
| `poi_uv_scroll = Vector2(u, v)` | material (Scrolling Texture in the dock) | pattern velocity in repeats/second; **negative V falls down a wall** |
| `poi_emitter = true` | GPUParticles3D | exports as an emitter record |
| `poi_additive` / `poi_y_locked` / `poi_wobble_amp` / `poi_wobble_freq` / `poi_knee` / `poi_seed` | emitter | fields Godot has no concept for (additive blending, cylinder billboard, wobble, size-curve knee, deterministic seed) |
| `poi_spawn` / `poi_walkable` / `poi_trigger` / `poi_rigid_body` | any node | scripted-entity descriptors written into the metadata lump |
| `poi_metadata_tag` + `poi_metadata_payload` | any node | arbitrary key/value written to the map's metadata (map name, options, …) |

### Runtime knobs, no rebuild (`host0:/poi_render.txt`, read at startup)

`filter=` (mip_lin | linear | nearest | asym), `bias=` (LOD bias — **positive is
cheaper, and the shipped +1 is already at the cache boundary**), `mips=0/1`,
`cutout_mips=`, `level_mode=auto|const`, `detail_mesh=`/`detail_bias=`/
`detail_const=` (per-mesh LOD policy for painted detail), `particles=` (bitmask:
1 blended, 2 additive, 3 both, 0 off), `uv_scroll=0/1`, `skip_mesh=<substring>`,
`preset=dawn|day|dusk|night`. Measured effects for all of these are in
`psp/HARDWARE-TESTING.md`.

---

## 6. Pitfalls

- **Looks fine in Godot, costs on the device.** The viewer renders the same
  `.glb`/`.pbm` but with a modern GPU; it cannot show fill cost, cache misses or
  the LOD cliffs. Only `./run_psp_hw.sh` prices a level.
- **Splat/stamp areas softer than their surroundings** — a texel-density mismatch
  (§4.1), not a bug.
- **Grazing-angle seams on tiled floors** — the GE derives LOD per primitive, so
  neighbouring tiles can land on different levels. The runtime now pins the
  painted detail meshes to one level (`detail_const`), which is the practical
  mitigation; the residual is a hardware property (see the README's known
  limitations and `psp/HARDWARE-TESTING.md`).
- **Soft alpha on screen-filling surfaces** (a giant mist quad, a full-screen
  window pane): each one is another blended pass.
- **Emitters in the player's face**: blended mist at point-blank range was the
  single worst measured frame in the showcase (25 ms) — the LOD policy fixed it,
  but the guidance stands.
- **Anything animated besides UV scroll and particles** does not exist at
  runtime: no skeletal animation, no shader effects, no runtime lights.

---

## 7. Before you ship a map

1. Every surface has a material (unassigned faces fall back to the default).
2. Base-material tiling matches the tile-bake density on painted floors.
3. Lighting looks right **in the viewer** (vertex-colour bake is what the device
   shows).
4. Colliders exist exactly where the player can stand or collide.
5. `./run_psp_hw.sh` — the sweep must stay inside 16.67 ms/frame on the worst
   pose, and the ablations should not show a new cliff.
6. If something is slow, ablate before redesigning: `skip_mesh=`, `particles=0`,
   `mips=0`, `bias=` in `poi_render.txt` will tell you in one run which surface
   or stage owns the time.
