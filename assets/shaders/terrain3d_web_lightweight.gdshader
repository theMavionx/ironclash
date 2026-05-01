shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

// Web terrain shader: keep Terrain3D albedo textures, but avoid the large
// material/uniform arrays from the default shader that exceed WebGL UBO limits.

const int WEB_REGION_LIMIT = 96;

const int TEX_GROUND = 0;
const int TEX_MOUNTAIN = 1;
const int TEX_ROAD = 2;
const int TEX_ROCK = 3;
const int TEX_ROCK_ALT = 4;
const int TEX_SNOW = 5;
const int TEX_COBBLE = 6;

uniform vec3 _camera_pos = vec3(0.0);
uniform float _mesh_size = 48.0;
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0;
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625;
uniform vec2 _region_locations[WEB_REGION_LIMIT];

uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap, repeat_enable;

uniform float auto_slope : hint_range(0.0, 4.0) = 1.0;
uniform float auto_height_reduction : hint_range(0.0, 1.0) = 0.1;
uniform int auto_base_texture : hint_range(0, 6) = 0;
uniform int auto_overlay_texture : hint_range(0, 6) = 1;
uniform bool height_blending = true;
uniform float blend_sharpness : hint_range(0.0, 1.0) = 0.87;

varying vec3 v_world_vertex;
varying vec3 v_world_normal;

int find_region_layer(vec2 region_location) {
	ivec2 wanted = ivec2(floor(region_location));
	for (int i = 0; i < WEB_REGION_LIMIT; i++) {
		if (ivec2(round(_region_locations[i])) == wanted) {
			return i;
		}
	}
	return -1;
}

ivec3 get_index_coord(vec2 uv) {
	vec2 rounded_uv = round(uv);
	vec2 region_location = floor(rounded_uv * _region_texel_size);
	int layer = find_region_layer(region_location);
	vec2 region_uv = mod(rounded_uv, _region_size);
	return ivec3(ivec2(region_uv), layer);
}

vec3 get_index_uv(vec2 uv2) {
	vec2 region_location = floor(uv2);
	int layer = find_region_layer(region_location);
	if (layer < 0) {
		return vec3(fract(uv2), -1.0);
	}
	return vec3(uv2 - _region_locations[layer], float(layer));
}

float height_at(vec2 uv, float fallback_height) {
	ivec3 index = get_index_coord(uv);
	if (index.z < 0) {
		return fallback_height;
	}
	return texelFetch(_height_maps, index, 0).r;
}

int safe_texture_id(int layer) {
	return clamp(layer, 0, TEX_COBBLE);
}

float texture_scale_for_layer(int layer) {
	if (layer == TEX_ROAD) {
		return 0.16;
	}
	if (layer == TEX_COBBLE) {
		return 0.22;
	}
	if (layer == TEX_SNOW) {
		return 0.09;
	}
	if (layer == TEX_MOUNTAIN || layer == TEX_ROCK || layer == TEX_ROCK_ALT) {
		return 0.075;
	}
	return 0.085;
}

vec4 sample_albedo_layer(int layer, vec2 world_xz, vec4 ddxy) {
	int safe_layer = safe_texture_id(layer);
	float scale = texture_scale_for_layer(safe_layer);
	vec2 uv = world_xz * scale;
	vec4 scaled_dd = ddxy * scale;
	return textureGrad(_texture_array_albedo, vec3(uv, float(safe_layer)), scaled_dd.xy, scaled_dd.zw);
}

float height_blend_weight(float a_height, float b_height, float blend) {
	if (!height_blending) {
		return clamp(blend, 0.0, 1.0);
	}
	float ma = max(a_height + (1.0 - blend), b_height + blend) - (1.001 - blend_sharpness);
	float b1 = max(a_height + (1.0 - blend) - ma, 0.0);
	float b2 = max(b_height + blend - ma, 0.0);
	return b2 / max(b1 + b2, 0.0001);
}

