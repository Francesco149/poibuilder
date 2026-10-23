## PBMaskTexture — an ImageTexture that saves its pixels zstd-compressed.
##
## Splat masks and decal windows were plain ImageTextures, which a scene
## stores as RAW bytes (base64 in a .tscn): one 3136x2304 decal window made
## the demo map 48 MB and cost 12.6 s just to parse, and a 40x40 m floor of 400
## painted faces saved 86.6 MB. Masks are mostly empty, so they compress
## extremely well: that decal is 736 KB as zstd (encoded in ~25 ms), a typical
## 256x256 mask 6 KB (~0.2 ms). WebP-lossless (PortableCompressedTexture2D)
## packs tighter but encoded ~60x slower — 1.4 s per save after a decal edit.
##
## At runtime it IS an ImageTexture (update()/set_image() as usual); only the
## storage differs: the engine's `image` property is not saved, `packed` is.
## Scenes from before v0.9.182 carry plain ImageTextures and load as before;
## PBSplat.adopt_compressed_storage converts them before the next save.
@tool
class_name PBMaskTexture
extends ImageTexture

## Bumped if the packed layout ever changes (the loader branches on it).
const PACK_VERSION := 1

## The saved form: {v, w, h, format, mipmaps, size, zstd}. Read from the live
## texture at save time; writing it (scene load) rebuilds the texture.
@export_storage var packed: Dictionary = {}:
	get = _pack, set = _unpack

## A mask texture holding `img`.
static func from_image(img: Image) -> PBMaskTexture:
	var tex := PBMaskTexture.new()
	if img != null and not img.is_empty():
		tex.set_image(img)
	return tex

func _validate_property(property: Dictionary) -> void:
	# The raw pixels are exactly what `packed` replaces: keep the engine
	# property for runtime use, drop it from storage.
	if property.name == "image":
		property.usage &= ~PROPERTY_USAGE_STORAGE

func _pack() -> Dictionary:
	var img := get_image()
	if img == null or img.is_empty():
		return {}
	var raw := img.get_data()
	return {
		"v": PACK_VERSION,
		"w": img.get_width(),
		"h": img.get_height(),
		"format": img.get_format(),
		"mipmaps": img.has_mipmaps(),
		"size": raw.size(),
		"zstd": raw.compress(FileAccess.COMPRESSION_ZSTD),
	}

func _unpack(value: Dictionary) -> void:
	if value.is_empty() or not value.has("zstd"):
		return
	var raw := (value["zstd"] as PackedByteArray).decompress(int(value["size"]), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != int(value["size"]):
		return
	var img := Image.create_from_data(int(value["w"]), int(value["h"]), bool(value["mipmaps"]),
			int(value["format"]) as Image.Format, raw)
	set_image(img)
