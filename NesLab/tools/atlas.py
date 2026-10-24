# 图块贴图：每个 16 字节的 NES 图块拆成颜色 1 / 2 / 3 三张白色蒙版（游戏里分别着色），一格 8×8。
# 一行 32 格起，图案多就加宽，让高度不超过 2048。nes2cart.py（CHR ROM 按地址顺序）和 chrram.py（CHR RAM 按收集到的图块）共用。
import os

import numpy as np

from blp import write_dxt1_mask

MAX_TILES = 256 * 256 // 3               # 2048 × 2048（256 × 256 格）放得下的图块数


def build(chr_bytes):
    """返回 (宽, 高, 每行格数, alpha 数组, used 字符串)"""
    tiles = len(chr_bytes) // 16
    slots_per_row = 32
    while (tiles * 3 + slots_per_row - 1) // slots_per_row * 8 > 2048 and slots_per_row < 256:
        slots_per_row *= 2
    w, h = slots_per_row * 8, 8
    while h < (tiles * 3 + slots_per_row - 1) // slots_per_row * 8:
        h *= 2
    alpha = np.zeros((h, w), dtype=np.uint8)
    used = []
    for t in range(tiles):
        p0 = np.frombuffer(chr_bytes[t * 16:t * 16 + 8], dtype=np.uint8)
        p1 = np.frombuffer(chr_bytes[t * 16 + 8:t * 16 + 16], dtype=np.uint8)
        bits = 7 - np.arange(8)
        v = ((p0[:, None] >> bits) & 1) | (((p1[:, None] >> bits) & 1) << 1)   # 8×8，颜色 0-3
        mask = 0
        for k in (1, 2, 3):
            sel = v == k
            if not sel.any():
                continue
            mask |= 1 << (k - 1)
            s = t * 3 + k - 1
            x, y = (s % slots_per_row) * 8, (s // slots_per_row) * 8
            alpha[y:y + 8, x:x + 8][sel] = 255
        used.append("%d" % mask)
    return w, h, slots_per_row, alpha, "".join(used)


def write(out_dir, chr_bytes):
    """写 tiles.blp，返回 (宽, 高, 每行格数, used)"""
    w, h, spr, alpha, used = build(chr_bytes)
    write_dxt1_mask(os.path.join(out_dir, "tiles.blp"), alpha)
    return w, h, spr, used
