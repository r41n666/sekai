extends RefCounted
class_name HitSounds
## 受击音效素材池：扫描 `res://sfx/hit_female/` 下**所有** `.wav`，**每次受击随机取一条**播放。
##
## 加载分三级（绝不崩、不报错刷屏）：
##   ① `AudioStreamWAV.load_from_file()` **直读 WAV** —— **首选**。不依赖 Godot 的导入缓存是否就绪，
##      在 headless / 未导入 / 源码运行 / 导入参数变化后都能出声。
##   ② 退回 Godot 导入资源 `load()` —— 导出包内、或将来重设导入参数时走这条。
##   ③ 都失败 → 返回 `null`，由**调用方**降级（bot 退回程序化合成音；player 静音）。
##
## 注：这些 wav **现已被 Godot 导入**（`sfx/hit_female/` 下有 27 个 `.wav.import`），
##   所以本文件早先「未被导入 ⇒ 常规 load() 拿不到」的注释已过时——但**结论不变**，
##   仍以 `load_from_file()` 为首选（理由见上）。

##
## 用法（⚠ 必须用 `preload` 引用，**不要**依赖全局 `class_name` ——
## 见 control_checklist §4-17：全局类缓存在未开编辑器时可能未注册，headless 会找不到类型）：
##     const HitSounds = preload("res://scripts/shooting/hit_sounds.gd")
##     var s: AudioStream = HitSounds.pick_random()
##     if s != null:
##         _hit_audio.stream = s

## 素材目录（用户指定：受击音效取自 `sfx/hit_female/`）
const SFX_DIR := "res://sfx/hit_female/"

## 已加载的素材池（进程内缓存，只扫一次）
static var _pool: Array[AudioStream] = []
static var _scanned := false


## 扫描并加载素材池。**只执行一次**，结果缓存（static）。
## 文件名排序后再加载 ⇒ 加载顺序稳定，便于测试复现与诊断。
static func _ensure_pool() -> void:
	if _scanned:
		return
	_scanned = true
	var names := _list_wav_names()
	for file_name in names:
		var stream := _load_one(SFX_DIR + file_name)
		if stream != null:
			_pool.append(stream)


## 列出目录下所有 `.wav` 文件名（已排序）。跳过子目录与 `.import` 等旁文件。
static func _list_wav_names() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(SFX_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.to_lower().ends_with(".wav"):
			out.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## 单个文件的加载（三级降级见类注释）。返回 null 表示这条不可用。
static func _load_one(path: String) -> AudioStream:
	# ① 直读 WAV（未导入状态下的唯一可行路径）
	if FileAccess.file_exists(path):
		var direct := AudioStreamWAV.load_from_file(path)
		if direct != null:
			return direct
	# ② 退回 Godot 导入资源（编辑器 / 导出包）
	if ResourceLoader.exists(path):
		var imported := load(path)
		if imported is AudioStream:
			return imported as AudioStream
	# ③ 不可用
	return null


## **每次受击调用一次**：从素材池随机取一条。
## 素材池为空（目录不存在 / 全部加载失败）时返回 `null`，调用方须自行降级。
static func pick_random() -> AudioStream:
	_ensure_pool()
	if _pool.is_empty():
		return null
	return _pool[randi() % _pool.size()]


## 素材池条数（供测试与诊断）
static func loaded_count() -> int:
	_ensure_pool()
	return _pool.size()


## 目录里 `.wav` 文件的**总数**（含加载失败的），用于诊断「有文件但没加载上」的情况
static func wav_file_count() -> int:
	return _list_wav_names().size()


## 仅供测试：清空缓存，让下次调用重新扫描目录
static func reset_cache() -> void:
	_pool.clear()
	_scanned = false
