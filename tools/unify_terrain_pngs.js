#!/usr/bin/env node
// Force every terrain albedo PNG to 8-bit RGBA so Terrain3DAssets can
// validate the texture array without "Texture formats don't match".
// Run from project root:
//   node tools/unify_terrain_pngs.js

const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');

const FILES = [
	'textures/graund.png',
	'textures/maountines.png',
	'textures/road.png',
	'textures/rockdown.png',
	'textures/downdown.png',
	'textures/snow.png',
	'textures/cobblestone.png',
];

function toRGBA8(srcPath) {
	const buf = fs.readFileSync(srcPath);
	const png = PNG.sync.read(buf);
	const { width, height, depth, colorType } = png;

	// pngjs always exposes 8-bit RGBA in png.data after read(), regardless of
	// the source (it scales 16-bit down). So we just re-encode with explicit
	// 8-bit RGBA settings and Godot will see a uniform format.
	const out = new PNG({
		width,
		height,
		colorType: 6,       // RGBA
		bitDepth: 8,
	});
	out.data = png.data;
	const encoded = PNG.sync.write(out);
	fs.writeFileSync(srcPath, encoded);
	const sizeKB = (encoded.length / 1024).toFixed(1);
	console.log(`  ${path.basename(srcPath)}: was depth=${depth} colorType=${colorType} -> 8-bit RGBA (${sizeKB} KB)`);
}

console.log('[unify] starting');
for (const rel of FILES) {
	const abs = path.resolve(__dirname, '..', rel);
	if (!fs.existsSync(abs)) {
		console.log(`  miss ${rel}`);
		continue;
	}
	try {
		toRGBA8(abs);
	} catch (e) {
		console.log(`  ERROR ${rel}: ${e.message}`);
	}
}
console.log('[unify] done. Refresh Godot — it will re-import all 7 textures uniformly.');
