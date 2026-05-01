shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

// WebGL on some Macs reports GL_MAX_UNIFORM_BLOCK_SIZE = 16384. Terrain3D's
// regular shaders declare _region_map[1024] plus texture/material arrays, which
// can exceed that limit and make the whole terrain disappear. This fallback keeps
// only the data needed to place vertices and uses procedural colors.

const int WEB_REGION_LIMIT = 96;

uniform vec3 _camera_pos = vec3(0.0);
uniform float _mesh_size = 48.0;
uniform uint _background_mode = 1u;
uniform uint _mouse_layer = 0x80000000u;
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0;
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625;
uniform vec2 _region_locations[WEB_REGION_LIMIT];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp usampler2DArray _control_maps : repeat_disable;

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

float height_at(vec2 uv, float fallback_height) {
	ivec3 index = get_index_coord(uv);
	if (index.z < 0) {
		return fallback_height;
	}
	return texelFetch(_height_maps, index, 0).r;
}

bool is_hole(vec2 uv) {
	ivec3 index = get_index_coord(uv);
	if (index.z < 0) {
		return _background_mode == 0u;
	}
	uint control = texelFetch(_control_maps, index, 0).r;
	return bool((control >> 2u) & 0x1u);
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

	if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer) && is_hole(start_pos)) {
		v_world_vertex.x = 0.0 / 0.0;
	} else {
		float h_start = height_at(start_pos, v_world_vertex.y);
		float h_end = height_at(end_pos, h_start);
		float h = mix(h_start, h_end, vertex_lerp);
		float h_x = height_at(start_pos + vec2(1.0, 0.0), h);
		float h_z = height_at(start_pos + vec2(0.0, 1.0), h);
		v_world_vertex.y = h;
		v_world_normal = normalize(vec3(h - h_x, _vertex_spacing, h - h_z));
	}

	VERTEX = (VIEW_MATRIX * vec4(v_world_vertex, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(v_world_normal, 0.0)).xyz);
	BINORMAL = normalize(cross(NORMAL, vec3(1.0, 0.0, 0.0)));
	TANGENT = normalize(cross(BINORMAL, NORMAL));
}

void fragment() {
	float height_factor = clamp((v_world_vertex.y + 4.0) / 42.0, 0.0, 1.0);
	float slope = 1.0 - clamp(v_world_normal.y, 0.0, 1.0);

	vec3 low_ground = vec3(0.30, 0.34, 0.24);
	vec3 dry_ground = vec3(0.42, 0.36, 0.27);
	vec3 rock = vec3(0.43, 0.45, 0.43);
	vec3 snow = vec3(0.82, 0.86, 0.88);

	vec3 color = mix(low_ground, dry_ground, smoothstep(0.12, 0.38, height_factor));
	color = mix(color, rock, smoothstep(0.18, 0.62, slope));
	color = mix(color, snow, smoothstep(0.62, 0.92, height_factor));

	ALBEDO = color;
	ROUGHNESS = 0.82;
	SPECULAR = 0.18;
}
