// Centralized event-name constants shared by Godot and React. Keep these in
// lockstep with whatever GDScript code calls WebBridge.send_event(...) /
// WebBridge.register_handler(...) so refactors don't silently break the wire.

/** Events Godot → React (game state telling the UI what to render). */
export const GameEvent = {
	GodotReady: "godot_ready",
	NetworkConnected: "network_connected",
	NetworkConnectionFailed: "network_connection_failed",
	NetworkDisconnected: "network_disconnected",
	NetworkKicked: "network_kicked",
	MatchState: "match_state",
	KillFeed: "kill_feed",
	LocalDied: "local_died",
	LocalRespawned: "local_respawned",
	VehicleDriveStart: "vehicle_drive_start",
	VehicleDriveEnd: "vehicle_drive_end",
	VehicleHp: "vehicle_hp",
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
	Play: "ui_play",
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

export interface NetworkConnectedPayload {
	peer_id: number;
	team: string;
}

export interface NetworkConnectionFailedPayload {
	reason: string;
	code?: number;
}

export interface MatchStatePayload {
	t: "match_state";
	state: "waiting" | "warmup" | "in_progress" | "post_match";
	time_remaining: number;
	red_score: number;
	blue_score: number;
	red_count: number;
	blue_count: number;
}

export interface KillFeedPayload {
	killer: number;
	victim: number;
	weapon: string;
	headshot: boolean;
}

export interface LocalDiedPayload {
	killer: number;
	weapon: string;
}

export interface VehicleDriveStartPayload {
	vehicle_id: string;
}

export interface VehicleHpPayload {
	vehicle_id: string;
	hp: number;
	max_hp: number;
	alive: boolean;
}
