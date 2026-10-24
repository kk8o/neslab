# CHR RAM 卡带的图块收集：图案是游戏运行时写进卡带内存的，没法按地址预先烘贴图。
# 这里用 LuaJIT（pip 包 lupa）直接跑 NesLab 自己的模拟核心（Cpu / Ppu / Apu / Nes.lua），不出画面、不出声，
# 让游戏自己演示一阵、再乱按一阵手柄，把它写过的每一种图块（16 字节）都收下来，交给 nes2cart.py 烘进贴图。
# 游戏里碰到没收到的图块会记进 NesLabDB.chrWanted，退出游戏后跑 chrlearn.py 补烘。
import os, random

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.normpath(os.path.join(HERE, ".."))

STUBS = b"""
NesLab = {}
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
debugprofilestop = function() return os.clock() * 1000 end
"""

# 一次跑：script 是 Python 给的按键表（每帧一个 0-255），每帧结束查一次图块，新见到的图块计数
DRIVER = b"""
return function(rom, script, seen)
	local m = NesLab.NewMachine(rom)
	local ppu = m.ppu
	ppu.onUnknownTile = function(key)
		seen[key] = (seen[key] or 0) + 1
	end
	for f = 1, #script do
		m.pad.buttons = script[f]
		m.Frame()
		ppu.ResolveChr()
	end
end
"""

A, B, SELECT, START, UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8, 16, 32, 64, 128


def script(seed, frames):
    """按键表：先看演示，再按开始，之后乱按（偏向往右走、开枪跳），隔一阵按一次开始（菜单往下走）"""
    rnd = random.Random(seed)
    out = [0] * min(frames, 1500 + seed * 300)                 # 片头、演示
    while len(out) < frames:
        n = len(out)
        if n % 900 < 8:
            out.append(START)                                   # 开始 / 菜单确认（暂停的话下次再按一次就回来）
            continue
        if n % 900 < 24:
            out.append(0)
            continue
        hold = rnd.randint(6, 30)
        b = 0
        d = rnd.random()
        b |= RIGHT if d < 0.45 else LEFT if d < 0.6 else UP if d < 0.75 else DOWN if d < 0.9 else 0
        if rnd.random() < 0.5:
            b |= A
        if rnd.random() < 0.5:
            b |= B
        if rnd.random() < 0.02:
            b |= SELECT
        out.extend([b] * hold)
    return out[:frames]


def collect(rom_fields, runs=4, frames=20000):
    """rom_fields：cart.lua 里的字段（prg 十六进制、mapper、mirror、battery）。返回 [(图块 16 字节, 见到次数)]，按先见到的顺序"""
    lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
    lua.execute(STUBS)
    for name in ("Cpu", "Ppu", "Apu", "Nes"):
        code = open(os.path.join(CORE, name + ".lua"), "rb").read()
        lua.execute(code)
    drive = lua.execute(DRIVER)
    seen = lua.table()
    order = {}
    for r in range(runs):
        rom = lua.table_from({k.encode() if isinstance(k, str) else k:
                              (v.encode() if isinstance(v, str) else v) for k, v in rom_fields.items()})
        rom[b"chrRam"] = True
        rom[b"tiles"] = b""
        drive(rom, lua.table_from(script(r, frames)), seen)
        for k, v in seen.items():
            if k not in order:
                order[k] = len(order)
    counts = dict(seen.items())
    return sorted(((k, counts[k]) for k in order), key=lambda kv: order[kv[0]])



def _code_score(blk):
    """一块里像 6502 程序的地方有几处：JSR / JMP 到 $8000 以上、读写 PPU / APU / 内存 $0300-$07FF 的绝对寻址"""
    n = 0
    for i in range(len(blk) - 2):
        o, h = blk[i], blk[i + 2]
        if o in (0x20, 0x4C) and h >= 0x80:
            n += 1
        elif o in (0x8D, 0xAD, 0x8E, 0x8C, 0xAE, 0xAC, 0xBD, 0x9D, 0xB9, 0x99) and (h in (0x20, 0x40) or 3 <= h <= 7):
            n += 1
    return n


def from_prg(prg, have, block=1024, min_hits=8, max_code=6):
    """程序里原样存着的图案：很多汉化 / 移植卡把图案不压缩地放在程序里，用到时整块拷进显存。
    程序按 block 字节切块：块里按 16 字节对齐、已经收到的（非全空）图块有 min_hits 个以上，就当它是一块图案；
    再从这些块往两边扩到相邻的、不像程序（_code_score <= max_code）的块——跑游戏没走到的关卡的图案多半挨着放。
    返回新图块列表：离确认的块近的在前（贴图放不下时先舍远的），不含 have 里已有的、全空的"""
    n = len(prg) // block
    chunks = [[prg[b * block + i:b * block + i + 16] for i in range(0, block, 16)] for b in range(n)]
    dist = {}
    for b in range(n):
        if sum(1 for c in chunks[b] if c in have and any(c)) >= min_hits:
            dist[b] = 0
    edge = list(dist)
    code = {}
    while edge:
        nxt = []
        for b in edge:
            for nb in (b - 1, b + 1):
                if 0 <= nb < n and nb not in dist:
                    if nb not in code:
                        code[nb] = _code_score(prg[nb * block:(nb + 1) * block])
                    if code[nb] <= max_code:
                        dist[nb] = dist[b] + 1
                        nxt.append(nb)
        edge = nxt
    out, got = [], set()
    for b in sorted(dist, key=lambda b: (dist[b], b)):
        for c in chunks[b]:
            if any(c) and c not in have and c not in got:
                got.add(c)
                out.append(c)
    return out
