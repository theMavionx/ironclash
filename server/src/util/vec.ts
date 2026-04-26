// Pure-function vector math for the server. No allocations elsewhere — every
// helper returns a fresh tuple, callers reuse if needed. Performance is fine
// at the scale we run (10 players × 30 Hz tick).

import type { Vec3 } from "../../../shared/protocol.ts";

export function vec_add(a: Vec3, b: Vec3): Vec3 { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
export function vec_sub(a: Vec3, b: Vec3): Vec3 { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
export function vec_scale(v: Vec3, s: number): Vec3 { return [v[0] * s, v[1] * s, v[2] * s]; }
export function vec_dot(a: Vec3, b: Vec3): number { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
export function vec_len_sq(v: Vec3): number { return v[0] * v[0] + v[1] * v[1] + v[2] * v[2]; }
export function vec_len(v: Vec3): number { return Math.sqrt(vec_len_sq(v)); }

export function vec_normalize(v: Vec3): Vec3 {
	const l: number = vec_len(v);
	if (l < 1e-6) return [0, 0, 0];
	return [v[0] / l, v[1] / l, v[2] / l];
}

export function vec_dist(a: Vec3, b: Vec3): number {
	return vec_len(vec_sub(a, b));
}

/** Validate a Vec3 wire-decoded payload — must be 3 finite numbers within
 *  the given absolute bound. Used to gate every pos / dir / vel from clients. */
export function is_finite_vec3(v: unknown, max_abs: number): v is Vec3 {
	if (!Array.isArray(v) || v.length !== 3) return false;
	for (let i = 0; i < 3; i++) {
		const n: unknown = v[i];
		if (typeof n !== "number" || !Number.isFinite(n) || Math.abs(n) > max_abs) return false;
	}
	return true;
}
