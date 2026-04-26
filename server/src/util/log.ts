// Tagged loggers. Every module gets one named after its concern so log lines
// stay greppable: `[net] join...`, `[match] kill...`, `[veh] explode...`.
//
// Build an env-var blacklist with IRONCLASH_LOG_DROP="net,veh" to silence
// noisy categories during local testing. INFO/WARN/ERROR severity is fixed —
// add a level filter here if/when production needs it.

const _DROP: Set<string> = new Set(
	(process.env.IRONCLASH_LOG_DROP ?? "").split(",").map(s => s.trim()).filter(s => s.length > 0),
);

export interface Logger {
	info(message: string): void;
	warn(message: string): void;
	error(message: string): void;
}

export function make_logger(tag: string): Logger {
	const prefix: string = `[${tag}]`;
	const dropped: boolean = _DROP.has(tag);
	return {
		info(m: string): void { if (!dropped) console.log(`${prefix} ${m}`); },
		warn(m: string): void { console.warn(`${prefix} ${m}`); },
		error(m: string): void { console.error(`${prefix} ${m}`); },
	};
}
