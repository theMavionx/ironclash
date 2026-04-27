#!/usr/bin/env node
// Slim Main.tscn by extracting embedded Image sub-resources used as
// Terrain3DTextureAsset normal maps into external PNG files.
//
// Usage:
//   node tools/slim_main_tscn.js
//
// Effect:
//   - Reads Main.tscn at the project root.
//   - For each Image sub-resource referenced (transitively) by a
//     Terrain3DTextureAsset.normal_texture, writes textures/<name>_normal.png.
//   - Removes the now-orphaned Image / ImageTexture sub_resource blocks.
//   - Adds [ext_resource] entries for the new PNGs.
//   - Replaces normal_texture = SubResource("ImageTexture_*") with
//     normal_texture = ExtResource("<id>").
//   - Overwrites Main.tscn with the slim version.
//
// Assumes RGBA8 1024x1024 + mipmaps for normal_textures (verified manually).
// PNGs encode only the base mip level — Godot regenerates mips on import.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');
const SCENE_PATH = path.join(ROOT, 'Main.tscn');
const TEX_DIR = path.join(ROOT, 'textures');

function log(...a) { console.log('[slim]', ...a); }

// ---------------------------------------------------------------------------
// PNG encoder (RGBA8, no interlace, single IDAT, filter=none)
// ---------------------------------------------------------------------------
function pngChunk(type, data) {
	const len = Buffer.alloc(4);
	len.writeUInt32BE(data.length, 0);
	const typeBuf = Buffer.from(type, 'ascii');
	const crc = zlib.crc32(Buffer.concat([typeBuf, data]));
	const crcBuf = Buffer.alloc(4);
	crcBuf.writeUInt32BE(crc >>> 0, 0);
	return Buffer.concat([len, typeBuf, data, crcBuf]);
}

function encodeRGBA8PNG(width, height, rgba) {
	if (rgba.length < width * height * 4) {
		throw new Error(`pixel buffer too small: ${rgba.length} < ${width * height * 4}`);
	}
	const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(width, 0);
	ihdr.writeUInt32BE(height, 4);
	ihdr[8] = 8;   // bit depth
	ihdr[9] = 6;   // color type RGBA
	ihdr[10] = 0;  // compression
	ihdr[11] = 0;  // filter method
	ihdr[12] = 0;  // interlace

	const stride = width * 4;
	const filtered = Buffer.alloc((stride + 1) * height);
	for (let y = 0; y < height; y++) {
		filtered[y * (stride + 1)] = 0;  // filter type 'None'
		rgba.copy(filtered, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
	}
	const idat = zlib.deflateSync(filtered);

	return Buffer.concat([
		sig,
		pngChunk('IHDR', ihdr),
		pngChunk('IDAT', idat),
		pngChunk('IEND', Buffer.alloc(0)),
	]);
}

// ---------------------------------------------------------------------------
// .tscn parser — splits into blocks delimited by '[...]' header lines.
// ---------------------------------------------------------------------------
function parseBlocks(text) {
	// Top section before first '[' (gd_scene line is itself a header).
	const blocks = [];
	const re = /^\[(\w+)\s*(.*)\]$/;
	const lines = text.split('\n');
	let cur = { header: '', body: [] };
	for (const line of lines) {
		if (re.test(line)) {
			if (cur.header || cur.body.length) blocks.push(cur);
			cur = { header: line, body: [] };
		} else {
			cur.body.push(line);
		}
	}
	if (cur.header || cur.body.length) blocks.push(cur);
	return blocks;
}

function blockType(b) {
	const m = b.header.match(/^\[(\w+)/);
	return m ? m[1] : '';
}

function blockId(b) {
	const m = b.header.match(/\bid="([^"]+)"/);
	return m ? m[1] : '';
}

function blockSubResType(b) {
	const m = b.header.match(/^\[sub_resource\s+type="([^"]+)"/);
	return m ? m[1] : '';
}

// ---------------------------------------------------------------------------
// Pull a PackedByteArray from a body line list. Looks for the line that has
// `"data": PackedByteArray(...)` (may run very long). Returns Buffer.
// ---------------------------------------------------------------------------
function parsePackedByteArrayFromBody(body) {
	let captured = '';
	let inside = false;
	let depth = 0;
	for (const line of body) {
		if (!inside) {
			const idx = line.indexOf('PackedByteArray(');
			if (idx >= 0) {
				inside = true;
				captured = line.slice(idx + 'PackedByteArray('.length);
				depth = 1;
				// Account for any close paren on same line
				const closeIdx = captured.indexOf(')');
				if (closeIdx >= 0) {
					captured = captured.slice(0, closeIdx);
					inside = false;
					break;
				}
			}
		} else {
			const closeIdx = line.indexOf(')');
			if (closeIdx >= 0) {
				captured += line.slice(0, closeIdx);
				inside = false;
				break;
			}
			captured += line;
		}
	}
	if (!captured) return null;
	// Parse comma-separated integers.
	const parts = captured.split(',');
	const buf = Buffer.alloc(parts.length);
	let written = 0;
	for (const p of parts) {
		const t = p.trim();
		if (!t) continue;
		const n = parseInt(t, 10);
		if (Number.isNaN(n)) continue;
		buf[written++] = n & 0xff;
	}
	return buf.subarray(0, written);
}

function parseImageMetadata(body) {
	const meta = { format: '', width: 0, height: 0, mipmaps: false };
	for (const line of body) {
		const fm = line.match(/^"format":\s*"([^"]+)"/);
		if (fm) meta.format = fm[1];
		const wm = line.match(/^"width":\s*(\d+)/);
		if (wm) meta.width = parseInt(wm[1], 10);
		const hm = line.match(/^"height":\s*(\d+)/);
		if (hm) meta.height = parseInt(hm[1], 10);
		const mm = line.match(/^"mipmaps":\s*(true|false)/);
		if (mm) meta.mipmaps = mm[1] === 'true';
	}
	return meta;
}

