 # gitlab-skill 凭据配置与 MR 能力实测

## 背景

在 `devopsclaw-openclaw` 容器内，对当前安装的 `gitlab-skill` 做了实际验证，目标是确认三件事：

1. GitLab 凭据到底应该写到哪里，skill 才能真正读到
2. `gitlab-skill` 是否能正常创建分支
3. `gitlab-skill` 是否能稳定创建 Merge Request

---

## 结论摘要

### 结论 1：当前环境下，`gitlab-skill` 生效配置不是 `openclaw.json`，而是 `~/.claude/gitlab_config.json`

在 OpenClaw 容器内，下面这种配置能够真正使能 `gitlab-skill`：

```bash
mkdir -p ~/.claude
cat > ~/.claude/gitlab_config.json << 'EOF'
{
  "host": "http://10.67.167.53:8088",
  "access_token": "glpat-your-token"
}
EOF
chmod 600 ~/.claude/gitlab_config.json
```

实测中，单纯检查：

```bash
cat /home/node/.openclaw/openclaw.json | grep mcpServers
cat /home/node/.openclaw/openclaw.json | grep GITLAB_URL
```

没有输出，**并不代表当前安装的 `gitlab-skill` 一定没配置成功**。  
对这套 skill 版本来说，真正生效的是 `~/.claude/gitlab_config.json`。

---

### 结论 2：`gitlab-skill` 可以创建分支

先验证项目搜索：

```bash
python3 /home/node/.openclaw/workspace/skills/gitlab-skill/scripts/gitlab_api.py projects --search test
```

实测可以列出项目，其中包含：

- `ci/test`

再通过 GitLab API 精确拿到项目 ID（比直接从 skill 输出里 `grep` 更稳）：

```bash
curl -s --header "PRIVATE-TOKEN: glpat-your-token" \
  "http://10.67.167.53:8088/api/v4/projects?search=test" \
  | python3 -m json.tool \
  | grep -B 5 '"path_with_namespace": "ci/test"' \
  | grep '"id"'
```

当前环境实测得到：

- `ci/test` 的项目 ID 为 `27`

再执行创建分支：

```bash
python3 /home/node/.openclaw/workspace/skills/gitlab-skill/scripts/gitlab_api.py create-branch \
  --project "ci/test" \
  --branch "test-branch-cli" \
  --branch-ref "main"
```

实测结果：

- 分支创建成功
- 返回分支 URL
- GitLab Web UI 中可以看到新分支

也就是说，**当前版本的 `gitlab-skill` 至少已经验证了“读项目 / 创建分支”能力可用**。

---

### 结论 3：当前环境下，`gitlab-skill` 创建 MR 不稳定，直接走 GitLab REST API 可以成功

当前版本 `gitlab-skill` 在本环境下**无法稳定完成创建 MR**。  
但直接使用 GitLab REST API 创建 MR，已经实测成功。

实测可用命令如下：

```bash
curl -X POST "http://10.67.167.53:8088/api/v4/projects/27/merge_requests" \
  --header "PRIVATE-TOKEN: glpat-your-token" \
  --data-urlencode "source_branch=test-branch-cli" \
  --data-urlencode "target_branch=main" \
  --data-urlencode "title=测试MR通过API" \
  --data-urlencode "description=这是一个测试合并请求"
```

实测结果：

- 成功返回 MR JSON
- `reference` 正常生成（如 `!5`）
- `web_url` 可访问

这说明：

- GitLab 权限本身没问题
- 仓库、分支、目标分支都没问题
- 问题集中在 **当前 `gitlab-skill` 的 MR 能力**，不是 GitLab API 或 Token 权限问题

---

## 为什么 `gitlab_api.py projects --format json | grep id` 不可靠

实测中，下面这种写法不能稳定拿到项目 ID：

```bash
python3 /home/node/.openclaw/workspace/skills/gitlab-skill/scripts/gitlab_api.py projects --search test --format json | grep -o '"id":[0-9]*' | head -1
```

原因通常有两种：

1. 这个脚本的 `--format json` 输出并不一定是纯净、扁平、适合直接 `grep -o '"id":[0-9]*'` 的 JSON
2. 直接 grep `id` 很容易匹配不到，或者匹配到不是你想要的层级

因此更稳妥的做法是：

- **项目搜索**：继续用 `gitlab_api.py projects --search ...`
- **项目 ID 定位**：直接调用 GitLab REST API

---

## 对 `ci-selfheal` 的影响

当前 `ci-selfheal` 对 GitLab 的现状可以总结为：

1. **分支创建 / 文件提交**：可以继续复用 `gitlab-skill`，或直接走 GitLab API
2. **Merge Request 创建**：建议不要再依赖当前版本的 `gitlab-skill`
3. **生产闭环**：MR 创建更适合在 `ci-selfheal` 自己的代码里用 GitLab REST API 实现

---

## 建议

### 短期建议

- `gitlab-skill` 继续用于：
  - 搜索项目
  - 创建分支
  - 可能的基础 Git 操作
- MR 创建统一改为 GitLab REST API：
  - `/api/v4/projects/:id/merge_requests`

### 中期建议

把 `ci-selfheal` 的 MR 创建逻辑从“提示 agent 调 `gitlab-skill`”改成“自己直接调 GitLab API”。

这样可以获得：

- 更稳定
- 更可测试
- 更容易定位错误
- 不依赖 agent 对 skill 的自然语言执行质量

---

## 对应代码现状

当前代码里：

- `ci-selfheal/verifier/pr_manager.py`：创建 MR 仍然是通过提示词委托 `gitlab-skill`
- `ci-selfheal/scripts/orchestrator.py`：已经直接用 GitLab REST API 创建分支、提交 commit

所以从架构一致性看，**把 MR 创建也迁到 `ci-selfheal` 自己的 GitLab API 调用层里，是最顺手也最合理的下一步**。
 优化md格式