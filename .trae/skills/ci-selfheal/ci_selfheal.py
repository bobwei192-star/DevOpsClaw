#!/usr/bin/env python3
# ============================================================
# 文件: ci_selfheal.py
# 名称: CI/CD 自愈核心逻辑
# 版本: 4.0.0 (Skill 架构版)
# 语言: Python 3.8+
#
# 变更日志:
#   v4.0.0 (2026-05-06)
#   - 重构为 Skill 架构，不再需要独立的 Bridge 服务
#   - 整合 Jenkins 客户端、JJB 管理器、状态管理
#   - 支持作为模块被调用，也支持命令行运行
#
# 闭环流程 (v4.0.0 高度自治):
#   1. Jenkins 构建失败 → Webhook 通知
#   2. Skill 被激活，接收事件
#   3. 拉取 Jenkinsfile 和构建日志
#   4. 调用 AI 诊断错误，生成修复代码
#   5. 更新 JJB YAML 配置文件
#   6. 执行 jenkins-jobs update 更新 Jenkins Job
#   7. 触发原 Job 重新构建
#   8. 等待结果，最多 5 轮修复
# ============================================================

import os
import sys
import json
import re
import logging
import subprocess
import argparse
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, Any, Tuple

# 尝试导入本地模块
try:
    from jenkins_client import JenkinsClient, create_jenkins_client, get_failure_details, extract_error_snippet
    from jjb_manager import JJBManager, create_jjb_manager
    HAS_LOCAL_MODULES = True
except ImportError:
    # 如果作为独立脚本运行，添加当前目录到路径
    sys.path.insert(0, str(Path(__file__).parent))
    from jenkins_client import JenkinsClient, create_jenkins_client, get_failure_details, extract_error_snippet
    from jjb_manager import JJBManager, create_jjb_manager
    HAS_LOCAL_MODULES = True


# ==================== 配置 ====================
class Config:
    # 最大修复轮次
    MAX_RETRY = int(os.getenv("MAX_RETRY", "5"))
    
    # 默认 AI 模型
    DEFAULT_MODEL = os.getenv("DEFAULT_MODEL", "deepseek-reasoner")
    
    # Agent 容器名称
    AGENT_CONTAINER = os.getenv("AGENT_CONTAINER", "agent")
    
    # 模型名称映射
    MODEL_MAPPING = {
        "kimi-k2.5": "custom-api-moonshot-cn/kimi-k2.5",
        "deepseek-reasoner": "custom-api-deepseek-com/deepseek-reasoner",
    }
    
    # 状态文件路径
    STATE_FILE = Path(os.getenv("STATE_FILE", "./.self-heal-state.json"))


# ==================== 日志系统 ====================
def setup_logging():
    logger = logging.getLogger("ci_selfheal")
    logger.setLevel(logging.DEBUG)

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)

    fmt = logging.Formatter('[%(asctime)s] [%(levelname)s] %(message)s')
    ch.setFormatter(fmt)

    if not logger.handlers:
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
    """状态管理器 - 跟踪自愈流程的状态"""
    
    def __init__(self, filepath: Path = None):
        self.filepath = filepath or Config.STATE_FILE
        self.filepath.parent.mkdir(parents=True, exist_ok=True)
        self._data = None

    def load(self) -> Dict[str, Any]:
        if self._data is not None:
            return self._data
        try:
            with open(self.filepath, 'r', encoding='utf-8') as f:
                self._data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self._data = {
                "version": "4.0.0",
                "chains": {}
            }
        return self._data

    def save(self):
        with open(self.filepath, 'w', encoding='utf-8') as f:
            json.dump(self._data, f, indent=2, ensure_ascii=False)

    def get_chain(self, job_name: str) -> Dict[str, Any]:
        """获取指定 Job 的自愈链状态"""
        return self.load()["chains"].get(job_name, {
            "current_retry": 0,
            "status": "idle",
            "history": [],
            "last_update": None
        })

    def start_chain(self, job_name: str, build_number: int):
        """开始一个新的自愈链"""
        self.load()
        self._data["chains"][job_name] = {
            "current_retry": 0,
            "status": "running",
            "original_build": build_number,
            "history": [],
            "created_at": datetime.now().isoformat(),
            "last_update": datetime.now().isoformat()
        }
        self.save()
        log_info("开始新的自愈链", job_name=job_name, build_number=build_number)

    def increment_retry(self, job_name: str, round_num: int, dsl_preview: str = ""):
        """增加重试次数"""
        def update(chain):
            chain["current_retry"] = round_num
            chain["status"] = "running"
            chain["last_update"] = datetime.now().isoformat()
            chain["history"].append({
                "round": round_num,
                "timestamp": datetime.now().isoformat(),
                "dsl_preview": dsl_preview[:200] if dsl_preview else ""
            })

        self.load()
        if job_name not in self._data["chains"]:
            self._data["chains"][job_name] = {
                "current_retry": 0,
                "status": "running",
                "history": [],
                "created_at": datetime.now().isoformat()
            }
        update(self._data["chains"][job_name])
        self.save()
        log_info("更新重试计数", job_name=job_name, round=round_num)

    def mark_success(self, job_name: str):
        """标记自愈成功"""
        def update(chain):
            chain["status"] = "success"
            chain["last_update"] = datetime.now().isoformat()

        self.load()
        if job_name in self._data["chains"]:
            update(self._data["chains"][job_name])
            self.save()
        log_info("自愈成功", job_name=job_name)

    def mark_failed(self, job_name: str, reason: str):
        """标记自愈失败"""
        def update(chain):
            chain["status"] = "failed"
            chain["fail_reason"] = reason
            chain["last_update"] = datetime.now().isoformat()

        self.load()
        if job_name in self._data["chains"]:
            update(self._data["chains"][job_name])
            self.save()
        log_warn("自愈失败", job_name=job_name, reason=reason)

    def mark_max_retry(self, job_name: str):
        """标记达到最大重试次数"""
        def update(chain):
            chain["status"] = "max_retry"
            chain["last_update"] = datetime.now().isoformat()

        self.load()
        if job_name in self._data["chains"]:
            update(self._data["chains"][job_name])
            self.save()
        log_warn("达到最大重试次数", job_name=job_name)