float box_mask(vec2 p, vec2 center, vec2 half_extents, float feather) {
	vec2 q = abs(p - center) - half_extents;
	float outside = length(max(q, vec2(0.0)));
	float inside = min(max(q.x, q.y), 0.0);
	float signed_distance = outside + inside;
	return 1.0 - smoothstep(0.0, feather, signed_distance);
}

float segment_distance(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
	return length(pa - ba * h);
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float road_mask(vec2 p) {
	float d = min(
		segment_distance(p, vec2(12.0, 24.0), vec2(-8.0, -25.0)),
		segment_distance(p, vec2(-8.0, -25.0), vec2(-24.0, -76.0))
	);
	return 1.0 - smoothstep(4.5, 7.5, d);
}

float base_cobble_mask(vec2 p) {
	float red_base = box_mask(p, vec2(15.5, 20.0), vec2(21.0, 15.5), 4.0);
	float blue_base = box_mask(p, vec2(-22.5, -73.0), vec2(22.0, 16.0), 4.0);
	return max(red_base, blue_base);
}

int procedural_base_layer(float slope, float height_value, float base_mask_value, float road_mask_value, vec2 world_xz) {
	float patch = value_noise(world_xz * 0.035);
	if (base_mask_value > 0.45) {
		return TEX_COBBLE;
	}
	if (road_mask_value > 0.50) {
		return TEX_ROAD;
	}
	if (height_value > 42.0) {
		return TEX_SNOW;
	}
	if (slope > 0.52) {
		return TEX_ROCK;
	}
	if (slope > 0.34 || patch > 0.76) {
		return TEX_MOUNTAIN;
	}
	if (patch < 0.18) {
		return TEX_ROCK_ALT;
	}
	return TEX_GROUND;
}

int procedural_overlay_layer(float slope, float height_value, int base_layer, vec2 world_xz) {
	float patch = value_noise(world_xz * 0.028 + vec2(19.3, 7.1));
	if (height_value > 32.0) {
		return TEX_SNOW;
	}
	if (slope > 0.32) {
		return TEX_MOUNTAIN;
	}
	if (patch > 0.68 && base_layer == TEX_GROUND) {
		return TEX_ROCK_ALT;
	}
	if (patch < 0.22 && base_layer == TEX_MOUNTAIN) {
		return TEX_GROUND;
	}
	return base_layer;
}

float procedural_blend(float slope, float height_value, int base_layer, int overlay_layer, vec2 world_xz) {
	if (base_layer == overlay_layer) {
		return 0.0;
	}
	float snow_blend = smoothstep(30.0, 48.0, height_value);
	float slope_blend = smoothstep(0.25, 0.70, slope);
	float patch_blend = smoothstep(0.40, 0.86, value_noise(world_xz * 0.028 + vec2(19.3, 7.1)));
	if (overlay_layer == TEX_SNOW) {
		return snow_blend;
	}
	return max(slope_blend, patch_blend * 0.65);
}

void resolve_layers(uint control, float slope, float height_value, float base_mask_value, float road_mask_value, vec2 world_xz, out int base_layer, out int overlay_layer, out float blend) {
	bool has_decoded_control = control != 0u;
	bool auto_shader = !has_decoded_control || bool(control & 0x1u);

	if (auto_shader) {
		base_layer = procedural_base_layer(slope, height_value, base_mask_value, road_mask_value, world_xz);
		overlay_layer = procedural_overlay_layer(slope, height_value, base_layer, world_xz);
		blend = procedural_blend(slope, height_value, base_layer, overlay_layer, world_xz);
		return;
	}

	base_layer = safe_texture_id(int((control >> 27u) & 0x1Fu));
	overlay_layer = safe_texture_id(int((control >> 22u) & 0x1Fu));
	blend = float((control >> 14u) & 0xFFu) / 255.0;

	float auto_blend = clamp(
		(auto_slope * 2.0 * (v_world_normal.y - 1.0) + 1.0)
		- auto_height_reduction * 0.01 * height_value,
		0.0,
		1.0
	);
	blend = mix(blend, auto_blend, 0.0);
}

void vertex() {
	v_world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	float scale = MODEL_MATRIX[0][0];
	float vertex_xz_dist = length(v_world_vertex.xz - _camera_pos.xz);
	float vertex_lerp = smoothstep(0.55, 0.95, (vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));

	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	vec2 shift = (scale < _vertex_spacing + 1e-6)
		? mix(
			v_fract,
			vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_world_vertex.z * _vertex_density, 4.0)) * round(mod(v_world_vertex.x * _vertex_density, 4.0)) * 0.25))
		)
		: v_fract * round((fract(v_world_vertex.xz * 0.25 / scale) - 0.5) * 4.0);

	vec2 start_pos = v_world_vertex.xz * _vertex_density;
	vec2 end_pos = (v_world_vertex.xz - shift * scale) * _vertex_density;
	v_world_vertex.xz -= shift * scale * vertex_lerp;

	UV = v_world_vertex.xz * _vertex_density;
	UV2 = UV * vec2(_region_texel_size) + vec2(0.5 * _region_texel_size);

	float h_start = height_at(start_pos, v_world_vertex.y);
	float h_end = height_at(end_pos, h_start);
	float h = mix(h_start, h_end, vertex_lerp);
	float h_x = height_at(start_pos + vec2(1.0, 0.0), h);
	float h_z = height_at(start_pos + vec2(0.0, 1.0), h);
	v_world_vertex.y = h;
	v_world_normal = normalize(vec3(h - h_x, _vertex_spacing, h - h_z));

	vec3 w_tangent = normalize(cross(v_world_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(v_world_normal, w_tangent));

	VERTEX = (VIEW_MATRIX * vec4(v_world_vertex, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(v_world_normal, 0.0)).xyz);
	BINORMAL = normalize((VIEW_MATRIX * vec4(w_binormal, 0.0)).xyz);
	TANGENT = normalize((VIEW_MATRIX * vec4(w_tangent, 0.0)).xyz);
}

