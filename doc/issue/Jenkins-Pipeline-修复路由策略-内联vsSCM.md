# Jenkins Pipeline 修复路由策略：SCM 模式 vs 内联脚本模式

> **日期**: 2026-05-13  
> **关联**: `openclaw-skill-ci-selfheal/scripts/orchestrator.py`  
> **背景**: `example_fauliure_job` 使用"Pipeline script"（内联模式），修复 GitLab 仓库的 Jenkinsfile 无效，需直接更新 Jenkins config.xml。

---

## 一、Jenkins Pipeline 的两种定义方式

Jenkins Pipeline Job 的脚本来源有两种，在 `config.xml` 中的表现完全不同：

| 模式 | Jenkins UI | config.xml 特征 | 修复方式 |
|------|-----------|----------------|---------|
| **内联脚本** | "Pipeline script" | `<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition">` + `<script>` | `POST /job/<name>/config.xml` 替换 `<script>` |
| **SCM 拉取** | "Pipeline script from SCM" | `<scm class="hudson.plugins.git.GitSCM">` + `scriptPath` | `git push` 到 GitLab，触发重建 |

### 1.1 当前 `example_fauliure_job` 的情况

```
Jenkins UI: "定义" → Pipeline script
config.xml: <definition class="...CpsFlowDefinition">
              <script>pipeline { agent any ...</script>
            </definition>
```

Pipeline 脚本**存储在 Jenkins 内部 XML 中**，与 GitLab 仓库完全解耦。修改 GitLab 仓库中的 Jenkinsfile 对此 Job 无任何影响。

### 1.2 如果是 SCM 模式的样子

```
Jenkins UI: "定义" → Pipeline script from SCM
config.xml: <scm class="hudson.plugins.git.GitSCM">
              <userRemoteConfigs>
                <hudson.plugins.git.UserRemoteConfig>
                  <url>https://172.19.0.5:8441/root/model_test.git</url>
                </hudson.plugins.git.UserRemoteConfig>
              </userRemoteConfigs>
              <branches>
                <hudson.plugins.git.BranchSpec>
                  <name>dev/test</name>
                </hudson.plugins.git.BranchSpec>
              </branches>
            </scm>
            <scriptPath>Jenkinsfile</scriptPath>
```

---

## 二、修复路由策略

### 2.1 决策流程

```
Jenkins 构建失败
      │
      ▼
S1: 拉取 Jenkins 日志 ──▶ 脱敏后给 AI 诊断
      │
      ▼
S2: AI 诊断 ──▶ { root_cause, error_type, confidence, fix_diff }
      │
      ▼
S3: 检测 Job 类型 ──▶ GET /job/<name>/config.xml
      │
      ├── 按 <definition class="...CpsFlowDefinition"> 匹配到?
      │     │
      │     ├── 是: 内联脚本模式
      │     │   → 替换 config.xml 中的 <script> 块
      │     │   → POST /job/<name>/config.xml
      │     │   → 触发重建
      │     │
      │     └── 否: SCM 模式（有 <scm> 块）
      │         │
      │         ├── 有 GitLab 凭证?
      │         │   │
      │         │   ├── 是: 创建 fix 分支 → commit → push
      │         │   │   │
      │         │   │   └── 有写权限?
      │         │   │       ├── 是: push → 触发重建 → 成功创建 MR
      │         │   │       └── 否: 生成 Patch 文件，通知人工
      │         │   │
      │         │   └── 否: 生成诊断报告 + Patch 文件，通知人工
      │         │
      │         └── 错误类型是 config/env?
      │             └── 直接生成修复建议，通知运维（人工变更）
      │
      └── 低置信度 (< 0.6)?
            └── 生成诊断报告，不自动修复
```

### 2.2 实现方案

在 `orchestrator.py` 的 `_run_loop` 中增加 Job 类型检测：

