#!/usr/bin/env python3
# ============================================================
# 文件: jenkins_client.py
# 名称: Jenkins API 客户端
# 版本: 2.0.0 (Skill 架构版)
# 功能: 封装 Jenkins REST API 操作
# ============================================================

import os
import re
import logging
from typing import Optional, Dict, Any

import requests

logger = logging.getLogger("jenkins_client")


class JenkinsClient:
    """Jenkins API 客户端"""
    
    def __init__(
        self,
        url: str = None,
        username: str = None,
        token: str = None
    ):
        """
        初始化 Jenkins 客户端
        
        Args:
            url: Jenkins URL (默认从环境变量 JENKINS_URL 读取)
            username: Jenkins 用户名 (默认从环境变量 JENKINS_USER 读取)
            token: Jenkins API Token (默认从环境变量 JENKINS_TOKEN 读取)
        """
        self.url = (url or os.getenv("JENKINS_URL", "http://127.0.0.1:8081/jenkins")).rstrip('/')
        self.username = username or os.getenv("JENKINS_USER", "admin")
        self.token = token or os.getenv("JENKINS_TOKEN", "")
        
        self.session = requests.Session()
        self.session.auth = (self.username, self.token)
        self.session.timeout = 30
        self._crumb = None
        
        logger.info(f"Jenkins 客户端初始化: {self.url}")
    
    def _get_crumb(self) -> Dict[str, str]:
        """获取 CSRF crumb (Jenkins 安全保护)"""
        if self._crumb is not None:
            return self._crumb
        
        try:
            r = self.session.get(f"{self.url}/crumbIssuer/api/json")
            if r.status_code == 200:
                data = r.json()
                self._crumb = {data["crumbRequestField"]: data["crumb"]}
                logger.debug("获取 CSRF crumb 成功")
                return self._crumb
        except Exception as e:
            logger.warning(f"获取 CSRF crumb 失败: {e}")
        
        return {}
    
    def get(self, path: str) -> str:
        """
        发送 GET 请求到 Jenkins
        
        Args:
            path: API 路径 (例如: /job/my-job/config.xml)
            
        Returns:
            响应内容
        """
        headers = self._get_crumb()
        url = f"{self.url}{path}"
        
        logger.debug(f"GET {url}")
        r = self.session.get(url, headers=headers, timeout=10)
        r.raise_for_status()
        return r.text
    
    def post(
        self,
        path: str,
        data: str = None,
        content_type: str = 'application/x-www-form-urlencoded'
    ) -> requests.Response:
        """
        发送 POST 请求到 Jenkins
        
        Args:
            path: API 路径
            data: 请求体数据
            content_type: Content-Type
            
        Returns:
            Response 对象
        """
        headers = {
            'Content-Type': content_type,
            **self._get_crumb()
        }
        url = f"{self.url}{path}"
        
        logger.debug(f"POST {url}")
        r = self.session.post(url, data=data, headers=headers, timeout=30)
        
        if r.status_code >= 400:
            error_msg = f"Jenkins API 错误: {r.status_code} {r.text[:500]}"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
        
        return r
    
    # ========================================
    # Job 相关操作
    # ========================================
    
    def get_job_config(self, job_name: str) -> str:
        """
        获取 Job 的 config.xml
        
        Args:
            job_name: Job 名称
            
        Returns:
            config.xml 内容
        """
        logger.info(f"获取 Job 配置: {job_name}")
        return self.get(f"/job/{job_name}/config.xml")
    
    def extract_jenkinsfile(self, config_xml: str) -> Optional[str]:
        """
        从 config.xml 提取 Pipeline 脚本 (Jenkinsfile)
        
        Args:
            config_xml: Job 的 config.xml 内容
            
        Returns:
            Jenkinsfile 内容，如果不是 Pipeline Job 返回 None
        """
        # 尝试匹配 CDATA 包裹的脚本
        cdata_match = re.search(
            r'<script>\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*</script>',
            config_xml
        )
        if cdata_match:
            return cdata_match.group(1).strip()
        
        # 尝试匹配普通文本脚本
        normal_match = re.search(
            r'<script>([\s\S]*?)</script>',
            config_xml
        )
        if normal_match:
            return normal_match.group(1).strip()
        
        logger.warning("无法从 config.xml 提取 Jenkinsfile")
        return None
    
    def get_build_log(self, job_name: str, build_number: int) -> str:
        """
        获取构建的控制台日志
        
        Args:
            job_name: Job 名称
            build_number: 构建号
            
        Returns:
            完整的控制台输出
        """
        logger.info(f"获取构建日志: {job_name} #{build_number}")
        return self.get(f"/job/{job_name}/{build_number}/consoleText")
    
    def get_build_log_tail(self, job_name: str, build_number: int, lines: int = 200) -> str:
        """
        获取构建日志的最后 N 行
        
        Args:
            job_name: Job 名称
            build_number: 构建号
            lines: 获取的行数
            
        Returns:
            日志的最后 N 行
        """
        full_log = self.get_build_log(job_name, build_number)
        log_lines = full_log.split('\n')
        return '\n'.join(log_lines[-lines:])
    
    def trigger_build(self, job_name: str, parameters: Dict[str, Any] = None) -> bool:
        """
        触发 Job 构建
        
        Args:
            job_name: Job 名称
            parameters: 构建参数 (可选)
            
        Returns:
            是否成功触发
        """
        logger.info(f"触发构建: {job_name}")
        
        try:
            if parameters:
                # 带参数的构建
                import urllib.parse
                query_string = urllib.parse.urlencode(parameters)
                self.post(f"/job/{job_name}/buildWithParameters?{query_string}")
            else:
                # 普通构建
                self.post(f"/job/{job_name}/build")
            
            logger.info(f"构建触发成功: {job_name}")
            return True
            
        except Exception as e:
            logger.error(f"触发构建失败: {e}")
            return False
    
    def get_build_info(self, job_name: str, build_number: int) -> Dict[str, Any]:
        """
        获取构建的详细信息
        
        Args:
            job_name: Job 名称
            build_number: 构建号
            
        Returns:
            构建信息字典
        """
        try:
            response = self.get(f"/job/{job_name}/{build_number}/api/json")
            import json
            return json.loads(response)
        except Exception as e:
            logger.error(f"获取构建信息失败: {e}")
            return {}
    
    def is_building(self, job_name: str, build_number: int) -> bool:
        """
        检查构建是否正在进行中
        
        Args:
            job_name: Job 名称
            build_number: 构建号
            
        Returns:
            是否正在构建
        """
        info = self.get_build_info(job_name, build_number)
        return info.get("building", False)
    
    def get_build_result(self, job_name: str, build_number: int) -> Optional[str]:
        """
        获取构建结果
        
        Args:
            job_name: Job 名称
            build_number: 构建号
            
        Returns:
            构建结果: SUCCESS, FAILURE, ABORTED, UNSTABLE 等
            如果正在构建返回 None
        """
        info = self.get_build_info(job_name, build_number)
        if info.get("building"):
            return None
        return info.get("result")
    
    def get_last_build_number(self, job_name: str) -> Optional[int]:
        """
        获取 Job 的最后一个构建号
        
        Args:
            job_name: Job 名称
            
        Returns:
            最后一个构建号，如果没有构建返回 None
        """
        try:
            response = self.get(f"/job/{job_name}/api/json")
            import json
            data = json.loads(response)
            builds = data.get("builds", [])
            if builds:
                return builds[0].get("number")
        except Exception as e:
            logger.error(f"获取最后构建号失败: {e}")
        
        return None


