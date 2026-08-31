## Test: PBFace
##
## Verifies PBFace creation, index validation, lazy-cached distinct indices and perimeter edges,
## quad detection and conversion, index transformations, deep copy semantics, UV settings, and static helpers.
extends GutTest

# ==============================================================================
# 1. Construction & Defaults
# ==============================================================================

func test_construction_default():
	var face := PBFace.new()
	assert_eq(face.get_indexes().size(), 0, "Default face should have empty indexes")
	assert_eq(face.smoothing_group, 0, "Default smoothing group should be 0")
	assert_eq(face.submesh_index, 0, "Default submesh index should be 0")
	assert_false(face.manual_uv, "Default manual_uv should be false")
	assert_eq(face.texture_group, -1, "Default texture group should be -1")
	assert_eq(face.element_group, 0, "Default element group should be 0")
	assert_eq(face.uv_offset, Vector2.ZERO)
	assert_eq(face.uv_rotation, 0.0)
	assert_eq(face.uv_scale, Vector2.ONE)
	assert_false(face.uv_use_world_space)
	assert_false(face.uv_flip_u)
	assert_false(face.uv_flip_v)
	assert_false(face.uv_swap_uv)
	assert_eq(face.uv_fill, 1)
	assert_eq(face.uv_anchor, 9)

func test_construction_with_indexes():
	var indices := PackedInt32Array([0, 1, 2])
	var face := PBFace.new(indices)
	assert_eq(face.get_indexes(), indices)
	assert_eq(face.indexes, indices)

func test_construction_make_factory():
	var indices := PackedInt32Array([3, 4, 5, 5, 6, 3])
	var face := PBFace.make(indices)
	assert_not_null(face)
	assert_eq(face.get_indexes(), indices)

# ==============================================================================
# 2. Index Validation
# ==============================================================================

func test_index_validation_in_constructor():
	# Length 2 is not a multiple of 3 -> rejected, left empty
	var invalid_indices := PackedInt32Array([0, 1])
	var face := PBFace.new(invalid_indices)
	assert_eq(face.get_indexes().size(), 0, "Invalid index array in constructor should result in empty face")

func test_index_validation_in_setter():
	var valid := PackedInt32Array([0, 1, 2])
	var face := PBFace.new(valid)
	assert_eq(face.get_indexes().size(), 3)

	# Try setting invalid array of size 4
	var invalid := PackedInt32Array([10, 11, 12, 13])
	face.set_indexes(invalid)
	assert_eq(face.get_indexes(), valid, "set_indexes should reject non-multiple of 3 and retain previous indexes")

	# Property setter should also reject invalid
	face.indexes = PackedInt32Array([20, 21])
	assert_eq(face.get_indexes(), valid, "Property setter should reject non-multiple of 3")

	# Valid replacement of size 6
	var valid_quad := PackedInt32Array([0, 1, 2, 2, 3, 0])
	face.set_indexes(valid_quad)
	assert_eq(face.get_indexes(), valid_quad, "set_indexes should accept valid array of multiple of 3")

# ==============================================================================
# 3. Distinct Indexes
# ==============================================================================

func test_distinct_indexes_quad():
	# Quad [0, 1, 2, 2, 3, 0] has unique vertices [0, 1, 2, 3] in first-seen order
	var quad_indices := PackedInt32Array([0, 1, 2, 2, 3, 0])
	var face := PBFace.new(quad_indices)
	var distinct := face.get_distinct_indexes()

	assert_eq(distinct.size(), 4, "Quad should have 4 distinct vertex indices")
	assert_eq(distinct[0], 0)
	assert_eq(distinct[1], 1)
	assert_eq(distinct[2], 2)
	assert_eq(distinct[3], 3)

func test_distinct_indexes_empty():
	var face := PBFace.new()
	assert_eq(face.get_distinct_indexes().size(), 0)

# ==============================================================================
# 4. Edge Caching (Quad Perimeter vs Diagonal)
# ==============================================================================

func test_edge_caching_quad():
	# Quad composed of triangles (0,1,2) and (2,3,0).
	# Shared interior edge is (2,0) / (0,2).
	# Perimeter edges are (0,1), (1,2), (2,3), (3,0).
	var face := PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))
	var edges := face.get_edges()

	assert_eq(edges.size(), 4, "Quad perimeter should have exactly 4 edges")

	# Check that interior edge (2, 0) is eliminated
	var diag_edge := PBEdge.new(2, 0)
	var has_diag := false
	for e in edges:
		if e.equals(diag_edge):
			has_diag = true
			break
	assert_false(has_diag, "Internal diagonal edge (2, 0) must be removed from perimeter edges")

	# Check that all 4 perimeter edges exist
	var e01 := PBEdge.new(0, 1)
	var e12 := PBEdge.new(1, 2)
	var e23 := PBEdge.new(2, 3)
	var e30 := PBEdge.new(3, 0)

	var has_e01 := false
	var has_e12 := false
	var has_e23 := false
	var has_e30 := false

	for e in edges:
		if e.equals(e01):
			has_e01 = true
		elif e.equals(e12):
			has_e12 = true
		elif e.equals(e23):
			has_e23 = true
		elif e.equals(e30):
			has_e30 = true

	assert_true(has_e01, "Perimeter must contain edge (0, 1)")
	assert_true(has_e12, "Perimeter must contain edge (1, 2)")
	assert_true(has_e23, "Perimeter must contain edge (2, 3)")
	assert_true(has_e30, "Perimeter must contain edge (3, 0)")

