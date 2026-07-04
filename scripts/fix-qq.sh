#!/usr/bin/env bash
# fix-qq.sh — QQ 适配器一键修复脚本
# 用法: bash fix-qq.sh [--dry-run]
#
# 作用：
#   1. 自动定位 Hermes 容器
#   2. 找到 docker-compose.yml 位置
#   3. 从 GitHub 下载补丁文件
#   4. 写入 docker-compose.override.yml（不碰原始文件）
#   5. 重启容器生效

set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
[[ "${1:-}" = "--dry-run" ]] && DRY_RUN=true

GITHUB_RAW="https://raw.githubusercontent.com/dteen/hermes-patches/main"
PATCH_URL="$GITHUB_RAW/qq-adapter.py"

# ============================================================
# 前提检查
# ============================================================
check_prereq() {
    local cmd="$1"
    local name="$2"
    local install_hint="$3"
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺少 $name"
        echo "   $install_hint"
        exit 1
    fi
}

check_prereq curl "curl" "请先安装 curl（apt install curl / yum install curl）"
check_prereq docker "docker" "请先安装 Docker"

if ! docker compose version &>/dev/null; then
    echo "❌ 缺少 docker compose 插件"
    echo "   请安装：apt install docker-compose-plugin 或升级 Docker"
    exit 1
fi

# ============================================================
# 接管信号，防止中途退出留下半残文件
# ============================================================
cleanup() {
    echo ""
    echo "⚠️  脚本被中断，请检查容器状态"
}
trap cleanup INT TERM

# ============================================================
# 1. 查找 Hermes 容器
# ============================================================
find_container() {
    local c
    c=$(docker ps --format '{{.Names}}' | grep -iE 'hermes|hermes-agent' | head -1)
    if [ -z "$c" ]; then
        echo "❌ 未找到运行中的 Hermes 容器"
        echo "   请确认容器已启动：docker ps | grep hermes"
        exit 1
    fi
    echo "$c"
}

CONTAINER=$(find_container)
echo "🔍 找到容器: $CONTAINER"

# ============================================================
# 2. 定位 compose 文件
# ============================================================
find_compose() {
    # 优先从 Docker label 反查
    local file
    file=$(docker inspect "$CONTAINER" \
        --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)
    if [ -n "$file" ] && [ "$file" != "<no value>" ]; then
        echo "$file"
        return
    fi

    # 回退：按常见路径猜
    for dir in /opt/hermes /opt/1panel/apps/hermes* /opt; do
        if [ -f "$dir/docker-compose.yml" ]; then
            echo "$dir/docker-compose.yml"
            return
        fi
    done

    echo ""
}

COMPOSE_FILE=$(find_compose)
if [ -z "$COMPOSE_FILE" ]; then
    echo "❌ 找不到 docker-compose.yml"
    echo "   请手动指定：bash fix-qq.sh /path/to/docker-compose.yml"
    exit 1
fi
COMPOSE_DIR=$(dirname "$COMPOSE_FILE")
echo "📁 Compose 目录: $COMPOSE_DIR"

# 提取 service 名
SERVICE=$(docker inspect "$CONTAINER" \
    --format '{{index .Config.Labels "com.docker.compose.project.service"}}' 2>/dev/null)
if [ -z "$SERVICE" ] || [ "$SERVICE" = "<no value>" ]; then
    SERVICE="gateway"
fi
echo "🔧 服务名: $SERVICE"

# ============================================================
# 3. 检测网络 + 下载补丁
# ============================================================
echo "🌐 检测 GitHub 连通性..."

# 如果设了 https_proxy 就直接用，否则测直连——不内置代理 IP，因为那是本地环境专用的
if curl -sI --connect-timeout 5 https://github.com &>/dev/null || \
   [ -n "${https_proxy:-}" ] || [ -n "${HTTPS_PROXY:-}" ]; then
    echo "   ✅ 可访问"
else
    echo "❌ GitHub 不通"
    echo "   此环境可能需要代理才能访问 GitHub。"
    echo "   请设置 https_proxy 后重试："
    echo "   export https_proxy=http://你的代理地址:端口"
    echo "   bash <(curl -sL ...)"
    exit 1
fi

echo "📥 下载补丁..."
if [ "$DRY_RUN" = true ]; then
    echo "   [--dry-run] 跳过下载"
    echo "   源: $PATCH_URL"
    echo "   目标: $COMPOSE_DIR/qq-adapter.py"
else
    curl -sL -o "$COMPOSE_DIR/qq-adapter.py" "$PATCH_URL"
    echo "   ✅ 已下载: $COMPOSE_DIR/qq-adapter.py ($(wc -c < "$COMPOSE_DIR/qq-adapter.py") bytes)"
fi

# ============================================================
# 4. 写 override 文件
# ============================================================
if [ -f "$COMPOSE_DIR/docker-compose.override.yml" ]; then
    echo "⚠️  发现已有 docker-compose.override.yml"
    echo "   将被覆盖，原文件备份为: docker-compose.override.yml.bak.$(date +%Y%m%d_%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
        cp "$COMPOSE_DIR/docker-compose.override.yml" \
           "$COMPOSE_DIR/docker-compose.override.yml.bak.$(date +%Y%m%d_%H%M%S)"
    fi
fi

OVERLAY_FILE="$COMPOSE_DIR/docker-compose.override.yml"
if [ "$DRY_RUN" = true ]; then
    echo "   [--dry-run] 不写入"
    echo "   将要写入 $OVERLAY_FILE:"
    echo "---"
    cat << EOF
services:
  $SERVICE:
    volumes:
      - $COMPOSE_DIR/qq-adapter.py:/opt/hermes/gateway/platforms/qqbot/adapter.py
EOF
    echo "---"
    echo ""
    echo "🏁 --dry-run 模式，未做任何修改"
    exit 0
fi

cat > "$OVERLAY_FILE" << EOF
services:
  $SERVICE:
    volumes:
      - $COMPOSE_DIR/qq-adapter.py:/opt/hermes/gateway/platforms/qqbot/adapter.py
EOF
echo "   ✅ override 已写入: $OVERLAY_FILE"

# ============================================================
# 5. 重启
# ============================================================
echo "🔄 重启容器..."
cd "$COMPOSE_DIR"
docker compose up -d --force-recreate
echo ""
echo "✅ 修复完成！验证方法："
echo "   1. docker compose logs --tail=20 $SERVICE | grep -i qq"
echo "   2. 确认 QQ 能收发消息"
echo ""
echo "📌 回滚方法：删除 $OVERLAY_FILE 然后重启"
