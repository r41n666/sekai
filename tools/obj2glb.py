#!/usr/bin/env python3
"""OBJ → glb 极简转换器（供本项目把 OBJ 模型接入 Godot）。

支持：v / vt / vn / f（四边形自动三角化、支持负索引与缺省分量），单张漫反射贴图内嵌进 glb。
忽略：.mtl 文件（贴图路径由命令行给出）、多材质、顶点色。

用法：python tools/obj2glb.py <model.obj> <out_dir> [texture.png]
"""
import json
import struct
import sys
from pathlib import Path

COMP_U16, COMP_U32, COMP_F32 = 5123, 5125, 5126
TARGET_ARRAY = 34962
TARGET_ELEMENT = 34963


def parse_obj(path: Path):
    positions, uvs, normals = [], [], []
    faces = []  # [(顶点序号, uv 序号, 法线序号)]，-1 表示缺省
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        tag = parts[0]
        if tag == "v":
            positions.append(tuple(float(x) for x in parts[1:4]))
        elif tag == "vt":
            uv = [float(x) for x in parts[1:3]]
            uvs.append(tuple(uv + [0.0] * (2 - len(uv))))
        elif tag == "vn":
            normals.append(tuple(float(x) for x in parts[1:4]))
        elif tag == "f":
            face = []
            for token in parts[1:]:
                comps = token.split("/")
                vi = _idx(comps[0], len(positions))
                ti = _idx(comps[1], len(uvs)) if len(comps) > 1 and comps[1] else -1
                ni = _idx(comps[2], len(normals)) if len(comps) > 2 and comps[2] else -1
                face.append((vi, ti, ni))
            # 扇形三角化（凸多边形够用；Noesis 导出的 OBJ 多为三角形）
            for k in range(1, len(face) - 1):
                faces.append((face[0], face[k], face[k + 1]))
    return positions, uvs, normals, faces


def _idx(token: str, count: int) -> int:
    value = int(token)
    return value - 1 if value > 0 else count + value


def build_vertices(positions, uvs, normals, faces):
    """把「位置/UV/法线」三个独立索引合并成唯一顶点表（glTF 顶点只有一个索引）。"""
    unique = {}
    out_pos, out_uv, out_nrm, indices = [], [], [], []
    flat_normal = not normals
    for face in faces:
        for vi, ti, ni in face:
            if flat_normal:
                ni = -2  # 扁平法线占位：按面单独生成
            key = (vi, ti, ni)
            if ni == -2:
                key = (vi, ti, -2, len(indices))
            index = unique.get(key)
            if index is None:
                index = len(out_pos)
                unique[key] = index
                out_pos.append(positions[vi])
                out_uv.append(uvs[ti] if 0 <= ti < len(uvs) else (0.0, 0.0))
                out_nrm.append(normals[ni] if 0 <= ni < len(normals) else None)
            indices.append(index)
    # 没有法线的模型：按面计算扁平法线
    for tri in range(0, len(indices), 3):
        tri_idx = indices[tri:tri + 3]
        if out_nrm[tri_idx[0]] is not None:
            continue
        a, b, c = (out_pos[i] for i in tri_idx)
        n = _cross(_sub(b, a), _sub(c, a))
        length = _length(n) or 1.0
        n = tuple(v / length for v in n)
        for i in tri_idx:
            out_nrm[i] = n
    return out_pos, out_uv, [n or (0.0, 1.0, 0.0) for n in out_nrm], indices


def _sub(a, b):
    return tuple(a[i] - b[i] for i in range(3))


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _length(v):
    return (v[0] ** 2 + v[1] ** 2 + v[2] ** 2) ** 0.5


