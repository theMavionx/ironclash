extends Node

## Autoloaded singleton that bridges Godot and the surrounding React UI when
## the game runs in a browser. On non-web platforms every method is a safe
## no-op so gameplay code can call into it unconditionally.
##
## Direction Godot → JS:
##   WebBridge.send_event("health_changed", {"hp": 27, "max": 100})
##   → calls window.GodotBridge.onGameEvent("health_changed", {...}) on the page.
##
## Direction JS → Godot:
##   WebBridge.register_handler("ui_pause", _on_ui_pause)
##   → JS calls window.GodotBridge.dispatch("ui_pause", {...}) and the matching
##   Callable receives the parsed payload as its single Dictionary argument.
##
## Implements: design/gdd/web-bridge.md (pending)

## Emitted whenever an event arrives from JS — handy for anything that prefers
## a single sink over the per-event handler registry. Args: (name: String,
## payload: Dictionary).
signal js_event(name: String, payload: Dictionary)

const _BRIDGE_GLOBAL: String = "GodotBridge"
const _WEB_IDLE_MAX_FPS: int = 30
const _WEB_ACTIVE_MAX_FPS: int = 60
const _WEB_HIDDEN_MAX_FPS: int = 10
const _WEB_PHYSICS_TICKS: int = 60
const _WEB_MAX_PHYSICS_STEPS_PER_FRAME: int = 2

var _is_web: bool = false
var _js_window: JavaScriptObject = null
var _js_bridge: JavaScriptObject = null
## Stable references to the JS callbacks we hand out — must outlive the call
## or the JS side loses the function pointer (Godot frees the JS proxy).
var _dispatch_callback: JavaScriptObject = null
var _ready_callback: JavaScriptObject = null
var _visibility_callback: JavaScriptObject = null
var _web_game_active: bool = false
var _web_page_hidden: bool = false
## name → Array[Callable]. Multiple GDScript handlers can subscribe to one
## event; all fire in registration order.
var _handlers: Dictionary = {}


func _ready() -> void:
	_is_web = OS.has_feature("web")
	if not _is_web:
		return
	_apply_web_runtime_budget(false)
	_js_window = JavaScriptBridge.get_interface("window")
	if _js_window == null:
		push_warning("WebBridge: window interface unavailable — JS bridge disabled")
		return
	_install_visibility_budget_hook()
	# Reuse an existing GodotBridge if React already created one (script load
	# order between the engine boot and the React bundle is not guaranteed).
	_js_bridge = _js_window[_BRIDGE_GLOBAL]
	if _js_bridge == null:
		_js_bridge = JavaScriptBridge.create_object("Object")
		_js_window[_BRIDGE_GLOBAL] = _js_bridge
	_dispatch_callback = JavaScriptBridge.create_callback(_receive_from_js)
	_js_bridge.dispatch = _dispatch_callback
	# Mark ready and notify the page so React knows it can start sending events.
	_js_bridge.engineReady = true
	_emit_to_js("godot_ready", {"engine_version": Engine.get_version_info()["string"]})


## Send an event to the JS side. Payload keys/values must be primitives,
## arrays, or dictionaries (anything JSON-serializable).
func send_event(event_name: String, payload: Dictionary = {}) -> void:
	if not _is_web or _js_bridge == null:
		return
	_emit_to_js(event_name, payload)


## Subscribe a Callable to a JS-originated event. Multiple handlers per event
## are allowed; each receives the payload Dictionary as its sole argument.
func register_handler(event_name: String, handler: Callable) -> void:
	if not _handlers.has(event_name):
		_handlers[event_name] = []
	(_handlers[event_name] as Array).append(handler)


## Remove a previously registered handler.
func unregister_handler(event_name: String, handler: Callable) -> void:
	if not _handlers.has(event_name):
		return
	(_handlers[event_name] as Array).erase(handler)


## Returns true when running inside a browser with the bridge initialized.
func is_available() -> bool:
	return _is_web and _js_bridge != null


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _apply_web_runtime_budget(page_hidden: bool) -> void:
	_web_page_hidden = page_hidden
	# Browser rAF follows the display refresh rate. On 120/144 Hz screens this
	# can double render work versus the editor, so web gets an explicit budget.
	if page_hidden:
		Engine.max_fps = _WEB_HIDDEN_MAX_FPS
	else:
		Engine.max_fps = _WEB_ACTIVE_MAX_FPS if _web_game_active else _WEB_IDLE_MAX_FPS
	Engine.physics_ticks_per_second = _WEB_PHYSICS_TICKS
	Engine.max_physics_steps_per_frame = _WEB_MAX_PHYSICS_STEPS_PER_FRAME


func _install_visibility_budget_hook() -> void:
	_visibility_callback = JavaScriptBridge.create_callback(_on_visibility_change)
	_js_window["_ironclashVisibilityChanged"] = _visibility_callback
	JavaScriptBridge.eval("""
		(function() {
			if (window.__ironclashVisibilityBudgetInstalled) return;
			window.__ironclashVisibilityBudgetInstalled = true;
			document.addEventListener('visibilitychange', function() {
				if (window._ironclashVisibilityChanged) {
					window._ironclashVisibilityChanged(document.hidden ? 1 : 0);
				}
			});
			if (window._ironclashVisibilityChanged) {
				window._ironclashVisibilityChanged(document.hidden ? 1 : 0);
			}
		})();
	""", true)


func _on_visibility_change(args: Array) -> void:
	var hidden: bool = args.size() > 0 and int(args[0]) != 0
	_apply_web_runtime_budget(hidden)


func _emit_to_js(event_name: String, payload: Dictionary) -> void:
	# JSON-stringify in GDScript and parse on the JS side — round-trips Vector
	# / Color / nested dicts as plain JS objects without surprises from Godot's
	# automatic Variant→JS coercion.
	var payload_json: String = JSON.stringify(payload)
	JavaScriptBridge.eval(
		"window.GodotBridge && window.GodotBridge.onGameEvent && window.GodotBridge.onGameEvent(%s, %s);"
		% [JSON.stringify(event_name), payload_json],
		true
	)


## Bound to window.GodotBridge.dispatch — receives (eventName, payloadJson).
## React calls it with already-stringified JSON so we don't have to traverse
## the live JS object graph from GDScript (which is awkward via JavaScriptBridge).
func _receive_from_js(args: Array) -> void:
	if args.size() < 1:
		return
	var event_name: String = String(args[0])
	var payload: Dictionary = {}
	if args.size() >= 2:
		var raw: Variant = args[1]
		if raw is String and (raw as String).length() > 0:
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Dictionary:
				payload = parsed
	if event_name == "ui_play":
		_web_game_active = true
		if _is_web:
			_apply_web_runtime_budget(_web_page_hidden)
	js_event.emit(event_name, payload)
	if _handlers.has(event_name):
		for handler: Callable in _handlers[event_name]:
			if handler.is_valid():
				handler.call(payload)
