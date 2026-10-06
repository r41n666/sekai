extends TestSuite
## 渲染驱动锁（C-19 回归防线）
##
## ## 为什么需要这个文件
## C-19 把 `project.godot` 的 `rendering_device/driver.windows` 从 d3d12 改成 vulkan，
## 修好了「窗口模式启动即崩」。但**这行配置后来丢过一次**：
## commit a3efe27 为了清理 Godot 自动写入的 `[debug] file_logging/*` 污染，
## 执行了 `git checkout -- project.godot` —— 那个命令按**文件**还原，
## 把同一文件里刚修好的 Vulkan 设置一并回退了，而且当时没人发现。
##
## ## 核心教训
## `tools/verify.sh` 走 `--headless`，**不经过渲染后端**。
## 所以这类「配置被误删」的回归，verify 全绿也照样漏过去。
## 要卡住它，只能在测试里**直接读 project.godot 并断言内容**。
##
## ## 本文件的定位
## 项目里唯一一处「断言配置文件文本」的地方。写法刻意保守：
##只读文件 + 找关键行，不启动渲染、不依赖任何后端。

const PROJECT_GODOT := "res://project.godot"


func _read_project() -> String:
	var f: FileAccess = FileAccess.open(PROJECT_GODOT, FileAccess.READ)
	return "" if f == null else f.get_as_text()


## ⚠ 核心锁：渲染驱动必须显式固定为 vulkan。
## 被删或被改回 d3d12 都会让 C-19 复发（启动即崩），故直接转红。
func test_render_driver_is_vulkan() -> void:
	var src := _read_project()
	check_true(src.find("rendering_device/driver.windows=\"vulkan\"") >= 0,
		"渲染驱动必须显式固定为 vulkan（C-19：本机 D3D12 后端启动即崩）")
	check_true(src.find("rendering_device/driver.windows=\"d3d12\"") < 0,
		"禁止把渲染驱动改回 d3d12（C-19 回归）")


## 锁住那行「勿改回」的说明注释在位。
## 不是洁癖：注释是这个配置唯一的存在理由，删了就一定会有人改回去。
func test_render_driver_carries_dont_revert_note() -> void:
	var src := _read_project()
	check_true(src.find("不要**改回 d3d12") >= 0 or src.find("不要改回 d3d12") >= 0,
		"Vulkan 配置旁应保留「勿改回 d3d12」的说明注释")


## 回归防线：C-19 的配置曾被 `git checkout -- project.godot` 连带回退。
## 现在注释里写明了「清理前先 diff」，此处钉住这条纪律确实写进去了。
func test_checkout_discipline_noted() -> void:
	var src := _read_project()
	check_true(src.find("git checkout -- project.godot") >= 0,
		"应记录「清理 project.godot 前必须先 diff」的纪律（该配置曾被误回退）")
