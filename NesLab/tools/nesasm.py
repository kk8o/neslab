# NesLab 自检卡带共用的东西：最小的两遍 6502 汇编器（只认用到的指令）、图块画法、字形和几个背景图块。
OPS = {  # (助记符, 寻址) -> 操作码
    ("SEI", "imp"): 0x78, ("CLD", "imp"): 0xD8, ("CLC", "imp"): 0x18, ("TXS", "imp"): 0x9A, ("INX", "imp"): 0xE8,
    ("DEX", "imp"): 0xCA, ("DEY", "imp"): 0x88, ("TXA", "imp"): 0x8A, ("TAX", "imp"): 0xAA, ("TYA", "imp"): 0x98,
    ("TAY", "imp"): 0xA8, ("PHA", "imp"): 0x48, ("PLA", "imp"): 0x68, ("RTI", "imp"): 0x40, ("RTS", "imp"): 0x60,
    ("LSRA", "imp"): 0x4A,
    ("LDA", "imm"): 0xA9, ("LDA", "zp"): 0xA5, ("LDA", "abs"): 0xAD, ("LDA", "absx"): 0xBD,
    ("LDX", "imm"): 0xA2, ("LDY", "imm"): 0xA0,
    ("STA", "zp"): 0x85, ("STA", "abs"): 0x8D, ("STA", "absx"): 0x9D, ("STX", "abs"): 0x8E,
    ("AND", "imm"): 0x29, ("AND", "zp"): 0x25, ("EOR", "imm"): 0x49, ("ADC", "imm"): 0x69,
    ("CMP", "imm"): 0xC9, ("CPX", "imm"): 0xE0,
    ("INC", "zp"): 0xE6, ("DEC", "zp"): 0xC6, ("ROL", "zp"): 0x26, ("BIT", "abs"): 0x2C,
    ("JMP", "abs"): 0x4C, ("JSR", "abs"): 0x20,
    ("BNE", "rel"): 0xD0, ("BEQ", "rel"): 0xF0, ("BPL", "rel"): 0x10, ("BVS", "rel"): 0x70, ("BVC", "rel"): 0x50,
}
SIZE = {"imp": 1, "imm": 2, "zp": 2, "rel": 2, "abs": 3, "absx": 3}


class Program:
    def __init__(self, org):
        self.org, self.items = org, []

    def L(self, name): self.items.append(("label", name))
    def I(self, m, mode="imp", arg=None): self.items.append(("ins", m, mode, arg))
    def DB(self, *bs): self.items.append(("bytes", list(bs)))

    def assemble(self):
        labels, pc = {}, self.org
        for item in self.items:
            if item[0] == "label": labels[item[1]] = pc
            elif item[0] == "bytes": pc += len(item[1])
            else: pc += SIZE[item[2]]
        out, pc = bytearray(), self.org
        for item in self.items:
            if item[0] == "label": continue
            if item[0] == "bytes":
                out += bytes(item[1]); pc += len(item[1]); continue
            _, m, mode, arg = item
            val = labels[arg] if isinstance(arg, str) else arg
            out.append(OPS[(m, mode)])
            if mode == "rel":
                off = val - (pc + 2)
                assert -128 <= off <= 127, (m, arg, off)
                out.append(off & 0xFF)
            elif mode in ("imm", "zp"):
                out.append(val & 0xFF)
            elif mode in ("abs", "absx"):
                out += bytes((val & 0xFF, val >> 8))
            pc += SIZE[mode]
        return out, labels


def tile(rows):
    """8×8 图块（每格写 0-3 颜色号）→ 16 字节 CHR"""
    p0, p1 = bytearray(8), bytearray(8)
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            v = int(ch) if ch in "0123" else 0
            if v & 1: p0[r] |= 0x80 >> c
            if v & 2: p1[r] |= 0x80 >> c
    return bytes(p0 + p1)


BG = {
    1: ["11111112", "11111112", "11111112", "22222222", "11121111", "11121111", "11121111", "22222222"],  # 砖
    2: ["33330000", "33330000", "33330000", "33330000", "00003333", "00003333", "00003333", "00003333"],  # 棋盘
    3: ["10000001", "01000010", "00200200", "00033000", "00033000", "00200200", "01000010", "10000001"],  # 叉
    4: ["00000000", "03000300", "00000000", "00000000", "00000000", "03000300", "00000000", "00000000"],  # 点
}
GLYPH = {
    "N": ["3000003", "3300003", "3030003", "3003003", "3000303", "3000033", "3000003"],
    "E": ["3333333", "3000000", "3000000", "3333330", "3000000", "3000000", "3333333"],
    "S": ["0333333", "3000000", "3000000", "0333330", "0000003", "0000003", "3333330"],
    "L": ["3000000", "3000000", "3000000", "3000000", "3000000", "3000000", "3333333"],
    "A": ["0033300", "0300030", "3000003", "3333333", "3000003", "3000003", "3000003"],
    "B": ["3333330", "3000003", "3000003", "3333330", "3000003", "3000003", "3333330"],
    "O": ["0333330", "3000003", "3000003", "3000003", "3000003", "3000003", "0333330"],
    "K": ["3000030", "3000300", "3003000", "3330000", "3003000", "3000300", "3000030"],
}
SMILE = ["00333300", "03111130", "31211213", "31111113", "31211213", "31122113", "03111130", "00333300"]
FONT_START = 16
LETTERS = "NESLABOK"
PALETTE = (0x0F, 0x16, 0x27, 0x18, 0x0F, 0x1A, 0x2A, 0x3A, 0x0F, 0x12, 0x22, 0x32, 0x0F, 0x14, 0x24, 0x34,
           0x0F, 0x28, 0x30, 0x0F, 0x0F, 0x11, 0x21, 0x31, 0x0F, 0x15, 0x25, 0x35, 0x0F, 0x19, 0x29, 0x39)


def letter(ch):
    return FONT_START + LETTERS.index(ch) if ch != " " else 0


def bg_bank(tiles=BG):
    """一个 4 KB 背景图案页：给定的背景图块 + 字形"""
    out = bytearray(4096)
    for i, rows in tiles.items():
        out[i * 16:(i + 1) * 16] = tile(rows)
    for i, ch in enumerate(LETTERS):
        out[(FONT_START + i) * 16:(FONT_START + i + 1) * 16] = tile([r + "0" for r in GLYPH[ch]] + ["00000000"])
    return out


def sprite_bank():
    """一个 4 KB 精灵图案页：1 号是笑脸"""
    out = bytearray(4096)
    out[16:32] = tile(SMILE)
    return out


def ines(prg, chr_, mapper, flags6_low=0x01):
    """iNES 文件头 + PRG + CHR；flags6_low：第 0 位竖向镜像、第 1 位电池"""
    f6 = ((mapper & 0x0F) << 4) | flags6_low
    f7 = mapper & 0xF0
    return b"NES\x1a" + bytes([len(prg) // 16384, len(chr_) // 8192, f6, f7]) + bytes(8) + bytes(prg) + bytes(chr_)
