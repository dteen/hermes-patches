#!/usr/bin/env bash
# fix-qq.sh — QQ 适配器一键修复脚本
# 用法: bash fix-qq.sh [--dry-run]
#
# 作用：
#   1. 自动定位 Hermes 容器
#   2. 找到 docker-compose.yml 位置
#   3. 从 GitHub 下载补丁文件
#   4. 停容器 → 读原文件 → Python 生成新文件（带挂载行）
#   5. docker compose config 校验 YAML 格式
#   6. 校验通过才替换原文件 → 启动容器

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
    c=$(docker ps -a --format '{{.Names}}' | grep -iE 'hermes|hermes-agent' | head -1)
    if [ -z "$c" ]; then
        echo "❌ 未找到 Hermes 容器"
        echo "   请确认容器已创建：docker ps -a | grep hermes"
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

# ============================================================
# 提取服务名
# ============================================================
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
# 4. 停容器 → Python 生成新文件 → 校验 → 替换
# ============================================================
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "🏁 --dry-run 模式，未做修改"
    exit 0
fi

echo "🛑 停止容器..."
cd "$COMPOSE_DIR"
docker compose down

# 检查补丁是否已注入
if grep -qF "$PATCH_FILE" "$COMPOSE_FILE" 2>/dev/null; then
    echo "   ℹ️  挂载已存在，直接启动"
else
    NEW_FILE="${COMPOSE_FILE}.new"
    MOUNT_BARE="- $PATCH_FILE:/opt/hermes/gateway/platforms/qqbot/adapter.py"

    # Python 读原文件 → 加挂载行 → 写出新文件
    python3 -c "
import sys
svc = '$SERVICE'
mount_bare = '$MOUNT_BARE'
inpath = '$COMPOSE_FILE'
outpath = '$NEW_FILE'

with open(inpath) as f:
    lines = f.readlines()

# 找 services: 缩进
svc_block_indent = None
for line in lines:
    s = line.lstrip()
    if s.rstrip() == 'services:':
        svc_block_indent = len(line) - len(s)
        break

if svc_block_indent is None:
    print('❌ 未找到 services: 块')
    sys.exit(1)

# 检测第一个服务的缩进
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
injected = False
for i, line in enumerate(lines):
    s = line.lstrip()
    ind = len(line) - len(s)
    if s.startswith(svc + ':') and ind == service_indent:
        in_svc = True
        continue
    if in_svc and s.startswith('volumes:'):
        # 看已有 volume 条目用什么缩进
        item_indent = None
        for j in range(i + 1, len(lines)):
            ns = lines[j].lstrip()
            nind = len(lines[j]) - len(ns)
            if ns.startswith('- ') and nind > ind:
                item_indent = nind
                break
            if ns and nind <= ind and not ns.startswith('#'):
                break
        if item_indent is None:
            item_indent = ind + 2
        # 插入 mount 行
        lines.insert(i + 1, ' ' * item_indent + mount_bare + '\n')
        injected = True
        break
    if in_svc and s and ind <= service_indent and not s.startswith('#'):
        in_svc = False

if not injected:
    print('❌ 未找到该服务的 volumes: 段，注入失败')
    sys.exit(1)

with open(outpath, 'w') as f:
    f.writelines(lines)
print('✅ 新文件已写出: $NEW_FILE')
" || {
    echo ""
    echo "❌ 生成新文件失败，原文件未改动"
    exit 1
}

    # 用 docker compose 校验 YAML
    echo "🔍 校验 YAML 格式..."
    if docker compose -f "$NEW_FILE" config > /dev/null 2>&1; then
        echo "   ✅ YAML 格式正确"
    else
        echo "   ❌ YAML 格式错误！"
        docker compose -f "$NEW_FILE" config 2>&1 || true
        echo ""
        echo "新文件保留在: $NEW_FILE（供检查）"
        echo "原文件未改动"
        exit 1
    fi

    # 备份原文件 + 替换
    BAK_FILE="$COMPOSE_FILE.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$COMPOSE_FILE" "$BAK_FILE"
    echo "   ✅ 原文件已备份: $BAK_FILE"

    mv "$NEW_FILE" "$COMPOSE_FILE"
    echo "   ✅ 新文件已替换原文件"
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
