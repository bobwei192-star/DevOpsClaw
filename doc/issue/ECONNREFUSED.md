问题 2: ECONNREFUSED 127.0.0.1:18440
错误:

text
Error: connect ECONNREFUSED 127.0.0.1:18440
原因: 容器内 127.0.0.1 指向容器自身，无法访问宿主机端口。

解决: 使用 Docker 网关 IP 访问宿主机。

查找网关 IP:

bash
ip route | grep default
# 输出: default via 172.19.0.1 dev eth0
正确的 URL:

bash
export JENKINS_URL="https://172.19.0.1:18440"
问题 3: nginx 返回 404
错误:

text
404 Not Found - nginx
原因: Jenkins 前面有 nginx 反向代理，Jenkins 不在根路径 /，而在 /jenkins。

验证方法:

bash
curl -k https://172.19.0.1:18440/api/json
# 返回 301，重定向到 /jenkins/login
解决:

bash
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
问题 4: 环境变量名错误
错误:

text
Missing required environment variables: JENKINS_URL, JENKINS_USER, JENKINS_API_TOKEN
原因: Skill 要求的变量名是 JENKINS_API_TOKEN，不是 JENKINS_TOKEN。

正确的环境变量:

bash
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec..."   # 注意: 是 API_TOKEN，不是 TOKEN
export NODE_TLS_REJECT_UNAUTHORIZED=0    # 跳过自签名证书验证
问题 5: agent config set 验证失败
错误:

text
Config validation failed: skills: Unrecognized key: "jenkins"
原因: Workspace skill 的配置不走 agent config set，而是通过环境变量直接传递给脚本。

正确方式: 直接在 shell 中 export 环境变量。

最终可用命令
bash
# 在容器内执行
baseDir="/home/node/.agent/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec..."
export NODE_TLS_REJECT_UNAUTHORIZED=0

# 列出 Job
node ${baseDir}/scripts/jenkins.mjs jobs

# 查看最后构建状态
node ${baseDir}/scripts/jenkins.mjs status --job "job-name" --last

# 查看控制台日志（最后 50 行）
node ${baseDir}/scripts/jenkins.mjs console --job "job-name" --last --tail 50

# 触发构建
node ${baseDir}/scripts/jenkins.mjs build --job "job-name"
text

---

### 文档 2: `agent-jenkins-skill-reference.md`

```markdown
# Agent Jenkins Skill 快速参考

## 前置条件

在容器内执行任何命令前，先设置环境变量：

```bash
baseDir="/home/node/.agent/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec..."
export NODE_TLS_REJECT_UNAUTHORIZED=0
注意: 每次新开 shell 都需要重新 export。

命令速查
操作	命令
列出所有 Job	node ${baseDir}/scripts/jenkins.mjs jobs
按名称过滤 Job	node ${baseDir}/scripts/jenkins.mjs jobs --pattern "deploy-*"
触发构建	node ${baseDir}/scripts/jenkins.mjs build --job "job-name"
带参数构建	node ${baseDir}/scripts/jenkins.mjs build --job "job-name" --params '{"BRANCH":"main"}'
查看构建状态	node ${baseDir}/scripts/jenkins.mjs status --job "job-name" --last
查看指定构建号	node ${baseDir}/scripts/jenkins.mjs status --job "job-name" --build 123
查看控制台日志	node ${baseDir}/scripts/jenkins.mjs console --job "job-name" --last --tail 50
停止构建	node ${baseDir}/scripts/jenkins.mjs stop --job "job-name" --build 123
查看队列	node ${baseDir}/scripts/jenkins.mjs queue
查看节点	node ${baseDir}/scripts/jenkins.mjs nodes
环境变量说明
变量	说明	示例
JENKINS_URL	Jenkins 完整 URL（含 /jenkins 路径）	https://172.19.0.1:18440/jenkins
JENKINS_USER	Jenkins 用户名	zx
JENKINS_API_TOKEN	Jenkins API Token（在 User → Configure → API Token 生成）	11e9fec...
NODE_TLS_REJECT_UNAUTHORIZED	跳过 SSL 证书验证（自签名证书必需）	0
网络地址说明
场景	JENKINS_URL
容器访问宿主机（推荐）	https://172.19.0.1:18440/jenkins
宿主机本地	https://127.0.0.1:18440/jenkins
Docker Desktop	https://host.docker.internal:18440/jenkins
在 Agent Agent 中使用
通过 Agent 对话自动调用 skill:

bash
agent agent --message "列出 Jenkins 上的所有 jobs"
agent agent --message "触发 example_fauliure_job 的构建"
agent agent --message "查看 example_fauliure_job 最后一次构建的日志"
或交互式聊天:

bash
agent chat
Skill 文件位置
text
/home/node/.agent/workspace/skills/jenkins/
├── SKILL.md          # 使用说明
├── _meta.json        # 元数据
├── .clawhub/         # 安装来源信息
└── scripts/
    └── jenkins.mjs   # 主脚本
text
继续啊
好的，我看到你成功运行了 agent agent，现在继续。

你现在应该已经进入了 agent 对话模式，可以直接输入自然语言让 Agent 调用 Jenkins skill。比如：

text
列出 Jenkins 上的所有 jobs
或者查看刚才那个失败的 job：

text
查看 example_fauliure_job 最后一次构建的控制台日志
如果你想退出 agent 对话模式回到 shell，按 Ctrl+C 或 Ctrl+D。

如果你想继续用命令行直接调脚本，现在是新的 shell，需要重新设置环境变量：

bash
baseDir="/home/node/.agent/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0

# 查看失败 job 的日志
node ${baseDir}/scripts/jenkins.mjs console --job "example_fauliure_job" --last --tail 100
你现在处在哪个界面？agent 对话还是 shell 终端？