日期: 2026-05-10
状态: ✅ Jenkins + GitLab 连通性验证通过

一、环境拓扑
text
┌─────────────────────────────────────────────────┐
│                  宿主机 WSL                       │
│  ┌──────────────┐ ┌──────────────┐               │
│  │ Jenkins      │ │ GitLab       │               │
│  │ nginx:18440  │ │ nginx:18441  │               │
│  └──────┬───────┘ └──────┬───────┘               │
│         │                │                       │
│  ┌──────┴────────────────┴───────┐               │
│  │   Docker Network (172.19.0.x) │               │
│  │  ┌─────────────────────────┐  │               │
│  │  │ OpenClaw 容器            │  │               │
│  │  │ IP: 172.19.0.3          │  │               │
│  │  └─────────────────────────┘  │               │
│  └───────────────────────────────┘               │
└─────────────────────────────────────────────────┘
二、已验证项目
2.1 OpenClaw 容器
检查项	命令	结果
容器运行状态	docker ps | grep devopsclaw-openclaw	✅ Up (healthy)
OpenClaw 版本	openclaw --version	✅ 2026.5.5
Gateway 状态	openclaw status	✅ 运行中，端口 18789
2.2 Jenkins 连通性
检查项	命令	结果
容器内访问 Jenkins API	node jenkins.mjs jobs	✅ 返回 1 job (example_fauliure_job)
Jenkins URL	https://172.19.0.1:18440/jenkins	✅
认证方式	JENKINS_USER + JENKINS_API_TOKEN	✅
2.3 GitLab 连通性
检查项	命令	结果
容器内访问 GitLab API	curl -k https://172.19.0.1:18441/api/v4/user	✅ 返回用户信息
GitLab URL	https://172.19.0.1:18441	✅
认证方式	PRIVATE-TOKEN header	✅
2.4 已安装 Skill
Skill	路径	状态
jenkins	/home/node/.openclaw/workspace/skills/jenkins/	✅ ready
capability-evolver-pro	/home/node/.openclaw/workspace/skills/capability-evolver-pro/	✅ ready
n8n	/home/node/.openclaw/workspace/skills/n8n/	△ needs setup
tavily	/home/node/.openclaw/workspace/skills/tavily/	✅ ready
三、关键配置速查
Jenkins 环境变量（容器内每次新 shell 需重新 export）
bash
baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0
Jenkins Skill 调用方式
bash
# 列出 Jobs
node ${baseDir}/scripts/jenkins.mjs jobs

# 查看构建状态
node ${baseDir}/scripts/jenkins.mjs status --job "<name>" --last

# 查看构建日志
node ${baseDir}/scripts/jenkins.mjs console --job "<name>" --last --tail 50

# 触发构建
node ${baseDir}/scripts/jenkins.mjs build --job "<name>"
GitLab API 调用方式
bash
TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"

# 获取用户信息
curl -k -H "PRIVATE-TOKEN: $TOKEN" "https://172.19.0.1:18441/api/v4/user"

# 获取项目列表
curl -k -H "PRIVATE-TOKEN: $TOKEN" "https://172.19.0.1:18441/api/v4/projects"

# 创建 MR
curl -k -X POST \
  -H "PRIVATE-TOKEN: $TOKEN" \
  -d "source_branch=fix/ci-selfheal-x" \
  -d "target_branch=main" \
  -d "title=[ci-selfheal] Auto-fix" \
  "https://172.19.0.1:18441/api/v4/projects/:id/merge_requests"
四、常见问题排错
错误	原因	解决
ECONNREFUSED 127.0.0.1	容器内 localhost 指向容器自身	改用 172.19.0.1（Docker 网关 IP）
404 Not Found - nginx	Jenkins 路径需要 /jenkins 前缀	JENKINS_URL 末尾加 /jenkins
ENOTFOUND host.docker.internal	WSL 下 Docker 不支持此主机名	改用 172.19.0.1
Missing required environment variables	变量名错误或未 export	确保用 export 且变量名是 JENKINS_API_TOKEN
Config validation failed: skills	workspace skill 不走 config set	直接用环境变量，不用 openclaw config set
Unknown command: openclaw jenkins	jenkins 是 workspace skill 不是 CLI 插件	用 node .../jenkins.mjs 直接调用
五、网络地址对照表
场景	Jenkins	GitLab
宿主机本地	https://127.0.0.1:18440/jenkins	https://127.0.0.1:18441
容器内（推荐）	https://172.19.0.1:18440/jenkins	https://172.19.0.1:18441
Docker Desktop	https://host.docker.internal:18440/jenkins	https://host.docker.internal:18441
