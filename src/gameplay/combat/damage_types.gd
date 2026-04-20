class_name DamageTypes
extends RefCounted

## Shared enum for identifying which weapon caused a hit.
## Used by projectiles (TankShell) and direct-collision damage (drone kamikaze)
## so VFX, scoring, and respawn logic can branch on damage source.

enum Source {
	TANK_SHELL,
	HELI_MISSILE,
	DRONE_KAMIKAZE,
}