STATE = StateManager()


# ==================== AI 调用 (Agent CLI) ====================
def build_prompt(
    jenkinsfile: str,
    log_tail: str,
    round_num: int,
    error_snippet: str,
    job_name: str
) -> str:
    """构建发送给 LLM 的 Prompt"""
    return f"""你是一位资深的 Jenkins Pipeline 与 Shell 脚本专家。

## 任务
当前 Jenkins 流水线构建失败，请分析日志并修复 Pipeline 代码中的错误。

## 上下文信息
- **Job 名称**: {job_name}
- **当前轮次**: 第 {round_num}/{Config.MAX_RETRY} 轮修复

## 当前 Jenkinsfile (Pipeline 定义)
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
1. **只修改导致构建失败的具体错误**，不要改变业务逻辑和整体结构
2. **保持 node / stage 的层级结构不变**，不要添加或删除 stage
3. **命令拼写错误**: 如 date-- 修正为 date，ech 修正为 echo 等
4. **语法错误**: 如括号不匹配、引号不闭合、变量引用错误等
5. **权限问题**: 添加适当的 sudo 或修改文件权限
6. **路径问题**: 检查工作目录、相对路径是否正确
7. **输出格式要求**:
   - 输出**完整的修复后 Jenkinsfile 代码**，用 ```groovy 包裹
   - 如果无法确定原因或无法安全修复，仅回复: `CANNOT_FIX`
   - 不要输出多余的解释文字，只输出代码块或 CANNOT_FIX

## 重要提示
- 这是第 {round_num} 轮修复，之前可能已经尝试过修复
- 请仔细分析日志中的具体错误信息
- 确保修复后的代码可以直接运行
- 不要修改与错误无关的代码

请直接输出修复后的完整代码。"""


def call_ai_with_cli(prompt: str, model: str = None) -> str:
    """使用 Agent CLI 调用 AI 模型"""
    model = model or Config.DEFAULT_MODEL
    
    # 模型名称映射
    full_model_name = Config.MODEL_MAPPING.get(model, model)

    try:
        # 构建 Agent CLI 命令
        cmd = [
            "docker", "exec", Config.AGENT_CONTAINER,
            "node", "agent.mjs",
            "infer", "model", "run",
            "--model", full_model_name,
            "--prompt", prompt
        ]

        log_info(f"调用 Agent CLI", model=full_model_name)

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300  # 5 分钟超时
        )

        if result.returncode != 0:
            raise RuntimeError(f"Agent CLI 失败: {result.stderr}")

        # 解析输出，提取 AI 回复
        output_lines = result.stdout.strip().split('\n')

        # 找到 "outputs:" 之后的行
        for i, line in enumerate(output_lines):
            if line.strip().startswith('outputs:') or line.strip().startswith('output:'):
                return '\n'.join(output_lines[i+1:]).strip()

        # 如果没有找到标记，返回最后几行
        return '\n'.join(output_lines[-15:]).strip()

    except Exception as e:
        log_error(f"Agent CLI 调用失败", error=str(e))
        raise


