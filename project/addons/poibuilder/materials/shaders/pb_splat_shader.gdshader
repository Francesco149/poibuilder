// PBSplatShader — Multi-layer texture splatting shader for PoiBuilder.
//
// Blends up to 8 texture layers over a face's base texture using painted alpha masks.
// Each additional layer follows the identical UV tiling as the base texture (UV).
// The alpha masks are localized per face using normalized face coordinates, which
// travel in the CUSTOM0 vertex attribute (NOT UV2 — UV2 is left free for a
// LightmapGI unwrap, so paint and baked lighting coexist on one surface).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D base_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 1
uniform bool layer_1_enabled = false;
uniform sampler2D layer_1_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_1_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_1_color : source_color = vec4(1.0);
uniform float layer_1_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 2
uniform bool layer_2_enabled = false;
uniform sampler2D layer_2_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_2_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_2_color : source_color = vec4(1.0);
uniform float layer_2_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 3
uniform bool layer_3_enabled = false;
uniform sampler2D layer_3_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_3_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_3_color : source_color = vec4(1.0);
uniform float layer_3_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 4
uniform bool layer_4_enabled = false;
uniform sampler2D layer_4_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_4_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_4_color : source_color = vec4(1.0);
uniform float layer_4_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 5
uniform bool layer_5_enabled = false;
uniform sampler2D layer_5_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_5_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_5_color : source_color = vec4(1.0);
uniform float layer_5_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 6
uniform bool layer_6_enabled = false;
uniform sampler2D layer_6_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_6_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_6_color : source_color = vec4(1.0);
uniform float layer_6_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 7
uniform bool layer_7_enabled = false;
uniform sampler2D layer_7_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_7_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_7_color : source_color = vec4(1.0);
uniform float layer_7_roughness : hint_range(0.0, 1.0) = 0.8;

// Layer 8
uniform bool layer_8_enabled = false;
uniform sampler2D layer_8_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_8_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec4 layer_8_color : source_color = vec4(1.0);
uniform float layer_8_roughness : hint_range(0.0, 1.0) = 0.8;
// Dedicated Stamp Layer (copied 1:1, sits on top of all splat layers).
// The image is a WINDOW inside the face's [0, 1] mask space (cropped to the
// painted area so its texels/m stay uniform on large faces); the two uniforms
// below map mask uv -> window uv. They default to the identity, which is what
// a layer painted by an older build covers (the whole face rect).
uniform bool stamp_layer_enabled = false;
uniform sampler2D stamp_layer_texture : source_color, filter_linear, repeat_disable;
uniform vec2 stamp_layer_uv_offset = vec2(0.0, 0.0);
uniform vec2 stamp_layer_uv_scale = vec2(1.0, 1.0);

// Face-planar mask coordinate, delivered by the CUSTOM0 vertex attribute.
// .xy carries it; the shader treats values outside [0,1] as "outside the
// painted area" (base texture shows through).
varying vec2 splat_uv;

void vertex() {
	splat_uv = CUSTOM0.xy;
}

void fragment() {
	vec4 base_col = texture(base_texture, UV) * base_color;
	vec3 albedo = base_col.rgb;
	float cur_roughness = roughness;

	if (layer_1_enabled) {
		vec4 l_col = texture(layer_1_texture, UV) * layer_1_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_1_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_1_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_1_roughness, blend * l_col.a);
	}
	if (layer_2_enabled) {
		vec4 l_col = texture(layer_2_texture, UV) * layer_2_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_2_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_2_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_2_roughness, blend * l_col.a);
	}
	if (layer_3_enabled) {
		vec4 l_col = texture(layer_3_texture, UV) * layer_3_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_3_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_3_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_3_roughness, blend * l_col.a);
	}
	if (layer_4_enabled) {
		vec4 l_col = texture(layer_4_texture, UV) * layer_4_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_4_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_4_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_4_roughness, blend * l_col.a);
	}
	if (layer_5_enabled) {
		vec4 l_col = texture(layer_5_texture, UV) * layer_5_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_5_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_5_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_5_roughness, blend * l_col.a);
	}
	if (layer_6_enabled) {
		vec4 l_col = texture(layer_6_texture, UV) * layer_6_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_6_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_6_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_6_roughness, blend * l_col.a);
	}
	if (layer_7_enabled) {
		vec4 l_col = texture(layer_7_texture, UV) * layer_7_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_7_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_7_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_7_roughness, blend * l_col.a);
	}
	if (layer_8_enabled) {
		vec4 l_col = texture(layer_8_texture, UV) * layer_8_color;
		float m = (splat_uv.x >= 0.0 && splat_uv.x <= 1.0 && splat_uv.y >= 0.0 && splat_uv.y <= 1.0) ? texture(layer_8_mask, splat_uv).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_8_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_8_roughness, blend * l_col.a);
	}
	if (stamp_layer_enabled) {
		// Mask uv -> decal window uv; outside the window there is no decal
		// (the same [0, 1] guard the masks use).
		vec2 decal_uv = (splat_uv - stamp_layer_uv_offset) * stamp_layer_uv_scale;
		vec4 stamp_col = (decal_uv.x >= 0.0 && decal_uv.x <= 1.0 && decal_uv.y >= 0.0 && decal_uv.y <= 1.0) ? texture(stamp_layer_texture, decal_uv) : vec4(0.0);
		albedo = mix(albedo, stamp_col.rgb, stamp_col.a);
	}

	ALBEDO = albedo;
	ROUGHNESS = cur_roughness;
}
