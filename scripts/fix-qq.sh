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

PATCH_DIR="${HOME}/.hermes-patches"
PATCH_FILE="$PATCH_DIR/qq-adapter.py"

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

# 提取 service 名——优先从 compose 文件读，Docker label 做备选
SERVICE=""
# 方法1：Docker label
SERVICE=$(docker inspect "$CONTAINER" \
    --format '{{index .Config.Labels "com.docker.compose.project.service"}}' 2>/dev/null)
if [ -z "$SERVICE" ] || [ "$SERVICE" = "<no value>" ]; then
    SERVICE=""
fi
# 方法2：从 compose 文件直接解析
if [ -z "$SERVICE" ] && [ -f "$COMPOSE_FILE" ]; then
    SERVICE=$(cd "$COMPOSE_DIR" && docker compose config --services 2>/dev/null | head -1)
fi
# 方法3：还能找不到？报错退出
if [ -z "$SERVICE" ]; then
    echo "❌ 无法确定服务名"
    echo "   请手动指定：SERVICE=xxx bash fix-qq.sh"
    exit 1
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
mkdir -p "$PATCH_DIR"
if [ "$DRY_RUN" = true ]; then
    echo "   [--dry-run] 跳过下载"
    echo "   源: $PATCH_URL"
    echo "   目标: $PATCH_FILE"
else
    curl -sL -o "$PATCH_FILE" "$PATCH_URL"
    echo "   ✅ 已下载: $PATCH_FILE ($(wc -c < "$PATCH_FILE") bytes)"
fi

# ============================================================
# 4. 先停容器（解锁文件），再注入，再启动
# ============================================================
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "🏁 --dry-run 模式，未做修改"
    exit 0
fi

echo "🛑 停止容器（解锁 compose 文件）..."
cd "$COMPOSE_DIR"
docker compose down

MOUNT_BARE="- $PATCH_FILE:/opt/hermes/gateway/platforms/qqbot/adapter.py"

# 检查是否已注入
if grep -qF "$PATCH_FILE" "$COMPOSE_FILE" 2>/dev/null; then
    echo "   ℹ️  挂载已存在"
else
    # 备份
    BAK_FILE="$COMPOSE_FILE.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$COMPOSE_FILE" "$BAK_FILE"
    echo "   ✅ 已备份: $BAK_FILE"

    # 注入挂载行（容器已停，文件不会被锁定）
    python3 -c "
import sys
svc = '$SERVICE'
mount_bare = '$MOUNT_BARE'
filepath = '$COMPOSE_FILE'

with open(filepath) as f:
    lines = f.readlines()

# 先找 services: 的缩进级别
svc_block_indent = None
for line in lines:
    s = line.lstrip()
    if s.rstrip() == 'services:':
        svc_block_indent = len(line) - len(s)
        break

if svc_block_indent is None:
    print('❌ 未找到 services: 块')
    sys.exit(1)

# 自动检测 services 下第一个服务的实际缩进
service_indent = None
for line in lines:
    s = line.lstrip()
    ind = len(line) - len(s)
    if ind > svc_block_indent and s and not s.startswith('#'):
        service_indent = ind
        break

if service_indent is None:
    print('❌ 未找到 services 下的服务定义')
    sys.exit(1)

in_svc = False
for i, line in enumerate(lines):
    s = line.lstrip()
    ind = len(line) - len(s)
    if s.startswith(svc + ':') and ind == service_indent:
        in_svc = True
        continue
    if in_svc and s.startswith('volumes:'):
        # 看已有 volume 条目用什么缩进，保持一致
        item_indent = None
        for j in range(i + 1, len(lines)):
            ns = lines[j].lstrip()
            nind = len(lines[j]) - len(ns)
            if ns.startswith('- ') and nind > ind:
                item_indent = nind
                break
            # 遇到同缩进或更少的行的就不继续了
            if ns and nind <= ind and not ns.startswith('#'):
                break
        if item_indent is None:
            # volumes: 是空的，用标准 +2
            item_indent = ind + 2
        lines.insert(i + 1, ' ' * item_indent + mount_bare + '\n')
        with open(filepath, 'w') as f:
            f.writelines(lines)
        print('✅ 挂载已注入')
        sys.exit(0)
    # 离开服务块
    if in_svc and s and ind <= service_indent and not s.startswith('#'):
        in_svc = False

print('❌ 未找到该服务的 volumes: 段，注入失败')
sys.exit(1)
"
fi

echo ""
echo "🚀 启动容器..."
docker compose up -d
echo ""
echo "✅ 修复完成！验证方法："
echo "   1. docker compose logs --tail=20 $SERVICE | grep -i qq"
echo "   2. 确认 QQ 能收发消息"
echo ""
echo "📌 回滚方法：用备份文件恢复"
echo "   cp $COMPOSE_FILE.bak.* $COMPOSE_FILE && docker compose up -d"