def ai_fix(
    jenkinsfile: str,
    log_tail: str,
    round_num: int,
    job_name: str
) -> str:
    """调用 AI 进行诊断和修复"""
    error_snippet = extract_error_snippet(log_tail)
    prompt = build_prompt(jenkinsfile, log_tail, round_num, error_snippet, job_name)

    log_info("调用 AI 诊断", round=round_num, log_length=len(log_tail), job_name=job_name)

    # 尝试多个模型
    models_to_try = [
        "deepseek-reasoner",
        "kimi-k2.5",
    ]

    last_error = None

    for model in models_to_try:
        try:
            log_info(f"尝试模型", model=model)
            result = call_ai_with_cli(prompt, model)
            log_info(f"模型调用成功", model=model, response_length=len(result))
            return result
        except Exception as e:
            log_warn(f"模型调用失败", model=model, error=str(e))
            last_error = e
            continue

    raise RuntimeError(f"所有 AI 模型都不可用，最后一个错误: {last_error}")


def extract_fixed_code(ai_response: str) -> Optional[str]:
    """从 AI 响应中提取修复后的代码"""
    if "CANNOT_FIX" in ai_response:
        log_warn("AI 表示无法修复")
        return None

    # 模式列表，按优先级排序
    patterns = [
        r'```groovy\s*\n([\s\S]*?)\n```',
        r'```jenkinsfile\s*\n([\s\S]*?)\n```',
        r'```\s*\n([\s\S]*?)\n```',
    ]

    for pattern in patterns:
        m = re.search(pattern, ai_response)
        if m:
            code = m.group(1).strip()
            if len(code) > 50:  # 确保是有意义的代码
                return code

    # 兜底：如果响应看起来像是 Jenkinsfile
    if "node {" in ai_response and "stage(" in ai_response:
        # 尝试提取从 node 开始的内容
        node_match = re.search(r'(node\s*\{[\s\S]*)', ai_response)
        if node_match:
            return node_match.group(1).strip()
        return ai_response.strip()

    log_warn("无法从 AI 响应中提取有效代码", response_preview=ai_response[:200])
    return None


# ==================== 核心自愈逻辑 ====================
def get_current_jenkinsfile(
    job_name: str,
    jenkins: JenkinsClient = None,
    jjb: JJBManager = None
) -> Tuple[Optional[str], str]:
    """
    获取当前的 Jenkinsfile (Pipeline)
    
    优先从 JJB YAML 配置读取，其次从 Jenkins API 读取
    
    Args:
        job_name: Job 名称
        jenkins: Jenkins 客户端 (可选)
        jjb: JJB 管理器 (可选)
        
    Returns:
        (jenkinsfile, source) - source: 'jjb' 或 'jenkins_api'
    """
    jenkins = jenkins or create_jenkins_client()
    jjb = jjb or create_jjb_manager()
    
    # 方法 1: 从 JJB YAML 配置读取
    dsl = jjb.get_job_dsl(job_name)
    if dsl:
        log_info("从 JJB YAML 配置读取 Jenkinsfile 成功", job_name=job_name)
        return dsl, 'jjb'
    
    # 方法 2: 从 Jenkins API 读取 (备用)
    log_warn("JJB YAML 配置读取失败，尝试从 Jenkins API 读取", job_name=job_name)
    try:
        config_xml = jenkins.get_job_config(job_name)
        jenkinsfile = jenkins.extract_jenkinsfile(config_xml)
        if jenkinsfile:
            log_info("从 Jenkins API 读取 Jenkinsfile 成功", job_name=job_name)
            return jenkinsfile, 'jenkins_api'
    except Exception as e:
        log_error("从 Jenkins API 读取失败", error=str(e))
    
    raise RuntimeError(f"无法获取 Job 的 Jenkinsfile: {job_name}")


