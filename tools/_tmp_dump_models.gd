extends Node
## 临时排查（验证后删除）：打印各角色模型导入后的节点结构 / 骨架 / 骨骼名，定位武器挂手失败原因。
## 运行：xvfb-run -a /tmp/godotbin/Godot_v4.7.2-stable_linux.x86_64 --path . res://tools/_tmp_dump_models.tscn

const MODELS := [
	"res://assets/models/miku/miku.glb",
	"res://assets/models/miku_navy/miku_navy.glb",
	"res://assets/models/miku_maid/miku_maid.glb",
]


func _ready() -> void:
	for path in MODELS:
		var packed := load(path) as PackedScene
		if packed == null:
			print("[dump] 加载失败 ", path)
			continue
		var root := packed.instantiate()
		add_child(root)
		var skeletons: Array[Skeleton3D] = []
		var meshes := 0
		_collect(root, skeletons)
		for node in _all(root):
			if node is MeshInstance3D:
				meshes += 1
		print("[dump] %s：网格=%d 骨架=%d" % [path.get_file(), meshes, skeletons.size()])
		for skeleton in skeletons:
			print("[dump]   骨架 %s 骨骼数=%d 缩放=%s" % [skeleton.name, skeleton.get_bone_count(), skeleton.scale])
			if skeleton.get_bone_count() > 0:
				var sample: Array[String] = []
				for i in mini(12, skeleton.get_bone_count()):
					sample.append("%d:%s" % [i, skeleton.get_bone_name(i)])
				print("[dump]   前 12 骨骼：", sample)
				# 找名字里带“手”的骨骼
				var hands: Array[String] = []
				for i in skeleton.get_bone_count():
					var n := skeleton.get_bone_name(i)
					if n.contains("手") or n.to_lower().contains("hand"):
						hands.append("%d:%s" % [i, n])
				print("[dump]   手相关骨骼：", hands)
		root.queue_free()
	get_tree().quit()


func _collect(node: Node, out: Array[Skeleton3D]) -> void:
	if node is Skeleton3D:
		out.append(node)
	for child in node.get_children():
		_collect(child, out)


func _all(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_all(child))
	return out