#!/usr/bin/env python3
# ============================================================
# 文件: bridge.py
# 名称: OpenClaw Jenkins Self-Healing Bridge
# 版本: 1.0.0 (Python3 Final)
# 语言: Python 3.8+
# 依赖: requests
# ============================================================

import os
import sys
import json
import re
import logging
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

import requests


# ==================== 配置区 ====================
class Config:
    # OpenClaw Gateway
    OPENCLAW_URL = os.getenv("OPENCLAW_URL", "http://127.0.0.1:18789/v1/chat/completions")
    OPENCLAW_TOKEN = os.getenv("OPENCLAW_GATEWAY_TOKEN")

    # Jenkins
    JENKINS_URL = os.getenv("JENKINS_URL", "http://127.0.0.1:8080").rstrip('/')
    JENKINS_USER = os.getenv("JENKINS_USER", "admin")
    JENKINS_TOKEN = os.getenv("JENKINS_TOKEN")

    # 业务规则
    MAX_RETRY = int(os.getenv("MAX_RETRY", "5"))
    DRY_RUN = os.getenv("DRY_RUN", "true").lower() == "true"

    # 服务
    PORT = int(os.getenv("BRIDGE_PORT", "5000"))
    STATE_FILE = os.getenv("STATE_FILE", "/home/worker/software/AI/CICD/openclaw/.self-heal-state.json")
    LOG_FILE = os.getenv("LOG_FILE", "/home/worker/software/AI/CICD/openclaw/bridge.log")


# ==================== 日志系统 ====================
def setup_logging():
    logger = logging.getLogger("bridge")
    logger.setLevel(logging.DEBUG)

    fh = logging.FileHandler(Config.LOG_FILE, encoding='utf-8')
    fh.setLevel(logging.INFO)

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)

    fmt = logging.Formatter('[%(asctime)s] [%(levelname)s] %(message)s')
    fh.setFormatter(fmt)
    ch.setFormatter(fmt)

    logger.addHandler(fh)
    logger.addHandler(ch)
    return logger

LOG = setup_logging()


def log_info(msg, **kwargs):
    extra = f" {json.dumps(kwargs, ensure_ascii=False)}" if kwargs else ""
    LOG.info(f"{msg}{extra}")


def log_warn(msg, **kwargs):
    extra = f" {json.dumps(kwargs, ensure_ascii=False)}" if kwargs else ""
    LOG.warning(f"{msg}{extra}")


def log_error(msg, **kwargs):
    extra = f" {json.dumps(kwargs, ensure_ascii=False)}" if kwargs else ""
    LOG.error(f"{msg}{extra}")


# ==================== 状态管理 ====================
class StateManager:
    def __init__(self, filepath):
        self.filepath = Path(filepath)
        self._data = None

    def load(self):
        if self._data is not None:
            return self._data
        try:
            with open(self.filepath, 'r', encoding='utf-8') as f:
                self._data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self._data = {"chains": {}}
        return self._data

    def save(self):
        with open(self.filepath, 'w', encoding='utf-8') as f:
            json.dump(self._data, f, indent=2, ensure_ascii=False)

    def get_chain(self, job_name):
        return self.load()["chains"].get(job_name, {
            "current_retry": 0,
            "history": []
        })

    def update_chain(self, job_name, update_fn):
        self.load()
        if job_name not in self._data["chains"]:
            self._data["chains"][job_name] = {"current_retry": 0, "history": []}
        update_fn(self._data["chains"][job_name])
        self.save()


STATE = StateManager(Config.STATE_FILE)


# ==================== Jenkins API 客户端 ====================
class JenkinsClient:
    def __init__(self):
        self.session = requests.Session()
        self.session.auth = (Config.JENKINS_USER, Config.JENKINS_TOKEN)
        self.session.timeout = 30
        self._crumb = None

    def _get_crumb(self):
        if self._crumb is not None:
            return self._crumb
        try:
            r = self.session.get(f"{Config.JENKINS_URL}/crumbIssuer/api/json")
            if r.status_code == 200:
                data = r.json()
                self._crumb = {data["crumbRequestField"]: data["crumb"]}
                return self._crumb
        except Exception:
            pass
        return {}

    def get(self, path):
        headers = self._get_crumb()
        url = f"{Config.JENKINS_URL}{path}"
        r = self.session.get(url, headers=headers, timeout=10)
        r.raise_for_status()
        return r.text

    def post(self, path, data=None, content_type='application/xml'):
        headers = {
            'Content-Type': content_type,
            **self._get_crumb()
        }
        url = f"{Config.JENKINS_URL}{path}"
        r = self.session.post(url, data=data, headers=headers, timeout=30)
        if r.status_code >= 400:
            raise RuntimeError(f"Jenkins API 错误: {r.status_code} {r.text[:500]}")
        return r


