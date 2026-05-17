# Agent 容器中调试 Jenkins Skill 全过程

## 环境信息

| 组件 | 说明 |
|------|------|
| Agent | 运行在 Docker 容器 `devopsagent-agent` 中 |
| Jenkins | 运行在宿主机 WSL，端口 18440 |
| 反向代理 | nginx，Jenkins 根路径为 `/jenkins` |
| Skill 类型 | workspace skill（非 CLI 插件） |

## 问题 1: `agent jenkins` 命令不存在

**错误:**
Error: Unknown command: agent jenkins.
No built-in command or plugin CLI metadata owns "jenkins".

text

**原因:** Jenkins 安装的是 **workspace skill**，不是 CLI 插件。Workspace skill 通过 `node` 直接执行脚本调用，不走 `agent jenkins` CLI 命令。

**检查 skill 安装位置:**
```bash
ls -la /home/node/.agent/workspace/skills/jenkins/
cat /home/node/.agent/workspace/skills/jenkins/SKILL.md
node@5da26b33f5b4:/app$ # 查看 jenkins skill 目录结构
ls -la /home/node/.agent/workspace/skills/jenkins/

# 查看 skill 的元数据和说明
cat /home/node/.agent/workspace/skills/jenkins/skill.md 2>/dev/null || cat /home/node/.agent/workspace/skills/jenkins/README.md 2>/dev/null || cat /home/node/.agent/workspace/skills/jenkins/SKILL.md 2>/dev/null
total 4
drwxrwxrwx 1 node node 4096 May 10 16:57 .
drwxrwxrwx 1 node node 4096 May 10 16:57 ..
drwxrwxrwx 1 node node 4096 May 10 16:57 .clawhub
-rwxrwxrwx 1 node node 1690 May 10 16:57 SKILL.md
-rwxrwxrwx 1 node node  126 May 10 16:57 _meta.json
drwxrwxrwx 1 node node 4096 May 10 16:57 scripts
---
name: jenkins
description: Interact with Jenkins CI/CD server via REST API. Use when you need to trigger builds, check build status, view console output, manage jobs, or monitor Jenkins nodes and queue. Supports deployment to different Jenkins instances via environment variables.
---

# Jenkins

Interact with Jenkins CI/CD server through REST API.

## Required environment variables

- `JENKINS_URL` (example: `https://jenkins.example.com`)
- `JENKINS_USER` (your Jenkins username)
- `JENKINS_API_TOKEN` (API token from Jenkins user settings)

## List jobs

```bash
node {baseDir}/scripts/jenkins.mjs jobs
node {baseDir}/scripts/jenkins.mjs jobs --pattern "deploy-*"
```

## Trigger build

```bash
node {baseDir}/scripts/jenkins.mjs build --job "my-job"
node {baseDir}/scripts/jenkins.mjs build --job "my-job" --params '{"BRANCH":"main","ENV":"dev"}'
```

## Check build status

```bash
node {baseDir}/scripts/jenkins.mjs status --job "my-job"
node {baseDir}/scripts/jenkins.mjs status --job "my-job" --build 123
node {baseDir}/scripts/jenkins.mjs status --job "my-job" --last
```

## View console output

```bash
node {baseDir}/scripts/jenkins.mjs console --job "my-job" --build 123
node {baseDir}/scripts/jenkins.mjs console --job "my-job" --last --tail 50
```

## Stop build

```bash
node {baseDir}/scripts/jenkins.mjs stop --job "my-job" --build 123
```

## View queue

```bash
node {baseDir}/scripts/jenkins.mjs queue
```

## View nodes

```bash
node {baseDir}/scripts/jenkins.mjs nodes
```

## Notes

- URL and credentials are variables by design for cross-environment deployment.
- API responses are output as JSON.
- For parameterized builds, use `--params` with JSON string.
node@5da26b33f5b4:/app$