# ==============================================================================
# 5. Triangle Face Edges & Distinct
# ==============================================================================

func test_triangle_face_edges():
	var face := PBFace.new(PackedInt32Array([4, 5, 6]))
	var edges := face.get_edges()
	assert_eq(edges.size(), 3, "Single triangle face must have 3 perimeter edges")

	var distinct := face.get_distinct_indexes()
	assert_eq(distinct.size(), 3)
	assert_eq(distinct[0], 4)
	assert_eq(distinct[1], 5)
	assert_eq(distinct[2], 6)

# ==============================================================================
# 6. Contains Triangle
# ==============================================================================

func test_contains_triangle():
	var face := PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))

	assert_true(face.contains_triangle(0, 1, 2), "Should contain first triangle (0, 1, 2)")
	assert_true(face.contains_triangle(2, 3, 0), "Should contain second triangle (2, 3, 0)")
	assert_false(face.contains_triangle(0, 2, 1), "Should not match different winding (0, 2, 1)")
	assert_false(face.contains_triangle(1, 2, 3), "Should not contain non-existent triangle (1, 2, 3)")
	assert_false(face.contains_triangle(0, 0, 0), "Should not contain arbitrary triangle (0, 0, 0)")

# ==============================================================================
# 7. is_quad / to_quad
# ==============================================================================

func test_is_quad_and_to_quad():
	var quad_face := PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))
	assert_true(quad_face.is_quad(), "Quad face should return true for is_quad()")

	var quad := quad_face.to_quad()
	assert_eq(quad.size(), 4, "to_quad() must return 4 vertices")
	assert_eq(quad[0], 0)
	assert_eq(quad[1], 1)
	assert_eq(quad[2], 2)
	assert_eq(quad[3], 3)

	var tri_face := PBFace.new(PackedInt32Array([0, 1, 2]))
	assert_false(tri_face.is_quad(), "Single triangle face is not a quad")
	assert_eq(tri_face.to_quad().size(), 0, "to_quad() on triangle must return empty array")

	var empty_face := PBFace.new()
	assert_false(empty_face.is_quad(), "Empty face is not a quad")
	assert_eq(empty_face.to_quad().size(), 0)

# ==============================================================================
# 8. Shift Indexes
# ==============================================================================

func test_shift_indexes():
	var face := PBFace.new(PackedInt32Array([0, 1, 2]))
	face.shift_indexes(10)
	assert_eq(face.get_indexes(), PackedInt32Array([10, 11, 12]), "Indexes should be shifted by +10")

	# Verify cache was invalidated and reflects new values
	var distinct := face.get_distinct_indexes()
	assert_eq(distinct, PackedInt32Array([10, 11, 12]), "Distinct indexes should reflect shifted values")
	var edges := face.get_edges()
	assert_eq(edges.size(), 3)
	assert_true(edges[0].contains(10))

# ==============================================================================
# 9. Shift Indexes to Zero
# ==============================================================================

func test_shift_indexes_to_zero():
	var face := PBFace.new(PackedInt32Array([3, 4, 5, 5, 6, 3]))
	face.shift_indexes_to_zero()
	assert_eq(face.get_indexes(), PackedInt32Array([0, 1, 2, 2, 3, 0]), "Lowest index (3) subtracted, base is 0")

	# Test on empty face (should not crash)
	var empty := PBFace.new()
	empty.shift_indexes_to_zero()
	assert_eq(empty.get_indexes().size(), 0)

# ==============================================================================
# 10. Reverse Winding
# ==============================================================================

func test_reverse():
	var face := PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))
	face.reverse()
	assert_eq(face.get_indexes(), PackedInt32Array([0, 3, 2, 2, 1, 0]), "Indexes array reversed in place")

	# Verify cache was invalidated
	assert_true(face.contains_triangle(0, 3, 2))
	assert_true(face.contains_triangle(2, 1, 0))
	assert_false(face.contains_triangle(0, 1, 2))

# ==============================================================================
# 11. copy_from & duplicate_face (Deep Copy Independence)
# ==============================================================================

