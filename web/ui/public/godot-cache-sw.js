const DB_NAME = "ironclash-godot-assets";
const DB_VERSION = 1;
const ASSET_STORE = "assets";
const META_STORE = "meta";
const LEGACY_CACHE_PREFIX = "ironclash-godot-";
const MANIFEST_PATH = "/godot/_manifest.json";
const STORED_RESPONSE_HEADER_BLOCKLIST = new Set([
	"content-encoding",
	"content-length",
	"transfer-encoding",
]);

self.addEventListener("install", (event) => {
	self.skipWaiting();
});

self.addEventListener("activate", (event) => {
	event.waitUntil(self.clients.claim());
});

self.addEventListener("message", (event) => {
	const data = event.data || {};
	if (typeof data.version !== "string" || data.version.trim().length === 0) {
		return;
	}

	if (data.type === "IRONCLASH_GODOT_CACHE_VERSION") {
		event.waitUntil(prepareGodotVersion(data.version));
		return;
	}

	if (data.type === "IRONCLASH_GODOT_CACHE") {
		const files = Array.isArray(data.files) ? data.files : [];
		event.waitUntil(prepareGodotCache(data.version, files));
	}
});

self.addEventListener("fetch", (event) => {
	const request = event.request;
	if (request.method !== "GET") return;

	const url = new URL(request.url);
	if (url.origin !== self.location.origin || !url.pathname.startsWith("/godot/")) return;
	if (url.pathname === MANIFEST_PATH) {
		event.respondWith(fetch(request, { cache: "no-store" }));
		return;
	}

	const version = url.searchParams.get("v");
	if (!version || !shouldCacheGodotPath(url.pathname)) return;

	event.respondWith(indexedDbFirst(request, version, event));
});

async function indexedDbFirst(request, version, event) {
	const url = new URL(request.url);
	const cached = await getAsset(version, url.pathname);
	if (cached) return responseFromRecord(cached);

	const response = await fetch(request);
	if (response.ok) {
		event.waitUntil(putResponse(version, url.pathname, response.clone()));
	}
	return response;
}

async function prepareGodotVersion(version) {
	await Promise.all([
		deleteOldGodotAssets(version),
		deleteOldLegacyCaches(version),
		putMeta("currentVersion", version),
	]);
}

async function prepareGodotCache(version, files) {
	await prepareGodotVersion(version);
	const urls = files
		.filter((fileName) => shouldCacheGodotFile(fileName))
		.map((fileName) => `/godot/${fileName}?v=${encodeURIComponent(version)}`);

	for (const url of urls) {
		const request = new Request(url, { credentials: "same-origin" });
		const path = new URL(request.url).pathname;
		if (await getAsset(version, path)) continue;
		try {
			const response = await fetch(request);
			if (response.ok) {
				await putResponse(version, path, response);
			}
		} catch (err) {
			console.warn("[godot-cache-sw] IndexedDB warm failed:", url, err);
		}
	}
}

function shouldCacheGodotFile(fileName) {
	return (
		fileName.endsWith(".pck") ||
		fileName.endsWith(".wasm") ||
		fileName.endsWith(".js") ||
		fileName.endsWith(".html")
	);
}

function shouldCacheGodotPath(pathname) {
	return shouldCacheGodotFile(pathname);
}

function assetKey(version, pathname) {
	return `${version}:${pathname}`;
}

function responseFromRecord(record) {
	return new Response(record.body, {
		status: record.status,
		statusText: record.statusText,
		headers: record.headers,
	});
}

async function putResponse(version, pathname, response) {
	const headers = {};
	response.headers.forEach((value, key) => {
		if (STORED_RESPONSE_HEADER_BLOCKLIST.has(key.toLowerCase())) return;
		headers[key] = value;
	});

	const record = {
		key: assetKey(version, pathname),
		version,
		pathname,
		status: response.status,
		statusText: response.statusText,
		headers,
		body: await response.blob(),
		createdAt: Date.now(),
	};

	const db = await openDb();
	await txDone(db.transaction(ASSET_STORE, "readwrite").objectStore(ASSET_STORE).put(record));
}

async function getAsset(version, pathname) {
	const db = await openDb();
	return await requestToPromise(
		db.transaction(ASSET_STORE, "readonly")
			.objectStore(ASSET_STORE)
			.get(assetKey(version, pathname)),
	);
}

async function deleteOldGodotAssets(currentVersion) {
	const db = await openDb();
	const tx = db.transaction(ASSET_STORE, "readwrite");
	const store = tx.objectStore(ASSET_STORE);
	const index = store.index("version");
	const request = index.openCursor();

	await new Promise((resolve, reject) => {
		request.onsuccess = () => {
			const cursor = request.result;
			if (!cursor) return;
			if (cursor.value.version !== currentVersion) {
				cursor.delete();
			}
			cursor.continue();
		};
		request.onerror = () => reject(request.error);
		tx.oncomplete = () => resolve();
		tx.onerror = () => reject(tx.error);
		tx.onabort = () => reject(tx.error);
	});
}

async function putMeta(key, value) {
	const db = await openDb();
	await txDone(db.transaction(META_STORE, "readwrite").objectStore(META_STORE).put({ key, value }));
}

async function deleteOldLegacyCaches(currentVersion) {
	if (!("caches" in self)) return;
	const keep = `${LEGACY_CACHE_PREFIX}${currentVersion}`;
	const names = await caches.keys();
	await Promise.all(
		names
			.filter((name) => name.startsWith(LEGACY_CACHE_PREFIX) && name !== keep)
			.map((name) => caches.delete(name)),
	);
}

function openDb() {
	return new Promise((resolve, reject) => {
		const request = indexedDB.open(DB_NAME, DB_VERSION);
		request.onupgradeneeded = () => {
			const db = request.result;
			if (!db.objectStoreNames.contains(ASSET_STORE)) {
				const assets = db.createObjectStore(ASSET_STORE, { keyPath: "key" });
				assets.createIndex("version", "version", { unique: false });
				assets.createIndex("pathname", "pathname", { unique: false });
			}
			if (!db.objectStoreNames.contains(META_STORE)) {
				db.createObjectStore(META_STORE, { keyPath: "key" });
			}
		};
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
	});
}

function requestToPromise(request) {
	return new Promise((resolve, reject) => {
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
	});
}

function txDone(request) {
	return new Promise((resolve, reject) => {
		const tx = request.transaction;
		tx.oncomplete = () => resolve();
		tx.onerror = () => reject(tx.error);
		tx.onabort = () => reject(tx.error);
		request.onerror = () => reject(request.error);
	});
}
