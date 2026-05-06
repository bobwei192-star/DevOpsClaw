#!/usr/bin/env python3
# ============================================================
# 文件: bridge_v3.py
# 名称: OpenClaw Jenkins Self-Healing Bridge v3
# 版本: 3.0.0 (高度自治 + JJB 版)
# 语言: Python 3.8+
# 
# 变更日志:
#   v3.0.0 (2025-06-04)
#   - 移除三级安全等级设计 (不再有 L1/L2/L3)
#   - 采用高度自治模式 (全自动运行，无 DRY_RUN)
#   - 闭环流程改为: 复用原 Job + JJB 配置管理
#   - 使用 Jenkins Job Builder (JJB) 管理 Job 配置
#   - 不再创建新 Job，而是更新原 Job 的配置
#   - 所有配置定义在 YAML 文件中，支持版本控制
#
# 闭环流程 (v3 高度自治):
#   1. Jenkins 构建失败 → WebHook 通知 Bridge
#   2. Bridge 从 JJB YAML 配置读取 Jenkinsfile
#   3. 调用 OpenClaw AI 诊断错误，生成修复代码
#   4. 更新 JJB YAML 配置文件中的 dsl
#   5. 执行 jenkins-jobs update 更新 Jenkins Job
#   6. 触发原 Job 重新构建
#   7. 等待构建结果，最多 5 轮修复
# ============================================================

import os
import sys
import json
import re
import logging
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

import requests
import yaml

# 导入 JJB 客户端
try:
    from jjb_client import JJBClient, update_job_config
    HAS_JJB_CLIENT = True
except ImportError:
    HAS_JJB_CLIENT = False
    logging.warning("未找到 jjb_client.py，将使用内置的 JJB 功能")


# ==================== 配置区 ====================
class Config:
    # Jenkins
    JENKINS_URL = os.getenv("JENKINS_URL", "http://127.0.0.1:8081/jenkins").rstrip('/')
    JENKINS_USER = os.getenv("JENKINS_USER", "admin")
    JENKINS_TOKEN = os.getenv("JENKINS_TOKEN", "")

    # 业务规则 (高度自治，无 DRY_RUN)
    MAX_RETRY = int(os.getenv("MAX_RETRY", "5"))
    
    # JJB 配置路径
    JJB_CONFIG_PATH = os.getenv("JJB_CONFIG_PATH", "./jjb-configs")
    
    # JJB INI 配置文件路径
    JJB_INI_PATH = os.getenv("JJB_INI_PATH", "./jjb-configs/jenkins_jobs.ini")

    # 服务配置
    PORT = int(os.getenv("BRIDGE_PORT", "5000"))
    STATE_FILE = os.getenv("STATE_FILE", "./.self-heal-state.json")
    LOG_FILE = os.getenv("LOG_FILE", "./bridge.log")

    # OpenClaw 配置
    OPENCLAW_CONTAINER = os.getenv("OPENCLAW_CONTAINER", "openclaw")
    DEFAULT_MODEL = os.getenv("DEFAULT_MODEL", "kimi-k2.5")
    
    # 模型名称映射
    MODEL_MAPPING = {
        "kimi-k2.5": "custom-api-moonshot-cn/kimi-k2.5",
        "deepseek-reasoner": "custom-api-deepseek-com/deepseek-reasoner",
    }


