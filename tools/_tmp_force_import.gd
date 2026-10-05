@tool
extends Node
## 临时：headless 的 --import / --editor 不给 glb 排队导入；但「启动时被加载的脚本里 preload」会触发编辑器按需导入。
## 用完删除本文件并把 project.godot 里的 autoload 项撤掉。

const _M4A4 := preload("res://assets/models/weapons/m4a4.glb")
const _PINK := preload("res://assets/models/weapons/pink_pistol.glb")
const _KNIFE := preload("res://assets/models/weapons/butterfly_knife.glb")