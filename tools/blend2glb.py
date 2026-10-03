# -*- coding: utf-8 -*-
"""用 bpy（Python 版 Blender）把 .blend 导出成 glb。

- 只导出网格（不含灯光 / 相机 / 骨骼，武器道具用不上骨架）；
- 有些 .blend 里的贴图没打包、外部文件也丢了，导出前会用文件里已打包的颜色贴图顶替，
  否则 glb 里的枪会没有颜色。

用法：python tools/blend2glb.py <model.blend> <out.glb>
"""
import sys
from pathlib import Path

import bpy

## 贴图最大边长（4096 的贴图会让 glb 涨到十几 MB，武器道具 2048 足够）
MAX_TEXTURE_SIZE = 2048


def repair_missing_textures() -> None:
    # 已打包且能读到像素的贴图才可以当备选（has_data 只有真正用过才为 True，不能作判据）
    candidates = [
        img for img in bpy.data.images
        if img.packed_file is not None and img.size[0] > 1
        and any(key in img.name.lower() for key in ("color", "albedo", "diffuse", "basecolor"))
    ]
    if not candidates:
        return
    for material in bpy.data.materials:
        if not material.use_nodes:
            continue
        for node in material.node_tree.nodes:
            if node.type != "TEX_IMAGE":
                continue
            image = node.image
            if image is None or image.size[0] > 0 or image.packed_file is not None:
                continue  # 能读到的都跳过（size 为 0 且没打包 = 外部文件丢了）
            prefix = image.name.split("_")[0].lower()
            same_family = [c for c in candidates if c.name.lower().startswith(prefix)]
            replacement = (same_family or candidates)[0]
            print("[blend2glb] 贴图缺失 %r -> 顶替为 %r" % (image.name, replacement.name))
            node.image = replacement


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src = Path(sys.argv[1]).resolve()
    dst = Path(sys.argv[2]).resolve()
    dst.parent.mkdir(parents=True, exist_ok=True)

    bpy.ops.wm.open_mainfile(filepath=str(src))
    repair_missing_textures()
    for image in bpy.data.images:
        if image.size[0] > MAX_TEXTURE_SIZE:
            print("[blend2glb] 贴图 %r %s -> %d" % (image.name, tuple(image.size), MAX_TEXTURE_SIZE))
            image.scale(MAX_TEXTURE_SIZE, MAX_TEXTURE_SIZE)

    bpy.ops.export_scene.gltf(
        filepath=str(dst),
        export_format="GLB",
        use_selection=False,
        export_apply=True,       # 应用修改器
        export_materials="EXPORT",
        export_yup=True,         # Blender Z-up → glTF Y-up
        export_skins=False,      # 武器道具不需要骨骼
        export_animations=False,
        export_cameras=False,
        export_lights=False,
    )

    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.visible_get()]
    verts = sum(len(o.data.vertices) for o in meshes)
    print("[blend2glb] %s -> %s | 可见网格=%d 顶点=%d" % (src.name, dst.name, len(meshes), verts))


if __name__ == "__main__":
    main()