JENKINS = JenkinsClient()


# ==================== 代码提取与构建 ====================
def extract_jenkinsfile(config_xml: str) -> str:
    """从 Jenkins config.xml 提取 Pipeline 脚本"""
    cdata_match = re.search(r'<script>\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*</script>', config_xml)
    if cdata_match:
        return cdata_match.group(1).strip()

    normal_match = re.search(r'<script>([\s\S]*?)</script>', config_xml)
    if normal_match:
        return normal_match.group(1).strip()

    return ""


def build_config_xml(script: str, description: str = "Auto-fixed by OpenClaw") -> str:
    """构建 Jenkins Job 的 config.xml"""
    escaped = (script
        .replace('&', '&amp;')
        .replace('<', '&lt;')
        .replace('>', '&gt;'))

    return f'''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>{description}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>{escaped}</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''


# ==================== AI 诊断引擎 ====================
def extract_error_snippet(log: str) -> str:
    """从日志中提取关键错误片段"""
    lines = log.split('\n')
    snippets = []
    for i, line in enumerate(lines):
        if re.search(r'ERROR|FAILED|Exception|command not found|syntax error', line, re.I):
            start = max(0, i - 3)
            end = min(len(lines), i + 4)
            snippets.append('\n'.join(lines[start:end]))

    result = '\n---\n'.join(snippets[-3:])
    return result or log[-500:]


def build_prompt(jenkinsfile: str, log_tail: str, round_num: int, error_snippet: str) -> str:
    """构建发送给 LLM 的 Prompt"""
    return f"""你是一位资深的 Jenkins Pipeline 与 Shell 脚本专家。
当前 Jenkins 流水线构建失败，请分析日志并修复 Pipeline 代码中的错误。

## 当前 Jenkinsfile
```groovy
{jenkinsfile}
```

## 构建日志（最后 200 行）
```
{log_tail}
```

## 关键错误片段
```
{error_snippet}
```

## 修复规则（严格遵守）
1. 只修改导致构建失败的具体错误，不要改变业务逻辑和整体结构
2. 保持 node / stage 的层级结构不变
3. 如果是命令拼写错误（如 date--），修正为正确命令（如 date）
4. 如果是语法错误（如括号不匹配），修正语法
5. 如果是权限问题，添加适当的 sudo 或权限修改
6. 输出完整的修复后 Jenkinsfile 代码，用 ```groovy 包裹
7. 如果无法确定原因或无法安全修复，仅回复：CANNOT_FIX

## 输出格式
直接输出修复后的完整代码，不要有多余解释。
当前是第 {round_num}/{Config.MAX_RETRY} 轮修复。"""


def ai_fix_with_model(model: str, prompt: str) -> str:
    """使用指定模型调用 OpenClaw API"""
    headers = {
        'Authorization': f'Bearer {Config.OPENCLAW_TOKEN}',
        'Content-Type': 'application/json'
    }

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "你是 Jenkins Pipeline 修复专家，只输出代码，不解释。"},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.1,
        "max_tokens": 4000
    }

    r = requests.post(Config.OPENCLAW_URL, headers=headers, json=payload, timeout=60)
    r.raise_for_status()

    return r.json()["choices"][0]["message"]["content"]


def ai_fix(jenkinsfile: str, log_tail: str, round_num: int) -> str:
    """调用 AI 进行诊断和修复，尝试多个模型"""
    error_snippet = extract_error_snippet(log_tail)
    prompt = build_prompt(jenkinsfile, log_tail, round_num, error_snippet)

    log_info("调用 AI 诊断", round=round_num, log_length=len(log_tail))

    # 尝试的模型列表（按优先级排序）
    models_to_try = [
        "kimi-k2-5",           # Kimi K2.5
        "kimi-k2.5",           # 备选命名
        "deepseek-reasoner",   # DeepSeek Reasoner
        "deepseek-chat",       # DeepSeek Chat
        "deepseek-coder",      # DeepSeek Coder
    ]

    last_error = None

    for model in models_to_try:
        try:
            log_info(f"尝试模型: {model}")
            result = ai_fix_with_model(model, prompt)
            log_info(f"模型 {model} 调用成功")
            return result
        except requests.exceptions.HTTPError as e:
            if e.response.status_code == 404:
                log_warn(f"模型 {model} 不可用 (404)")
                last_error = e
                continue
            else:
                log_error(f"模型 {model} 调用失败", status=e.response.status_code)
                last_error = e
                continue
        except Exception as e:
            log_error(f"模型 {model} 调用异常", error=str(e))
            last_error = e
            continue

    # 所有模型都失败了
    raise RuntimeError(f"所有 AI 模型都不可用，最后一个错误: {last_error}")


def extract_fixed_code(ai_response: str) -> str | None:
    """从 AI 响应中提取修复后的代码"""
    if "CANNOT_FIX" in ai_response:
        return None

    patterns = [
        r'```groovy\s*\n([\s\S]*?)\n```',
        r'```jenkinsfile\s*\n([\s\S]*?)\n```',
        r'```\s*\n([\s\S]*?)\n```',
        r'(node\s*\{[\s\S]*\})',
    ]

    for pattern in patterns:
        m = re.search(pattern, ai_response)
        if m:
            return m.group(1).strip()

    if "node {" in ai_response and "stage(" in ai_response:
        return ai_response.strip()

    return None


# ==================== 核心处理逻辑 ====================
def handle_build(payload: dict) -> dict:
    """处理 Jenkins 构建事件"""
    job_name = payload.get("jobName", "")
    build_number = payload.get("buildNumber", "")
    status = payload.get("status", "SUCCESS")
    build_tag = payload.get("buildTag", "")
    is_openclaw = payload.get("isOpenclaw", False)
    retry_count = payload.get("retryCount", 0)

    log_info("收到构建事件", job_name=job_name, build_number=build_number,
             status=status, retry_count=retry_count, is_openclaw=is_openclaw)

    # ---- 成功：清理状态 ----
    if status == "SUCCESS":
        if is_openclaw:
            log_info("OpenClaw 修复成功", job_name=job_name,
                    build_number=build_number, retry_count=retry_count)
            original_job = re.sub(r'-openclaw-fix-\d+$', '', job_name)
            chain = STATE.get_chain(original_job)
            chain["history"].append({
                "result": "SUCCESS",
                "fixed_job": job_name,
                "build_number": build_number,
                "timestamp": datetime.now().isoformat()
            })
            STATE.update_chain(original_job, lambda c: c.update(chain))
        else:
            log_info("原始 Job 构建成功，无需动作", job_name=job_name)
        return {"action": "none", "reason": "success"}

    # ---- 失败处理 ----
    if is_openclaw:
        original_job = re.sub(r'-openclaw-fix-\d+$', '', job_name)
        current_retry = retry_count
    else:
        original_job = job_name
        current_retry = 0

    # 检查上限
    if current_retry >= Config.MAX_RETRY:
        log_warn("已达最大修复次数，停止自愈",
                original_job=original_job, current_retry=current_retry,
                max_retry=Config.MAX_RETRY)
        return {"action": "stop", "reason": "max_retry_exceeded"}

    # 拉取原始代码和日志
    try:
        config_xml = JENKINS.get(f"/job/{original_job}/config.xml")
        jenkinsfile = extract_jenkinsfile(config_xml)
        if not jenkinsfile:
            raise RuntimeError("无法从 config.xml 提取 Pipeline 代码")

        full_log = JENKINS.get(f"/job/{job_name}/{build_number}/consoleText")
        log_tail = '\n'.join(full_log.split('\n')[-200:])

    except Exception as e:
        log_error("拉取代码或日志失败", error=str(e))
        return {"action": "error", "reason": str(e)}

    # AI 诊断
    try:
        ai_result = ai_fix(jenkinsfile, log_tail, current_retry + 1)
        fixed_code = extract_fixed_code(ai_result)

        if not fixed_code:
            log_warn("AI 无法生成有效修复代码",
                    original_job=original_job, round=current_retry + 1)
            return {"action": "stop", "reason": "ai_cannot_fix"}

        log_info("AI 生成修复代码", original_job=original_job,
                round=current_retry + 1, code_length=len(fixed_code))

    except Exception as e:
        log_error("AI 诊断失败", error=str(e))
        return {"action": "error", "reason": f"ai_error: {e}"}

    # DRY_RUN 模式（L2 安全）
    if Config.DRY_RUN:
        log_info("DRY_RUN 模式：仅输出修复建议", original_job=original_job)
        print("\n" + "=" * 50 + " AI 修复建议 " + "=" * 50)
        print(fixed_code)
        print("=" * 110)
        print("请手动确认后设置 DRY_RUN=false 重新运行")
        return {"action": "dry_run", "fixed_code": fixed_code}

    # 创建修复 Job
    new_job_name = f"{original_job}-openclaw-fix-{current_retry + 1}"
    try:
        try:
            JENKINS.post(f"/job/{new_job_name}/doDelete", data="")
            log_info("删除已存在的旧修复 Job", new_job_name=new_job_name)
        except Exception:
            pass

        JENKINS.post(f"/createItem?name={new_job_name}",
                    data=build_config_xml(fixed_code))
        log_info("已创建修复 Job", new_job_name=new_job_name)

    except Exception as e:
        log_error("创建修复 Job 失败", new_job_name=new_job_name, error=str(e))
        return {"action": "error", "reason": f"create_job_failed: {e}"}

    # 触发构建
    try:
        JENKINS.post(f"/job/{new_job_name}/build", data="")
        log_info("已触发修复构建", new_job_name=new_job_name)

        STATE.update_chain(original_job, lambda chain: chain.update({
            "current_retry": current_retry + 1,
            "history": chain.get("history", []) + [{
                "round": current_retry + 1,
                "fixed_job": new_job_name,
                "original_build": build_tag,
                "timestamp": datetime.now().isoformat()
            }]
        }))

        return {"action": "fix_triggered", "new_job_name": new_job_name,
                "round": current_retry + 1}

    except Exception as e:
        log_error("触发构建失败", new_job_name=new_job_name, error=str(e))
        return {"action": "error", "reason": f"trigger_failed: {e}"}


# ==================== HTTP 服务 ====================
class BridgeHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, status_code, data):
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == '/health':
            self._send_json(200, {
                "status": "healthy",
                "version": "1.0.0",
                "dry_run": Config.DRY_RUN,
                "max_retry": Config.MAX_RETRY
            })
        elif parsed.path == '/state':
            self._send_json(200, STATE.load())
        else:
            self._send_json(404, {"error": "Not Found"})

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == '/webhook/jenkins':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')

            try:
                payload = json.loads(body)
                result = handle_build(payload)
                self._send_json(200, {"status": "ok", "result": result})
            except json.JSONDecodeError as e:
                log_error("JSON 解析失败", error=str(e), body=body[:500])
                self._send_json(400, {"status": "error", "message": "Invalid JSON"})
            except Exception as e:
                log_error("处理请求失败", error=str(e))
                self._send_json(500, {"status": "error", "message": str(e)})
        else:
            self._send_json(404, {"error": "Not Found"})


# ==================== 启动 ====================
def main():
    if not Config.OPENCLAW_TOKEN:
        print("错误: 未设置 OPENCLAW_GATEWAY_TOKEN")
        sys.exit(1)
    if not Config.JENKINS_TOKEN:
        print("错误: 未设置 JENKINS_TOKEN")
        sys.exit(1)

    log_info("Bridge 启动中...", port=Config.PORT, dry_run=Config.DRY_RUN,
             max_retry=Config.MAX_RETRY)

    server = HTTPServer(('0.0.0.0', Config.PORT), BridgeHandler)

    print(f"""
╔══════════════════════════════════════════════════════════════╗
║     OpenClaw Jenkins Self-Healing Bridge v1.0.0 (Python3)    ║
╠══════════════════════════════════════════════════════════════╣
║  监听端口:    {str(Config.PORT).ljust(43)}║
║  OpenClaw:   {Config.OPENCLAW_URL[:40].ljust(43)}║
║  Jenkins:    {Config.JENKINS_URL[:40].ljust(43)}║
║  DRY_RUN:    {(Config.DRY_RUN and '开启 (L2 安全模式)' or '关闭 (L3 自动模式)').ljust(43)}║
║  最大修复:   {str(Config.MAX_RETRY).ljust(43)}║
╠══════════════════════════════════════════════════════════════╣
║  健康检查:   GET http://127.0.0.1:{Config.PORT}/health        ║
║  状态查看:   GET http://127.0.0.1:{Config.PORT}/state         ║
╚══════════════════════════════════════════════════════════════╝
""")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log_info("Bridge 已停止")
        server.shutdown()


if __name__ == '__main__':
    main()
