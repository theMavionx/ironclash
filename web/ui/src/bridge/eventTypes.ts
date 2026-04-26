// Centralized event-name constants shared by Godot and React. Keep these in
// lockstep with whatever GDScript code calls WebBridge.send_event(...) /
// WebBridge.register_handler(...) so refactors don't silently break the wire.

/** Events Godot → React (game state telling the UI what to render). */
export const GameEvent = {
	GodotReady: "godot_ready",
	HealthChanged: "health_changed",
	AmmoChanged: "ammo_changed",
	VehicleEntered: "vehicle_entered",
	VehicleExited: "vehicle_exited",
	DroneArmed: "drone_armed",
	DroneDestroyed: "drone_destroyed",
	DroneRespawned: "drone_respawned",
	MatchEnded: "match_ended",
} as const;

export type GameEventName = (typeof GameEvent)[keyof typeof GameEvent];

/** Events React → Godot (UI input telling the game to do something). */
export const UiEvent = {
	Pause: "ui_pause",
	Resume: "ui_resume",
	Restart: "ui_restart",
	OpenSettings: "ui_open_settings",
	SelectClass: "ui_select_class",
} as const;

export type UiEventName = (typeof UiEvent)[keyof typeof UiEvent];

// Payload shapes — extend as features come online. Keep them flat and JSON-
// serializable (no functions, no class instances, no Date — use ISO strings).

export interface HealthChangedPayload {
	hp: number;
	max: number;
	source?: string;
}

export interface AmmoChangedPayload {
	current: number;
	reserve: number;
	weapon: string;
}

export interface VehicleEnteredPayload {
	vehicle: "tank" | "helicopter" | "drone";
}

export interface DroneArmedPayload {
	throttle: number;
}

export interface MatchEndedPayload {
	winner: string;
	score: Record<string, number>;
}
