extends Control
## 可定制合成音效生成器：在界面输入参数 → _tone() 逐采样合成 16-bit PCM
## → 封装为 AudioStreamWAV 播放/预览 → 需要时 save_to_wav() 导出 .wav 文件。

const WAVES := ["sine", "square", "tri", "saw", "noise"]
const SETTINGS_PATH := "user://settings.cfg"
# 用 preload 而不是依赖 class_name 全局类：新脚本要等编辑器重扫后才会进全局类缓存
const WaveViewScript := preload("res://scripts/wave_view.gd")

## 常用音效预设：点击后自动填入界面参数并生成
const PRESETS := [
	{"name": "经典 Blip", "freq": 880.0, "freq_end": -1.0, "dur": 0.35, "decay": 12.0, "wave": "sine", "vol": 0.5},
	{"name": "上扬 Launch", "freq": 220.0, "freq_end": 990.0, "dur": 0.3, "decay": 5.0, "wave": "square", "vol": 0.35},
	{"name": "下坠 Drain", "freq": 880.0, "freq_end": 110.0, "dur": 0.45, "decay": 5.0, "wave": "tri", "vol": 0.5},
	{"name": "敲击 Hit", "freq": 180.0, "freq_end": -1.0, "dur": 0.12, "decay": 40.0, "wave": "square", "vol": 0.5},
	{"name": "金币 Coin", "freq": 988.0, "freq_end": 1319.0, "dur": 0.3, "decay": 8.0, "wave": "square", "vol": 0.3},
	{"name": "爆炸 Boom", "freq": 100.0, "freq_end": -1.0, "dur": 0.5, "decay": 9.0, "wave": "noise", "vol": 0.6},
]

@onready var _player: AudioStreamPlayer = $Player
@onready var _wave: OptionButton = $Center/Panel/Margin/VBox/Grid/Wave
@onready var _freq: SpinBox = $Center/Panel/Margin/VBox/Grid/Freq
@onready var _freq_end: SpinBox = $Center/Panel/Margin/VBox/Grid/FreqEnd
@onready var _dur: SpinBox = $Center/Panel/Margin/VBox/Grid/Dur
@onready var _decay: SpinBox = $Center/Panel/Margin/VBox/Grid/Decay
@onready var _vol: SpinBox = $Center/Panel/Margin/VBox/Grid/Vol
@onready var _file_name: LineEdit = $Center/Panel/Margin/VBox/Grid/FileName
@onready var _info: Label = $Center/Panel/Margin/VBox/Info
@onready var _wave_view: WaveViewScript = $Center/Panel/Margin/VBox/WaveView

var _stream: AudioStreamWAV


func _ready() -> void:
	for w in WAVES:
		_wave.add_item(w)
	for p in PRESETS:
		var b := Button.new()
		b.text = p["name"]
		b.pressed.connect(_apply_preset.bind(p))
		$Center/Panel/Margin/VBox/Presets.add_child(b)
	$Center/Panel/Margin/VBox/Buttons/PlayButton.pressed.connect(_regenerate)
	$Center/Panel/Margin/VBox/Buttons/PlayOnlyButton.pressed.connect(_play)
	$Center/Panel/Margin/VBox/Buttons/ExportButton.pressed.connect(_export_wav)
	# 首次运行（没有参数存档）时顺便导出一份，让用户开箱即拿到 WAV 文件
	var first_run := not FileAccess.file_exists(SETTINGS_PATH)
	_load_settings()
	_regenerate()
	if first_run:
		_export_wav()


func _unhandled_input(event: InputEvent) -> void:
	# LineEdit 有焦点时按键会被它自己消费，不会走到这里，所以不影响输入文件名
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_regenerate()


func _play() -> void:
	_player.play()


## 读取界面参数 → 合成 → 更新预览 → 播放（不写文件，导出走 _export_wav）
func _regenerate() -> void:
	_stream = _tone(_freq.value, _dur.value, _decay.value,
			WAVES[_wave.selected], _vol.value, _freq_end.value)
	_player.stream = _stream
	_wave_view.set_samples(_extract_samples(_stream))
	_save_settings()
	_play()
	_info.text = "已合成 %s" % _describe()


func _apply_preset(p: Dictionary) -> void:
	_wave.select(WAVES.find(p.wave))
	_freq.value = p.freq
	_freq_end.value = p.freq_end
	_dur.value = p.dur
	_decay.value = p.decay
	_vol.value = p.vol
	_regenerate()


