# music/ —— 本地歌单目录

把你想听的 **.ogg** 歌曲文件直接放进这个目录即可。

## 使用步骤

1. 把 `*.ogg` 文件复制到本目录（`music/`）。
2. 重启 Godot 编辑器或重新运行游戏（Godot 需要先导入音频资源）。
3. 游戏启动后会自动开始播放。

> 如果游戏正在运行中放入了新歌，请在编辑器里等它导入完成，然后重启游戏。
> 阶段 1 不做运行时热扫描（音乐管理器提供 `reload_playlist()`，后续可由 UI 按钮调用）。

## 快捷键

| 按键 | 功能 |
| --- | --- |
| `N` | 下一首 |
| `P` | 暂停 / 继续 |

## 说明

- 只支持 `.ogg`（Ogg Vorbis）。MP3 请先转换成 ogg，例如用 ffmpeg：
  `ffmpeg -i song.mp3 -c:a libvorbis -q:a 5 song.ogg`
- 播放顺序为**文件名排序**（`music_manager.gd` 里 `found.sort()`）。
  想让顺序固定，可以在文件名前加序号，例如 `01_xxx.ogg`、`02_yyy.ogg`。
- 想改成随机播放或单曲循环：在 `scripts/music_manager.gd` 顶部把
  `play_mode` 改成 `PlayMode.SHUFFLE` 或 `PlayMode.LOOP_ONE`。
- 默认音量 -6 dB，改 `volume_db` 即可。
- 若 `res://music/` 扫描不到任何 `.ogg`，音乐管理器会退回使用
  `music_manager.gd` 里的手动数组 `music_playlist`（填 `res://` 路径），
  仍然为空时只在控制台打印一条警告，不影响游戏运行。

## 版权提醒

请只使用你拥有版权或已获授权/免费授权的音乐文件，不要随仓库分发商业音乐。