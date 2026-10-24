# 写 BLP2（DXT1、1 位透明度、不带 mipmap）：图块贴图只有「白」和「透明」两种像素，DXT1 的三色 + 透明模式能原样存下，
# 每像素半个字节（32 位 TGA 的八分之一）。每个 4×4 块：两个端点色都是白（相等 → 三色 + 透明模式），下标 0 = 白、3 = 透明。
import struct

import numpy as np


def write_dxt1_mask(path, mask):
    """mask：h×w 的数组，非 0 = 不透明（白）；h、w 是 4 的倍数"""
    h, w = mask.shape
    clear = (np.asarray(mask) == 0).astype(np.uint32)
    # (块行, 块列, 块内行, 块内列) → 每块 16 个像素按行排，第 i 个像素占下标的第 2i、2i+1 位
    b = clear.reshape(h // 4, 4, w // 4, 4).transpose(0, 2, 1, 3).reshape(h // 4, w // 4, 16)
    idx = (b * (np.uint32(3) << (2 * np.arange(16, dtype=np.uint32)))).sum(axis=2, dtype=np.uint64).astype("<u4")
    blocks = np.zeros((h // 4, w // 4, 2), dtype="<u4")
    blocks[:, :, 0] = 0xFFFFFFFF                     # 两个 16 位端点色都是白
    blocks[:, :, 1] = idx
    data = blocks.tobytes()
    header = b"BLP2" + struct.pack("<I", 1) + bytes([2, 1, 0, 0]) + struct.pack("<II", w, h)
    header += struct.pack("<16I", 1172, *[0] * 15) + struct.pack("<16I", len(data), *[0] * 15) + bytes(1024)
    with open(path, "wb") as f:
        f.write(header)
        f.write(data)
