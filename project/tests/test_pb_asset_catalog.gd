## Test: PBAssetCatalog — sprites / stamps / textures classification.
##
## Verifies:
## 1. Folder-name classification wins (sprites/, stamps/, particles/, textures/).
## 2. Prefix classification (sprite_, stamp_, particle_, tree_, bush_, ...).
## 3. Shipped default names that predate prefixes (flower_patch, tapestry).
## 4. Unknown names fall back to the texture bucket.
## 5. The buckets are disjoint (a sprite never shows up as a stamp or texture).
extends GutTest

func test_folder_classification_wins():
	assert_eq(PBAssetCatalog.classify_path("res://materials/sprites/my_billboard.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://materials/stamps/my_decal.png"), "stamp")
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/particles/anything.png"), "particle")
	assert_eq(PBAssetCatalog.classify_path("res://materials/textures/brick_wall.png"), "texture")

func test_prefix_classification():
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/sprite_lamp.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://whatever/tree_maple.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://whatever/bush_round.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://whatever/grass_patch.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://whatever/stamp_sign.png"), "stamp")
	assert_eq(PBAssetCatalog.classify_path("res://whatever/decal_arrow.png"), "stamp")
	assert_eq(PBAssetCatalog.classify_path("res://whatever/particle_spark.png"), "particle")

func test_shipped_default_names():
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/tree_oak.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/bush_foliage.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/grass_tuft.png"), "sprite")
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/flower_patch.png"), "stamp")
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/tapestry.png"), "stamp")
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/stamp_hello_world.png"), "stamp")
	# The circular square pattern is a stamp, not a paint texture (it appears
	# in the Stamp tab's palette on a fresh project).
	assert_eq(PBAssetCatalog.classify_path("res://addons/poibuilder/materials/textures/circular_square_pattern.png"), "stamp")

func test_unknown_falls_back_to_texture_and_buckets_are_disjoint():
	assert_eq(PBAssetCatalog.classify_path("res://materials/textures/brick_path_4x4.png"), "texture")
	assert_eq(PBAssetCatalog.classify_path("res://materials/textures/tiles_wet_4x4.png"), "texture")
	for path in ["res://addons/poibuilder/materials/textures/tree_oak.png",
			"res://addons/poibuilder/materials/textures/flower_patch.png",
			"res://addons/poibuilder/materials/textures/brick_path_4x4.png"]:
		var buckets := {
			"sprite": PBAssetCatalog.is_sprite(path),
			"stamp": PBAssetCatalog.is_stamp(path),
			"texture": PBAssetCatalog.is_texture(path),
		}
		var claimed := 0
		for b in buckets:
			if buckets[b]:
				claimed += 1
		assert_eq(claimed, 1, "Each asset must land in exactly one picker bucket: %s" % path)
	# Particles belong to no picker at all
	assert_true(PBAssetCatalog.is_particle("res://addons/poibuilder/materials/textures/particle_flame.png"),
			"Particles must classify as particle")
	assert_false(PBAssetCatalog.is_texture("res://addons/poibuilder/materials/textures/particle_flame.png"),
			"Particles must not appear in the paint texture bucket")