# ==================== 日志系统 ====================
def setup_logging():
    logger = logging.getLogger("bridge")
    logger.setLevel(logging.DEBUG)

    # 确保日志目录存在
    log_path = Path(Config.LOG_FILE)
    log_path.parent.mkdir(parents=True, exist_ok=True)

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
    """状态管理器 - 跟踪自愈流程的状态"""
    
    def __init__(self, filepath):
        self.filepath = Path(filepath)
        self.filepath.parent.mkdir(parents=True, exist_ok=True)
        self._data = None

    def load(self):
        if self._data is not None:
            return self._data
        try:
            with open(self.filepath, 'r', encoding='utf-8') as f:
                self._data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self._data = {
                "chains": {},  # job_name -> chain_state
                "version": "3.0.0"
            }
        return self._data

    def save(self):
        with open(self.filepath, 'w', encoding='utf-8') as f:
            json.dump(self._data, f, indent=2, ensure_ascii=False)

    def get_chain(self, job_name):
        """获取指定 Job 的自愈链状态"""
        return self.load()["chains"].get(job_name, {
            "current_retry": 0,
            "status": "idle",  # idle, running, success, failed, max_retry
            "history": [],
            "last_update": None
        })

    def start_chain(self, job_name, build_number):
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

    def increment_retry(self, job_name, round_num, new_dsl_preview=""):
        """增加重试次数"""
        def update(chain):
            chain["current_retry"] = round_num
            chain["status"] = "running"
            chain["last_update"] = datetime.now().isoformat()
            # 记录历史
            chain["history"].append({
                "round": round_num,
                "timestamp": datetime.now().isoformat(),
                "dsl_preview": new_dsl_preview[:200] if new_dsl_preview else ""
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

    def mark_success(self, job_name):
        """标记自愈成功"""
        def update(chain):
            chain["status"] = "success"
            chain["last_update"] = datetime.now().isoformat()

        self.load()
        if job_name in self._data["chains"]:
            update(self._data["chains"][job_name])
            self.save()
        log_info("自愈成功", job_name=job_name)

    def mark_failed(self, job_name, reason: str):
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

    def mark_max_retry(self, job_name):
        """标记达到最大重试次数"""
        def update(chain):
            chain["status"] = "max_retry"
            chain["last_update"] = datetime.now().isoformat()

        self.load()
        if job_name in self._data["chains"]:
            update(self._data["chains"][job_name])
            self.save()
        log_warn("达到最大重试次数", job_name=job_name)


STATE = StateManager(Config.STATE_FILE)


# ==================== 内置 JJB 功能 (当 jjb_client 不可用时使用) ====================
class BuiltinJJBClient:
    """内置 JJB 客户端 - 简化版"""
    
    def __init__(self, config_path: str = None):
        self.config_path = Path(config_path or Config.JJB_CONFIG_PATH)
        self.ini_path = Path(Config.JJB_INI_PATH)
        
        log_info(f"内置 JJB 客户端初始化", config_path=str(self.config_path))
    
    def find_job_yaml(self, job_name: str) -> Path | None:
        """查找 Job 对应的 YAML 配置文件"""
        # 策略 1: 精确匹配文件名
        yaml_files = [
            self.config_path / f"{job_name}.yaml",
            self.config_path / f"{job_name}.yml",
        ]
        
        for yaml_file in yaml_files:
            if yaml_file.exists():
                log_info(f"找到 Job 配置文件: {yaml_file}")
                return yaml_file
        
        # 策略 2: 在所有 YAML 文件中搜索
        all_yaml_files = list(self.config_path.glob("*.yaml")) + list(self.config_path.glob("*.yml"))
        
        for yaml_file in all_yaml_files:
            try:
                with open(yaml_file, 'r', encoding='utf-8') as f:
                    data = yaml.safe_load(f)
                
                if data is None:
                    continue
                
                # 搜索 job 定义
                if isinstance(data, list):
                    for item in data:
                        if isinstance(item, dict) and 'job' in item:
                            if item['job'].get('name') == job_name:
                                log_info(f"在 {yaml_file} 中找到 Job: {job_name}")
                                return yaml_file
                
                elif isinstance(data, dict) and 'job' in data:
                    if data['job'].get('name') == job_name:
                        log_info(f"在 {yaml_file} 中找到 Job: {job_name}")
                        return yaml_file
                        
            except Exception as e:
                log_warn(f"解析 YAML 文件失败", file=str(yaml_file), error=str(e))
                continue
        
        log_warn(f"未找到 Job 配置文件", job_name=job_name)
        return None
    
    def extract_dsl_from_yaml(self, yaml_file: Path) -> str | None:
        """从 YAML 配置中提取 dsl (Jenkinsfile)"""
        try:
            with open(yaml_file, 'r', encoding='utf-8') as f:
                data = yaml.safe_load(f)
            
            if data is None:
                return None
            
            # 递归查找 dsl
            def find_dsl(obj: any) -> str | None:
                if isinstance(obj, dict):
                    if 'dsl' in obj:
                        return obj['dsl']
                    if 'job' in obj:
                        return find_dsl(obj['job'])
                    if 'definition' in obj:
                        return find_dsl(obj['definition'])
                    for v in obj.values():
                        result = find_dsl(v)
                        if result is not None:
                            return result
                elif isinstance(obj, list):
                    for item in obj:
                        result = find_dsl(item)
                        if result is not None:
                            return result
                return None
            
            dsl = find_dsl(data)
            if dsl:
                log_info(f"从 YAML 提取 dsl 成功", file=str(yaml_file))
                return dsl.strip()
            else:
                log_warn(f"在 YAML 中未找到 dsl", file=str(yaml_file))
                return None
                
        except Exception as e:
            log_error(f"从 YAML 提取 dsl 失败", error=str(e))
            return None
    
    def update_dsl_in_yaml(self, yaml_file: Path, new_dsl: str) -> bool:
        """更新 YAML 配置中的 dsl"""
        try:
            with open(yaml_file, 'r', encoding='utf-8') as f:
                original_content = f.read()
            
            # 方法 1: 正则表达式替换 (保留格式和注释)
            # 匹配 dsl: | 后的多行内容
            # 这种模式更精确，不会破坏其他结构
            
            # 查找 dsl 行的缩进
            indent_match = re.search(r'^(\s*)dsl:', original_content, re.MULTILINE)
            if not indent_match:
                log_warn(f"未找到 dsl: 标记，尝试 YAML 解析方式")
                return self._update_dsl_yaml_parse(yaml_file, new_dsl)
            
            base_indent = indent_match.group(1)
            
            # 构建新的 dsl 内容（保持缩进）
            dsl_indent = base_indent + '  '
            new_dsl_lines = new_dsl.split('\n')
            indented_dsl = '\n'.join([
                dsl_indent + line if line.strip() else line 
                for line in new_dsl_lines
            ])
            
            # 构建替换内容
            replacement = f'{base_indent}dsl: |\n{indented_dsl}'
            
            # 执行替换 - 匹配 dsl: | 开头的块直到下一个非空缩进行
            # 模式: dsl: | 后跟任意字符，直到遇到 1) 文件结束 或 2) 新的非缩进行
            pattern = r'(^\s*dsl:\s*\|(?:[\s\S]*?))(?=\n\S|\Z)'
            
            new_content = re.sub(
                pattern,
                replacement,
                original_content,
                flags=re.DOTALL | re.MULTILINE
            )
            
            if new_content == original_content:
                log_warn("正则替换未生效，尝试 YAML 解析方式")
                return self._update_dsl_yaml_parse(yaml_file, new_dsl)
            
            # 写入更新后的内容
            with open(yaml_file, 'w', encoding='utf-8') as f:
                f.write(new_content)
            
            log_info(f"成功更新 YAML 配置", file=str(yaml_file))
            return True
            
        except Exception as e:
            log_error(f"更新 YAML 配置失败", error=str(e))
            return False
    
    def _update_dsl_yaml_parse(self, yaml_file: Path, new_dsl: str) -> bool:
        """使用 YAML 解析方式更新 (备用方法)"""
        try:
            with open(yaml_file, 'r', encoding='utf-8') as f:
                data = yaml.safe_load(f)
            
            if data is None:
                return False
            
            # 递归更新 dsl
            def update_dsl(obj: any) -> bool:
                if isinstance(obj, dict):
                    if 'dsl' in obj:
                        obj['dsl'] = new_dsl
                        return True
                    if 'job' in obj:
                        return update_dsl(obj['job'])
                    if 'definition' in obj:
                        return update_dsl(obj['definition'])
                    for v in obj.values():
                        if update_dsl(v):
                            return True
                elif isinstance(obj, list):
                    for item in obj:
                        if update_dsl(item):
                            return True
                return False
            
            if not update_dsl(data):
                log_warn("在 YAML 中未找到 dsl 字段")
                return False
            
            # 写入
            with open(yaml_file, 'w', encoding='utf-8') as f:
                yaml.dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
            
            log_info(f"通过 YAML 解析更新配置成功", file=str(yaml_file))
            return True
            
        except Exception as e:
            log_error(f"YAML 解析更新失败", error=str(e))
            return False
    
    def run_jjb_update(self, yaml_file: Path) -> bool:
        """执行 jenkins-jobs update 命令"""
        cmd = [
            'jenkins-jobs',
            '--conf', str(self.ini_path),
            'update',
            str(yaml_file)
        ]
        
        log_info(f"执行 JJB update 命令", cmd=' '.join(cmd))
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120
            )
            
            if result.returncode == 0:
                log_info(f"JJB update 成功", stdout=result.stdout[:500] if result.stdout else "")
                return True
            else:
                log_error(f"JJB update 失败", stderr=result.stderr[:500] if result.stderr else "")
                return False
                
        except subprocess.TimeoutExpired:
            log_error("JJB 命令执行超时")
            return False
        except FileNotFoundError:
            log_error("jenkins-jobs 命令未找到，请确保已安装 jenkins-job-builder")
            return False
        except Exception as e:
            log_error(f"JJB 命令执行异常", error=str(e))
            return False
    
    def update_job(self, job_name: str, new_dsl: str) -> bool:
        """
        更新 Job 的完整流程:
        1. 查找 YAML 配置文件
        2. 更新 YAML 中的 dsl
        3. 执行 jenkins-jobs update
        """
        log_info(f"开始更新 Job", job_name=job_name)
        
        # 步骤 1: 查找 YAML 配置
        yaml_file = self.find_job_yaml(job_name)
        if not yaml_file:
            log_error(f"无法找到 Job 配置文件", job_name=job_name)
            return False
        
        # 步骤 2: 更新 YAML 中的 dsl
        if not self.update_dsl_in_yaml(yaml_file, new_dsl):
            log_error(f"更新 YAML 配置失败", job_name=job_name)
            return False
        
        # 步骤 3: 执行 jenkins-jobs update
        if not self.run_jjb_update(yaml_file):
            log_error(f"执行 JJB update 失败", job_name=job_name)
            return False
        
        log_info(f"Job 更新成功", job_name=job_name)
        return True


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

    def trigger_build(self, job_name):
        """触发 Job 构建"""
        log_info("触发 Job 构建", job_name=job_name)
        return self.post(f"/job/{job_name}/build", data="")

    def get_build_log(self, job_name, build_number):
        """获取构建日志"""
        return self.get(f"/job/{job_name}/{build_number}/consoleText")


JENKINS = JenkinsClient()

# 初始化 JJB 客户端
if HAS_JJB_CLIENT:
    JJB = JJBClient(Config.JJB_CONFIG_PATH)
else:
    JJB = BuiltinJJBClient(Config.JJB_CONFIG_PATH)


# ==================== 代码提取与构建 ====================
def extract_jenkinsfile_from_jenkins(config_xml: str) -> str:
    """从 Jenkins config.xml 提取 Pipeline 脚本 (备用方法)"""
    cdata_match = re.search(r'<script>\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*</script>', config_xml)
    if cdata_match:
        return cdata_match.group(1).strip()

    normal_match = re.search(r'<script>([\s\S]*?)</script>', config_xml)
    if normal_match:
        return normal_match.group(1).strip()

    return ""


# ==================== AI 诊断引擎 (OpenClaw CLI) ====================
def extract_error_snippet(log: str) -> str:
    """从日志中提取关键错误片段"""
    lines = log.split('\n')
    snippets = []
    for i, line in enumerate(lines):
        if re.search(r'ERROR|FAILED|Exception|command not found|syntax error|Error|失败', line, re.I):
            start = max(0, i - 3)
            end = min(len(lines), i + 4)
            snippets.append('\n'.join(lines[start:end]))

    result = '\n---\n'.join(snippets[-3:])
    return result or log[-800:]


def build_prompt(jenkinsfile: str, log_tail: str, round_num: int, error_snippet: str, job_name: str) -> str:
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


def ai_fix_with_cli(prompt: str, model: str = None) -> str:
    """使用 OpenClaw CLI 调用 AI 模型"""
    model = model or Config.DEFAULT_MODEL
    
    # 模型名称映射
    full_model_name = Config.MODEL_MAPPING.get(model, model)

    try:
        # 构建 OpenClaw CLI 命令
        cmd = [
            "docker", "exec", Config.OPENCLAW_CONTAINER,
            "node", "openclaw.mjs",
            "infer", "model", "run",
            "--model", full_model_name,
            "--prompt", prompt
        ]

        log_info(f"调用 OpenClaw CLI", model=full_model_name)

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300  # 5 分钟超时
        )

        if result.returncode != 0:
            raise RuntimeError(f"OpenClaw CLI 失败: {result.stderr}")

        # 解析输出，提取 AI 回复
        output_lines = result.stdout.strip().split('\n')

        # 找到 "outputs:" 之后的行
        for i, line in enumerate(output_lines):
            if line.strip().startswith('outputs:') or line.strip().startswith('output:'):
                return '\n'.join(output_lines[i+1:]).strip()

        # 如果没有找到标记，返回最后几行
        return '\n'.join(output_lines[-15:]).strip()

    except Exception as e:
        log_error(f"OpenClaw CLI 调用失败", error=str(e))
        raise