def pack_glb(name: str, positions, uvs, normals, indices, texture: Path, out_path: Path):
    bin_parts = []
    buffer_views = []
    accessors = []

    def add_view(data: bytes, target=None):
        offset = sum(len(p) for p in bin_parts)
        while offset % 4:
            bin_parts.append(b"\x00")
            offset += 1
        bin_parts.append(data)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target:
            view["target"] = target
        buffer_views.append(view)
        return len(buffer_views) - 1

    def add_accessor(view, comp, count, kind, minmax=None):
        acc = {"bufferView": view, "componentType": comp, "count": count, "type": kind}
        if minmax:
            acc["min"], acc["max"] = minmax
        accessors.append(acc)
        return len(accessors) - 1

    pos_min = [min(p[i] for p in positions) for i in range(3)]
    pos_max = [max(p[i] for p in positions) for i in range(3)]
    pos_acc = add_accessor(
        add_view(b"".join(struct.pack("<3f", *p) for p in positions), TARGET_ARRAY),
        COMP_F32, len(positions), "VEC3", (pos_min, pos_max),
    )
    nrm_acc = add_accessor(
        add_view(b"".join(struct.pack("<3f", *n) for n in normals), TARGET_ARRAY),
        COMP_F32, len(normals), "VEC3",
    )
    # glTF 的 UV 原点在左上，OBJ 在左下：翻转 V
    uv_acc = add_accessor(
        add_view(b"".join(struct.pack("<2f", u, 1.0 - v) for u, v in uvs), TARGET_ARRAY),
        COMP_F32, len(uvs), "VEC2",
    )
    if len(positions) > 65535:
        data = struct.pack("<%dI" % len(indices), *indices)
        comp = COMP_U32
    else:
        data = struct.pack("<%dH" % len(indices), *indices)
        comp = COMP_U16
    idx_acc = add_accessor(add_view(data, TARGET_ELEMENT), comp, len(indices), "SCALAR")

    material = {
        "name": name,
        "pbrMetallicRoughness": {"metallicFactor": 0.15, "roughnessFactor": 0.55},
        "doubleSided": True,
    }
    gltf = {
        "asset": {"version": "2.0", "generator": "obj2glb (trae)"},
        "scene": 0,
        "scenes": [{"name": "Scene", "nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"name": name, "primitives": [{
            "attributes": {"POSITION": pos_acc, "NORMAL": nrm_acc, "TEXCOORD_0": uv_acc},
            "indices": idx_acc,
            "material": 0, # 不挂材质的话 Godot 里就是没贴图的默认材质（青花瓷手雷曾踩过这个坑）
        }]}],
        "materials": [material],
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": 0}],
    }

    if texture is not None and texture.exists():
        data = texture.read_bytes()
        suffix = texture.suffix.lower()
        mime = "image/png" if suffix == ".png" or data[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
        view = add_view(data)
        gltf["images"] = [{"bufferView": view, "mimeType": mime, "name": texture.name}]
        gltf["textures"] = [{"source": 0, "sampler": 0}]
        gltf["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
        material["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 0}

    bin_blob = b"".join(bin_parts)
    while len(bin_blob) % 4:
        bin_blob += b"\x00"
    gltf["buffers"][0]["byteLength"] = len(bin_blob)
    json_blob = json.dumps(gltf, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    while len(json_blob) % 4:
        json_blob += b" "

    with out_path.open("wb") as f:
        f.write(b"glTF" + struct.pack("<II", 2, 12 + 8 + len(json_blob) + 8 + len(bin_blob)))
        f.write(struct.pack("<I", len(json_blob)) + b"JSON" + json_blob)
        f.write(struct.pack("<I", len(bin_blob)) + b"BIN\x00" + bin_blob)

    return len(positions), len(indices) // 3


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    obj = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    texture = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    out_dir.mkdir(parents=True, exist_ok=True)
    positions, uvs, normals, faces = parse_obj(obj)
    if not faces:
        raise SystemExit("OBJ 里没有面数据：%s" % obj)
    out_pos, out_uv, out_nrm, indices = build_vertices(positions, uvs, normals, faces)
    out_path = out_dir / ("%s.glb" % obj.stem)
    stats = pack_glb(obj.stem, out_pos, out_uv, out_nrm, indices, texture, out_path)
    print("[obj2glb] %s -> %s | 顶点=%d 三角面=%d 贴图=%s" % (
        obj.name, out_path.name, stats[0], stats[1], texture.name if texture else "无"))


if __name__ == "__main__":
    main()