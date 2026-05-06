#!/usr/bin/env python3
# ============================================================
# 文件: jjb_client.py
# 名称: Jenkins Job Builder (JJB) 客户端
# 版本: 1.0.0
# 功能: 管理 JJB YAML 配置文件，执行 jenkins-jobs 命令
# ============================================================

import os
import re
import yaml
import subprocess
import logging
from pathlib import Path
from typing import Optional, Dict, Any, List

logger = logging.getLogger("jjb_client")


class JJBClient:
    """Jenkins Job Builder 客户端"""
    
    def __init__(self, config_path: str = None):
        """
        初始化 JJB 客户端
        
        Args:
            config_path: JJB 配置文件目录路径
        """
        self.config_path = Path(config_path or os.getenv("JJB_CONFIG_PATH", "./jjb-configs"))
        self.jenkins_url = os.getenv("JENKINS_URL", "http://127.0.0.1:8081/jenkins")
        self.jenkins_user = os.getenv("JENKINS_USER", "admin")
        self.jenkins_token = os.getenv("JENKINS_TOKEN", "")
        
        # JJB 配置文件路径
        self.ini_path = self.config_path / "jenkins_jobs.ini"
        
        logger.info(f"JJB 客户端初始化完成, 配置路径: {self.config_path}")
    
    def find_job_yaml(self, job_name: str) -> Optional[Path]:
        """
        根据 Job 名称查找对应的 YAML 配置文件
        
        Args:
            job_name: Jenkins Job 名称
            
        Returns:
            YAML 文件路径，如果未找到返回 None
        """
        # 搜索策略:
        # 1. 查找 {job_name}.yaml
        # 2. 查找 {job_name}.yml
        # 3. 在所有 YAML 文件中搜索 job.name == job_name
        
        # 策略 1: 精确匹配文件名
        yaml_files = [
            self.config_path / f"{job_name}.yaml",
            self.config_path / f"{job_name}.yml",
        ]
        
        for yaml_file in yaml_files:
            if yaml_file.exists():
                logger.info(f"找到 Job 配置文件: {yaml_file}")
                return yaml_file
        
        # 策略 2: 在所有 YAML 文件中搜索
        all_yaml_files = list(self.config_path.glob("*.yaml")) + list(self.config_path.glob("*.yml"))
        
        for yaml_file in all_yaml_files:
            try:
                with open(yaml_file, 'r', encoding='utf-8') as f:
                    data = yaml.safe_load(f)
                
                if data is None:
                    continue
                
                # JJB 配置通常是一个列表
                if isinstance(data, list):
                    for item in data:
                        if isinstance(item, dict) and 'job' in item:
                            job_config = item['job']
                            if job_config.get('name') == job_name:
                                logger.info(f"在 {yaml_file} 中找到 Job: {job_name}")
                                return yaml_file
                
                # 也可能是字典形式
                elif isinstance(data, dict) and 'job' in data:
                    if data['job'].get('name') == job_name:
                        logger.info(f"在 {yaml_file} 中找到 Job: {job_name}")
                        return yaml_file
                        
            except Exception as e:
                logger.warning(f"解析 YAML 文件失败 {yaml_file}: {e}")
                continue
        
        logger.warning(f"未找到 Job 配置文件: {job_name}")
        return None
    
    def extract_dsl_from_yaml(self, yaml_file: Path) -> Optional[str]:
        """
        从 YAML 配置文件中提取 dsl (Jenkinsfile) 内容
        
        Args:
            yaml_file: YAML 文件路径
            
        Returns:
            dsl 内容字符串，如果未找到返回 None
        """
        try:
            with open(yaml_file, 'r', encoding='utf-8') as f:
                data = yaml.safe_load(f)
            
            if data is None:
                return None
            
            # 遍历查找 job 配置中的 dsl
            def find_dsl(obj: Any) -> Optional[str]:
                if isinstance(obj, dict):
                    if 'dsl' in obj:
                        return obj['dsl']
                    if 'job' in obj:
                        return find_dsl(obj['job'])
                    # 也可能在 definition 中
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
                logger.info(f"从 {yaml_file} 提取 dsl 成功")
                return dsl.strip()
            else:
                logger.warning(f"在 {yaml_file} 中未找到 dsl")
                return None
                
        except Exception as e:
            logger.error(f"从 YAML 提取 dsl 失败: {e}")
            return None
    
    def update_dsl_in_yaml(self, yaml_file: Path, new_dsl: str) -> bool:
        """
        更新 YAML 配置文件中的 dsl 内容
        
        Args:
            yaml_file: YAML 文件路径
            new_dsl: 新的 dsl (Jenkinsfile) 内容
            
        Returns:
            是否更新成功
        """
        try:
            # 读取原始文件内容
            with open(yaml_file, 'r', encoding='utf-8') as f:
                original_content = f.read()
            
            # 方法 1: 使用正则表达式直接替换 dsl 块 (保留注释和格式)
            # JJB YAML 中 dsl 通常格式为:
            # dsl: |
            #   pipeline {
            #     ...
            #   }
            
            # 匹配 dsl: | 开头的多行块
            # 这种方式更精确，不会破坏 YAML 的其他结构
            
            # 模式 1: dsl: | 后跟缩进的内容
            # 查找 dsl: | 行，然后捕获所有后续缩进相同或更多的行
            pattern = r'(^\s*dsl:\s*\|.*?)(?=\n\S|\Z)'
            
            # 准备新的 dsl 内容
            # 需要保持相同的缩进
            # 首先查找原始 dsl 的缩进级别
            indent_match = re.search(r'^(\s*)dsl:', original_content, re.MULTILINE)
            base_indent = indent_match.group(1) if indent_match else ''
            
            # 新的 dsl 内容需要在每行前添加缩进 (基础缩进 + 2 空格)
            dsl_indent = base_indent + '  '
            new_dsl_lines = new_dsl.split('\n')
            indented_dsl = '\n'.join([dsl_indent + line if line.strip() else line for line in new_dsl_lines])
            
            # 构建替换内容
            replacement = f'{base_indent}dsl: |\n{indented_dsl}'
            
            # 执行替换
            new_content = re.sub(
                pattern,
                replacement,
                original_content,
                flags=re.DOTALL | re.MULTILINE
            )
            
            # 如果没有匹配到，尝试方法 2: 使用 YAML 解析后重写
            if new_content == original_content:
                logger.warning("正则替换未生效，尝试 YAML 解析方式")
                return self._update_dsl_yaml_parse(yaml_file, new_dsl)
            
            # 写入更新后的内容
            with open(yaml_file, 'w', encoding='utf-8') as f:
                f.write(new_content)
            
            logger.info(f"成功更新 YAML 配置: {yaml_file}")
            return True
            
        except Exception as e:
            logger.error(f"更新 YAML 配置失败: {e}")
            return False
    
    def _update_dsl_yaml_parse(self, yaml_file: Path, new_dsl: str) -> bool:
        """
        使用 YAML 解析方式更新 dsl (备用方法)
        
        Args:
            yaml_file: YAML 文件路径
            new_dsl: 新的 dsl 内容
            
        Returns:
            是否更新成功
        """
        try:
            with open(yaml_file, 'r', encoding='utf-8') as f:
                data = yaml.safe_load(f)
            
            if data is None:
                return False
            
            # 递归更新 dsl
            def update_dsl(obj: Any) -> bool:
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
                logger.warning("在 YAML 中未找到 dsl 字段")
                return False
            
            # 写入更新后的 YAML
            with open(yaml_file, 'w', encoding='utf-8') as f:
                yaml.dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
            
            logger.info(f"成功通过 YAML 解析更新配置: {yaml_file}")
            return True
            
        except Exception as e:
            logger.error(f"YAML 解析更新失败: {e}")
            return False
    
    def run_jjb_command(self, command: str, yaml_file: Path = None) -> bool:
        """
        执行 jenkins-jobs 命令
        
        Args:
            command: 命令类型 ('update', 'test', 'delete' 等)
            yaml_file: YAML 文件路径 (可选)
            
        Returns:
            命令执行是否成功
        """
        # 构建命令
        cmd = [
            'jenkins-jobs',
            '--conf', str(self.ini_path),
            command
        ]
        
        if yaml_file:
            cmd.append(str(yaml_file))
        
        logger.info(f"执行 JJB 命令: {' '.join(cmd)}")
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120
            )
            
            if result.returncode == 0:
                logger.info(f"JJB 命令执行成功: {result.stdout}")
                return True
            else:
                logger.error(f"JJB 命令执行失败: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            logger.error("JJB 命令执行超时")
            return False
        except Exception as e:
            logger.error(f"JJB 命令执行异常: {e}")
            return False
    
    def update_job(self, job_name: str, new_dsl: str) -> bool:
        """
        更新指定 Job 的配置
        
        完整流程:
        1. 查找 Job 对应的 YAML 配置文件
        2. 更新 YAML 文件中的 dsl 内容
        3. 执行 jenkins-jobs update 更新到 Jenkins
        
        Args:
            job_name: Job 名称
            new_dsl: 新的 Jenkinsfile (dsl) 内容
            
        Returns:
            是否更新成功
        """
        logger.info(f"开始更新 Job: {job_name}")
        
        # 步骤 1: 查找 YAML 配置文件
        yaml_file = self.find_job_yaml(job_name)
        if not yaml_file:
            logger.error(f"无法找到 Job 配置文件: {job_name}")
            return False
        
        # 步骤 2: 更新 YAML 文件中的 dsl
        if not self.update_dsl_in_yaml(yaml_file, new_dsl):
            logger.error(f"更新 YAML 配置失败: {job_name}")
            return False
        
        # 步骤 3: 执行 jenkins-jobs update
        if not self.run_jjb_command('update', yaml_file):
            logger.error(f"执行 JJB update 失败: {job_name}")
            return False
        
        logger.info(f"Job 更新成功: {job_name}")
        return True
    
    def test_job(self, job_name: str) -> bool:
        """
        测试 Job 配置 (不实际更新 Jenkins)
        
        Args:
            job_name: Job 名称
            
        Returns:
            配置是否有效
        """
        yaml_file = self.find_job_yaml(job_name)
        if not yaml_file:
            return False
        
        return self.run_jjb_command('test', yaml_file)
    
    def get_all_jobs(self) -> List[str]:
        """
        获取配置目录中所有定义的 Job 名称
        
        Returns:
            Job 名称列表
        """
        jobs = []
        
        all_yaml_files = list(self.config_path.glob("*.yaml")) + list(self.config_path.glob("*.yml"))
        
        for yaml_file in all_yaml_files:
            try:
                with open(yaml_file, 'r', encoding='utf-8') as f:
                    data = yaml.safe_load(f)
                
                if data is None:
                    continue
                
                def extract_jobs(obj: Any):
                    if isinstance(obj, dict):
                        if 'job' in obj:
                            job_name = obj['job'].get('name')
                            if job_name:
                                jobs.append(job_name)
                        for v in obj.values():
                            extract_jobs(v)
                    elif isinstance(obj, list):
                        for item in obj:
                            extract_jobs(item)
                
                extract_jobs(data)
                
            except Exception as e:
                logger.warning(f"解析 YAML 文件失败 {yaml_file}: {e}")
                continue
        
        return list(set(jobs))  # 去重


# 便捷函数
def update_job_config(job_name: str, new_dsl: str, config_path: str = None) -> bool:
    """
    更新 Job 配置的便捷函数
    
    Args:
        job_name: Job 名称
        new_dsl: 新的 Jenkinsfile 内容
        config_path: JJB 配置路径 (可选)
        
    Returns:
        是否更新成功
    """
    client = JJBClient(config_path)
    return client.update_job(job_name, new_dsl)