function parseImageTextureRef(body) {
	for (const line of body) {
		const m = line.match(/^image\s*=\s*SubResource\("([^"]+)"\)/);
		if (m) return m[1];
	}
	return '';
}

function parseTextureAssetNormalRef(body) {
	for (const line of body) {
		const m = line.match(/^normal_texture\s*=\s*SubResource\("([^"]+)"\)/);
		if (m) return m[1];
	}
	return '';
}

function parseTextureAssetName(body) {
	for (const line of body) {
		const m = line.match(/^name\s*=\s*"([^"]+)"/);
		if (m) return m[1];
	}
	return '';
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
log('reading', SCENE_PATH);
const sizeBefore = fs.statSync(SCENE_PATH).size;
log('size before:', (sizeBefore / 1024 / 1024).toFixed(2), 'MB');

const text = fs.readFileSync(SCENE_PATH, 'utf-8');
const blocks = parseBlocks(text);
log('parsed', blocks.length, 'blocks');

// Index sub_resources by id.
const imageBlocks = new Map();          // id → block
const imageTextureBlocks = new Map();   // id → block (with image ref)
const textureAssetBlocks = [];          // {block, name, normalImageTextureId}

for (const b of blocks) {
	if (blockType(b) !== 'sub_resource') continue;
	const t = blockSubResType(b);
	const id = blockId(b);
	if (t === 'Image') imageBlocks.set(id, b);
	else if (t === 'ImageTexture') imageTextureBlocks.set(id, b);
	else if (t === 'Terrain3DTextureAsset') {
		const ntId = parseTextureAssetNormalRef(b.body);
		const name = parseTextureAssetName(b.body) || ('tex' + textureAssetBlocks.length);
		textureAssetBlocks.push({ block: b, name, normalImageTextureId: ntId });
	}
}

log('Images:', imageBlocks.size, 'ImageTextures:', imageTextureBlocks.size, 'TextureAssets:', textureAssetBlocks.length);

// Resolve ImageTexture → Image and extract.
const extractions = []; // {assetName, pngPath, imageTextureId, imageId}
for (const ta of textureAssetBlocks) {
	if (!ta.normalImageTextureId) continue;
	const itBlock = imageTextureBlocks.get(ta.normalImageTextureId);
	if (!itBlock) {
		log('WARN: ImageTexture not found for asset', ta.name, ta.normalImageTextureId);
		continue;
	}
	const imgId = parseImageTextureRef(itBlock.body);
	if (!imgId) continue;
	const imgBlock = imageBlocks.get(imgId);
	if (!imgBlock) {
		log('WARN: Image not found for ImageTexture', ta.normalImageTextureId);
		continue;
	}
	const meta = parseImageMetadata(imgBlock.body);
	if (meta.format !== 'RGBA8') {
		log('WARN: unexpected format', meta.format, 'for', ta.name, '— skipping');
		continue;
	}
	const data = parsePackedByteArrayFromBody(imgBlock.body);
	if (!data) {
		log('WARN: could not parse data for', ta.name);
		continue;
	}
	const baseSize = meta.width * meta.height * 4;
	if (data.length < baseSize) {
		log('WARN: data shorter than expected for', ta.name, data.length, '<', baseSize);
		continue;
	}
	const baseRgba = data.subarray(0, baseSize);
	const pngBuf = encodeRGBA8PNG(meta.width, meta.height, baseRgba);
	const pngPath = path.join(TEX_DIR, ta.name.toLowerCase() + '_normal.png');
	fs.writeFileSync(pngPath, pngBuf);
	const rel = 'res://textures/' + path.basename(pngPath);
	log('  wrote', rel, '(' + meta.width + 'x' + meta.height + ',', pngBuf.length, 'bytes)');
	extractions.push({
		assetName: ta.name,
		pngRel: rel,
		imageTextureId: ta.normalImageTextureId,
		imageId: imgId,
	});
}

