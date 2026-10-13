#!/usr/bin/env bash
#
# 想你机 · 本地 ntfy 中继（Docker）
#
# 自建一个 ntfy 跑在本机，两台设备指向它，就能把轮询压到几百毫秒，
# 也不再受公共实例限速影响——本地调试"实时感"只能这么做。
#
# 用法：
#   ./ntfy-local.sh              启动，并打印要填进源码的 NT
#   ./ntfy-local.sh --flash      启动 + 生成指向本机的副本 + 烧录两台
#   ./ntfy-local.sh status       看运行状态与地址
#   ./ntfy-local.sh url          只打印地址（便于脚本取值）
#   ./ntfy-local.sh logs         看中继日志
#   ./ntfy-local.sh stop         停掉并移除容器
#
# 选项：
#   --port N    监听端口，默认 8080（也认环境变量 PORT）
#   --poll N    --flash 时把 POLL_MS 设成多少，默认 2000
#   --host IP   指定印在地址里的局域网 IP（默认自动探测 en0）
#
# 为什么必须自建：公共 ntfy.sh 有速率限制；而自建实例的默认限速是
# 「burst 60、每 5 秒补一个」，长轮询也会被限，所以这里显式放宽。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
NAME=${NAME:-think-of-you-ntfy}
IMAGE=${IMAGE:-binwiederhier/ntfy:latest}
VOLUME=${VOLUME:-think-of-you-ntfy-cache}
PORT=${PORT:-8080}
LOCAL_POLL_MS=${LOCAL_POLL_MS:-2000}
HOST_IP=${HOST_IP:-}

CMD=start
DO_FLASH=0

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        start)        CMD=start; shift ;;
        stop)         CMD=stop; shift ;;
        status)       CMD=status; shift ;;
        url)          CMD=url; shift ;;
        logs)         CMD=logs; shift ;;
        --flash)      DO_FLASH=1; shift ;;
        --port)       PORT="${2:-}"; [ -n "$PORT" ] || { echo "错误：--port 缺少值" >&2; exit 2; }; shift 2 ;;
        --poll)       LOCAL_POLL_MS="${2:-}"; [ -n "$LOCAL_POLL_MS" ] || { echo "错误：--poll 缺少值" >&2; exit 2; }; shift 2 ;;
        --host)       HOST_IP="${2:-}"; [ -n "$HOST_IP" ] || { echo "错误：--host 缺少值" >&2; exit 2; }; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "错误：未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── 探测局域网地址 ────────────────────────────────────────────────
lan_ip() {
    if [ -n "$HOST_IP" ]; then printf '%s\n' "$HOST_IP"; return 0; fi
    local ip
    for iface in en0 en1 en2 en3; do
        ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    done
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)   # Linux
    if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)
    if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    return 1
}

base_url() { printf 'http://%s:%s/' "$(lan_ip)" "$PORT"; }

require_docker() {
    command -v docker >/dev/null 2>&1 || {
        echo "错误：找不到 docker。装 Docker Desktop 或 OrbStack 后重试。" >&2; exit 1; }
    if ! docker info >/dev/null 2>&1; then
        echo "错误：Docker 守护进程没在跑。先把 Docker Desktop / OrbStack 启动起来。" >&2
        exit 1
    fi
}

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; }

