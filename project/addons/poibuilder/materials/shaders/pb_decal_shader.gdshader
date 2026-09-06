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
uniform mat4 mesh_to_world = mat4(1.0);
uniform bool clip_to_face = true;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clip_to_face) {
		// Calculate position in mesh-local coordinates
		vec3 p = (inverse(mesh_to_world) * vec4(world_pos, 1.0)).xyz;
		float u = dot(face_u, p);
		float v = dot(face_v, p);
		if (u < face_bounds.x || u > face_bounds.y || v < face_bounds.z || v > face_bounds.w) {
			discard;
		}
	}

	vec4 col = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