def ai_fix(jenkinsfile: str, log_tail: str, round_num: int, job_name: str) -> str:
    """调用 AI 进行诊断和修复"""
    error_snippet = extract_error_snippet(log_tail)
    prompt = build_prompt(jenkinsfile, log_tail, round_num, error_snippet, job_name)

    log_info("调用 AI 诊断", round=round_num, log_length=len(log_tail), job_name=job_name)

    # 尝试多个模型
    models_to_try = [
        "kimi-k2.5",
        "deepseek-reasoner",
    ]

    last_error = None

    for model in models_to_try:
        try:
            log_info(f"尝试模型", model=model)
            result = ai_fix_with_cli(prompt, model)
            log_info(f"模型调用成功", model=model, response_length=len(result))
            return result
        except Exception as e:
            log_warn(f"模型调用失败", model=model, error=str(e))
            last_error = e
            continue

    raise RuntimeError(f"所有 AI 模型都不可用，最后一个错误: {last_error}")


def extract_fixed_code(ai_response: str) -> str | None:
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


# ==================== 核心处理逻辑 (v3 高度自治版) ====================
def get_current_jenkinsfile(job_name: str) -> str:
    """
    获取当前的 Jenkinsfile (Pipeline)
    优先从 JJB YAML 配置读取，其次从 Jenkins API 读取
    """
    # 方法 1: 从 JJB YAML 配置读取
    yaml_file = JJB.find_job_yaml(job_name)
    if yaml_file:
        dsl = JJB.extract_dsl_from_yaml(yaml_file)
        if dsl:
            log_info("从 JJB YAML 配置读取 Jenkinsfile 成功", job_name=job_name)
            return dsl
    
    # 方法 2: 从 Jenkins API 读取 (备用)
    log_warn("JJB YAML 配置读取失败，尝试从 Jenkins API 读取", job_name=job_name)
    try:
        config_xml = JENKINS.get(f"/job/{job_name}/config.xml")
        jenkinsfile = extract_jenkinsfile_from_jenkins(config_xml)
        if jenkinsfile:
            log_info("从 Jenkins API 读取 Jenkinsfile 成功", job_name=job_name)
            return jenkinsfile
    except Exception as e:
        log_error("从 Jenkins API 读取失败", error=str(e))
    
    raise RuntimeError(f"无法获取 Job 的 Jenkinsfile: {job_name}")


