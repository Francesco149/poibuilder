## PBAssetCatalog — Classifies image assets into sprites / stamps / textures so
## the pickers don't cross-populate.
##
## Classification for an image path, in priority order:
##   1. Parent folder name:  .../sprites/  .../stamps/  .../particles/  .../textures/
##   2. File-name prefix:    sprite_ billboard_ tree_ bush_ grass_   -> sprite
##                           stamp_ decal_                            -> stamp
##                           particle_                                -> particle
##   3. Shipped default names that predate prefixes (flower_patch, tapestry ...).
##   4. Everything else -> texture (the paint/material bucket).
##
## Users add their own assets by dropping files into a matching folder
## (res://materials/sprites/, res://materials/stamps/, res://materials/textures/)
## or by using the prefixes — the addon's own folder is never touched.
@tool
class_name PBAssetCatalog

const SPRITE_FOLDER_NAMES := ["sprites", "sprite"]
const STAMP_FOLDER_NAMES := ["stamps", "stamp", "decals", "decal"]
const PARTICLE_FOLDER_NAMES := ["particles", "particle"]

const SPRITE_PREFIXES := ["sprite_", "billboard_", "tree_", "bush_", "grass_"]
const STAMP_PREFIXES := ["stamp_", "decal_"]
const PARTICLE_PREFIXES := ["particle_"]

## Shipped textures that predate the prefix convention.
const DEFAULT_SPRITE_NAMES := ["tree_oak", "tree_pine", "bush_foliage", "grass_tuft"]
const DEFAULT_STAMP_NAMES := ["flower_patch", "tapestry", "hello_world"]

## Returns one of "sprite", "stamp", "texture", "particle".
static func classify_path(path: String) -> String:
	var lower := path.to_lower()
	var parent := lower.get_base_dir().get_file()
	if parent in SPRITE_FOLDER_NAMES:
		return "sprite"
	if parent in STAMP_FOLDER_NAMES:
		return "stamp"
	if parent in PARTICLE_FOLDER_NAMES:
		return "particle"
	var name := lower.get_file()
	for p in SPRITE_PREFIXES:
		if name.begins_with(p):
			return "sprite"
	for p in STAMP_PREFIXES:
		if name.begins_with(p):
			return "stamp"
	for p in PARTICLE_PREFIXES:
		if name.begins_with(p):
			return "particle"
	for n in DEFAULT_SPRITE_NAMES:
		if name.begins_with(n):
			return "sprite"
	for n in DEFAULT_STAMP_NAMES:
		if name.begins_with(n):
			return "stamp"
	return "texture"

static func is_sprite(path: String) -> bool:
	return classify_path(path) == "sprite"

static func is_stamp(path: String) -> bool:
	return classify_path(path) == "stamp"

static func is_particle(path: String) -> bool:
	return classify_path(path) == "particle"

## Textures usable for painting/materials: everything except sprites, stamps
## and particles (those live in their own pickers).
static func is_texture(path: String) -> bool:
	return not is_sprite(path) and not is_stamp(path) and not is_particle(path)
