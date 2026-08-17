extends Control
class_name NavConsole
## The nav console: pick a destination, see what it costs, engage.
##
## This is the first station built on the console pattern from
## docs/architecture.md — opening it puts the game in `FOCUSED` input mode, so
## the flight controls stand down while the player is reading a screen rather
## than flying. Travel is the one thing worth a console before the walkable
## interior exists, because it is the only system where the player's decision is
## "where to" rather than "how".
##
## Rows are built in code rather than authored: the destination list comes from
## SolarSystemData and would otherwise need hand-editing every time a body is
## added.

const ROW_HEIGHT: float = 26.0

var _system: SolarSystem
var _autopilot: Autopilot

var _panel: PanelContainer
var _rows: VBoxContainer
var _footer: Label
var _destinations: Array[CelestialBody] = []
var _selected: int = 0
var _row_labels: Array[Label] = []
var _refresh_accum: float = 0.0


func setup(system: SolarSystem, autopilot: Autopilot) -> void:
	_system = system
	_autopilot = autopilot
	_destinations = system.destinations()
	_build_ui()
	_close()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(520, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.05, 0.92)
	style.border_color = Color(0.45, 0.52, 0.55, 0.6)
	style.set_border_width_all(1)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	var title := Label.new()
	title.text = "NAV — SELECT DESTINATION"
	title.modulate = Color(0.72, 0.78, 0.80)
	column.add_child(title)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	column.add_child(_rows)

	for body in _destinations:
		var row := Label.new()
		row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		_rows.add_child(row)
		_row_labels.append(row)

	_footer = Label.new()
	_footer.text = "↑↓ select    ENTER engage    M / ESC close"
	_footer.modulate = Color(0.45, 0.50, 0.52)
	column.add_child(_footer)


## --- Open / close ------------------------------------------------------------

func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		_close()
	else:
		_open()


func _open() -> void:
	if _autopilot and _autopilot.phase != Autopilot.Phase.IDLE:
		# Already under way — the console would only offer to re-engage.
		return
	visible = true
	GameState.input_mode = GameState.InputMode.FOCUSED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_rows()


func _close() -> void:
	visible = false
	if GameState.input_mode == GameState.InputMode.FOCUSED:
		GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"nav_console"):
		toggle()
		return
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		_close()
	elif event.is_action_pressed(&"ui_down"):
		_move_selection(1)
	elif event.is_action_pressed(&"ui_up"):
		_move_selection(-1)
	elif event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"engage_autopilot"):
		_engage_selected()


func _move_selection(step: int) -> void:
	if _destinations.is_empty():
		return
	_selected = wrapi(_selected + step, 0, _destinations.size())
	_refresh_rows()


func _engage_selected() -> void:
	if _autopilot == null or _destinations.is_empty():
		return
	var body := _destinations[_selected]
	if _autopilot.engage(body):
		_close()


## --- Rows --------------------------------------------------------------------

func _process(delta: float) -> void:
	if not visible:
		return
	# Distances change as bodies orbit; a stale ETA would be a lie.
	_refresh_accum += delta
	if _refresh_accum >= 0.25:
		_refresh_accum = 0.0
		_refresh_rows()


func _refresh_rows() -> void:
	for i in _destinations.size():
		var body := _destinations[i]
		var est: Dictionary = _autopilot.estimate_transfer(body) if _autopilot else {}
		var distance: float = est.get("distance", 0.0)
		var real_seconds: float = est.get("real_seconds", 0.0)
		var label := _row_labels[i]
		var marker: String = "▸" if i == _selected else " "
		label.text = "%s %-10s %10s   %s" % [
			marker,
			body.def.display_name,
			_format_distance(distance),
			_format_clock(real_seconds),
		]
		label.modulate = Color(0.92, 0.94, 0.94) if i == _selected else Color(0.58, 0.62, 0.64)

	if _destinations.is_empty():
		return
	var note: String = _destinations[_selected].def.nav_note
	_footer.text = note if note != "" else "↑↓ select    ENTER engage    M / ESC close"


static func _format_distance(metres: float) -> String:
	if metres >= 1000.0:
		return "%.0f km" % (metres / 1000.0)
	return "%.0f m" % metres


static func _format_clock(seconds: float) -> String:
	var s: int = int(maxf(seconds, 0.0))
	return "%d:%02d" % [s / 60, s % 60]
