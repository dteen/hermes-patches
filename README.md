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

将 `qq-adapter.py` 挂载到容器内覆盖原文件：

```yaml
volumes:
  - ./qq-adapter.py:/opt/hermes/gateway/platforms/qqbot/adapter.py
```

然后重启容器。
