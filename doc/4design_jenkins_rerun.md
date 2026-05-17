

---

## 附录：实施过程记录

### A.1 遇到的问题与解决方案

#### 问题 1：Jenkins 脚本审批错误
**现象**：
```
org.jenkinsci.plugins.scriptsecurity.scripts.UnapprovedUsageException: script not yet approved for use
```

**原因**：Jenkins Pipeline 使用了需要审批的 Groovy 脚本方法。

**解决方案**：
1. 使用纯声明式 Pipeline（Declarative Pipeline），避免使用 `script` 块
2. 或者在 Jenkins 管理界面手动批准脚本：`Manage Jenkins` → `In-process Script Approval`
3. 对于测试阶段，可以临时禁用脚本安全（不推荐生产环境使用）

**示例 - 安全的声明式 Pipeline**：
```groovy
pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                sh 'echo "Hello World"'  // 纯声明式，无 script 块
            }
        }
    }
}
```

---

#### 问题 2：Agent HTTP API 404 错误
**现象**：
```bash
curl -X POST http://127.0.0.1:18789/api/v1/pipeline/result
# 返回：404 Not Found
```

**原因**：Agent Gateway 没有实现标准的 OpenAI API 端点 `/v1/chat/completions`，也没有自定义的 `/api/v1/pipeline/result` 端点。

**解决方案**：
放弃 HTTP API 调用方式，改用 **Agent CLI** 直接调用：

```bash
# 正确的 CLI 调用方式
docker exec agent node agent.mjs infer model run \
  --model "custom-api-moonshot-cn/kimi-k2.5" \
  --prompt "你的提示词"
```

**CLI 命令结构**：
- `infer model run` - 运行文本推理
- `--model` - 指定模型（完整格式：`custom-api-moonshot-cn/kimi-k2.5`）
- `--prompt` - 输入提示词

---

#### 问题 3：Docker 容器间网络隔离
**现象**：
- Jenkins 容器无法访问 Agent 的 18789 端口
- `curl http://127.0.0.1:18789/health` 在宿主机成功，在 Jenkins 容器内失败

**原因**：
- Agent 使用 `host` 网络模式（直接使用宿主机网络栈）
- Jenkins 使用 `bridge` 网络模式（独立的容器网络）
- 容器间无法通过 `localhost` 或 `127.0.0.1` 互通

**解决方案**：
1. **使用宿主机 IP 地址**（推荐）：
   ```bash
   # 获取宿主机 IP
   HOST_IP="192.168.43.17"  # 根据实际情况修改
   
   # Jenkins Pipeline 中使用
   BRIDGE_URL="http://${HOST_IP}:5000"
   ```

2. **配置说明**：
   | 服务 | 容器内访问地址 | 说明 |
   |------|---------------|------|
   | Agent Gateway | `http://192.168.43.17:18789` | 宿主机 IP + 端口 |
   | Bridge 服务 | `http://192.168.43.17:5000` | 宿主机 IP + 端口 |

---

#### 问题 4：Agent CLI 调用超时
**现象**：
```
Command '['docker', 'exec', 'agent', ...]' timed out after 120 seconds
```

**原因**：AI 模型推理需要时间，特别是 DeepSeek Reasoner 推理时间较长。

**解决方案**：
增大超时时间到 5 分钟（300 秒）：

```python
# bridge_v2.py
result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    timeout=300  # 从 120 秒增加到 300 秒
)
```

同时，Webhook 调用方也需要增大超时：
```bash
# Jenkins Pipeline 中的 curl 命令
curl --max-time 360 ...  # 6 分钟超时
```

---

#### 问题 5：环境变量未正确加载
**现象**：
Bridge 启动时显示 `DRY_RUN: true`，但 `.env` 文件中设置为 `false`。

**原因**：启动脚本 `start_bridge_v2.sh` 中硬编码了环境变量，覆盖了 `.env` 文件的配置。

**解决方案**：
修改启动脚本，从 `.env` 文件加载配置：

```bash
#!/bin/bash
# 加载环境变量（从 .env 文件读取）
if [ -f .env ]; then
    set -a
    source .env
    set +a
    echo "已从 .env 加载配置"
fi

echo "DRY_RUN: $DRY_RUN"
python3 bridge_v2.py
```

---

#### 问题 6：Kimi K2.5 模型调用失败
**现象**：
```
Error: No text output returned for provider "custom-api-moonshot-cn" model "kimi-k2.5"
```

**原因**：Kimi API 可能偶发失败或返回格式不符合预期。

**解决方案**：
实现**多模型 fallback 机制**：

```python
# 尝试多个模型
models_to_try = [
    "kimi-k2.5",
    "deepseek-reasoner",  # fallback
]

for model in models_to_try:
    try:
        result = ai_fix_with_cli(prompt, model)
        return result
    except Exception as e:
        log_warning(f"模型 {model} 失败", error=str(e))
        continue
```

实际运行中，DeepSeek Reasoner 表现稳定，成为主要使用的模型。

---

### A.2 成功运行流程

#### 完整流程验证（2026-05-02）

**测试场景**：故意使用错误命令 `date--` 触发构建失败

**流程步骤**：

