# 卡带文件夹名：NesLab_<游戏名的拼音>。插件文件夹名不能有中文（游戏会进不去），
# 所以汉字换成首字母大写的拼音（测试游戏 → CeShiYouXi），字母数字原样，其余符号并成一个下划线。
# 要 pypinyin（pip install pypinyin）；没装就退回卡带 id。
import re


def folder_name(name, fallback):
    try:
        from pypinyin import lazy_pinyin
    except ImportError:
        return "NesLab_" + fallback
    out = []
    for ch in name:
        if "一" <= ch <= "鿿":
            out.append(lazy_pinyin(ch, errors=lambda s: "_")[0].capitalize())   # 不认识的字别原样留下
        elif ch.isascii() and ch.isalnum():
            out.append(ch)
        else:
            out.append("_")
    s = re.sub(r"_+", "_", "".join(out)).strip("_")[:56].rstrip("_")
    if not s.isascii():                              # 插件文件夹名有一个非 ASCII 字符，游戏就进不去
        s = ""
    return "NesLab_" + (s or fallback)