def handle_build_failure(
    job_name: str,
    build_number: int,
    jenkins: JenkinsClient = None,
    jjb: JJBManager = None
) -> Dict[str, Any]:
    """
    处理构建失败事件
    
    完整闭环流程:
    1. 检查当前状态和重试次数
    2. 拉取 Jenkinsfile 和构建日志
    3. 调用 AI 诊断并生成修复代码
    4. 更新 JJB 配置
    5. 触发原 Job 重新构建
    
    Args:
        job_name: Job 名称
        build_number: 构建号
        jenkins: Jenkins 客户端 (可选)
        jjb: JJB 管理器 (可选)
        
    Returns:
        处理结果字典
    """
    jenkins = jenkins or create_jenkins_client()
    jjb = jjb or create_jjb_manager()
    
    log_info(
        "处理构建失败",
        job_name=job_name,
        build_number=build_number
    )
    
    # 步骤 1: 检查状态
    chain = STATE.get_chain(job_name)
    current_retry = chain["current_retry"]
    
    # 如果是新的失败 (status 不是 running)，开始新的自愈链
    if chain["status"] not in ["running"]:
        STATE.start_chain(job_name, build_number)
        current_retry = 0
    
    # 检查是否达到最大重试次数
    if current_retry >= Config.MAX_RETRY:
        STATE.mark_max_retry(job_name)
        log_warn(
            "已达最大修复次数，停止自愈",
            job_name=job_name,
            current_retry=current_retry,
            max_retry=Config.MAX_RETRY
        )
        return {
            "action": "stop",
            "reason": "max_retry_exceeded",
            "message": f"已达到最大修复次数 ({Config.MAX_RETRY})，请人工介入"
        }
    
    next_round = current_retry + 1
    log_info(
        f"开始第 {next_round}/{Config.MAX_RETRY} 轮自愈",
        job_name=job_name
    )
    
    # 步骤 2: 拉取 Jenkinsfile 和构建日志
    try:
        # 获取 Jenkinsfile
        jenkinsfile, source = get_current_jenkinsfile(job_name, jenkins, jjb)
        if not jenkinsfile:
            raise RuntimeError("无法获取 Jenkinsfile")
        
        # 获取构建日志
        log_tail = jenkins.get_build_log_tail(job_name, build_number, lines=200)
        
        log_info(
            "获取构建信息成功",
            job_name=job_name,
            jenkinsfile_length=len(jenkinsfile),
            log_length=len(log_tail),
            source=source
        )
        
    except Exception as e:
        log_error("拉取代码或日志失败", error=str(e))
        STATE.mark_failed(job_name, f"pull_failed: {e}")
        return {"action": "error", "reason": str(e)}
    
    # 步骤 3: AI 诊断与修复
    try:
        ai_result = ai_fix(jenkinsfile, log_tail, next_round, job_name)
        fixed_code = extract_fixed_code(ai_result)
        
        if not fixed_code:
            log_warn(
                "AI 无法生成有效修复代码",
                job_name=job_name,
                round=next_round
            )
            STATE.mark_failed(job_name, "ai_cannot_fix")
            return {
                "action": "stop",
                "reason": "ai_cannot_fix",
                "message": "AI 无法确定修复方案，请人工介入"
            }
        
        log_info(
            "AI 生成修复代码",
            job_name=job_name,
            round=next_round,
            code_length=len(fixed_code)
        )
        
    except Exception as e:
        log_error("AI 诊断失败", error=str(e))
        STATE.mark_failed(job_name, f"ai_error: {e}")
        return {"action": "error", "reason": f"ai_error: {e}"}
    
    # 步骤 4: 更新 JJB 配置
    try:
        update_success = False
        
        # 尝试使用 JJB 更新
        yaml_file = jjb.find_job_yaml(job_name)
        if yaml_file:
            # 更新 YAML 中的 dsl
            if jjb.update_dsl(yaml_file, fixed_code):
                # 执行 jenkins-jobs update
                if jjb.update_job_to_jenkins(yaml_file):
                    update_success = True
                    log_info("JJB 配置更新成功", job_name=job_name)
        
        # 如果 JJB 方式失败，记录但继续（AI 可能已修复，只是无法通过 JJB 更新）
        if not update_success:
            log_warn(
                "JJB 方式更新失败，可能需要手动更新",
                job_name=job_name
            )
            # 继续执行，至少触发构建
            
    except Exception as e:
        log_error("更新 Job 配置时出现异常", error=str(e))
        # 非致命错误，继续尝试触发构建
    
    # 步骤 5: 触发原 Job 重新构建
    try:
        jenkins.trigger_build(job_name)
        log_info("已触发原 Job 重新构建", job_name=job_name, round=next_round)
        
        # 更新状态
        STATE.increment_retry(
            job_name,
            next_round,
            dsl_preview=fixed_code[:200]
        )
        
        return {
            "action": "heal_triggered",
            "job_name": job_name,
            "round": next_round,
            "message": f"第 {next_round} 轮自愈已触发，等待构建结果..."
        }
        
    except Exception as e:
        log_error("触发构建失败", error=str(e))
        STATE.mark_failed(job_name, f"trigger_failed: {e}")
        return {"action": "error", "reason": f"trigger_failed: {e}"}