```python
def _detect_job_type(self, job_name):
    """检测 Jenkins Job 的 Pipeline 脚本来源"""
    config_xml = self._jenkins_get(
        f"{self.config['jenkins']['url']}/job/{job_name}/config.xml"
    )
    if not config_xml:
        return "unknown"

    if "CpsFlowDefinition" in config_xml and "<script>" in config_xml:
        return "inline"    # 内联脚本模式 → 更新 config.xml
    if "<scm" in config_xml and "<scriptPath>" in config_xml:
        return "scm"       # SCM 模式 → git push 到仓库
    return "unknown"
```

然后在修复阶段分叉：

```python
job_type = self._detect_job_type(ctx["job"])

if job_type == "inline":
    # 直接更新 Jenkins config.xml
    applied = self._apply_fix_inline(ctx["job"], fix_diff)
elif job_type == "scm":
    # 从 config.xml 提取 GitLab repo URL 和 scriptPath
    repo_url = extract_repo_from_config(config_xml)
    branch = extract_branch_from_config(config_xml)
    # 通过 gitlab-skill 或 GitLab API 提交修复
    applied = self._apply_fix_scm(repo_url, branch, fix_diff)
```

### 2.3 内联模式无需 GitLab 凭证

这是关键优势：内联脚本模式完全不依赖 GitLab。只需要 Jenkins API Token（已有），没有任何前提条件。修复流程极其简洁：

```
AI 诊断出修复代码
    │  fix_diff: {"Jenkinsfile": "pipeline {...}"}
    ▼
GET /job/example_fauliure_job/config.xml  ← 只需 Jenkins API Token
    │  <script>旧的 Pipeline 代码</script>
    ▼
替换 <script> 块
    │
    ▼
POST /job/example_fauliure_job/config.xml  ← 更新配置
    │  HTTP 200
    ▼
POST /job/example_fauliure_job/build       ← 触发重建
    │  新构建 #N
    ▼
轮询 #N 状态 → SUCCESS ✅
```

---

## 三、边界情况处理

| 场景 | 检测方式 | 处理策略 |
|------|---------|---------|
| **内联脚本 + shell 语法错误**（当前 case） | `CpsFlowDefinition` + `<script>` | 替换 config.xml → 重建 |
| **内联脚本 + 依赖缺失**（如命令未安装） | 同上 | AI 诊断 → 生成建议报告 → 人工（不可自动） |
| **SCM 模式 + Jenkinsfile 语法错误** | `<scm>` + `<scriptPath>` | git push fix → 重建 → MR |
| **SCM 模式 + 业务代码错误**（diff 指向 src/main/） | 同上，但 G1 故障预判拦截 | 仅生成诊断报告，不修 |
| **SCM 模式 + 无 GitLab 凭证** | `GITLAB_TOKEN` 未设 | 生成 Patch 文件，通知人工 |
| **Multibranch Pipeline** | `<scm>` + `<sources class="jenkins.branch.MultiBranchProject$BranchSource">` | 更复杂，建议不自动修 |

---

## 四、当前状态与下一步

### 已实现 ✅

- `_apply_fix()` 通过 Jenkins REST API 替换内联 Pipeline 的 `<script>` 块
- `_jenkins_get()` / `_jenkins_post()` 封装了 Jenkins API curl 调用
- AI 诊断返回 `confidence: 0.95`，根因精确，修复代码完整

### 待实现 🔜

- `_detect_job_type()` 方法（CpsFlowDefinition vs SCM 检测）
- SCM 模式的 gitlab-skill / GitLab API 修复路径
- 修复后重启服务的逻辑（Pipeline 修改后需重新加载）

---

## 五、总结

> **不要假设 Pipeline 脚本一定在 GitLab 仓库里。** Jenkins Pipeline Job 支持两种模式，必须根据 `config.xml` 的内容来决定修复策略。内联模式直接用 Jenkins API 替换 `<script>` 块，SCM 模式才需要走 GitLab push 流程。