func test_copy_from_and_duplicate():
	var orig := PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))
	orig.smoothing_group = 4
	orig.submesh_index = 2
	orig.manual_uv = true
	orig.texture_group = 7
	orig.element_group = 3
	orig.uv_offset = Vector2(0.5, 0.25)
	orig.uv_rotation = 45.0
	orig.uv_scale = Vector2(2.0, 3.0)
	orig.uv_use_world_space = true
	orig.uv_flip_u = true
	orig.uv_flip_v = false
	orig.uv_swap_uv = true
	orig.uv_fill = 2
	orig.uv_anchor = 4

	# Test duplicate_face
	var dup := orig.duplicate_face()
	assert_eq(dup.get_indexes(), orig.get_indexes())
	assert_eq(dup.smoothing_group, 4)
	assert_eq(dup.submesh_index, 2)
	assert_eq(dup.manual_uv, true)
	assert_eq(dup.texture_group, 7)
	assert_eq(dup.element_group, 3)
	assert_eq(dup.uv_offset, Vector2(0.5, 0.25))
	assert_eq(dup.uv_rotation, 45.0)
	assert_eq(dup.uv_scale, Vector2(2.0, 3.0))
	assert_eq(dup.uv_use_world_space, true)
	assert_eq(dup.uv_flip_u, true)
	assert_eq(dup.uv_flip_v, false)
	assert_eq(dup.uv_swap_uv, true)
	assert_eq(dup.uv_fill, 2)
	assert_eq(dup.uv_anchor, 4)

	# Verify mutation independence
	dup.shift_indexes(100)
	dup.smoothing_group = 99
	dup.uv_offset = Vector2.ONE

	assert_eq(orig.get_indexes(), PackedInt32Array([0, 1, 2, 2, 3, 0]), "Original indexes must not be affected by duplicate mutation")
	assert_eq(orig.smoothing_group, 4, "Original smoothing group must remain unchanged")
	assert_eq(orig.uv_offset, Vector2(0.5, 0.25), "Original uv_offset must remain unchanged")

	# Test copy_from into new face
	var copy_target := PBFace.new()
	copy_target.copy_from(dup)
	assert_eq(copy_target.smoothing_group, 99)
	assert_eq(copy_target.get_indexes(), PackedInt32Array([100, 101, 102, 102, 103, 100]))

# ==============================================================================
# 12. UV Settings
# ==============================================================================

func test_uv_settings():
	var face := PBFace.new()
	face.uv_offset = Vector2(1.0, -1.0)
	face.uv_rotation = 90.0
	face.uv_scale = Vector2(0.5, 0.5)
	face.uv_use_world_space = true
	face.uv_flip_u = true
	face.uv_flip_v = true
	face.uv_swap_uv = true
	face.uv_fill = 0 # Fit
	face.uv_anchor = 0 # UpperLeft
	face.manual_uv = true
	face.texture_group = 12
	face.element_group = 5

	assert_eq(face.uv_offset, Vector2(1.0, -1.0))
	assert_eq(face.uv_rotation, 90.0)
	assert_eq(face.uv_scale, Vector2(0.5, 0.5))
	assert_true(face.uv_use_world_space)
	assert_true(face.uv_flip_u)
	assert_true(face.uv_flip_v)
	assert_true(face.uv_swap_uv)
	assert_eq(face.uv_fill, 0)
	assert_eq(face.uv_anchor, 0)
	assert_true(face.manual_uv)
	assert_eq(face.texture_group, 12)
	assert_eq(face.element_group, 5)

# ==============================================================================
# 13. Static Helpers
# ==============================================================================

func test_static_helpers():
	var f1 := PBFace.new(PackedInt32Array([0, 1, 2]))
	var f2 := PBFace.new(PackedInt32Array([2, 3, 4, 4, 5, 2]))
	var faces: Array[PBFace] = [f1, f2]

	var all_indexes := PBFace.get_all_indexes(faces)
	assert_eq(all_indexes, PackedInt32Array([0, 1, 2, 2, 3, 4, 4, 5, 2]), "Should concatenate all triangle indexes")

	var all_distinct := PBFace.get_all_distinct_indexes(faces)
	assert_eq(all_distinct, PackedInt32Array([0, 1, 2, 2, 3, 4, 5]), "Should concatenate distinct indexes per face")

# ==============================================================================
# 14. String Representation (_to_string)
# ==============================================================================

func test_to_string():
	var empty := PBFace.new()
	assert_eq(empty._to_string(), "")
	assert_eq(str(empty), "")

	var single_tri := PBFace.new(PackedInt32Array([0, 1, 2]))
	assert_eq(single_tri._to_string(), "[0, 1, 2]")
	assert_eq(str(single_tri), "[0, 1, 2]")

	var quad := PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))
	assert_eq(quad._to_string(), "[0, 1, 2], [2, 3, 0]")
	assert_eq(str(quad), "[0, 1, 2], [2, 3, 0]")
