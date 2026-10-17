// PBAtlasTile — wrap mesh UVs inside one atlas cell.
//
// UV is treated as a repeat count (PoiBuilder Auto UV: 1 unit = 1 meter).
// tile_origin / tile_size are a 0–1 rectangle on the sheet. Default size
// (1,1) is ordinary full-texture tiling.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D albedo_map : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D emission_map : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 emission_color : source_color = vec4(0.0);
uniform bool enable_emission = false;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_amount : hint_range(0.0, 2.0) = 1.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float smoothness : hint_range(0.0, 1.0) = 0.2;
uniform bool enable_alpha_clip = false;
uniform float alpha_clip_threshold : hint_range(0.0, 1.0) = 0.5;
uniform vec2 tile_origin = vec2(0.0, 0.0);
uniform vec2 tile_size = vec2(1.0, 1.0);

vec2 atlas_uv(vec2 uv) {
	vec2 ts = max(tile_size, vec2(1.0e-4));
	return fract(uv) * ts + tile_origin;
}

void fragment() {
	vec2 uv = atlas_uv(UV);
	vec4 alb = texture(albedo_map, uv) * albedo_color;
	if (enable_alpha_clip && alb.a < alpha_clip_threshold) {
		discard;
	}
	ALBEDO = alb.rgb;
	// Do not write ALPHA. Writing it forces transparent shading, which made
	// atlas cells see-through even when clip discarded the holes.
	METALLIC = metallic;
	ROUGHNESS = clamp(1.0 - smoothness, 0.0, 1.0);
	if (enable_emission) {
		EMISSION = texture(emission_map, uv).rgb * emission_color.rgb;
	}
	NORMAL_MAP = texture(normal_map, uv).rgb;
	NORMAL_MAP_DEPTH = normal_amount;
}
