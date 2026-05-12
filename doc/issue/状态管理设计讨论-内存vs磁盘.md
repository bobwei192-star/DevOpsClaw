# 状态管理设计讨论：内存 vs 磁盘

> **日期**: 2026-05-13  
> **关联**: `openclaw-skill-ci-selfheal/scripts/orchestrator.py`  
> **现状**: 启动时读 `.self-heal-state.json` 到 `self.state` 内存字典，后续所有操作（`_save_state`、`_get_chain`、`_circuit_break`）操作内存，`_save_state` 时同步写回磁盘。

---

## 一、现状分析

```python
class Orchestrator:
    def __init__(self):
        self.state = self._load_state()          # 启动时读一次

    def _load_state(self):
        return json.load(open(STATE_FILE))

    def _save_state(self):
        json.dump(self.state, open(STATE_FILE))  # 每次变更写回磁盘

    def _get_chain(self, job_name):
        return self.state["chains"][job_name]     # 读内存，不读磁盘
```

**关键行为**：
- 变更立即写磁盘（`_save_state` 在 `_record_history`、`_circuit_break` 中被调用）
- 但**读取始终从内存**（启动后不再读文件）
- 外部修改磁盘文件**不影响运行中的进程**

---

## 二、为什么是"先读内存再写磁盘"？

### 2.1 设计方案 A：纯内存（不写盘）

```python
def _save_state(self):
    pass  # 不写盘，进程重启后状态丢失
```

| 优点 | 缺点 |
|------|------|
| 绝对无 IO 竞争 | **进程重启后熔断状态全部丢失** |
| 最快 | 无法跨进程共享状态 |
| 状态不会残留 | 轮询中间状态也无法持久化（重试计数会丢） |

### 2.2 设计方案 B：每次操作读磁盘 + 写磁盘

```python
def _get_chain(self, job_name):
    state = json.load(open(STATE_FILE))  # 每次读磁盘
    return state["chains"][job_name]
```

| 优点 | 缺点 |
|------|------|
| 外部改文件立即生效 | **高并发下多请求同时读写，竞态会导致数据丢失** |
| 重启后自动恢复 | 磁盘 IO 频繁，延迟不可控 |

### 2.3 当前方案 C：启动读内存 + 变更写磁盘（现状）

| 优点 | 缺点 |
|------|------|
| 无 IO 竞态（单进程单线程写） | **外部改文件不生效（需重启或 /admin/reset）** |
| 进程重启可通过磁盘恢复 | 单点——只有一个 webhook_listener 实例写 |
| 变更实时持久化 | 内存占用随自愈历史线性增长 |

---

## 三、当前方案 C 的问题

### 问题 1：外部修改磁盘文件无效

用户手动 `echo '{"version":"2.0.0",...}' > .self-heal-state.json` 后，运行中的进程状态不变——因为 `__init__` 之后再也没读过文件。

**已缓解**：添加了 `/admin/reset` 端点直接操作 `self.state`。

### 问题 2：单例设计不支持多实例

如果有多个 `webhook_listener` 实例（负载均衡 / HA），每个实例持有独立的内存副本，熔断状态不同步。

**影响**：当前是单进程部署，暂无此问题。但未来如有高可用需求，需改用 Redis 等外置存储。

---

## 四、推荐方案 D：内存主 + 磁盘写 + 定时刷新

综合方案 B 和 C 的优点，消除"外部改文件无效"的痛点：

```python
class Orchestrator:
    def __init__(self):
        self.state = self._load_state()
        self._last_file_mtime = os.path.getmtime(STATE_FILE)

    def _maybe_reload(self):
        """如果文件被外部更新过（/admin/reset 写盘），自动重新加载"""
        mtime = os.path.getmtime(STATE_FILE)
        if mtime > self._last_file_mtime:
            self.state = self._load_state()
            self._last_file_mtime = mtime
            return True
        return False

    def _get_chain(self, job_name):
        self._maybe_reload()  # 每次操作前检查文件是否被外部更新
        return self.state["chains"][job_name]
```

| 维度 | 方案 C（现状） | 方案 D（推荐） |
|------|-------------|-------------|
| 外部改文件是否生效 | ❌ 不生效 | ✅ 自动检测文件变更 |
| IO 频率 | 仅写盘 | 写盘 + 每次读前一次 `stat`（极小开销） |
| 实现复杂度 | 低 | +5 行代码 |
| 并发安全 | 单进程安全 | 单进程安全（stat 是原子操作） |

---

## 五、建议

| 阶段 | 采取方案 | 理由 |
|------|---------|------|
| **当前（Phase 0）** | 方案 C + `/admin/reset` 端点 | 单进程部署够用，已解决操作瓶颈 |
| **生产化（Phase 1）** | 方案 D（mtime 自动重载） | 让用户改 JSON 文件也能生效，降低运维心智负担 |
| **多实例（Phase 2）** | Redis 外置存储 + pub/sub 广播 | 跨实例状态同步 |

---

## 六、总结

> 现状不是 bug，是一次权衡——用"启动时一次性加载"换来了无 IO 竞态的安全性和性能。代价是内存和磁盘可能不同步。已通过 `/admin/reset` 端点兜底，后续可升级为方案 D 让文件变更自动生效。