# ========================================
# 便捷函数
# ========================================

def create_jenkins_client() -> JenkinsClient:
    """
    从环境变量创建 Jenkins 客户端
    
    Returns:
        JenkinsClient 实例
    """
    return JenkinsClient()


def get_failure_details(
    job_name: str,
    build_number: int,
    jenkins: JenkinsClient = None
) -> Dict[str, Any]:
    """
    获取构建失败的详细信息
    
    Args:
        job_name: Job 名称
        build_number: 构建号
        jenkins: Jenkins 客户端实例 (可选)
        
    Returns:
        包含 jenkinsfile、log_tail、error_snippet 的字典
    """
    jenkins = jenkins or create_jenkins_client()
    
    # 1. 获取当前 Jenkinsfile
    config_xml = jenkins.get_job_config(job_name)
    jenkinsfile = jenkins.extract_jenkinsfile(config_xml)
    
    # 2. 获取构建日志
    log_tail = jenkins.get_build_log_tail(job_name, build_number, lines=200)
    
    # 3. 提取错误片段
    error_snippet = extract_error_snippet(log_tail)
    
    return {
        "jenkinsfile": jenkinsfile,
        "log_tail": log_tail,
        "error_snippet": error_snippet,
        "job_name": job_name,
        "build_number": build_number
    }


def extract_error_snippet(log: str) -> str:
    """
    从日志中提取关键错误片段
    
    Args:
        log: 完整日志
        
    Returns:
        关键错误片段
    """
    lines = log.split('\n')
    snippets = []
    
    # 错误关键词
    error_patterns = [
        r'ERROR', r'FAILED', r'Exception', r'Error',
        r'command not found', r'syntax error', r'失败',
        r'Permission denied', r'No such file', r'not found'
    ]
    
    for i, line in enumerate(lines):
        for pattern in error_patterns:
            if re.search(pattern, line, re.I):
                start = max(0, i - 3)
                end = min(len(lines), i + 4)
                snippets.append('\n'.join(lines[start:end]))
                break
    
    # 最多返回最近的 3 个错误片段
    result = '\n---\n'.join(snippets[-3:])
    
    # 如果没有找到错误，返回日志的最后部分
    return result or log[-800:]
