extends RigidBody3D
## 手雷投掷物：引信到点后爆炸 —— 闪光 + 冲击波球 + 低频爆炸声 + 烟雾，
## 对范围内的本地玩家造成伤害（伤害/震动由 PlayerController.take_damage 处理）。

@export var fuse_time := 1.6
@export var blast_radius := 6.0
@export var blast_damage := 70.0

var _exploded := false


func _ready() -> void:
	var timer := get_tree().create_timer(fuse_time)
	timer.timeout.connect(explode)


func explode() -> void:
	if _exploded:
		return
	_exploded = true
	_show_blast()
	_damage_nearby()
	set_physics_process(false)
	freeze = true
	hide()
	var timer := get_tree().create_timer(1.2)
	timer.timeout.connect(queue_free)


## 闪光 + 扩散的冲击波球
func _show_blast() -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.75, 0.4)
	light.light_energy = 9.0
	light.omni_range = blast_radius * 2.0
	add_child(light)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.85, 0.5, 0.55)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.7, 0.35, 1.0)
	material.emission_energy_multiplier = 3.0
	var wave := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	wave.mesh = sphere
	wave.material_override = material
	wave.scale = Vector3.ONE * 0.4
	add_child(wave)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(wave, "scale", Vector3.ONE * blast_radius, 0.35).set_ease(Tween.EASE_OUT)
	tween.tween_property(material, "albedo_color", Color(1.0, 0.85, 0.5, 0.0), 0.45)
	tween.tween_property(material, "emission_energy_multiplier", 0.0, 0.45)
	tween.tween_property(light, "light_energy", 0.0, 0.4)

	_play_boom()


## 范围伤害：只结算本地玩家（原型简化；伤害由 take_damage 附带屏幕震动）
func _damage_nearby() -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null or not player.has_method("take_damage"):
		return
	var distance := global_position.distance_to((player as Node3D).global_position)
	if distance > blast_radius:
		return
	var falloff := 1.0 - distance / blast_radius
	player.take_damage(blast_damage * falloff)


func _play_boom() -> void:
	var audio := AudioStreamPlayer3D.new()
	audio.stream = _build_boom()
	audio.unit_size = 20.0
	audio.max_distance = 120.0
	add_child(audio)
	audio.play()


## 程序化爆炸声：低频冲击 + 噪声轰鸣 + 余响
func _build_boom() -> AudioStreamWAV:
	var rate := 44100
	var duration := 0.7
	var count := int(rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in count:
		var t := float(i) / float(rate)
		var punch := sin(TAU * 55.0 * t) * exp(-t * 12.0) * 0.8
		var rumble := rng.randf_range(-1.0, 1.0) * exp(-t * 6.0) * 0.6
		var crack := rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.7
		var sample := clampf(punch + rumble + crack, -1.0, 1.0) * 0.95
		data.encode_s16(i * 2, int(sample * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav