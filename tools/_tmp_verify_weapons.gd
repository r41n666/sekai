extends Node
## 临时验证（验证后删除）：武器模型移植 + 角色朝向 + 玩法冒烟
## 运行：godot --headless --path . res://tools/_tmp_verify_weapons.tscn

func _ready() -> void:
	var runner := Runner.new()
	runner.name = "WeaponVerifyRunner"
	get_tree().root.add_child.call_deferred(runner)


class Runner extends Node:
	var _fails := 0
	var _checks := 0

	func _ready() -> void:
		_run()

	func _run() -> void:
		await get_tree().process_frame

		# ---------- 1) 武器模型与贴图 ----------
		var expect := {
			"res://scenes/weapons/rifle.tscn": {"name": "M4A4 突击步枪", "len": [0.6, 1.3]},
			"res://scenes/weapons/usp.tscn": {"name": "USP · 半自动", "len": [0.1, 0.4]},
			"res://scenes/weapons/knife.tscn": {"name": "蝴蝶刀", "len": [0.2, 0.4]},
			"res://scenes/weapons/grenade.tscn": {"name": "手雷", "len": [0.05, 0.3]},
		}
		for path in expect:
			var packed := load(path) as PackedScene
			_check(packed != null, "加载 %s" % path.get_file())
			if packed == null:
				continue
			var inst := packed.instantiate() as Node3D
			add_child(inst)
			await get_tree().process_frame
			var model := inst.get_node_or_null("Model")
			_check(model != null, "%s 有 Model 子节点（真实模型）" % path.get_file())
			var meshes: Array[MeshInstance3D] = []
			_collect(inst, meshes)
			# 排除曳光弹 / 枪口火光等辅助网格
			var gun: MeshInstance3D = null
			for m in meshes:
				var n := String(m.name).to_lower()
				if not n.contains("tracer") and not n.contains("muzzleflash"):
					gun = m
					break
			_check(gun != null, "%s 找到枪械本体网格" % path.get_file())
			if gun != null:
				# 整个 Model 子树合起来的包围盒（蝴蝶刀是 7 个 Mesh 拼的，单个网格量不出总长）
				var length := 0.0
				if model is Node3D:
					var box := AABB()
					var first := true
					for m in meshes:
						var n := String(m.name).to_lower()
						if n.contains("tracer") or n.contains("muzzleflash"):
							continue
						if not m.is_ancestor_of(model) and m != model and not model.is_ancestor_of(m):
							continue
						var local: AABB = m.get_aabb()
						for corner_index in 8:
							var corner := local.position + Vector3(
								local.size.x * (corner_index & 1),
								local.size.y * ((corner_index >> 1) & 1),
								local.size.z * ((corner_index >> 2) & 1))
							var point: Vector3 = m.global_transform * corner
							if first:
								box = AABB(point, Vector3.ZERO)
								first = false
							else:
								box = box.expand(point)
					length = maxf(box.size.x, box.size.z) # 朝 +Z 摆放时长度在 Z 轴上
				var want: Array = expect[path]["len"]
				_check(length >= float(want[0]) and length <= float(want[1]),
					"%s 尺寸合理（长 %.3f m，期望 %.2f~%.2f）" % [path.get_file(), length, want[0], want[1]])
				var textured := 0
				var total := 0
				var mesh: Mesh = gun.mesh
				for s in mesh.get_surface_count():
					total += 1
					var mat := mesh.surface_get_material(s)
					if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
						textured += 1
					elif mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
						textured += 1
				_check(textured == total, "%s 每个表面都有贴图（%d/%d）" % [path.get_file(), textured, total])
			_check(String(inst.get("display_name")) == String(expect[path]["name"]),
				"%s display_name = %s" % [path.get_file(), str(inst.get("display_name"))])
			inst.queue_free()
			await get_tree().process_frame

		# ---------- 2) 角色模型朝向（脚尖应比足首更靠 +Z） ----------
		for model_path in ["res://assets/models/miku_navy/miku_navy.glb",
				"res://assets/models/miku_maid/miku_maid.glb", "res://assets/models/miku_maid/miku_maid2.glb"]:
			var scene := load(model_path) as PackedScene
			if scene == null:
				_check(false, "加载 %s" % model_path)
				continue
			var inst := scene.instantiate()
			add_child(inst)
			var skel := _find_skeleton(inst)
			if skel == null:
				_check(false, "%s 有骨架" % model_path)
				inst.queue_free()
				continue
			var ankle := -1
			var toe := -1
			var right_hand := -1
			for i in skel.get_bone_count():
				var bone_name := skel.get_bone_name(i)
				if ankle < 0 and bone_name == "右足首":
					ankle = i
				if toe < 0 and bone_name == "右つま先":
					toe = i
				if right_hand < 0 and bone_name == "右手首":
					right_hand = i
			if ankle >= 0 and toe >= 0:
				var dz: float = skel.get_bone_rest(toe).origin.z - skel.get_bone_rest(ankle).origin.z
				_check(dz > 0.0, "%s 面朝 +Z（脚尖 Δz=%+.2f）" % [model_path.get_file(), dz])
			else:
				_check(false, "%s 找到 右足首/右つま先 骨骼" % model_path.get_file())
			# PMX 是左手系：转 glb 时必须镜像 Z（而不是绕 Y 转 180°），否则模型左右反、
			# 右手跑到 +X —— 枪就会挂在「左手」。这条盯住转换器别回退。
			if right_hand >= 0:
				var hx: float = skel.get_bone_rest(right_hand).origin.x
				_check(hx < 0.0, "%s 右手在 -X（右手首 x=%+.2f，未被镜像）" % [model_path.get_file(), hx])
			else:
				_check(false, "%s 找到 右手首 骨骼" % model_path.get_file())
			inst.queue_free()
			await get_tree().process_frame

		# ---------- 3) 玩法冒烟：武器槽 + 开火 + 人机 ----------
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		for i in 8:
			await get_tree().process_frame
		var player: Node = get_tree().get_first_node_in_group("player")
		_check(player != null, "对局场景里玩家已生成")
		if player != null:
			var slot_map := {"weapon_1": "Rifle", "weapon_2": "USP", "weapon_3": "Knife", "weapon_4": "Grenade"}
			for slot in [["weapon_1", "M4A4 突击步枪"], ["weapon_2", "USP · 半自动"], ["weapon_3", "蝴蝶刀"], ["weapon_4", "手雷"]]:
				player._equip_slot(slot_map[slot[0]])
				await get_tree().process_frame
				if player.get_weapon() == null:
					# 出生时已装备主武器：同键再按一次是「空手」，所以再按一次把它装回来
					player._equip_slot(slot_map[slot[0]])
					await get_tree().process_frame
				var weapon: Node = player.get_weapon()
				var dn := str(weapon.get("display_name")) if weapon != null else "(空手)"
				_check(weapon != null, "装备 %s → %s" % [slot[1], dn])
			player._equip_slot("Rifle")
			await get_tree().process_frame
			var mag_before: int = int(player.get_weapon().get_mag())
			Input.action_press("shoot")
			await _wait_seconds(0.6)
			Input.action_release("shoot")
			await get_tree().process_frame
			var mag_after: int = int(player.get_weapon().get_mag())
			_check(mag_after < mag_before, "M4A4 开火消耗弹药（%d → %d）" % [mag_before, mag_after])

			var manager: Node = get_tree().current_scene.get_node_or_null("Bots")
			manager.change_count(2)
			await get_tree().process_frame
			_check(manager.get_alive_count() == 2, "人机仍可刷新（%d 个）" % manager.get_alive_count())
			manager.change_count(-99)

			# ---------- 4) 武器挂点跟手 + 皮肤 ----------
			var model: Node = player.get_node_or_null("MikuModel")
			_check(model != null, "玩家有 MikuModel")
			var mount: Node3D = model.get_node_or_null("WeaponMount")
			_check(mount != null and mount.get_parent() == model,
				"武器挂点始终挂在 MikuModel 下（player.gd / bot.gd 的固定路径不失效）")
			await _wait_seconds(0.8) # 等模型加载 + 程序化姿态 + 挂点跟手
			# 注意：只能从「角色模型」里找骨架。MikuModel 子树里还挂着武器，
			# USP 自带骨架（骨骼名 Barrel / Magazine 之类），直接递归会先撞上它、测出假数据。
			var character: Node = null
			for child in model.get_children():
				if child.name == "Placeholder" or child.name == "WeaponMount":
					continue
				character = child
				break
			var skeleton := _find_skeleton(character) if character != null else null
			_check(skeleton != null, "玩家模型有骨架")
			if skeleton != null and mount != null:
				var hand_name: String = model._find_hand_bone(skeleton)
				_check(hand_name != "", "识别出右手骨骼（%s）" % hand_name)
				var hand_idx := skeleton.find_bone(hand_name)
				if hand_idx >= 0:
					var hand_pos: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hand_idx).origin
					var gap := hand_pos.distance_to(mount.global_position)
					_check(gap < 0.35, "武器挂点在右手上（手骨 %s，距离 %.3f m）" % [hand_name, gap])
					# 几何法找的手也必须落在角色右侧（-X）：miku.glb 的骨骼名是乱码，只能靠几何；
					# 落错边同样会变成「左手持枪」。
					var hand_local: Vector3 = (model as Node3D).global_transform.affine_inverse() * hand_pos
					_check(hand_local.x < 0.0, "手骨在角色右侧 -X（局部 x=%+.2f）" % hand_local.x)
			# 皮肤：伽玛多普勒应先有材质，再套到武器网格上
			var material := WeaponSkin.build_material("gamma_doppler")
			_check(material != null and material.albedo_texture != null,
				"伽玛多普勒皮肤贴图已生成（%dx%d）" % [
					material.albedo_texture.get_width() if material != null and material.albedo_texture != null else 0,
					material.albedo_texture.get_height() if material != null and material.albedo_texture != null else 0])
			player.set_weapon_skin("Rifle", "gamma_doppler")
			await get_tree().process_frame
			var rifle: Node = player.get_weapon()
			var skinned := 0
			for mesh in WeaponSkin.model_meshes(rifle):
				if mesh.material_override != null:
					skinned += 1
			_check(skinned > 0, "皮肤已套到 M4A4 的 %d 个网格上" % skinned)
			player.set_weapon_skin("Rifle", "")
			await get_tree().process_frame
			var cleared := true
			for mesh in WeaponSkin.model_meshes(rifle):
				if mesh.material_override != null:
					cleared = false
			_check(cleared, "切回原版后材质覆盖已清掉")

		_finish()

	func _wait_seconds(seconds: float) -> void:
		var until := Time.get_ticks_msec() + int(seconds * 1000.0)
		while Time.get_ticks_msec() < until:
			await get_tree().process_frame

	func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
		if node is MeshInstance3D:
			out.append(node)
		for child in node.get_children():
			_collect(child, out)

	func _find_skeleton(node: Node) -> Skeleton3D:
		if node is Skeleton3D:
			return node
		for child in node.get_children():
			var found := _find_skeleton(child)
			if found != null:
				return found
		return null

	func _check(ok: bool, message: String) -> void:
		_checks += 1
		if ok:
			print("  [OK] ", message)
		else:
			_fails += 1
			print("  [FAIL] ", message)

	func _finish() -> void:
		print("=== 共 %d 项检查，失败 %d 项 ===" % [_checks, _fails])
		get_tree().quit(1 if _fails > 0 else 0)