import { useEffect, useRef, useState, type ReactNode } from "react";
import { godotBridge } from "@/bridge/godotBridge";
import { GameEvent, MatchLoadingProgressPayload } from "@/bridge/eventTypes";

interface Props {
	/** Which standalone loading screen this instance represents. */
	mode: "engine" | "warmup";
	/** Engine-boot progress (Godot WASM + .pck download). When `engineTotal` is
	 *  0 we treat the engine as not started yet. */
	engineCurrent: number;
	engineTotal: number;
	/** True once Godot's WebBridge autoload has dispatched `godot_ready`. */
	engineReady: boolean;
	/** Optional message: surfaces a fatal boot error coming from GameCanvas. */
	error: string | null;
}

type Phase = "engine" | "warmup" | "done";

const ENGINE_FAKE_CRAWL_MS: number = 9000;
const WARMUP_FAKE_CRAWL_MS: number = 11200;
const ENGINE_CAP_BEFORE_READY: number = 0.985;
const WARMUP_CAP_BEFORE_READY: number = 0.985;

/**
 * Covers the canvas either while the Godot export boots on site entry, or
 * while the post-PLAY warmup loads Main.tscn.
 *
 * Godot web progress is naturally chunky: the browser can stay quiet while it
 * downloads/decompresses the wasm + pck, and warmup can jump when threaded
 * ResourceLoader finishes. The UI renders one monotonic eased value per phase.
 */
