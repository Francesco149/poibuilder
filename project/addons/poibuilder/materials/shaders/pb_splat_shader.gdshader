// PBSplatShader — Multi-layer texture splatting shader for PoiBuilder.
//
// Blends up to 8 texture layers over a face's base texture using painted alpha masks.
// Each additional layer follows the identical UV tiling as the base texture (UV).
// The alpha masks are localized per face using normalized face coordinates (UV2).
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
// Dedicated Stamp Layer (copied 1:1, sits on top of all splat layers)
uniform bool stamp_layer_enabled = false;
uniform sampler2D stamp_layer_texture : source_color, filter_linear, repeat_disable;


void fragment() {
	vec4 base_col = texture(base_texture, UV) * base_color;
	vec3 albedo = base_col.rgb;
	float cur_roughness = roughness;

	if (layer_1_enabled) {
		vec4 l_col = texture(layer_1_texture, UV) * layer_1_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_1_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_1_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_1_roughness, blend * l_col.a);
	}
	if (layer_2_enabled) {
		vec4 l_col = texture(layer_2_texture, UV) * layer_2_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_2_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_2_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_2_roughness, blend * l_col.a);
	}
	if (layer_3_enabled) {
		vec4 l_col = texture(layer_3_texture, UV) * layer_3_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_3_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_3_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_3_roughness, blend * l_col.a);
	}
	if (layer_4_enabled) {
		vec4 l_col = texture(layer_4_texture, UV) * layer_4_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_4_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_4_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_4_roughness, blend * l_col.a);
	}
	if (layer_5_enabled) {
		vec4 l_col = texture(layer_5_texture, UV) * layer_5_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_5_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_5_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_5_roughness, blend * l_col.a);
	}
	if (layer_6_enabled) {
		vec4 l_col = texture(layer_6_texture, UV) * layer_6_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_6_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_6_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_6_roughness, blend * l_col.a);
	}
	if (layer_7_enabled) {
		vec4 l_col = texture(layer_7_texture, UV) * layer_7_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_7_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_7_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_7_roughness, blend * l_col.a);
	}
	if (layer_8_enabled) {
		vec4 l_col = texture(layer_8_texture, UV) * layer_8_color;
		float m = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(layer_8_mask, UV2).r : 0.0;
		float fw = max(fwidth(m), 0.0001);
		float edge_w = mix(max(fw * 2.0, 0.02), 0.48, layer_8_roughness);
		float blend = smoothstep(0.5 - edge_w, 0.5 + edge_w, m);
		albedo = mix(albedo, l_col.rgb, blend * l_col.a);
		cur_roughness = mix(cur_roughness, layer_8_roughness, blend * l_col.a);
	}
	if (stamp_layer_enabled) {
		vec4 stamp_col = (UV2.x >= 0.0 && UV2.x <= 1.0 && UV2.y >= 0.0 && UV2.y <= 1.0) ? texture(stamp_layer_texture, UV2) : vec4(0.0);
		albedo = mix(albedo, stamp_col.rgb, stamp_col.a);
	}

	ALBEDO = albedo;
	ROUGHNESS = cur_roughness;
}