void fragment() {
	vec3 dx = dFdx(v_world_vertex);
	vec3 dy = dFdy(v_world_vertex);
	vec4 ddxy = vec4(dx.xz, dy.xz);
	float region_mip = log2(max(length(dx.xz), length(dy.xz)) * _vertex_density);

	// Terrain3D control maps are integer textures on native renderers, but some
	// WebGL/Compatibility paths bind them as normalized textures. Sampling them
	// from a custom shader can trigger signed/unsigned sampler mismatches and
	// make the whole terrain disappear. Keep web stable by using the same
	// albedo texture array with procedural layer selection instead.
	uint control = 0u;
	if (control != 0u && bool((control >> 2u) & 0x1u)) {
		discard;
	}

	float slope = 1.0 - clamp(v_world_normal.y, 0.0, 1.0);
	float cobble_mask = base_cobble_mask(v_world_vertex.xz);
	float road_value = road_mask(v_world_vertex.xz) * (1.0 - cobble_mask);

	int base_layer;
	int overlay_layer;
	float blend;
	resolve_layers(control, slope, v_world_vertex.y, cobble_mask, road_value, v_world_vertex.xz, base_layer, overlay_layer, blend);

	vec4 base_albedo = sample_albedo_layer(base_layer, v_world_vertex.xz, ddxy);
	vec4 overlay_albedo = sample_albedo_layer(overlay_layer, v_world_vertex.xz, ddxy);
	float blend_weight = height_blend_weight(base_albedo.a, overlay_albedo.a, blend);
	vec3 albedo = mix(base_albedo.rgb, overlay_albedo.rgb, blend_weight);

	vec3 region_uv = get_index_uv(UV2);
	vec4 color_map = region_uv.z > -0.5 ? textureLod(_color_maps, region_uv, region_mip) : vec4(1.0, 1.0, 1.0, 0.0);
	albedo *= mix(vec3(1.0), max(color_map.rgb * 1.25, vec3(0.2)), clamp(color_map.a * 0.35, 0.0, 1.0));

	ALBEDO = albedo;
	ROUGHNESS = 0.86;
	SPECULAR = 0.18;
}
