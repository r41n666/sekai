extends Node
## 本地歌单播放器（Autoload，阶段 1 完成）
##
## 扫描 res://music/ 目录下的所有 .ogg 文件，顺序 / 随机 / 单曲循环播放。
## 快捷键：N = 下一首，P = 暂停 / 继续。
##
## 使用方法：把 .ogg 歌曲文件丢进 music/ 目录，重启游戏即可播放（详见 music/README.md）。
## 如果扫描不到任何文件，会退回使用 music_playlist 手动数组（可在代码里直接修改）。

signal track_changed(track_name: String, index: int)
signal playlist_reloaded(count: int)
signal pause_toggled(paused: bool)

const MUSIC_DIR := "res://music/"
const DEFAULT_VOLUME_DB := -6.0

enum PlayMode {
	SEQUENTIAL, ## 顺序播放，播完最后一首回到第一首
	SHUFFLE, ## 随机播放，每轮重新洗牌
	LOOP_ONE, ## 单曲循环
}

## 播放音量（dB），-6 dB 为默认值
@export var volume_db := DEFAULT_VOLUME_DB
## 播放模式
@export var play_mode: PlayMode = PlayMode.SEQUENTIAL
## 游戏启动后自动开始播放
@export var autoplay := true
## 后备歌单：当 res://music/ 扫描不到文件时使用（手写 res:// 路径）
@export var music_playlist: PackedStringArray = []

var _player: AudioStreamPlayer
var _tracks: Array[String] = []
var _order: Array[int] = []
var _order_pos := -1
var _current_index := -1
var _paused := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# 即使是暂停状态也继续放歌
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()

	_player = AudioStreamPlayer.new()
	_player.name = "MusicPlayer"
	_player.bus = "Master"
	_player.volume_db = volume_db
	_player.finished.connect(_on_track_finished)
	add_child(_player)

	reload_playlist()
	if autoplay and not _tracks.is_empty():
		next()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.echo:
		return
	if event.is_action_pressed("music_next"):
		next()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("music_pause"):
		toggle_pause()
		get_viewport().set_input_as_handled()


## 重新扫描歌单；返回值是否扫描到歌曲
func reload_playlist() -> bool:
	_tracks = _scan_tracks()
	if _tracks.is_empty():
		_tracks = _fallback_tracks()
	_rebuild_order()
	playlist_reloaded.emit(_tracks.size())
	if _tracks.is_empty():
		push_warning("MusicManager：res://music/ 里没有找到 .ogg 歌曲，也没有可用的后备歌单。")
	return not _tracks.is_empty()


## 播放下一首
func next() -> void:
	if _tracks.is_empty():
		return
	if play_mode == PlayMode.LOOP_ONE and _current_index >= 0:
		play_index(_current_index)
		return
	_order_pos += 1
	if _order_pos >= _order.size():
		_rebuild_order()
		_order_pos = 0
	if _order.is_empty():
		return
	play_index(_order[_order_pos])


## 播放上一首
func previous() -> void:
	if _tracks.is_empty():
		return
	if play_mode == PlayMode.LOOP_ONE and _current_index >= 0:
		play_index(_current_index)
		return
	_order_pos -= 1
	if _order_pos < 0:
		_order_pos = maxi(_order.size() - 1, 0)
	if _order.is_empty():
		return
	play_index(_order[_order_pos])


## 播放指定索引的歌曲
func play_index(index: int) -> void:
	if _tracks.is_empty():
		return
	_current_index = wrapi(index, 0, _tracks.size())
	var path := _tracks[_current_index]
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("MusicManager：无法加载歌曲 %s" % path)
		return
	# 保证播完能触发 finished，从而自动切下一首
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	_player.stream = stream
	_player.volume_db = volume_db
	_player.stream_paused = false
	_paused = false
	_player.play()
	track_changed.emit(get_current_track_name(), _current_index)


## 暂停 / 继续
func toggle_pause() -> void:
	if _player == null or _player.stream == null:
		return
	_paused = not _paused
	_player.stream_paused = _paused
	pause_toggled.emit(_paused)


func is_paused() -> bool:
	return _paused


func get_current_track_path() -> String:
	if _current_index < 0 or _current_index >= _tracks.size():
		return ""
	return _tracks[_current_index]


## 当前曲名（去掉目录与后缀，供 HUD 显示）
func get_current_track_name() -> String:
	var path := get_current_track_path()
	return path.get_file().get_basename() if path != "" else ""


func get_track_count() -> int:
	return _tracks.size()


func get_tracks() -> Array[String]:
	return _tracks.duplicate()


func _scan_tracks() -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(MUSIC_DIR)
	if dir == null:
		return found
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			# 跳过 .ogg.import 之类的导入旁文件
			if lower.ends_with(".ogg") and not lower.ends_with(".ogg.import"):
				found.append(MUSIC_DIR + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	found.sort()
	return found


func _fallback_tracks() -> Array[String]:
	var found: Array[String] = []
	for path in music_playlist:
		if ResourceLoader.exists(path):
			found.append(path)
		else:
			push_warning("MusicManager：后备歌单中的 %s 不存在。" % path)
	return found


func _rebuild_order() -> void:
	_order.clear()
	for i in _tracks.size():
		_order.append(i)
	if play_mode == PlayMode.SHUFFLE:
		# Fisher-Yates 洗牌
		for i in range(_order.size() - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var tmp := _order[i]
			_order[i] = _order[j]
			_order[j] = tmp
	_order_pos = -1


func _on_track_finished() -> void:
	next()