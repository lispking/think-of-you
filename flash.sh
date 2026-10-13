#!/usr/bin/env bash
#
# 想你机 · 烧录脚本
#
# 把 think-of-you.lua 烧到所有已连接的小聆设备上。做的事只有三件：
#   1. 把 TOPIC 注入源码，生成 device-flash.lua（两台内容完全相同）；
#   2. 按 transport_id 逐台 adb push 到 /miniapp/think-of-you.lua；
#   3. 从每台设备回读正在跑的源码，和本地逐字节比对。
#
# 为什么需要注入：设备读不了外部文件，TOPIC 必须内联在推给设备的源码里；
# 而 TOPIC 相当于密码，不该写进版本库。生成的副本与主题名都已被 .gitignore 挡掉。
# 两台设备跑的是同一份源码——不需要 KEY，自己的回显靠每条消息的随机 token 认出来。
#
# 用法：
#   ./flash.sh                       # 用上次记住的主题重烧（首次会自动生成一个）
#   ./flash.sh --topic <主题名>       # 换主题并记住，两台一起重烧
#   ./flash.sh --list                # 只列出设备
#   ./flash.sh --only 1 --dry-run    # 只看会做什么，不真烧
#
# 选项：
#   --topic <名>    指定 ntfy 主题（两台必须相同），会记到 device-flash.topic
#   --file <路径>   指定源文件，默认 think-of-you.lua
#   --only <ids>    只烧指定的 transport_id，逗号分隔，例如 --only 1,3
#   --dry-run       只显示计划，不推送
#   --no-verify     跳过回读校验
#   --list          列出设备后退出
#   --force         允许使用含 CHANGE-ME 的占位主题
#
# 环境变量：ADB=<adb 路径> 可覆盖自动查找。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPT_DIR/think-of-you.lua"
OUT="$SCRIPT_DIR/device-flash.lua"
TOPIC_FILE="$SCRIPT_DIR/device-flash.topic"
REMOTE="/miniapp/think-of-you.lua"

TOPIC=""
ONLY=""
VERIFY=1
DRY=0
JUST_LIST=0
FORCE=0

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --topic)
            TOPIC="${2:-}"
            if [ -z "$TOPIC" ]; then echo "错误：--topic 缺少值" >&2; exit 2; fi
            shift 2 ;;
        --topic=*)
            TOPIC="${1#--topic=}"
            if [ -z "$TOPIC" ]; then echo "错误：--topic 缺少值" >&2; exit 2; fi
            shift ;;
        --file)
            SRC="${2:-}"
            if [ -z "$SRC" ]; then echo "错误：--file 缺少值" >&2; exit 2; fi
            shift 2 ;;
        --only)
            ONLY="${2:-}"
            if [ -z "$ONLY" ]; then echo "错误：--only 缺少值" >&2; exit 2; fi
            shift 2 ;;
        --only=*)
            ONLY="${1#--only=}"
            if [ -z "$ONLY" ]; then echo "错误：--only 缺少值" >&2; exit 2; fi
            shift ;;
        --dry-run)   DRY=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        --list)      JUST_LIST=1; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "错误：未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── adb ────────────────────────────────────────────────────────────