# ── 各子命令 ──────────────────────────────────────────────────────
do_start() {
    require_docker
    local url; url=$(base_url)
    if running; then
        echo "本地中继已经在跑了：$url"
    else
        docker rm -f "$NAME" >/dev/null 2>&1 || true
        docker volume create "$VOLUME" >/dev/null
        echo "启动本地中继 ${IMAGE}（容器 ${NAME}，端口 ${PORT}）…"
        docker run -d --name "$NAME" --restart unless-stopped \
            -p "${PORT}:80" \
            -v "${VOLUME}:/var/cache/ntfy" \
            "$IMAGE" serve \
                --listen-http :80 \
                --base-url "$url" \
                --cache-file /var/cache/ntfy/cache.db \
                --cache-duration 12h \
                --visitor-request-limit-burst 5000 \
                --visitor-request-limit-replenish 1s \
            >/dev/null
        # 等健康检查通过（容器起来 + ntfy 就绪）
        local i
        for i in $(seq 1 60); do
            if curl -fsS --max-time 2 "${url}v1/health" >/dev/null 2>&1; then break; fi
            sleep 0.25
        done
        if ! curl -fsS --max-time 2 "${url}v1/health" >/dev/null 2>&1; then
            echo "启动后健康检查没通过，看日志：" >&2
            docker logs --tail 20 "$NAME" >&2 || true
            exit 1
        fi
        echo "已就绪。"
    fi

    cat <<EOF

地址        $url
健康检查    ${url}v1/health
日志        ./ntfy-local.sh logs
限速        已放宽到 burst 5000 / 每 1 秒补一个（默认值会把长轮询限死）

把两台设备指过来，改 ${ROOT}/think-of-you.lua 里这一行（两台都要改）：
    local NT    = "$url"

想更快就顺手把轮询调快（本地中继没有公共实例的限速压力）：
    local POLL_MS          = $LOCAL_POLL_MS -- 本机中继：调试用

或者一条命令搞定：
    ./ntfy-local.sh --flash
EOF
}

do_stop() {
    require_docker
    if running; then
        docker rm -f "$NAME" >/dev/null && echo "已停止并移除容器 ${NAME}（缓存卷 ${VOLUME} 保留）"
    else
        echo "容器 $NAME 没在跑。"
    fi
}

do_status() {
    require_docker
    local url; url=$(base_url)
    if running; then
        echo "运行中    $NAME  ->  $url"
        curl -fsS --max-time 3 "${url}v1/health" 2>/dev/null || echo "（健康检查没通过，试试 ./ntfy-local.sh logs）"
    else
        echo "未运行    （启动：./ntfy-local.sh）"
    fi
}

do_url() { base_url; }

do_logs() { require_docker; docker logs --tail "${TAIL:-40}" "$NAME" 2>&1 || true; }

# ── --flash：生成指向本机的副本并烧录 ──────────────────────────────
do_flash() {
    local url; url=$(base_url)
    local src="$ROOT/think-of-you.lua"
    local out="$ROOT/device-local.lua"
    local tmp="$out.tmp.$$"

    [ -f "$src" ] || { echo "错误：找不到 $src" >&2; exit 1; }

    sed -e "s|^local NT    = \"https://ntfy.sh/\"|local NT    = \"${url}\"|" \
        -e "s|^local POLL_MS          = 10000 .*|local POLL_MS          = ${LOCAL_POLL_MS} -- 本机中继：调试用，快一点|" \
        "$src" > "$tmp"

    local changed
    changed=$(diff "$src" "$tmp" | grep -c '^[<>]' || true)
    if [ "$changed" != 4 ]; then
        echo "错误：应恰好改动 NT 与 POLL_MS 两行（实际 $changed 行）；源码可能改过了。" >&2
        rm -f "$tmp"; exit 1
    fi
    mv "$tmp" "$out"
    echo "已生成 $out"
    echo "  NT      = $url"
    echo "  POLL_MS = $LOCAL_POLL_MS"

    if [ ! -x "$ROOT/flash.sh" ]; then
        echo "提示：接下来手工烧录：adb push $out /miniapp/think-of-you.lua" >&2
        return 0
    fi
    "$ROOT/flash.sh" --file "$out"
}

case "$CMD" in
    url)    do_url ;;
    logs)   do_logs ;;
    stop)   do_stop ;;
    status) do_status ;;
    start)
        if [ "$DO_FLASH" = 1 ]; then do_start >/dev/null; do_flash
        else do_start; fi ;;
esac
