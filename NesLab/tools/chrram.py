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