if (extractions.length === 0) {
	log('nothing extracted, scene unchanged');
	process.exit(0);
}

// ---------------------------------------------------------------------------
// Rewrite scene:
//  - Drop sub_resource blocks for Image and ImageTexture we extracted.
//  - Add ext_resource entries for the new PNGs (insert after last ext_resource).
//  - Replace normal_texture = SubResource("ImageTexture_x") with ExtResource("y").
// ---------------------------------------------------------------------------
const droppedImage = new Set(extractions.map(e => e.imageId));
const droppedImageTexture = new Set(extractions.map(e => e.imageTextureId));
const itToExtId = new Map();  // ImageTexture_xxx → new ext id

// Find next free numeric ext_resource id base. Existing IDs are like "13_lgf56".
// We'll add fresh ones with prefix "normal_<i>".
let extIdCounter = 0;
for (const e of extractions) {
	const newId = 'normal_' + (++extIdCounter);
	itToExtId.set(e.imageTextureId, newId);
	e.newExtId = newId;
}

const newExtResLines = extractions.map(e =>
	`[ext_resource type="Texture2D" path="${e.pngRel}" id="${e.newExtId}"]`
);

// Walk blocks in order, emit slim version.
const out = [];
let extResourceInserted = false;
let lastExtResourceIndex = -1;
// First pass: find index of last ext_resource block to know where to insert.
for (let i = 0; i < blocks.length; i++) {
	if (blockType(blocks[i]) === 'ext_resource') lastExtResourceIndex = i;
}

for (let i = 0; i < blocks.length; i++) {
	const b = blocks[i];
	const typ = blockType(b);

	// Drop extracted Image / ImageTexture sub_resources entirely.
	if (typ === 'sub_resource') {
		const sr = blockSubResType(b);
		const id = blockId(b);
		if (sr === 'Image' && droppedImage.has(id)) continue;
		if (sr === 'ImageTexture' && droppedImageTexture.has(id)) continue;
	}

	// Emit header + body (with normal_texture rewrite if Terrain3DTextureAsset).
	out.push(b.header);
	if (typ === 'sub_resource' && blockSubResType(b) === 'Terrain3DTextureAsset') {
		for (const line of b.body) {
			const m = line.match(/^normal_texture\s*=\s*SubResource\("([^"]+)"\)\s*$/);
			if (m) {
				const newId = itToExtId.get(m[1]);
				if (newId) {
					out.push(`normal_texture = ExtResource("${newId}")`);
					continue;
				}
			}
			out.push(line);
		}
	} else {
		for (const line of b.body) out.push(line);
	}

	// After the last ext_resource block in the original file, insert new ones.
	if (i === lastExtResourceIndex && !extResourceInserted) {
		// out already has the ext_resource block lines pushed.
		// Append a blank line then our new ext_resources.
		// Note: ext_resource blocks have no body lines in Godot .tscn (single-line headers).
		for (const ln of newExtResLines) out.push(ln);
		extResourceInserted = true;
	}
}

// If no ext_resource block existed, fall back to inserting after gd_scene.
if (!extResourceInserted) {
	const gdSceneIdx = out.findIndex(l => l.startsWith('[gd_scene'));
	if (gdSceneIdx >= 0) {
		out.splice(gdSceneIdx + 1, 0, ...newExtResLines);
	} else {
		out.unshift(...newExtResLines);
	}
}

const newText = out.join('\n');
fs.writeFileSync(SCENE_PATH, newText);

const sizeAfter = fs.statSync(SCENE_PATH).size;
log('size after: ', (sizeAfter / 1024 / 1024).toFixed(2), 'MB');
log('saved', extractions.length, 'normal maps:');
for (const e of extractions) log('  ', e.assetName, '→', e.pngRel, '(ext id', e.newExtId + ')');
log('done. open the project in Godot — it will auto-import the new PNGs.');
