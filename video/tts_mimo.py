#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
小米 MiMo TTS 客户端封装 (mimo-v2.5-tts)。

用法:
  python3 video/tts_mimo.py --say "要合成的文本" --out a.wav [--voice 冰糖] [--style "..."]
  python3 video/tts_mimo.py --probe-samples --outdir video/audio/samples

依赖: 环境变量 MIMO_API_KEY (不写在代码里、不打印)
接口: POST https://api.xiaomimimo.com/v1/chat/completions
"""
import os
import sys
import json
import time
import wave
import base64
import ssl
import argparse

import urllib.request
import urllib.error

API_URL = "https://api.xiaomimimo.com/v1/chat/completions"
MODEL = "mimo-v2.5-tts"


def _ssl_context():
    """优先用 certifi 的根证书; 系统 Python 常缺证书链"""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()

# 预置中文音色
VOICES = {
    "冰糖": ("冰糖", "中文 女声"),
    "茉莉": ("茉莉", "中文 女声"),
    "苏打": ("苏打", "中文 男声"),
    "白桦": ("白桦", "中文 男声"),
}


def api_key():
    k = os.environ.get("MIMO_API_KEY", "").strip()
    if not k:
        raise SystemExit("缺少环境变量 MIMO_API_KEY")
    return k


def synthesize(text, voice="冰糖", style=None, fmt="wav", timeout=120, retries=3):
    """返回音频字节; voice 为预置音色名, style 为自然语言风格指令"""
    messages = []
    if style:
        messages.append({"role": "user", "content": style})
    messages.append({"role": "assistant", "content": text})
    payload = {
        "model": MODEL,
        "messages": messages,
        "audio": {"format": fmt, "voice": voice},
    }
    data = json.dumps(payload).encode("utf-8")
    last = None
    for attempt in range(retries):
        req = urllib.request.Request(
            API_URL, data=data,
            headers={"Content-Type": "application/json", "api-key": api_key()},
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as r:
                body = json.loads(r.read().decode("utf-8"))
            b64 = body["choices"][0]["message"]["audio"]["data"]
            return base64.b64decode(b64)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "ignore")[:300]
            last = "HTTP %s: %s" % (e.code, detail)
            if e.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                time.sleep(2 + attempt * 3)
                continue
            break
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, e)
            if attempt < retries - 1:
                time.sleep(2 + attempt * 3)
                continue
            break
    raise RuntimeError("TTS 合成失败: %s" % last)


def wav_info(path):
    """返回 (时长秒, 采样率); 非 wav 返回 None"""
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / float(w.getframerate()), w.getframerate()
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--say")
    ap.add_argument("--out")
    ap.add_argument("--voice", default="冰糖")
    ap.add_argument("--style")
    ap.add_argument("--probe-samples", action="store_true")
    ap.add_argument("--outdir", default="video/audio/samples")
    args = ap.parse_args()

    if args.probe_samples:
        os.makedirs(args.outdir, exist_ok=True)
        text = "一块屏幕，三件事。"
        style = "轻快自信的产品介绍口吻，语速稍快，声音明亮有亲和力，像在跟朋友推荐好东西。"
        for name in VOICES:
            for tag, st in (("plain", None), ("styled", style)):
                out = os.path.join(args.outdir, "%s_%s.wav" % (name, tag))
                try:
                    raw = synthesize(text, voice=VOICES[name][0], style=st)
                    with open(out, "wb") as f:
                        f.write(raw)
                    info = wav_info(out)
                    print("%-16s %-7s %6.2fs -> %s"
                          % (VOICES[name][1], tag, info[0] if info else -1, out))
                except Exception as e:
                    print("%-16s %-7s 失败: %s" % (name, tag, e))
        return

    if not args.say or not args.out:
        raise SystemExit("需要 --say 与 --out")
    raw = synthesize(args.say, voice=VOICES.get(args.voice, (args.voice,))[0],
                     style=args.style)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(raw)
    info = wav_info(args.out)
    print("已生成 %s%s" % (args.out, "  时长 %.2fs" % info[0] if info else ""))


if __name__ == "__main__":
    main()
