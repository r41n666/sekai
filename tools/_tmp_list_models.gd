extends Node
## 临时验证（验证后删除）：打印角色模型扫描结果（应只含 4 个初音模型，不含 weapons/）。
## 运行：godot --headless --path . res://tools/_tmp_list_models.tscn

func _ready() -> void:
	var paths := MikuModel.list_available_models()
	print("[models] 共 %d 个：" % paths.size())
	for path in paths:
		print("[models]   ", path)
	get_tree().quit(0 if paths.size() == 4 else 1)