def handle_build_success(job_name: str, build_number: int) -> Dict[str, Any]:
    """
    处理构建成功事件
    
    Args:
        job_name: Job 名称
        build_number: 构建号
        
    Returns:
        处理结果字典
    """
    chain = STATE.get_chain(job_name)
    
    if chain["status"] == "running":
        # 这是一次成功的自愈
        STATE.mark_success(job_name)
        log_info(
            "自愈成功!",
            job_name=job_name,
            build_number=build_number,
            total_rounds=chain["current_retry"]
        )
        return {
            "action": "heal_success",
            "job_name": job_name,
            "rounds": chain["current_retry"],
            "message": f"自愈成功! 共尝试 {chain['current_retry']} 轮修复"
        }
    else:
        # 原始 Job 首次构建成功，无需动作
        log_info("原始 Job 构建成功，无需自愈", job_name=job_name)
        return {"action": "none", "reason": "original_success"}


# ==================== 主入口 ====================
def process_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    处理 Jenkins 构建事件（主入口）
    
    Args:
        event: 事件字典，包含:
            - jobName: Job 名称
            - buildNumber: 构建号
            - status: 构建状态 (SUCCESS/FAILURE 等)
            
    Returns:
        处理结果字典
    """
    job_name = event.get("jobName", "")
    build_number = event.get("buildNumber", "")
    status = event.get("status", "SUCCESS")
    
    if not job_name or not build_number:
        return {
            "action": "error",
            "reason": "missing_required_fields",
            "message": "缺少 jobName 或 buildNumber"
        }
    
    log_info(
        "处理构建事件",
        job_name=job_name,
        build_number=build_number,
        status=status
    )
    
    if status == "SUCCESS":
        return handle_build_success(job_name, int(build_number))
    else:
        # 处理失败（包括 FAILURE, ABORTED, UNSTABLE 等）
        return handle_build_failure(job_name, int(build_number))


def main():
    """命令行入口"""
    parser = argparse.ArgumentParser(
        description='CI/CD 自愈工具 - 自动诊断和修复 Jenkins 构建失败',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 处理一个失败事件
  python ci_selfheal.py --job-name "my-pipeline" --build-number 42 --status FAILURE
  
  # 从 JSON 文件读取事件
  python ci_selfheal.py --event-file event.json
  
  # 查看状态
  python ci_selfheal.py --status
        """
    )
    
    # 事件参数
    parser.add_argument('--job-name', type=str, help='Jenkins Job 名称')
    parser.add_argument('--build-number', type=int, help='构建号')
    parser.add_argument('--status', type=str, default='FAILURE', 
                        choices=['SUCCESS', 'FAILURE', 'ABORTED', 'UNSTABLE'],
                        help='构建状态')
    
    # 其他选项
    parser.add_argument('--event-file', type=str, help='包含事件数据的 JSON 文件路径')
    parser.add_argument('--status', action='store_true', dest='show_status',
                        help='显示当前自愈状态')
    parser.add_argument('--max-retry', type=int, default=Config.MAX_RETRY,
                        help=f'最大修复轮次 (默认: {Config.MAX_RETRY})')
    parser.add_argument('--model', type=str, default=Config.DEFAULT_MODEL,
                        help=f'AI 模型 (默认: {Config.DEFAULT_MODEL})')
    
    args = parser.parse_args()
    
    # 更新配置
    Config.MAX_RETRY = args.max_retry
    Config.DEFAULT_MODEL = args.model
    
    # 显示状态
    if args.show_status:
        state = STATE.load()
        print(json.dumps(state, indent=2, ensure_ascii=False))
        return
    
    # 构建事件
    event = {}
    
    if args.event_file:
        # 从文件读取
        with open(args.event_file, 'r', encoding='utf-8') as f:
            event = json.load(f)
    elif args.job_name and args.build_number:
        # 从命令行参数构建
        event = {
            "jobName": args.job_name,
            "buildNumber": args.build_number,
            "status": args.status
        }
    else:
        parser.error("需要提供 --job-name 和 --build-number，或 --event-file")
    
    # 处理事件
    result = process_event(event)
    
    # 输出结果
    print(json.dumps(result, indent=2, ensure_ascii=False))
    
    # 根据结果设置退出码
    if result.get("action") in ["error", "stop"]:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
