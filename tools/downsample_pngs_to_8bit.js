#!/usr/bin/env node
// One-shot fix for Terrain3D's "Texture formats don't match" warning.
// Reads listed source PNGs, converts any that are 16-bit-per-channel to
// 8-bit, and overwrites them in place. 8-bit RGB matches the most common
// import bucket in this project (graund/maountines/snow), so unifying
// formats here lets Terrain3DAssets validate cleanly.
//
// Run from project root:
//   node tools/downsample_pngs_to_8bit.js
//
// pngjs is the only runtime dependency. Install once with `npm i pngjs`.

const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');

// Edit this list when more terrain textures are added.
const FILES = [
	'textures/cobblestone.png',
	'textures/road.png',
	'textures/rockdown.png',
	'textures/downdown.png',
];

function downsampleToRGB8(srcPath) {
	const buf = fs.readFileSync(srcPath);
	const png = PNG.sync.read(buf);
	const { width, height, depth, colorType } = png;
	const had16Bit = depth === 16;
	const hadAlpha = (colorType & 4) !== 0; // PNG color type bit 2 = alpha

	if (!had16Bit && !hadAlpha && colorType === 2 /* RGB */) {
		console.log(`  skip ${path.basename(srcPath)} — already 8-bit RGB`);
		return;
	}

	// pngjs stores pixels as 8-bit RGBA after read() regardless of source.
	// (For 16-bit source it scales down to 8.) So png.data is always
	// width*height*4 bytes, in RGBA8.
	const inData = png.data;
	if (inData.length !== width * height * 4) {
		console.log(`  WARN ${path.basename(srcPath)} — unexpected data length ${inData.length}`);
		return;
	}

	// Re-encode as 8-bit RGB (drop alpha) so it matches the project baseline
	// and the resulting file is also smaller.
	const out = new PNG({
		width,
		height,
		colorType: 2,        // RGB
		inputColorType: 6,   // tell pngjs source is RGBA in input array
		bitDepth: 8,
		inputHasAlpha: true,
	});
	// PNG (encoder) wants RGBA in its data buffer; it will strip alpha because
	// colorType=2.
	out.data = inData;
	const encoded = PNG.sync.write(out);
	fs.writeFileSync(srcPath, encoded);

	const sizeKB = (encoded.length / 1024).toFixed(1);
	console.log(`  ${path.basename(srcPath)}: ${width}x${height} ${depth}-bit ${hadAlpha ? 'RGBA' : 'RGB'} -> 8-bit RGB (${sizeKB} KB)`);
}

console.log('[downsample] starting');
for (const rel of FILES) {
	const abs = path.resolve(__dirname, '..', rel);
	if (!fs.existsSync(abs)) {
		console.log(`  miss ${rel}`);
		continue;
	}
	try {
		downsampleToRGB8(abs);
	} catch (e) {
		console.log(`  ERROR ${rel}: ${e.message}`);
	}
}
console.log('[downsample] done — refresh Godot to re-import.');