def handle_build(payload: dict) -> dict:
    """
    处理 Jenkins 构建事件 (v3 高度自治版)
    
    闭环流程:
    1. 检查构建状态
    2. 成功: 清理状态，标记成功
    3. 失败:
       a. 获取当前状态，检查重试次数
       b. 读取 Jenkinsfile
       c. 获取构建日志
       d. 调用 AI 诊断并生成修复代码
       e. 更新 JJB YAML 配置
       f. 执行 jenkins-jobs update
       g. 触发原 Job 重新构建
       h. 更新状态
    """
    job_name = payload.get("jobName", "")
    build_number = payload.get("buildNumber", "")
    status = payload.get("status", "SUCCESS")
    build_tag = payload.get("buildTag", "")
    is_openclaw = payload.get("isOpenclaw", False)
    retry_count = payload.get("retryCount", 0)

    log_info(
        "收到构建事件", 
        job_name=job_name, 
        build_number=build_number,
        status=status, 
        retry_count=retry_count, 
        is_openclaw=is_openclaw
    )

    # ========================================
    # 情况 1: 构建成功
    # ========================================
    if status == "SUCCESS":
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

    # ========================================
    # 情况 2: 构建失败 - 进入自愈流程
    # ========================================
    
    # 获取当前状态
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
        "开始第 {}/{} 轮自愈".format(next_round, Config.MAX_RETRY),
        job_name=job_name
    )

    # ========================================
    # 步骤 1: 拉取 Jenkinsfile 和构建日志
    # ========================================
    try:
        # 获取 Jenkinsfile (优先从 JJB YAML)
        jenkinsfile = get_current_jenkinsfile(job_name)
        if not jenkinsfile:
            raise RuntimeError("无法获取 Jenkinsfile")

        # 获取构建日志
        full_log = JENKINS.get_build_log(job_name, build_number)
        log_tail = '\n'.join(full_log.split('\n')[-200:])

        log_info(
            "获取构建信息成功",
            job_name=job_name,
            jenkinsfile_length=len(jenkinsfile),
            log_length=len(log_tail)
        )

    except Exception as e:
        log_error("拉取代码或日志失败", error=str(e))
        STATE.mark_failed(job_name, f"pull_failed: {e}")
        return {"action": "error", "reason": str(e)}

    # ========================================
    # 步骤 2: AI 诊断与修复
    # ========================================
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

    # ========================================
    # 步骤 3: 更新 JJB 配置并更新 Jenkins Job
    # ========================================
    try:
        # 尝试更新 JJB 配置
        update_success = False
        
        # 方法 1: 使用 JJB 客户端更新 YAML + jenkins-jobs update
        yaml_file = JJB.find_job_yaml(job_name)
        if yaml_file:
            # 更新 YAML 中的 dsl
            if JJB.update_dsl_in_yaml(yaml_file, fixed_code):
                # 执行 jenkins-jobs update
                if JJB.run_jjb_update(yaml_file):
                    update_success = True
                    log_info("JJB 配置更新成功", job_name=job_name)
        
        # 方法 2: 如果 JJB 方式失败，使用 Jenkins API 直接更新 (备用)
        if not update_success:
            log_warn("JJB 方式更新失败，尝试使用 Jenkins API 直接更新", job_name=job_name)
            # 这里可以添加通过 API 直接更新 config.xml 的逻辑
            # 但为了保持与设计文档一致，我们还是抛出错误
            raise RuntimeError("JJB 配置更新失败，无法继续自愈")

    except Exception as e:
        log_error("更新 Job 配置失败", error=str(e))
        STATE.mark_failed(job_name, f"update_job_failed: {e}")
        return {"action": "error", "reason": f"update_job_failed: {e}"}

    # ========================================
    # 步骤 4: 触发原 Job 重新构建
    # ========================================
    try:
        JENKINS.trigger_build(job_name)
        log_info("已触发原 Job 重新构建", job_name=job_name, round=next_round)

        # 更新状态
        STATE.increment_retry(
            job_name, 
            next_round,
            new_dsl_preview=fixed_code[:200]
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
                "version": "3.0.0",
                "mode": "高度自治 (High Autonomy)",
                "max_retry": Config.MAX_RETRY,
                "jjb_config_path": Config.JJB_CONFIG_PATH,
                "jenkins_url": Config.JENKINS_URL
            })
        elif parsed.path == '/state':
            self._send_json(200, STATE.load())
        elif parsed.path == '/api/jobs':
            # 获取所有有自愈记录的 Job
            state_data = STATE.load()
            jobs = []
            for job_name, chain in state_data.get("chains", {}).items():
                jobs.append({
                    "name": job_name,
                    "status": chain.get("status", "idle"),
                    "current_retry": chain.get("current_retry", 0),
                    "last_update": chain.get("last_update"),
                    "history_count": len(chain.get("history", []))
                })
            self._send_json(200, {"jobs": jobs})
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
        
        elif parsed.path == '/api/reset':
            # 重置指定 Job 的状态 (调试用)
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length > 0:
                body = self.rfile.read(content_length).decode('utf-8')
                payload = json.loads(body)
                job_name = payload.get("job_name")
                if job_name:
                    STATE.load()
                    if job_name in STATE._data["chains"]:
                        del STATE._data["chains"][job_name]
                        STATE.save()
                    self._send_json(200, {"status": "ok", "message": f"已重置 Job: {job_name}"})
                else:
                    self._send_json(400, {"error": "job_name required"})
            else:
                self._send_json(400, {"error": "body required"})
        
        else:
            self._send_json(404, {"error": "Not Found"})


