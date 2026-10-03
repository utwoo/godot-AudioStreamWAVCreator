class_name WaveformView
extends Control
## 波形预览：把采样按像素分桶取 min/max，画成类似 DAW 的振幅包络图。

const WAVE_COLOR := Color(0.31, 0.82, 0.77)
const GRID_COLOR := Color(1, 1, 1, 0.12)

var _samples := PackedFloat32Array()
var _minmax := PackedFloat32Array()  # 每个像素桶依次存 [min, max]
var _bucket_count := 0


func set_samples(samples: PackedFloat32Array) -> void:
	_samples = samples
	_rebuild()


func _notification(what: int) -> void:
	# 首次布局和窗口缩放时按新宽度重新分桶
	if what == NOTIFICATION_RESIZED:
		_rebuild()


func _rebuild() -> void:
	_minmax = PackedFloat32Array()
	_bucket_count = maxi(1, int(size.x))
	var n := _samples.size()
	if n == 0:
		queue_redraw()
		return
	_minmax.resize(_bucket_count * 2)
	var per := float(n) / _bucket_count
	for b in _bucket_count:
		var start := mini(int(b * per), n - 1)
		var end := mini(maxi(start + 1, int((b + 1) * per)), n)
		var lo := 1.0
		var hi := -1.0
		for i in range(start, end):
			lo = minf(lo, _samples[i])
			hi = maxf(hi, _samples[i])
		_minmax[b * 2] = lo
		_minmax[b * 2 + 1] = hi
	queue_redraw()


func _draw() -> void:
	var mid := size.y / 2.0
	draw_line(Vector2(0, mid), Vector2(size.x, mid), GRID_COLOR, 1.0)
	if _bucket_count == 0 or _minmax.is_empty():
		return
	var amp := mid - 3.0  # 上下各留 3px 余量
	for x in _bucket_count:
		var top := mid - _minmax[x * 2 + 1] * amp
		var bottom := mid - _minmax[x * 2] * amp
		draw_rect(Rect2(x, top, 1.0, maxf(bottom - top, 1.0)), WAVE_COLOR)
