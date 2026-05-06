#!/usr/bin/env python3
# ============================================================
# 文件: jjb_manager.py
# 名称: Jenkins Job Builder (JJB) 配置管理器
# 版本: 2.0.0 (Skill 架构版)
# 功能: 管理 JJB YAML 配置文件，执行 jenkins-jobs 命令
# ============================================================

import os
import re
import subprocess
import logging
from pathlib import Path
from typing import Optional, Dict, Any, List

import yaml

logger = logging.getLogger("jjb_manager")


class JJBManager:
    """Jenkins Job Builder 配置管理器"""
    
    def __init__(
        self,
        config_path: str = None,
        ini_path: str = None
    ):
        """
        初始化 JJB 管理器
        
        Args:
            config_path: JJB YAML 配置文件目录路径
            ini_path: JJB jenkins_jobs.ini 配置文件路径
        """
        self.config_path = Path(
            config_path or 
            os.getenv("JJB_CONFIG_PATH", "./jjb-configs")
        )
        
        self.ini_path = Path(
            ini_path or
            os.getenv("JJB_INI_PATH", "./jjb-configs/jenkins_jobs.ini")
        )
        
        logger.info(f"JJB 管理器初始化: config_path={self.config_path}, ini_path={self.ini_path}")
    
    # ========================================
    # YAML 配置文件查找和读取
    # ========================================
    
    def find_job_yaml(self, job_name: str) -> Optional[Path]:
        """
        根据 Job 名称查找对应的 YAML 配置文件
        
        搜索策略:
        1. 查找 {job_name}.yaml 或 {job_name}.yml
        2. 在所有 YAML 文件中搜索 job.name == job_name
        
        Args:
            job_name: Jenkins Job 名称
            
        Returns:
            YAML 文件路径，如果未找到返回 None
        """
        logger.info(f"查找 Job 配置文件: {job_name}")
        
        # 策略 1: 精确匹配文件名
        yaml_files = [
            self.config_path / f"{job_name}.yaml",
            self.config_path / f"{job_name}.yml",
        ]
        
        for yaml_file in yaml_files:
            if yaml_file.exists():
                logger.info(f"通过文件名找到配置: {yaml_file}")
                return yaml_file
        
        # 策略 2: 在所有 YAML 文件中搜索
        all_yaml_files = list(self.config_path.glob("*.yaml")) + \
                         list(self.config_path.glob("*.yml"))
        
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
                            if item['job'].get('name') == job_name:
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
    
    def extract_dsl(self, yaml_file: Path) -> Optional[str]:
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
            
            # 递归查找 dsl 字段
            def find_dsl(obj: Any) -> Optional[str]:
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
                logger.info(f"从 {yaml_file} 提取 dsl 成功，长度: {len(dsl)}")
                return dsl.strip()
            else:
                logger.warning(f"在 {yaml_file} 中未找到 dsl 字段")
                return None
                
        except Exception as e:
            logger.error(f"从 YAML 提取 dsl 失败: {e}")
            return None
    
    def get_job_dsl(self, job_name: str) -> Optional[str]:
        """
        获取指定 Job 的当前 Jenkinsfile (dsl)
        
        Args:
            job_name: Job 名称
            
        Returns:
            Jenkinsfile 内容，如果未找到返回 None
        """
        yaml_file = self.find_job_yaml(job_name)
        if yaml_file:
            return self.extract_dsl(yaml_file)
        return None
    
    # ========================================
    # YAML 配置文件更新
    # ========================================
    
    def update_dsl(self, yaml_file: Path, new_dsl: str) -> bool:
        """
        更新 YAML 配置文件中的 dsl 内容
        
        优先使用正则表达式替换（保留格式和注释），
        失败时使用 YAML 解析重写。
        
        Args:
            yaml_file: YAML 文件路径
            new_dsl: 新的 dsl (Jenkinsfile) 内容
            
        Returns:
            是否更新成功
        """
        try:
            logger.info(f"更新 YAML 配置中的 dsl: {yaml_file}")
            
            with open(yaml_file, 'r', encoding='utf-8') as f:
                original_content = f.read()
            
            # 方法 1: 正则表达式替换 (保留格式和注释)
            # 匹配 dsl: | 开头的多行块
            
            # 查找 dsl 行的缩进
            indent_match = re.search(r'^(\s*)dsl:', original_content, re.MULTILINE)
            if not indent_match:
                logger.warning("未找到 dsl: 标记，尝试 YAML 解析方式")
                return self._update_dsl_yaml_parse(yaml_file, new_dsl)
            
            base_indent = indent_match.group(1)
            
            # 构建新的 dsl 内容（保持缩进）
            # dsl: | 后面的内容需要比 dsl: 行多 2 个空格缩进
            dsl_indent = base_indent + '  '
            new_dsl_lines = new_dsl.split('\n')
            indented_dsl = '\n'.join([
                dsl_indent + line if line.strip() else line
                for line in new_dsl_lines
            ])
            
            # 构建替换内容
            replacement = f'{base_indent}dsl: |\n{indented_dsl}'
            
            # 执行替换
            # 模式: dsl: | 后跟任意字符，直到遇到下一个非缩进行或文件结束
            pattern = r'(^\s*dsl:\s*\|(?:[\s\S]*?))(?=\n\S|\Z)'
            
            new_content = re.sub(
                pattern,
                replacement,
                original_content,
                flags=re.DOTALL | re.MULTILINE
            )
            
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
        
        注意: 这种方式会丢失注释和格式
        
        Args:
            yaml_file: YAML 文件路径
            new_dsl: 新的 dsl 内容
            
        Returns:
            是否更新成功
        """
        try:
            logger.info(f"使用 YAML 解析方式更新: {yaml_file}")
            
            with open(yaml_file, 'r', encoding='utf-8') as f:
                data = yaml.safe_load(f)
            
            if data is None:
                logger.error("YAML 文件内容为空")
                return False
            
            # 递归更新 dsl
            def update_dsl_field(obj: Any) -> bool:
                if isinstance(obj, dict):
                    if 'dsl' in obj:
                        obj['dsl'] = new_dsl
                        return True
                    if 'job' in obj:
                        return update_dsl_field(obj['job'])
                    if 'definition' in obj:
                        return update_dsl_field(obj['definition'])
                    for v in obj.values():
                        if update_dsl_field(v):
                            return True
                elif isinstance(obj, list):
                    for item in obj:
                        if update_dsl_field(item):
                            return True
                return False
            
            if not update_dsl_field(data):
                logger.warning("在 YAML 中未找到 dsl 字段")
                return False
            
            # 写入更新后的 YAML
            with open(yaml_file, 'w', encoding='utf-8') as f:
                yaml.dump(
                    data, 
                    f, 
                    allow_unicode=True, 
                    default_flow_style=False, 
                    sort_keys=False
                )
            
            logger.info(f"通过 YAML 解析更新配置成功: {yaml_file}")
            return True
            
        except Exception as e:
            logger.error(f"YAML 解析更新失败: {e}")
            return False
    
    # ========================================
    # jenkins-jobs 命令执行
    # ========================================
    
    def run_jjb_command(
        self,
        command: str,
        yaml_file: Path = None,
        timeout: int = 120
    ) -> bool:
        """
        执行 jenkins-jobs 命令
        
        Args:
            command: 命令类型 ('update', 'test', 'delete' 等)
            yaml_file: YAML 文件路径 (可选)
            timeout: 超时时间（秒）
            
        Returns:
            命令执行是否成功
        """
        cmd = [
            'jenkins-jobs',
            '--conf', str(self.ini_path),
            command
        ]
        
        if yaml_file:
            cmd.append(str(yaml_file))
        
        cmd_str = ' '.join(cmd)
        logger.info(f"执行 JJB 命令: {cmd_str}")
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            
            if result.returncode == 0:
                logger.info(f"JJB 命令执行成功")
                if result.stdout:
                    logger.debug(f"stdout: {result.stdout[:500]}")
                return True
            else:
                logger.error(f"JJB 命令执行失败: {result.stderr[:500] if result.stderr else 'unknown error'}")
                return False
                
        except subprocess.TimeoutExpired:
            logger.error(f"JJB 命令执行超时 ({timeout}秒)")
            return False
        except FileNotFoundError:
            logger.error("jenkins-jobs 命令未找到，请安装: pip install jenkins-job-builder")
            return False
        except Exception as e:
            logger.error(f"JJB 命令执行异常: {e}")
            return False
    
    def test_job(self, yaml_file: Path) -> bool:
        """
        测试 Job 配置 (不实际更新 Jenkins)
        
        Args:
            yaml_file: YAML 文件路径
            
        Returns:
            配置是否有效
        """
        return self.run_jjb_command('test', yaml_file)
    
    def update_job_to_jenkins(self, yaml_file: Path) -> bool:
        """
        更新 Job 到 Jenkins
        
        Args:
            yaml_file: YAML 文件路径
            
        Returns:
            是否更新成功
        """
        return self.run_jjb_command('update', yaml_file)
    
    # ========================================
    # 完整的 Job 更新流程
    # ========================================
    
    def update_job(
        self,
        job_name: str,
        new_dsl: str,
        test_first: bool = False
    ) -> bool:
        """
        更新 Job 的完整流程
        
        步骤:
        1. 查找 Job 对应的 YAML 配置文件
        2. 更新 YAML 文件中的 dsl 内容
        3. (可选) 测试配置有效性
        4. 执行 jenkins-jobs update 更新到 Jenkins
        
        Args:
            job_name: Job 名称
            new_dsl: 新的 Jenkinsfile (dsl) 内容
            test_first: 是否先测试配置
            
        Returns:
            是否更新成功
        """
        logger.info(f"开始更新 Job: {job_name}")
        
        # 步骤 1: 查找 YAML 配置文件
        yaml_file = self.find_job_yaml(job_name)
        if not yaml_file:
            logger.error(f"无法找到 Job 配置文件: {job_name}")
            return False
        
        # 步骤 2: 更新 YAML 中的 dsl
        if not self.update_dsl(yaml_file, new_dsl):
            logger.error(f"更新 YAML 配置失败: {job_name}")
            return False
        
        # 步骤 3 (可选): 测试配置
        if test_first:
            if not self.test_job(yaml_file):
                logger.error(f"Job 配置测试失败: {job_name}")
                return False
        
        # 步骤 4: 执行 jenkins-jobs update
        if not self.update_job_to_jenkins(yaml_file):
            logger.error(f"执行 JJB update 失败: {job_name}")
            return False
        
        logger.info(f"Job 更新成功: {job_name}")
        return True
    
    # ========================================
    # 其他工具方法
    # ========================================
    
    def list_all_jobs(self) -> List[str]:
        """
        获取配置目录中所有定义的 Job 名称
        
        Returns:
            Job 名称列表
        """
        jobs = []
        
        all_yaml_files = list(self.config_path.glob("*.yaml")) + \
                         list(self.config_path.glob("*.yml"))
        
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
        
        # 去重并返回
        return list(set(jobs))


# ========================================
# 便捷函数
# ========================================

def create_jjb_manager() -> JJBManager:
    """
    从环境变量创建 JJB 管理器
    
    Returns:
        JJBManager 实例
    """
    return JJBManager()


def update_job_config(
    job_name: str,
    new_dsl: str,
    config_path: str = None
) -> bool:
    """
    更新 Job 配置的便捷函数
    
    Args:
        job_name: Job 名称
        new_dsl: 新的 Jenkinsfile 内容
        config_path: JJB 配置路径 (可选)
        
    Returns:
        是否更新成功
    """
    manager = JJBManager(config_path)
    return manager.update_job(job_name, new_dsl)
