# Hermes Patches

Hermes Agent 的补丁合集。

## QQ 适配器补丁 (`qq-adapter.py`)

### 问题

Hermes QQ Bot 适配器在 v0.18.0 升级后存在两个 Bug：

1. **连接崩溃** — `connect()` 方法缺少 `is_reconnect` 参数，断线重连时抛异常
2. **审批路由失效** — `chat_type` 只认 `"c2c"`，不认 `"dm"`，导致 QQ 私聊审批按钮点击无响应

### 修复内容（5 处）

| 行号 | 修改 | 作用 |
|------|------|------|
| 281 | `connect(self)` → `connect(self, *, is_reconnect: bool=False)` | 修复断线重连崩溃 |
| 1095 | `chat_type == "c2c"` → `chat_type in {"c2c","dm"}` | 审批按钮授权 |
| 2475 | 同上 | DM 消息发送路由 |
| 2602 | 同上 | 带键盘 DM 发送 |
| 2924 | 同上 | API 端点选择 |

### 使用方法

#### 方法一：手动挂载

将 `qq-adapter.py` 挂载到容器内覆盖原文件：

```yaml
volumes:
  - ./qq-adapter.py:/opt/hermes/gateway/platforms/qqbot/adapter.py
```

然后重启容器。

#### 方法二：一键修复脚本

```bash
# 预览（不做任何修改）
bash <(curl -sL https://raw.githubusercontent.com/dteen/hermes-patches/main/scripts/fix-qq.sh) --dry-run

# 执行修复
bash <(curl -sL https://raw.githubusercontent.com/dteen/hermes-patches/main/scripts/fix-qq.sh)
```

脚本会自动完成：
1. 查找 Hermes 容器
2. 定位 docker-compose.yml
3. 下载补丁文件
4. 写入 docker-compose.override.yml（不碰原始文件）
5. 重启容器

### 脚本说明

- **原理：** 利用 Docker Compose 的 `docker-compose.override.yml` 自动合并机制，无需修改原始 compose 文件
- **兼容：** 标准安装 / 1Panel 安装均可自动定位
- **回滚：** 删除 `docker-compose.override.yml` 后重启即可
- **前提：** 需要 `curl`、`docker`、`docker compose` 插件