# ==================== 启动 ====================
def main():
    if not Config.JENKINS_TOKEN:
        print("错误: 未设置 JENKINS_TOKEN 环境变量")
        sys.exit(1)

    log_info(
        "Bridge v3 启动中...", 
        port=Config.PORT,
        max_retry=Config.MAX_RETRY,
        jjb_config_path=Config.JJB_CONFIG_PATH
    )

    server = HTTPServer(('0.0.0.0', Config.PORT), BridgeHandler)

    print(f"""
╔══════════════════════════════════════════════════════════════════════════════╗
║       OpenClaw Jenkins Self-Healing Bridge v3.0.0 (高度自治版)                 ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  模式:         高度自治 (High Autonomy) - 全自动运行                           ║
║  监听端口:     {str(Config.PORT).ljust(53)}║
║  Jenkins:      {Config.JENKINS_URL[:50].ljust(53)}║
║  JJB 配置:     {Config.JJB_CONFIG_PATH[:50].ljust(53)}║
║  最大修复轮次: {str(Config.MAX_RETRY).ljust(53)}║
╠══════════════════════════════════════════════════════════════════════════════╣
║  健康检查:     GET  http://127.0.0.1:{Config.PORT}/health                        ║
║  状态查看:     GET  http://127.0.0.1:{Config.PORT}/state                         ║
║  WebHook:      POST http://127.0.0.1:{Config.PORT}/webhook/jenkins              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  闭环流程 (v3 高度自治):                                                          ║
║    Jenkins 构建失败 → AI 诊断 → 修复代码 → 更新 JJB YAML → jenkins-jobs update  ║
║    → 触发原 Job 重新构建 → 等待结果 → 最多 {Config.MAX_RETRY} 轮                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
""")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log_info("Bridge 已停止")
        server.shutdown()


if __name__ == '__main__':
    main()