export default function LoadingOverlay({
	mode,
	engineCurrent,
	engineTotal,
	engineReady,
	error,
}: Props) {
	const [phase, setPhase] = useState<Phase>(mode);
	const [warmupProgress, setWarmupProgress] = useState<number>(0);
	const [warmupStage, setWarmupStage] = useState<MatchLoadingProgressPayload["stage"]>(
		"loading_assets",
	);
	const [fading, setFading] = useState<boolean>(false);
	const [displayProgress, setDisplayProgress] = useState<number>(0);
	const fadeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	const bootStartedAtRef = useRef<number>(performance.now());
	const warmupStartedAtRef = useRef<number | null>(null);
	const phaseRef = useRef<Phase>(mode);
	const engineCurrentRef = useRef<number>(0);
	const engineTotalRef = useRef<number>(0);
	const engineReadyRef = useRef<boolean>(false);
	const warmupProgressRef = useRef<number>(0);
	const warmupStageRef = useRef<MatchLoadingProgressPayload["stage"]>("loading_assets");
	const fadingRef = useRef<boolean>(false);
	const doneRef = useRef<boolean>(false);

	phaseRef.current = phase;
	engineCurrentRef.current = engineCurrent;
	engineTotalRef.current = engineTotal;
	engineReadyRef.current = engineReady;
	warmupProgressRef.current = warmupProgress;
	warmupStageRef.current = warmupStage;
	fadingRef.current = fading;

	useEffect(() => {
		phaseRef.current = mode;
		setPhase(mode);
		if (mode === "warmup") {
			warmupStartedAtRef.current = performance.now();
		}
	}, [mode]);

	useEffect(() => {
		let frame: number = 0;
		const tick = (now: number): void => {
			const target: number = getTargetProgress(now);
			setDisplayProgress((prev) => {
				if (target <= prev) return prev;
				const easing: number = target >= 1.0 ? 0.18 : 0.075;
				const minStep: number = target >= 1.0 ? 0.008 : 0.0015;
				const eased: number = prev + (target - prev) * easing;
				const stepped: number = Math.max(prev + minStep, eased);
				if (target >= 1.0 && 1.0 - stepped < 0.002) return 1.0;
				return clamp01(Math.min(target, stepped));
			});
			if (!doneRef.current) {
				frame = requestAnimationFrame(tick);
			}
		};
		frame = requestAnimationFrame(tick);
		return () => cancelAnimationFrame(frame);
	}, []);

	useEffect(() => {
		const off = godotBridge.subscribe<MatchLoadingProgressPayload>(
			GameEvent.MatchLoadingProgress,
			(payload) => {
				if (payload === undefined || payload === null) return;
				const next: number = clamp01(Number(payload.progress ?? 0));
				const nextStage: MatchLoadingProgressPayload["stage"] =
					payload.stage ?? "loading_assets";
				cancelFade();
				const monotonicNext: number = Math.max(warmupProgressRef.current, next);
				warmupProgressRef.current = monotonicNext;
				warmupStageRef.current = nextStage;
				setWarmupProgress(monotonicNext);
				setWarmupStage(nextStage);
				if (monotonicNext >= 1.0 && nextStage === "ready") {
					fadeTimerRef.current = setTimeout(() => {
						fadingRef.current = true;
						setFading(true);
						fadeTimerRef.current = setTimeout(() => {
							doneRef.current = true;
							phaseRef.current = "done";
							setPhase("done");
							fadingRef.current = false;
							setFading(false);
						}, 350);
					}, 650);
				}
			},
		);
		return off;
	}, []);

	function cancelFade(): void {
		if (fadeTimerRef.current !== null) {
			clearTimeout(fadeTimerRef.current);
			fadeTimerRef.current = null;
		}
	}

	function getTargetProgress(now: number): number {
		if (phaseRef.current === "done" || fadingRef.current) return 1.0;

		const rawEngine: number =
			engineTotalRef.current > 0
				? clamp01(engineCurrentRef.current / engineTotalRef.current)
				: 0;
		const engineCrawl: number =
			0.03 + clamp01((now - bootStartedAtRef.current) / ENGINE_FAKE_CRAWL_MS) * 0.86;
		const engineStage: number = engineReadyRef.current
			? 1.0
			: Math.min(Math.max(rawEngine, engineCrawl), 0.965);

		if (phaseRef.current === "engine") {
			return clamp01(
				engineReadyRef.current ? 1.0 : Math.min(engineStage, ENGINE_CAP_BEFORE_READY),
			);
		}

		const warmupStartedAt: number = warmupStartedAtRef.current ?? now;
		const rawWarmup: number = warmupProgressRef.current;
		const warmupCrawl: number =
			0.04 + clamp01((now - warmupStartedAt) / WARMUP_FAKE_CRAWL_MS) * 0.90;
		const warmupStageProgress: number =
			warmupStageRef.current === "ready"
				? 1.0
				: Math.min(Math.max(rawWarmup, warmupCrawl), WARMUP_CAP_BEFORE_READY);
		return clamp01(warmupStageProgress);
	}

	if (phase === "done" && error === null) return null;

	const heading: string =
		phase === "engine" ? "LOADING GAME ENGINE" : "ENTERING MATCH";
	const subline: string = phase === "engine" ? "Downloading assets..." : warmupHint(warmupStage);
	const percent: number = Math.round(displayProgress * 100);
	const showStageDots: boolean = phase === "warmup";

	return (
		<div
			className={
				"pointer-events-auto absolute inset-0 flex flex-col items-center justify-center " +
				"z-50 bg-black transition-opacity duration-300 " +
				(fading ? "opacity-0" : "opacity-100")
			}
			role="status"
			aria-live="polite"
			aria-busy={!fading}
		>
			<div className="flex w-[min(640px,80vw)] flex-col items-center gap-6">
				<div className="font-sans text-display tracking-tight text-text leading-none">
					{heading}
				</div>
				<div className="w-full">
					<div className="h-2 w-full overflow-hidden border border-accent/30 bg-bg">
						<div
							className="h-full bg-accent transition-[width] duration-150 ease-out"
							style={{ width: `${displayProgress * 100}%` }}
						/>
					</div>
					<div className="mt-3 flex items-center justify-between font-mono text-caption uppercase tracking-label">
						<span className="text-accent">{subline}</span>
						<span className="text-text-muted">{percent}%</span>
					</div>
				</div>
				{showStageDots && (
					<div className="flex items-center gap-3 font-mono text-caption uppercase tracking-label text-text-muted">
						<StageDot active={phase === "engine"} done={engineReady}>
							Engine
						</StageDot>
						<span className="opacity-30">.</span>
						<StageDot active={phase === "warmup"} done={warmupStage === "ready"}>
							Warmup
						</StageDot>
					</div>
				)}
				{error !== null ? (
					<div className="mt-2 max-w-prose text-center font-mono text-caption text-danger">
						{error}
					</div>
				) : (
					<div className="font-sans text-caption uppercase tracking-label text-text-muted">
						Pre-compiling combat effects. Do not refresh
					</div>
				)}
			</div>
		</div>
	);
}

function StageDot({
	active,
	done,
	children,
}: {
	active: boolean;
	done: boolean;
	children: ReactNode;
}) {
	return (
		<span
			className={
				"flex items-center gap-2 " +
				(active ? "text-accent" : done ? "text-ok" : "text-text-muted")
			}
		>
			<span
				className={
					"h-2 w-2 " +
					(active
						? "bg-accent animate-pulse"
						: done
							? "bg-ok"
							: "bg-text-muted opacity-50")
				}
			/>
			{children}
		</span>
	);
}

function warmupHint(stage: MatchLoadingProgressPayload["stage"]): string {
	switch (stage) {
		case "loading_assets":
			return "Loading map...";
		case "compiling_shaders":
			return "Warming GPU pipelines...";
		case "ready":
			return "Spawning...";
	}
}

function clamp01(n: number): number {
	if (Number.isNaN(n)) return 0;
	if (n < 0) return 0;
	if (n > 1) return 1;
	return n;
}
