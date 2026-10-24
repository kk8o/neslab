# 生成 NesLab 的音色采样（sound/*.ogg），游戏里按 APU 音符事件播放。需要 ffmpeg（带 libvorbis）。
#   方波 p<占空比>_<音符>_<音量档>.ogg：占空比 0/1/2（12.5 / 25 / 50%；75% 听起来同 25%），音符 33-108，音量 1-4
#   三角波 t_<音符>.ogg：音符 21-96（三角波没有音量控制）
#   噪声 n<模式><周期>_<音量档>.ogg：模式 0/1，周期 0-15，音量 1-4
# 方波、三角波 2 秒，噪声 1 秒；开头 2 ms 淡入、结尾 30 ms 淡出，免得起音和停音时爆音。
import os, subprocess, sys

RATE, CPU = 44100, 1789773
DUTY = (0.125, 0.25, 0.5)
NOISE_PERIOD = (4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068)
TRI = [15 - i for i in range(16)] + list(range(16))
root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
out_dir = os.path.join(root, "sound")
os.makedirs(out_dir, exist_ok=True)

def envelope(samples):
    n, fi, fo = len(samples), int(RATE * 0.002), int(RATE * 0.03)
    for i in range(fi): samples[i] *= i / fi
    for i in range(fo): samples[n - 1 - i] *= i / fo
    return samples

def encode(name, samples):
    pcm = b"".join(int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True) for s in samples)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(RATE), "-ac", "1",
                    "-i", "-", "-c:a", "libvorbis", "-q:a", "3", os.path.join(out_dir, name + ".ogg")],
                   input=pcm, check=True)

def freq(note): return 440 * 2 ** ((note - 69) / 12)

count = 0
for duty, d in enumerate(DUTY):
    for note in range(33, 109):
        f = freq(note)
        base = [1.0 if (i * f / RATE) % 1.0 < d else -1.0 for i in range(RATE * 2)]
        for vb in range(1, 5):
            encode("p%d_%d_%d" % (duty, note, vb), envelope([s * 0.45 * vb / 4 for s in base]))
            count += 1
for note in range(21, 97):
    f = freq(note)
    encode("t_%d" % note, envelope([(TRI[int((i * f / RATE) % 1.0 * 32)] / 7.5 - 1) * 0.55 for i in range(RATE * 2)]))
    count += 1
for mode in (0, 1):
    for period in range(16):
        step, lfsr, acc, base = CPU / NOISE_PERIOD[period] / RATE, 1, 0.0, []
        for _ in range(RATE):
            acc += step
            while acc >= 1:
                acc -= 1
                bit = (lfsr ^ (lfsr >> (6 if mode else 1))) & 1
                lfsr = (lfsr >> 1) | (bit << 14)
            base.append(1.0 if lfsr & 1 else -1.0)
        for vb in range(1, 5):
            encode("n%d%d_%d" % (mode, period, vb), envelope([s * 0.35 * vb / 4 for s in base]))
            count += 1
print(count, "samples ->", out_dir)
