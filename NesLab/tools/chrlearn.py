# CHR RAM 卡带补烘图块：游戏里碰到贴图里没有的图块（chrram.py 跑游戏时没走到的画面），会记进存档 NesLabDB.chrWanted
# （卡带 id → 图块的十六进制）。退出游戏（存档写盘）后跑这个：把这些图块加进卡带贴图，下次启动游戏就画得出来。
# 用法：python chrlearn.py
import glob, os, re, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ADDONS = os.path.dirname(os.path.dirname(HERE))
GAME = os.path.dirname(os.path.dirname(ADDONS))


def block(text, name):
    """存档里 ["name"] = { ... } 这一块的内容（按括号配对，存档有时带缩进、有时不带）"""
    i = text.find('["%s"] = {' % name)
    if i < 0:
        return None
    start = i = text.index("{", i)
    depth = 0
    while True:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start + 1:i]
        i += 1


def wanted():
    """{卡带 id: {图块十六进制, ...}}（所有账号合在一起）"""
    out = {}
    for sv in glob.glob(os.path.join(GAME, "WTF", "Account", "*", "SavedVariables", "NesLab.lua")):
        body = block(open(sv, encoding="utf-8", errors="replace").read(), "chrWanted")
        if not body:
            continue
        for cart, inner in re.findall(r'\["([^"]+)"\] = \{(.*?)\}', body, re.S):
            out.setdefault(cart, set()).update(h.upper() for h in re.findall(r'\["([0-9a-fA-F]{32})"\]', inner))
    return out


def main():
    sys.path.insert(0, HERE)
    import atlas
    want = wanted()
    if not want:
        print("存档里没有要补的图块（先玩 CHR RAM 的游戏，再退出游戏让存档写盘）")
        return
    total = 0
    for d in sorted(os.listdir(ADDONS)):
        path = os.path.join(ADDONS, d, "cart.lua")
        if not d.startswith("NesLab_") or not os.path.exists(path):
            continue
        text = open(path, encoding="utf-8").read()
        m = re.search(r'\bid = "([^"]+)"', text)
        t = re.search(r'\ttiles = "([0-9A-F]*)"', text)
        if not m or not t or m.group(1) not in want:
            continue
        hexs = t.group(1)
        have = {hexs[i:i + 32] for i in range(0, len(hexs), 32)}
        add = [h for h in sorted(want[m.group(1)]) if h not in have]
        room = atlas.MAX_TILES - len(hexs) // 32
        add = add[:max(0, room)]
        if not add:
            continue
        hexs += "".join(add)
        w, h, spr, used = atlas.write(os.path.join(ADDONS, d), bytes.fromhex(hexs))
        text = re.sub(r"atlasW = \d+, atlasH = \d+, slotsPerRow = \d+",
                      "atlasW = %d, atlasH = %d, slotsPerRow = %d" % (w, h, spr), text)
        text = re.sub(r'\tused = "\d*"', '\tused = "%s"' % used, text)
        text = text.replace(t.group(0), '\ttiles = "%s"' % hexs)
        open(path, "w", encoding="utf-8", newline="").write(text)
        print("%s：补 %d 种图块（共 %d）" % (d, len(add), len(hexs) // 32))
        total += len(add)
    print("补了 %d 种图块。重启游戏后生效。" % total)


if __name__ == "__main__":
    main()
