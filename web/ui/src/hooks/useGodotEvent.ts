import { useEffect, useRef } from "react";
import { godotBridge } from "@/bridge/godotBridge";

/**
 * Subscribe a component to a Godot-side event. The handler is wrapped in a ref
 * so callers can pass an inline arrow function without re-subscribing every
 * render. Unsubscribes automatically on unmount.
 */
export function useGodotEvent<T = unknown>(
	eventName: string,
	handler: (payload: T) => void,
): void {
	const handlerRef = useRef(handler);
	handlerRef.current = handler;

	useEffect(() => {
		const unsubscribe = godotBridge.subscribe<T>(eventName, (payload) => {
			handlerRef.current(payload);
		});
		return unsubscribe;
	}, [eventName]);
}

/** Convenience: emit an event TO Godot. Pure passthrough — kept here so
 *  components import from one module instead of reaching into the bridge. */
export function emitToGodot(eventName: string, payload: Record<string, unknown> = {}): void {
	godotBridge.emit(eventName, payload);
}
