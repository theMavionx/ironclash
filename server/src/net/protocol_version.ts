import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const shared_protocol_path = path.resolve(here, "../../../shared/protocol.ts");
const shared_protocol_source = fs.readFileSync(shared_protocol_path, "utf8");
const protocol_match = shared_protocol_source.match(/export\s+const\s+PROTOCOL_VERSION\s*=\s*["']([^"']+)["']/);

if (protocol_match === null || protocol_match[1] === undefined) {
	throw new Error("Could not read PROTOCOL_VERSION from shared/protocol.ts");
}

export const PROTOCOL_VERSION: string = protocol_match[1];
