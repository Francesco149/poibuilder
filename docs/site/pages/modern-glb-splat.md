---
title: Splatting in a modern .glb
lead: How the modern export carries paint — baked into textures, or as documented sidecar data your engine (or Godot) re-blends at runtime.
---
# Splatting in a modern `.glb` export

PoiBuilder's splat/decals are a custom shader plus per-face mask images, which
glTF cannot express as a material. The modern export therefore offers two
routes (Export dialog → **Modern paint**):

| Option | What lands in the file | When to use |
|---|---|---|
| **Bake into textures** (default) | Every painted face is composited into **its own texture**, its UV1 is rewritten into mask space, and the material is a plain `StandardMaterial3D`. | Any consumer, no custom code. What you see is what ships. |
| **Include splat data** | Geometry keeps its mask coordinates (as `TEXCOORD_2`), each painted face's material carries a `poi_splat` record in its glTF `extras`, and the masks / layer textures / decal channel are written as PNGs next to the `.glb` under `<mapname>.splat/`. | Engines that run the blend themselves (dynamic re-tinting, runtime mask edits), or a round trip back into Godot (see below). |

Both routes keep **uniform texel density**: the mask (and therefore the baked
texture) is sized from the face's world size at 256 texels/m, clamped to
256..2048 px. A large floor is never blurrier than a small cube, and the export
matches what the editor showed.

Only *painted* faces pay anything. An unpainted face keeps its base material
and its authored UVs in both modes.

## BAKE mode

For each painted face the exporter writes one texture in **mask space** — the
face-planar `[0,1]` rectangle the masks live in — and remaps that face's UV1 to
the same rectangle. Composition order matches the live shader:

1. base texture sampled through the face's *original* UV1 (so tiling is baked
   in), multiplied by the base color;
2. each blend layer, sampled through the original UV1 and blended by
   `smoothstep(0.5 - e, 0.5 + e, mask.r) * layer_color.a`, where `e` is the
   anti-aliasing edge width (`#8` below);
3. the decal layer on top, `mix(color, decal.rgb, decal.a)`.

Non-opaque materials (a cutout or a soft blend) are **not** baked — a composited
texture would lose the alpha semantics; those faces keep their base material.

## INCLUDE mode

The `.glb` is accompanied by a sidecar folder:

```
map.glb
map.splat/
  f12_layer1_tex.png    # layer 1's tiling texture
  f12_layer1_mask.png   # layer 1's weight mask, single channel
  f12_decal.png         # the face's decal layer (RGBA)
  ...
```

`f12` is the face index inside the exporter's view of the mesh. Each painted
face's material carries:

```json
"extras": {
  "poi_splat": [
    {
      "version": 1,
      "face": 12,
      "mask_uv": "TEXCOORD_2",
      "layers": [
        { "slot": 1,
          "texture": "map.splat/f12_layer1_tex.png",
          "mask":    "map.splat/f12_layer1_mask.png",
          "color": [1.0, 1.0, 1.0, 1.0],
          "roughness": 0.8 }
      ],
      "decal": "map.splat/f12_decal.png"
    }
  ]
}
```

Geometry contract:

* `TEXCOORD_0` — the base texture tiling UV (unchanged).
* `TEXCOORD_2` — the **mask coordinate** (`vec2`): where the face sits inside
  its masks, `[0,1]` over the face's planar rect, values outside `[0,1]` mean
  "outside the painted area". (Written as a Godot custom vertex attribute; the
  engine's glTF writer maps custom channel 0 to `TEXCOORD_2`.) Godot restores
  it as `ARRAY_CUSTOM0` on import, which is why the round trip below works.
* `TEXCOORD_1` is untouched and stays whatever you authored (a lightmap unwrap,
  usually).

### Reproducing the blend outside Godot

Per fragment, per layer `i` (0-based in the order they appear in `layers`):

```glsl
// inputs: uv (TEXCOORD_0), mask_uv (TEXCOORD_2)
vec4 base = texture(baseColorTexture, uv) * baseColorFactor;
vec3 albedo = base.rgb;
float roughness = baseRoughness;

for each layer:
    vec4  tex  = texture(layer.texture, uv) * layer.color;      // U = REPEAT
    float w    = texture(layer.mask, mask_uv).r;                // U/V = CLAMP
    float e    = max(fwidth(w) * 2.0, 0.02);                    // edge width
    float k    = smoothstep(0.5 - e, 0.5 + e, w);
    albedo     = mix(albedo, tex.rgb, k * tex.a);
    roughness  = mix(roughness, layer.roughness, k * tex.a);

if (decal present):
    vec4 d = texture(decal, mask_uv);                           // U/V = CLAMP
    albedo = mix(albedo, d.rgb, d.a);
```

The mask sample is skipped when `mask_uv` leaves `[0,1]` (the painted rect is a
fixed object-space area: resizing geometry never stretches it, it just clips).

### Round trip into Godot

`PBSplatImport.rebuild_from_extras(scene)` walks an imported scene, reads each
material's `poi_splat` extras, loads the sidecar PNGs and installs live splat
`ShaderMaterial`s — so an exported map comes back paint-editable:

```gdscript
var root: Node = load("res://maps/level.glb").instantiate()
add_child(root)
PBSplatImport.rebuild_from_extras(root)
# If the scene was moved away from its .glb, pass the export path instead:
# PBSplatImport.rebuild_from_extras(root, "res://maps/level.glb")
```

Note the sidecar files are **not** packed into the `.glb`: delete them and the
splat record is inert (the geometry still renders with its base material).