func _tone(freq: float, dur: float, decay: float, wave := "sine", vol := 0.5, freq_end := -1.0) -> AudioStreamWAV:
	# 采样率 22050Hz：对短音效足够清晰，数据量比 CD 标准 44100Hz 少一半
	var rate := 22050
	# 总采样点数 = 时长 × 采样率
	var n := roundi(dur * rate)
	var bytes := PackedByteArray()
	# 16-bit 采样每个点占 2 字节，缓冲区按字节数预分配
	bytes.resize(n * 2)
	# 相位累加器：不直接用 sin(t * f) 计算是为了滑音——若频率随时间变化，
	# sin(t * f) 会在变频率处产生相位跳变（听感是"咔"的爆音）；累加相位则始终连续
	var phase := 0.0
	for i in n:
		# 当前采样点对应的时间（秒）
		var t := float(i) / float(rate)
		# 频率：freq_end > 0 时随时间从 freq 线性滑向 freq_end
		# （launch 的上扬音、drain 的下坠音都靠这个参数）
		var f := freq
		if freq_end > 0.0:
			f = lerpf(freq, freq_end, t / dur)
		# 每个采样点推进的相位量：一圈相位（2π）对应一个完整振动周期
		phase += TAU * f / float(rate)
		# 基础波形取正弦
		var s := sin(phase)
		if wave == "square":
			# 方波：只保留正负号。谐波成分多，听感更"刺"，适合机械撞击声
			s = 1.0 if s >= 0.0 else -1.0
		elif wave == "tri":
			# 三角波：把相位折叠进 [0,1) 再映射到 [-1,1]，音色介于正弦与方波之间
			s = 2.0 * absf(2.0 * fposmod(phase / TAU, 1.0) - 1.0) - 1.0
		elif wave == "saw":
			# 锯齿波：相位线性上升形成斜坡。谐波丰富且比方波"亮"，适合科幻风格的滑音
			s = 2.0 * fposmod(phase / TAU, 1.0) - 1.0
		elif wave == "noise":
			# 白噪声：每个采样点随机取值，与音高参数无关；爆炸、打击乐的底子
			s = randf() * 2.0 - 1.0
		# 音量包络：exp(-t * decay) 指数衰减，模拟敲击后的自然消音（decay 越大消失越快）；
		# min(t * 500, 1) 是约 2ms 的快速淡入，防止波形从非零值起始产生"咔哒"声。
		# 有了淡入 + 衰减，乘积理论上达不到 1.0，clampf 只是防参数改动后削波的保险丝
		var env := exp(-t * decay) * minf(t * 500.0, 1.0)
		# 波形 × 音量 × 包络，钳制到 [-1,1] 后量化为 16-bit 有符号整数（峰值取 32000 留少量余量）
		var v := int(clampf(s * vol * env, -1.0, 1.0) * 32000.0)
		# 按小端序写入第 i 个采样的 2 字节
		bytes.encode_s16(i * 2, v)
	# 组装 WAV 流：16-bit PCM、22050Hz、单声道，引擎可直接播放
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav


func _export_wav() -> void:
	if _stream == null:
		return
	# 编辑器内写到项目目录；导出后的游戏写到用户目录
	var dir := "res://sounds" if OS.has_feature("editor") else "user://sounds"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(_clean_name() + ".wav")
	var err := _stream.save_to_wav(path)
	if err == OK:
		_info.text = "已导出 %s → %s" % [_describe(), ProjectSettings.globalize_path(path)]
	else:
		_info.text = "导出失败（错误码 %d）：%s" % [err, path]


## 从 16-bit PCM 数据还原归一化采样，供波形预览使用
func _extract_samples(wav: AudioStreamWAV) -> PackedFloat32Array:
	var bytes := wav.data
	var out := PackedFloat32Array()
	out.resize(bytes.size() >> 1)  # 每个采样 2 字节
	for i in out.size():
		out[i] = float(bytes.decode_s16(i * 2)) / 32000.0
	return out


## 当前参数的一句话描述，显示在界面底部
func _describe() -> String:
	var slide := ""
	if _freq_end.value > 0.0:
		slide = "，滑音 %d→%d Hz" % [_freq.value, _freq_end.value]
	return "%s %d Hz · %.2f 秒%s" % [WAVES[_wave.selected], _freq.value, _dur.value, slide]


## 只保留文件名中的安全字符，避免拼出非法路径；全被滤掉时回退到 blip
func _clean_name() -> String:
	var clean := ""
	for c in _file_name.text.strip_edges():
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
				or (c >= "0" and c <= "9") or c == "-" or c == "_":
			clean += c
	return clean if not clean.is_empty() else "blip"


## 上次使用的参数保存在 user://settings.cfg，下次启动自动恢复
func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_wave.select(clampi(int(cfg.get_value("params", "wave", 0)), 0, WAVES.size() - 1))
	_freq.value = float(cfg.get_value("params", "freq", 880.0))
	_freq_end.value = float(cfg.get_value("params", "freq_end", -1.0))
	_dur.value = float(cfg.get_value("params", "dur", 0.35))
	_decay.value = float(cfg.get_value("params", "decay", 12.0))
	_vol.value = float(cfg.get_value("params", "vol", 0.5))
	_file_name.text = str(cfg.get_value("params", "file_name", "blip"))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("params", "wave", _wave.selected)
	cfg.set_value("params", "freq", _freq.value)
	cfg.set_value("params", "freq_end", _freq_end.value)
	cfg.set_value("params", "dur", _dur.value)
	cfg.set_value("params", "decay", _decay.value)
	cfg.set_value("params", "vol", _vol.value)
	cfg.set_value("params", "file_name", _file_name.text)
	cfg.save(SETTINGS_PATH)
