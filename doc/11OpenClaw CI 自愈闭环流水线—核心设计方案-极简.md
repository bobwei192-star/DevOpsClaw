/home/zx/CICD/DevOpsClaw/doc/11OpenClaw CI 自愈闭环流水线—核心设计方案_极简.md最优融合方案（推荐）
text
Jenkins Job 构建失败
      │
      ▼
┌──────────────────────────────────┐
│ 1. Jenkins Webhook 通知 OpenClaw │  ← 唯一入口，仅失败时触发
└────────────────┬─────────────────┘
                 │
                 ▼
┌──────────────────────────────────┐
│ 2. OpenClaw 自愈执行：            │
│   · 拉取 Jenkins 日志（脱敏）      │
│   · 拉取 GitLab 代码（只读）       │
│   · AI 诊断 + 生成修复代码        │
│   · 创建 fix 分支并提交            │
└────────────────┬─────────────────┘
                 │
                 ▼
┌──────────────────────────────────┐
│ 3. OpenClaw 触发 Jenkins 重建     │  ← OpenClaw 主动调用 API
│    （在 fix 分支上构建）           │
│    最多重试 5 轮                  │
│    · 每轮失败 → 拿新日志再诊断     │
│    · 每轮成功 → 立即创建 MR       │
└────────────────┬─────────────────┘
                 │
        ┌────────┴────────┐
        │                 │
        ▼                 ▼
┌─────────────┐   ┌─────────────────┐
│ 构建 SUCCESS │   │  5 轮全部失败     │
│ · OpenClaw   │   │  · 熔断，停止自愈  │
│   主动轮询   │   │  · 生成诊断报告    │
│   直到成功   │   │  · 通知人工介入    │
└──────┬──────┘   └─────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 4. 自动创建 Merge Request    │  ← 唯一成功出口
│   · 源分支：fix/ci-selfheal  │
│   · 目标分支：原失败分支      │
│   · 标签：auto-fix           │
│   · 指派 Reviewer 审核       │
└──────────────────────────────┘
关键机制说明
Jenkins 只通知一次：仅在初始构建失败时发送 Webhook。

修复后的成功，由 OpenClaw 自己发现：通过 Jenkins REST API 定期轮询修复构建（例如每 5 秒查一次），一旦状态变为 SUCCESS，立即创建 MR，不需要 Jenkins 二次通知。

这样可以避免：

Jenkins 成功通知被误判为新失败；

复杂的回调逻辑，所有状态管理集中在 OpenClaw 一端。

一句话总结
Jenkins 失败 → OpenClaw 接管 → 自修后自己触发构建 → 自己轮询结果 → 成功立即提 MR。Jenkins 全程只当工具，不参与决策。

---

## 并发保护：BUILD_TYPE 参数（无锁设计）

### 问题

OpenClaw 触发验证构建后，若验证构建也失败，Jenkins `post { failure }` 会二次发送 webhook，导致同一 Job 上出现两个并行的修复进程：

```
Build #34 失败 → Webhook → 修复进程-A 启动 → 触发 Build #35 → 轮询 #35
                                                        ↓
Build #35 失败 → Jenkins post-failure 发 Webhook → 修复进程-B 启动
                                                        ↓
                              修复进程-A 还在轮询 #35！两进程并行操作同一个 Job！
```

### 解决方案：让 Jenkins 区分构建类型（零依赖、零状态）

思路：不是处理竞态，而是消灭竞态——不该有第二次通知。

**Jenkinsfile：**

```groovy
pipeline {
    parameters {
        choice(name: 'BUILD_TYPE', choices: ['normal', 'selfheal'])
    }
    post {
        failure {
            script {
                if (params.BUILD_TYPE == 'normal') {
                    // 只有初始构建失败才发 Webhook
                    sh "curl -X POST .../webhook/ci-failure ..."
                }
                // BUILD_TYPE=selfheal 时 Jenkins 沉默，OpenClaw 自己轮询
            }
        }
    }
}
```

**orchestrator.py：**

```python
def _trigger_build(self, job_name, branch):
    cmd = ["node", "jenkins.mjs", "build", "--job", job_name,
           "--param", "BUILD_TYPE=selfheal"]  # ← 自愈构建带此参数
```

### 为什么这比锁方案更好

| 对比维度 | 文件锁 / 运行锁 | BUILD_TYPE 参数 |
|---|---|---|
| 处理方式 | 被动防守（拦截重复 webhook） | 主动消灭（不发重复 webhook） |
| 状态管理 | 需要 running_since、managed_builds、死锁检测 | 零状态 |
| 代码量 | +46 行锁管理 | 2 行 Jenkins + 1 行 Python |
| Skill 无状态 | 依赖 .self-heal-state.json | 完全无状态 |
| Hub 发布 | 用户需理解锁机制 | 一行参数说明即上手 |
| 健壮性 | 并发读可能绕过锁 | 不会有重复 webhook |
