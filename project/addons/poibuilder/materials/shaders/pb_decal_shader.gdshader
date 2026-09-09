// PBDecalShader — Billboard decal shader with face bounds clipping for PoiBuilder.
//
// Clips decal billboard quads to the face planar bounds so they do not stick out past edges.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 face_u = vec3(1.0, 0.0, 0.0);
uniform vec3 face_v = vec3(0.0, 1.0, 0.0);
uniform vec4 face_bounds = vec4(-1000.0, 1000.0, -1000.0, 1000.0); // min_u, max_u, min_v, max_v in node local coordinates
uniform mat4 stamp_to_mesh = mat4(1.0);
uniform bool clip_to_face = true;

varying vec2 face_uv;

void vertex() {
	// Compute face planar coordinates in mesh-local space (invariant to object-mode movement)
	vec3 mesh_pos = (stamp_to_mesh * vec4(VERTEX, 1.0)).xyz;
	face_uv = vec2(dot(face_u, mesh_pos), dot(face_v, mesh_pos));
}

void fragment() {
	if (clip_to_face) {
		if (face_uv.x < face_bounds.x || face_uv.x > face_bounds.y || face_uv.y < face_bounds.z || face_uv.y > face_bounds.w) {
			discard;
		}
	}

	vec4 col = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
