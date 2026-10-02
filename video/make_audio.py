#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成「小聆 AI · 时钟天气番茄钟」介绍片的音轨。

旁白用小米 MiMo TTS (mimo-v2.5-tts, 音色 冰糖), 需要环境变量 MIMO_API_KEY。

产物:
  audio/vo_<n>.wav  逐句中文旁白
  audio/bgm.wav     背景垫乐
  audio/sfx.wav     转场音效
  audio/mix_voice.wav  垫乐 + 音效 + 旁白
  audio/mix_novoice.wav 垫乐 + 音效

用法: python3 video/make_audio.py --probe   # 只探旁白时长
      python3 video/make_audio.py           # 全量生成
"""
import os
import sys
import math
import wave
import subprocess

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tts_mimo import synthesize  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
AUD = os.path.join(HERE, "audio")
SR = 48000
DUR = 30.0
N = int(SR * DUR)

VOICE = "冰糖"
STYLE = "轻快自信的产品介绍口吻，语速稍快，声音明亮有亲和力，像在跟朋友推荐好东西。"

# (起播时间, 文本) —— 与 render.py 的分镜时间轴对齐
VO = [
    (0.35, "一块屏幕，三件事。"),
    (3.70, "几度、下不下雨、要不要带伞，抬眼就有答案。"),
    (9.75, "二十五分钟专注，五分钟起身。按下开始，剩下的交给它。"),
    (17.70, "时钟、天气、专注，都在这一块屏幕上。"),
    (22.75, "不用写代码，跟小聆 AI 说一句就够了。"),
]

SCENE_BOUNDS = [3.5, 9.5, 17.5, 22.8, 28.0]


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("命令失败: %s\n%s" % (" ".join(cmd), r.stderr))
    return r.stdout


def synth_vo(text, out_wav):
    raw = synthesize(text, voice=VOICE, style=STYLE)
    tmp = out_wav + ".raw"
    with open(tmp, "wb") as f:
        f.write(raw)
    # MiMo 返回 24kHz 单声道 16bit wav, 统一重采样到 SR
    run(["afconvert", "-f", "WAVE", "-d", "LEI16@%d" % SR, "-c", "1", tmp, out_wav])
    os.remove(tmp)
    return out_wav


def read_wav(path):
    with wave.open(path, "rb") as w:
        ch, sw, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    assert sw == 2, "只支持 16bit wav"
    a = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    if sr != SR:
        idx = np.linspace(0, len(a) - 1, int(len(a) * SR / sr))
        a = np.interp(idx, np.arange(len(a)), a).astype(np.float32)
    return a


def write_wav(path, data, sr=SR):
    d = np.clip(data, -1.0, 1.0)
    pcm = (d * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def t_axis(n=None):
    return np.arange(n if n is not None else N) / SR


def env_ad(t, attack, decay, power=2.0):
    a = np.clip(t / max(1e-6, attack), 0, 1)
    d = np.exp(-np.clip(t, 0, None) / max(1e-6, decay)) ** power
    return a * d


def pluck(freq, dur, decay=0.55):
    t = t_axis(int(dur * SR))
    e = env_ad(t, 0.004, decay, 1.6)
    y = (np.sin(2 * np.pi * freq * t) * 1.0
         + np.sin(2 * np.pi * freq * 2 * t) * 0.28
         + np.sin(2 * np.pi * freq * 3 * t) * 0.10)
    return y * e


def add(buf, sig, at):
    i = int(at * SR)
    if i >= len(buf):
        return
    seg = sig[:len(buf) - i]
    buf[i:i + len(seg)] += seg


def make_bgm():
    t = t_axis()
    y = np.zeros(N, dtype=np.float32)

    # 低音铺底: 两个长音交替
    for f, st, dur in [(65.41, 0.0, 9.0), (98.00, 8.5, 9.0), (87.31, 17.0, 6.5),
                       (65.41, 22.5, 7.5)]:
        n = int(dur * SR)
        tt = t_axis(n)
        env = np.minimum(1.0, tt / 0.9) * np.minimum(1.0, (dur - tt) / 1.1)
        y[:n] += (np.sin(2 * np.pi * f * tt) * 0.30
                  + np.sin(2 * np.pi * f * 1.5 * tt) * 0.06) * np.clip(env, 0, 1)

    # 中高音持续和弦(带轻微颤音), 17.5s 后加入更亮的音
    pad_specs = [(196.00, 0.0, 10.0, 0.085), (246.94, 1.2, 9.0, 0.075),
                 (146.83, 0.0, 11.0, 0.065),
                 (293.66, 17.4, 6.5, 0.085), (369.99, 17.9, 6.0, 0.070),
                 (220.00, 17.5, 10.5, 0.075)]
    for f, st, dur, amp in pad_specs:
        n = int(dur * SR)
        tt = t_axis(n)
        vib = 1.0 + 0.0016 * np.sin(2 * np.pi * 4.4 * tt)
        env = np.minimum(1.0, tt / 1.3) * np.clip((dur - tt) / 1.6, 0, 1)
        y[:n] += np.sin(2 * np.pi * f * vib * tt) * amp * env

    # 分解和弦, 每 0.75s 一颗
    arp = [261.63, 329.63, 392.00, 523.25]
    tt = 0.35
    i = 0
    while tt < 27.4:
        f = arp[i % len(arp)] * (2.0 if 17.5 <= tt < 24.0 else 1.0)
        add(y, pluck(f, 1.5, 0.42) * 0.075, tt)
        tt += 0.75
        i += 1

    # 尾部 2 秒留白, 整体收尾渐弱
    tail = int(1.6 * SR)
    y[-tail:] *= np.linspace(1, 0, tail) ** 1.2
    y[:int(0.4 * SR)] *= np.linspace(0, 1, int(0.4 * SR))
    y = np.tanh(y * 1.25) * 0.72
    return y


def make_sfx():
    y = np.zeros(N, dtype=np.float32)
    rng = np.random.default_rng(11)

    # 场景切换: 短促扫频噪声
    for at in SCENE_BOUNDS[:-1]:
        dur = 0.42
        n = int(dur * SR)
        tt = t_axis(n)
        noise = rng.normal(0, 1, n)
        # 一阶低通让噪声变"气流"感
        lp = np.cumsum(noise) / np.arange(1, n + 1) ** 0.5
        env = np.exp(-tt / 0.13)
        tone = np.sin(2 * np.pi * (300 + 900 * tt / dur) * tt) * 0.35
        sig = (lp / (np.max(np.abs(lp)) + 1e-9) * 0.8 + tone) * env
        add(y, sig * 0.30, at)

    # 结尾: 低频收束
    n = int(2.2 * SR)
    tt = t_axis(n)
    env = np.exp(-tt / 0.85)
    y[:n] += (np.sin(2 * np.pi * 55 * tt) * 0.55
              + np.sin(2 * np.pi * 82.5 * tt) * 0.22) * env * 0.34
    return y


def norm_peak(x, target=0.89):
    m = np.max(np.abs(x))
    return x * (target / m) if m > 1e-9 else x


def main():
    os.makedirs(AUD, exist_ok=True)
    probe = "--probe" in sys.argv
    force = "--force" in sys.argv or probe
    total_end = 0.0
    for i, (at, text) in enumerate(VO, start=1):
        p = os.path.join(AUD, "vo_%d.wav" % i)
        if force or not os.path.exists(p):
            synth_vo(text, p)
        a = read_wav(p)
        d = len(a) / SR
        end = at + d
        total_end = max(total_end, end)
        flag = ""
        if end > SCENE_BOUNDS[min(i, 4)] + 0.35:
            flag = "  <== 可能压到下一镜, 建议改短"
        print("vo_%d  %5.2fs -> %5.2fs  时长 %.2fs  %s%s"
              % (i, at, end, d, text[:18], flag))
    print("旁白最晚结束于 %.2fs (成片 28.0s 处黑场)" % total_end)
    if probe:
        return

    bgm = norm_peak(make_bgm(), 0.34)
    sfx = norm_peak(make_sfx(), 0.80)
    write_wav(os.path.join(AUD, "bgm.wav"), bgm)
    write_wav(os.path.join(AUD, "sfx.wav"), sfx)

    bed = bgm + sfx * 0.9
    write_wav(os.path.join(AUD, "mix_novoice.wav"), np.tanh(bed * 1.05) * 0.82)

    mix = bed.copy()
    for i, (at, _) in enumerate(VO, start=1):
        v = norm_peak(read_wav(os.path.join(AUD, "vo_%d.wav" % i)), 0.92)
        add(mix, v, at)
    mix = np.tanh(mix * 1.02) * 0.85
    write_wav(os.path.join(AUD, "mix_voice.wav"), mix)
    print("音轨完成 ->", AUD)


if __name__ == "__main__":
    main()
