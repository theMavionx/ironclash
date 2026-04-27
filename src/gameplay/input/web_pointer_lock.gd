class_name WebPointerLock
extends RefCounted

static func capture_for_activation() -> void:
	if OS.has_feature("web"):
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


static func capture_from_user_gesture() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