find_adb() {
    if [ -n "${ADB:-}" ] && [ -x "${ADB}" ]; then printf '%s\n' "$ADB"; return 0; fi
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    for c in \
        "${ANDROID_HOME:-}/platform-tools/adb" \
        "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
        "$HOME/Library/Android/sdk/platform-tools/adb" \
        /opt/homebrew/share/android-commandlinetools/platform-tools/adb \
        /usr/local/share/android-commandlinetools/platform-tools/adb \
        /usr/lib/android-sdk/platform-tools/adb
    do
        case "$c" in
            /*) if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi ;;
        esac
    done
    return 1
}

if ! ADB=$(find_adb); then
    echo "错误：找不到 adb。装 Android Platform Tools，或用 ADB=<路径> 指定。" >&2
    exit 1
fi

# 同一批设备的 ADB 序列号可能相同，adb -s 会歧义，所以一律用 transport_id。
list_transports() {
    "$ADB" devices -l 2>/dev/null | awk '$2 == "device" {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^transport_id:/) { sub(/^transport_id:/, "", $i); print $i }
        }
    }'
}

# 逗号列表里是否含某个值；命中返回 0
contains() {
    local needle="$1" list="$2" oldifs="$IFS" item found=0
    IFS=','
    for item in $list; do
        if [ "$item" = "$needle" ]; then found=1; fi
    done
    IFS="$oldifs"
    [ "$found" = 1 ]
}

TRANSPORTS=$(list_transports)

if [ "$JUST_LIST" = 1 ]; then
    if [ -z "$TRANSPORTS" ]; then
        echo "没有已连接的设备。"
    else
        echo "已连接设备（transport_id）:"
        for t in $TRANSPORTS; do printf '  %s\n' "$t"; done
    fi
    exit 0
fi

if [ -z "$TRANSPORTS" ]; then
    echo "错误：没有找到已连接的设备（${ADB} devices）" >&2
    exit 1
fi

SELECTED=""
for t in $TRANSPORTS; do
    if [ -n "$ONLY" ]; then
        contains "$t" "$ONLY" || continue
    fi
    SELECTED="$SELECTED $t"
done

if [ -z "$SELECTED" ]; then
    echo "错误：--only ${ONLY} 没有匹配到设备；当前是 ${TRANSPORTS}" >&2
    exit 1
fi

# ── 主题名 ─────────────────────────────────────────────────────────
if [ -z "$TOPIC" ] && [ -f "$TOPIC_FILE" ]; then
    TOPIC=$(tr -d ' \t\r\n' < "$TOPIC_FILE")
fi

if [ -z "$TOPIC" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "错误：需要 openssl 生成随机主题名，或用 --topic 指定。" >&2
        exit 1
    fi
    TOPIC="lingclaw-think-$(openssl rand -hex 6)"
    echo "首次烧录，生成主题名：${TOPIC}"
fi

case "$TOPIC" in
    *[!A-Za-z0-9_-]*)
        echo "错误：主题名只能用英文字母、数字、连字符和下划线：${TOPIC}" >&2
        exit 2 ;;
esac
if [ ${#TOPIC} -gt 64 ]; then
    echo "错误：主题名过长（>64）：${TOPIC}" >&2
    exit 2
fi
case "$TOPIC" in
    *CHANGE-ME*)
        if [ "$FORCE" != 1 ]; then
            echo "错误：${TOPIC} 还是占位主题，请用 --topic 换成难猜的字符串。" >&2
            exit 2
        fi ;;
esac

if [ ! -f "$SRC" ]; then
    echo "错误：找不到源文件 ${SRC}" >&2
    exit 1
fi

# ── 注入 TOPIC，生成烧录副本 ────────────────────────────────────────
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

gen() {
    local topic="$1" tmp="$TMPD/gen.lua" changed
    # 只替换引号里的主题名，行尾注释保持不动
    sed "s|^local TOPIC = \"[^\"]*\"|local TOPIC = \"$topic\"|" "$SRC" > "$tmp"

    # 只允许改到 TOPIC 那一行：一删一增正好 2 行 diff
    changed=$(diff "$SRC" "$tmp" | grep -c '^[<>]' || true)
    if [ "$changed" != 2 ]; then
        echo "错误：注入 TOPIC 失败，源码里应恰好有一行 'local TOPIC = \"…\"'（实际改动 ${changed} 行）" >&2
        return 1
    fi
    if ! grep -q "^local TOPIC = \"$topic\"" "$tmp"; then
        echo "错误：注入后没找到目标主题名" >&2
        return 1
    fi
    cp "$tmp" "$OUT"
    printf '%s\n' "$topic" > "$TOPIC_FILE"
}

gen "$TOPIC"
echo "源文件   $SRC"
echo "烧录副本 $OUT"
echo "主题名   $TOPIC  （已记入 ${TOPIC_FILE}）"
echo "目标     $REMOTE"

if [ "$DRY" = 1 ]; then
    echo
    echo "计划（--dry-run，不推送）："
    for t in $SELECTED; do printf '  transport %s\n' "$t"; done
    exit 0
fi

# ── 逐台烧录 ───────────────────────────────────────────────────────
echo
fails=0
for t in $SELECTED; do
    printf 'transport %s: 推送… ' "$t"
    if ! "$ADB" -t "$t" push "$OUT" "$REMOTE" >/dev/null 2>&1; then
        echo "失败"
        fails=$((fails + 1))
        continue
    fi
    echo "完成"

    if [ "$VERIFY" = 1 ]; then
        # 回读的是设备上正在跑的源码：只有应用真的跑起来了才拉得到
        if "$ADB" -t "$t" pull /miniapp/miniapp.lua "$TMPD/verify-$t.lua" >/dev/null 2>&1 \
           && cmp -s "$OUT" "$TMPD/verify-$t.lua"
        then
            printf 'transport %s: 回读校验通过\n' "$t"
        else
            printf 'transport %s: 回读校验失败（设备上可能没跑起来）\n' "$t" >&2
            fails=$((fails + 1))
        fi
    fi
done

echo
if [ "$fails" != 0 ]; then
    echo "有 ${fails} 台设备没烧成功。" >&2
    exit 1
fi

echo "全部完成。按任意一台的 function 键试一下：对端应在 10 秒内响两声并念出那句话。"
echo "注意：源码只存在设备内存里，设备重启后要重新执行本脚本。"