| 步骤 | Job 名称 | 构建号 | 状态 | 关键日志 |
|------|---------|--------|------|---------|
| 1 | `example-failure-pipeline` | #21 | ❌ FAILURE | `date--: not found` |
| 2 | Webhook 发送到 Bridge | - | ✅ 200 | `action: fix_triggered` |
| 3 | Bridge 调用 DeepSeek | - | ✅ 成功 | 生成修复代码 |
| 4 | Bridge 创建修复 Job | - | ✅ 成功 | `example-failure-pipeline-agent-fix-1` |
| 5 | 修复 Job 自动构建 | #1 | ✅ SUCCESS | `+ date` |

**修复对比**：

```diff
# 修复前（错误）
- sh 'date--'
+ sh 'date'
# 修复后（正确）
```

**关键成功日志**：
```
[Pipeline] sh
+ date
Sat May  2 09:45:33 UTC 2026
[Pipeline] echo
如果执行到这里，说明前面的错误已被修复
```

---

### A.3 当前遗留问题

#### 问题 1：修复 Job 的 `isOpenclaw` 标记未正确设置
**现象**：修复后的 Job 发送的 Webhook 中 `isOpenclaw: false`，理论上应该是 `true`。

**影响**：可能导致 Bridge 对修复 Job 的构建结果进行重复处理。

**临时解决方案**：在 Bridge 中通过 Job 名称后缀 `-agent-fix-*` 识别修复 Job。

**长期解决方案**：修改 `create_jenkins_job` 函数，在创建 Job 时正确设置 `AGENT_MARKER` 环境变量。

---

#### 问题 2：Bridge 服务需要手动维护运行
**现象**：Bridge 服务在前台运行，如果终端关闭或服务器重启，服务会停止。

**临时解决方案**：使用 `nohup` 或 `screen` 保持服务运行。

**长期解决方案**：
1. 配置 Systemd 服务自动启动
2. 或使用 Docker Compose 统一管理所有服务

**Systemd 配置示例**（待实施）：
```ini
# /etc/systemd/system/agent-bridge.service
[Unit]
Description=Agent Jenkins Bridge
After=network.target

[Service]
Type=simple
User=worker
WorkingDirectory=/home/worker/software/AI/CICD/agent
EnvironmentFile=/home/worker/software/AI/CICD/agent/.env
ExecStart=/usr/bin/python3 bridge_v2.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

---

#### 问题 3：AI 模型输出格式不稳定
**现象**：偶尔 AI 返回的代码格式不符合预期，可能导致解析失败。

**当前处理**：使用正则表达式提取代码块：
```python
pattern = r'```groovy\s*\n(.*?)\n```'
match = re.search(pattern, ai_output, re.DOTALL)
```

**改进方向**：
1. 增加更多的输出格式兼容处理
2. 添加 AI 输出质量检查，不符合格式时重新请求
3. 考虑使用结构化输出（如 JSON）

---

#### 问题 4：日志和状态管理较简单
**现象**：当前使用本地 JSON 文件存储状态，日志写入本地文件。

**限制**：
- 不支持多实例部署
- 日志查询不方便
- 无法查看历史统计

**改进方向**：
1. 使用 Redis 或数据库持久化状态
2. 接入 ELK 或 Loki 日志系统
3. 添加 Web UI 查看修复历史和统计

---

#### 问题 5：安全性待加强
**当前状态**：
- Jenkins Token 明文存储在 `.env` 文件
- Bridge 服务没有认证机制
- 日志中可能包含敏感信息

**改进方向**：
1. 使用 Jenkins Credential 管理 Token
2. 为 Bridge API 添加 Token 认证
3. 敏感信息脱敏处理

---

### A.4 经验总结

#### 关键成功因素

1. **Bridge 架构设计正确**：作为独立服务解耦 Jenkins 和 Agent，避免直接依赖
2. **多模型 fallback**：Kimi 失败时自动切换到 DeepSeek，保证服务可用性
3. **DRY_RUN 模式**：先验证再自动化，降低风险
4. **详细的日志记录**：便于问题排查和流程验证

#### 技术选型验证

| 技术方案 | 验证结果 | 说明 |
|---------|---------|------|
| Agent CLI | ✅ 可行 | 比 HTTP API 更稳定可靠 |
| DeepSeek Reasoner | ✅ 推荐 | 推理质量高，响应稳定 |
| Kimi K2.5 | ⚠️ 备用 | 偶有失败，作为 fallback |
| Bridge 独立服务 | ✅ 正确 | 解耦双方，灵活可控 |
| Docker 容器化 | ✅ 可行 | 注意网络模式差异 |

#### 下一步优化建议

1. **高可用**：配置 Systemd 服务，确保 Bridge 持续运行
2. **监控告警**：添加 Prometheus 指标，监控修复成功率和延迟
3. **Web UI**：开发简单的管理界面，查看修复历史和配置
4. **更多场景**：支持 Maven/Gradle 构建失败、单元测试失败等更多场景
5. **安全加固**：Token 加密存储，API 认证，日志脱敏

---

**文档更新日期**：2026-05-02  
**版本**：v1.1.0（增加实施记录）




agent skills install jenkins
agent skills info jenkins


export JENKINS_URL="http://localhost:8081"
export JENKINS_USER="your_jenkins_user"
export JENKINS_API_TOKEN="your_jenkins_api_token_here"