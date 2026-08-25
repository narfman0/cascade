class_name PerfOverlay extends Label
## Debug-build performance readout — the boot test's instrument.
##
## Mobile work has no self-verification loop: the gates run headless on
## llvmpipe and nothing here can measure a phone. So the phone reports for
## itself — FPS, frame time, renderer, resolution, and whether the planet is
## streaming — in text big enough to read at arm's length and screenshot.
##
## Debug builds only; a release export never shows it.

var _accum: float = 0.0
var _frames: int = 0
var _fps: float = 0.0
var _worst: float = 0.0


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return
	add_theme_font_size_override("font_size", 22)
	modulate = Color(0.6, 1.0, 0.75)
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	position = Vector2(-360, 300)
	custom_minimum_size = Vector2(340, 120)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_accum += delta
	_frames += 1
	_worst = maxf(_worst, delta)
	if _accum < 0.5:
		return
	_fps = _frames / _accum
	var worst_ms: float = _worst * 1000.0
	_accum = 0.0
	_frames = 0
	_worst = 0.0

	var vp := get_viewport()
	text = "%.0f fps   worst %.0f ms\n%s\n%dx%d  %s" % [
		_fps, worst_ms,
		RenderingServer.get_video_adapter_name(),
		int(vp.get_visible_rect().size.x), int(vp.get_visible_rect().size.y),
		"gl_compat" if RenderingServer.get_video_adapter_api_version().begins_with("OpenGL") \
			else "vulkan",
	]
