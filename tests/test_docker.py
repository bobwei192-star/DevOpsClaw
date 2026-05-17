#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DevOpsAgent Docker 镜像速度测试脚本
功能：
  - 测试不同 Docker 镜像源的连接速度
  - 测试 Docker Hub 代理的拉取速度
  - 生成速度测试报告

使用方法：
  pytest tests/test_docker.py -v
  pytest tests/test_docker.py -v --timeout=300

注意：
  - 测试需要 Docker 环境
  - 测试会自动清理测试镜像
"""

import subprocess
import time
import re
import os
import sys
from pathlib import Path
from typing import Optional, Tuple, List, Dict
import pytest

PROJECT_ROOT = Path(__file__).parent.parent
TESTS_DIR = PROJECT_ROOT / "tests"
DEPLOY_LOG = PROJECT_ROOT / "deploy.log"

DOCKER_MIRRORS = [
    ("docker.xuanyuan.me", "轩辕镜像（免费版）", "2026实测推荐"),
    ("docker.1ms.run", "毫秒镜像", "2026实测推荐"),
    ("xuanyuan.cloud", "轩辕镜像（专业版）", "2026实测推荐"),
    ("docker.m.daocloud.io", "DaoCloud 镜像站", "老牌服务"),
    ("dockerproxy.com", "Docker 代理", "第三方代理"),
    ("atomhub.openatom.cn", "AtomHub（开放原子）", "官方公益"),
    ("docker.nju.edu.cn", "南京大学镜像站", "教育网"),
    ("docker.mirrors.ustc.edu.cn", "中科大镜像站", "教育网（已限制）"),
    ("hub-mirror.c.163.com", "网易云", "已失效"),
    ("docker.mirrors.sjtug.sjtu.edu.cn", "上海交大", "已失效"),
]

TEST_IMAGES = {
    "small": "alpine:latest",
    "medium": "nginx:alpine",
    "large": "jenkins/jenkins:lts-jdk17",
}


class DockerSpeedTest:
    """Docker 镜像速度测试类"""

    def __init__(self):
        self.docker_available = self._check_docker_available()
        self.results: List[Dict] = []

    def _check_docker_available(self) -> bool:
        """检查 Docker 是否可用"""
        try:
            result = subprocess.run(
                ["docker", "info"],
                capture_output=True,
                text=True,
                timeout=30
            )
            return result.returncode == 0
        except Exception:
            return False

    def _check_mirror_connectivity(self, mirror: str, timeout: int = 10) -> Tuple[bool, float, str]:
        """
        检查镜像源的连通性（使用 curl/ping）
        
        Args:
            mirror: 镜像源地址（不含 https://）
            timeout: 超时时间（秒）
            
        Returns:
            (是否成功, 耗时秒数, 错误信息)
        """
        url = f"https://{mirror}"
        start_time = time.time()
        
        try:
            if sys.platform == "win32":
                result = subprocess.run(
                    ["curl", "-s", "-o", "NUL", "-w", "%{time_total}", "--connect-timeout", str(timeout), url],
                    capture_output=True,
                    text=True,
                    timeout=timeout + 5
                )
            else:
                result = subprocess.run(
                    ["curl", "-s", "-o", "/dev/null", "-w", "%{time_total}", "--connect-timeout", str(timeout), url],
                    capture_output=True,
                    text=True,
                    timeout=timeout + 5
                )
            
            elapsed = time.time() - start_time
            
            if result.returncode == 0:
                try:
                    curl_time = float(result.stdout.strip())
                    return True, curl_time, f"连接成功，耗时 {curl_time:.3f}s"
                except ValueError:
                    return True, elapsed, f"连接成功，耗时 {elapsed:.3f}s"
            else:
                return False, elapsed, f"连接失败: {result.stderr.strip()}"
                
        except subprocess.TimeoutExpired:
            elapsed = time.time() - start_time
            return False, elapsed, f"连接超时 ({timeout}s)"
        except Exception as e:
            elapsed = time.time() - start_time
            return False, elapsed, f"连接异常: {str(e)}"

    def _pull_image_with_timing(self, image: str, timeout: int = 300) -> Tuple[bool, float, str]:
        """
        拉取镜像并计时
        
        Args:
            image: 镜像名称（如 nginx:alpine）
            timeout: 超时时间（秒）
            
        Returns:
            (是否成功, 耗时秒数, 输出信息)
        """
        start_time = time.time()
        
        try:
            result = subprocess.run(
                ["docker", "pull", image],
                capture_output=True,
                text=True,
                timeout=timeout
            )
            
            elapsed = time.time() - start_time
            
            if result.returncode == 0:
                return True, elapsed, result.stdout
            else:
                return False, elapsed, f"拉取失败: {result.stderr}"
                
        except subprocess.TimeoutExpired:
            elapsed = time.time() - start_time
            return False, elapsed, f"拉取超时 ({timeout}s)"
        except Exception as e:
            elapsed = time.time() - start_time
            return False, elapsed, f"拉取异常: {str(e)}"

    def _remove_image(self, image: str) -> bool:
        """删除镜像"""
        try:
            result = subprocess.run(
                ["docker", "rmi", "-f", image],
                capture_output=True,
                timeout=60
            )
            return result.returncode == 0
        except Exception:
            return False

    def test_mirror_connectivity(self) -> List[Dict]:
        """测试所有镜像源的连通性"""
        print("\n" + "=" * 80)
        print("Docker 镜像源连通性测试")
        print("=" * 80)
        
        results = []
        
        for mirror, name, desc in DOCKER_MIRRORS:
            print(f"\n测试: {name} ({mirror}) - {desc}")
            
            success, elapsed, message = self._check_mirror_connectivity(mirror, timeout=15)
            
            result = {
                "mirror": mirror,
                "name": name,
                "description": desc,
                "test_type": "connectivity",
                "success": success,
                "elapsed": elapsed,
                "message": message
            }
            results.append(result)
            
            if success:
                print(f"\n  [OK] 连通性测试通过: {elapsed:.3f}s")
            else:
                print(f"  [FAIL] 连通性测试失败: {message}")
        
        self._print_connectivity_report(results)
        self.results.extend(results)
        return results

    def _print_connectivity_report(self, results: List[Dict]):
        """打印连通性测试报告"""
        print("\n" + "=" * 80)
        print("连通性测试报告")
        print("=" * 80)
        
        successful = [r for r in results if r["success"]]
        failed = [r for r in results if not r["success"]]
        
        print(f"\n成功: {len(successful)}/{len(results)}")
        print(f"失败: {len(failed)}/{len(results)}")
        
        if successful:
            print("\n✅ 可用的镜像源（按速度排序）:")
            successful_sorted = sorted(successful, key=lambda x: x["elapsed"])
            for i, r in enumerate(successful_sorted, 1):
                print(f"  {i}. {r['name']} ({r['mirror']}) - {r['elapsed']:.3f}s - {r['description']}")
        
        if failed:
            print("\n❌ 不可用的镜像源:")
            for r in failed:
                print(f"  - {r['name']} ({r['mirror']}) - {r['message']}")

    def test_image_pull_speed(self, image_size: str = "small", cleanup: bool = True) -> Dict:
        """
        测试镜像拉取速度（使用当前 Docker 配置的镜像源）
        
        Args:
            image_size: 镜像大小 (small/medium/large)
            cleanup: 测试后是否清理镜像
            
        Returns:
            测试结果字典
        """
        if not self.docker_available:
            return {
                "test_type": "pull_speed",
                "success": False,
                "message": "Docker 不可用"
            }
        
        image = TEST_IMAGES[image_size]
        
        print(f"\n" + "=" * 80)
        print(f"Docker 镜像拉取速度测试 ({image_size} 镜像: {image})")
        print("=" * 80)
        
        print(f"\n首先清理可能存在的镜像...")
        self._remove_image(image)
        
        print(f"\n开始拉取镜像: {image}")
        success, elapsed, message = self._pull_image_with_timing(image, timeout=300)
        
        result = {
            "test_type": "pull_speed",
            "image_size": image_size,
            "image": image,
            "success": success,
            "elapsed": elapsed,
            "message": message
        }
        
        if success:
            print(f"\n  ✓ 镜像拉取成功!")
            print(f"    耗时: {elapsed:.2f} 秒")
            
            image_size_mb = self._get_image_size(image)
            if image_size_mb > 0:
                speed = image_size_mb / elapsed
                print(f"    镜像大小: {image_size_mb:.2f} MB")
                print(f"    平均速度: {speed:.2f} MB/s")
                result["image_size_mb"] = image_size_mb
                result["speed_mbps"] = speed
        else:
            print(f"\n  ✗ 镜像拉取失败: {message}")
        
        if cleanup and success:
            print(f"\n清理测试镜像...")
            self._remove_image(image)
        
        self.results.append(result)
        return result

    def _get_image_size(self, image: str) -> float:
        """获取镜像大小（MB）"""
        try:
            result = subprocess.run(
                ["docker", "inspect", "--format={{.Size}}", image],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode == 0:
                size_bytes = int(result.stdout.strip())
                return size_bytes / (1024 * 1024)
        except Exception:
            pass
        
        return 0.0

    def test_current_docker_config(self) -> Dict:
        """测试当前 Docker 配置"""
        print("\n" + "=" * 80)
        print("当前 Docker 配置检查")
        print("=" * 80)
        
        result = {
            "test_type": "docker_config",
            "docker_available": self.docker_available,
            "version": None,
            "registry_mirrors": [],
            "storage_driver": None
        }
        
        if not self.docker_available:
            print("\n  ✗ Docker 不可用")
            return result
        
        try:
            version_result = subprocess.run(
                ["docker", "version", "--format", "{{.Server.Version}}"],
                capture_output=True,
                text=True,
                timeout=10
            )
            if version_result.returncode == 0:
                result["version"] = version_result.stdout.strip()
                print(f"\n  Docker 版本: {result['version']}")
            
            info_result = subprocess.run(
                ["docker", "info"],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            if info_result.returncode == 0:
                info_output = info_result.stdout
                
                mirrors = re.findall(r"Registry Mirrors:\s*\n\s+(.+)", info_output)
                if not mirrors:
                    mirrors_match = re.search(r"Registry Mirrors:((?:\n\s+.+)+)", info_output)
                    if mirrors_match:
                        mirrors = [m.strip() for m in mirrors_match.group(1).strip().split("\n")]
                
                result["registry_mirrors"] = mirrors
                if mirrors:
                    print(f"\n  已配置的镜像源:")
                    for m in mirrors:
                        print(f"    - {m}")
                else:
                    print(f"\n  ⚠ 未配置镜像源，直接从 Docker Hub 拉取")
                
                storage_match = re.search(r"Storage Driver:\s+(.+)", info_output)
                if storage_match:
                    result["storage_driver"] = storage_match.group(1)
                    print(f"\n  存储驱动: {result['storage_driver']}")
                    
        except Exception as e:
            print(f"\n  获取 Docker 配置异常: {e}")
        
        self.results.append(result)
        return result

    def generate_report(self) -> str:
        """生成测试报告"""
        report_lines = []
        report_lines.append("=" * 80)
        report_lines.append("DevOpsAgent Docker 镜像测试报告")
        report_lines.append("=" * 80)
        report_lines.append(f"测试时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")
        
        docker_config = [r for r in self.results if r.get("test_type") == "docker_config"]
        if docker_config:
            report_lines.append("\n[Docker 环境]")
            cfg = docker_config[0]
            if cfg.get("docker_available"):
                report_lines.append(f"  ✓ Docker 可用")
                if cfg.get("version"):
                    report_lines.append(f"  版本: {cfg['version']}")
                if cfg.get("registry_mirrors"):
                    report_lines.append(f"  镜像源: {', '.join(cfg['registry_mirrors'])}")
            else:
                report_lines.append(f"  ✗ Docker 不可用")
        
        connectivity = [r for r in self.results if r.get("test_type") == "connectivity"]
        if connectivity:
            report_lines.append("\n[镜像源连通性测试]")
            successful = [r for r in connectivity if r["success"]]
            failed = [r for r in connectivity if not r["success"]]
            report_lines.append(f"  成功: {len(successful)}/{len(connectivity)}")
            
            if successful:
                report_lines.append(f"\n  ✅ 可用镜像源（按速度排序）:")
                for i, r in enumerate(sorted(successful, key=lambda x: x["elapsed"]), 1):
                    report_lines.append(f"    {i}. {r['name']} ({r['mirror']}) - {r['elapsed']:.3f}s")
            
            if failed:
                report_lines.append(f"\n  ❌ 不可用镜像源:")
                for r in failed:
                    report_lines.append(f"    - {r['name']} ({r['mirror']}) - {r['message']}")
        
        pull_tests = [r for r in self.results if r.get("test_type") == "pull_speed"]
        if pull_tests:
            report_lines.append("\n[镜像拉取速度测试]")
            for r in pull_tests:
                if r["success"]:
                    report_lines.append(f"\n  ✓ {r['image_size']} 镜像 ({r['image']}):")
                    report_lines.append(f"    耗时: {r['elapsed']:.2f}s")
                    if "speed_mbps" in r:
                        report_lines.append(f"    速度: {r['speed_mbps']:.2f} MB/s")
                        report_lines.append(f"    大小: {r['image_size_mb']:.2f} MB")
                else:
                    report_lines.append(f"\n  ✗ {r['image_size']} 镜像 ({r['image']}): {r['message']}")
        
        report_lines.append("\n" + "=" * 80)
        report_lines.append("测试完成")
        report_lines.append("=" * 80)
        
        return "\n".join(report_lines)


class TestDockerSpeed:
    """pytest 测试类"""
    
    @classmethod
    def setup_class(cls):
        """类级别的初始化"""
        cls.tester = DockerSpeedTest()
    
    def test_01_docker_available(self):
        """测试 Docker 是否可用"""
        print("\n" + "=" * 80)
        print("测试 1: Docker 环境检查")
        print("=" * 80)
        
        docker_config = self.tester.test_current_docker_config()
        
        assert self.tester.docker_available, \
            f"Docker 不可用，请确保 Docker 已安装并运行。错误信息: {docker_config}"
        
        print("\n  ✓ Docker 环境正常")
    
    def test_02_mirror_connectivity(self):
        """测试镜像源连通性"""
        print("\n" + "=" * 80)
        print("测试 2: Docker 镜像源连通性测试")
        print("=" * 80)
        
        results = self.tester.test_mirror_connectivity()
        
        successful = [r for r in results if r["success"]]
        
        print(f"\n连通性测试结果: {len(successful)}/{len(results)} 个镜像源可用")
        
        if not successful:
            print("\n  ⚠ 警告: 没有可用的镜像源，可能需要配置代理或使用其他网络")
        else:
            fastest = min(successful, key=lambda x: x["elapsed"])
            print(f"\n  最快的镜像源: {fastest['name']} ({fastest['mirror']}) - {fastest['elapsed']:.3f}s")
    
    @pytest.mark.slow
    def test_03_pull_small_image(self):
        """测试拉取小型镜像 (alpine:latest)"""
        if not self.tester.docker_available:
            pytest.skip("Docker 不可用，跳过拉取测试")
        
        result = self.tester.test_image_pull_speed("small", cleanup=True)
        
        if not result["success"]:
            print(f"\n  ⚠ 镜像拉取失败: {result['message']}")
            print("  这可能是网络问题，建议:")
            print("  1. 配置 Docker 镜像加速器")
            print("  2. 检查网络连接")
            print("  3. 配置代理")
        
        assert result["success"], f"小型镜像拉取失败: {result['message']}"
        
        print(f"\n  ✓ 小型镜像拉取测试通过")
        print(f"    耗时: {result['elapsed']:.2f}s")
        if "speed_mbps" in result:
            print(f"    速度: {result['speed_mbps']:.2f} MB/s")
    
    @pytest.mark.slow
    def test_04_pull_medium_image(self):
        """测试拉取中型镜像 (nginx:alpine)"""
        if not self.tester.docker_available:
            pytest.skip("Docker 不可用，跳过拉取测试")
        
        result = self.tester.test_image_pull_speed("medium", cleanup=True)
        
        if not result["success"]:
            print(f"\n  ⚠ 镜像拉取失败: {result['message']}")
        
        assert result["success"], f"中型镜像拉取失败: {result['message']}"
        
        print(f"\n  ✓ 中型镜像拉取测试通过")
        print(f"    耗时: {result['elapsed']:.2f}s")
        if "speed_mbps" in result:
            print(f"    速度: {result['speed_mbps']:.2f} MB/s")
    
    @pytest.mark.very_slow
    def test_05_pull_large_image(self):
        """测试拉取大型镜像 (jenkins/jenkins:lts-jdk17) - 可选"""
        if not self.tester.docker_available:
            pytest.skip("Docker 不可用，跳过拉取测试")
        
        print("\n" + "=" * 80)
        print("注意: 大型镜像测试可能需要较长时间（5-30分钟）")
        print("建议使用配置了镜像加速器的网络环境")
        print("=" * 80)
        
        result = self.tester.test_image_pull_speed("large", cleanup=True)
        
        if not result["success"]:
            print(f"\n  ⚠ 大型镜像拉取失败: {result['message']}")
            print("  大型镜像更容易超时，建议:")
            print("  1. 使用更稳定的网络")
            print("  2. 配置可靠的镜像加速器")
        
        assert result["success"], f"大型镜像拉取失败: {result['message']}"
        
        print(f"\n  ✓ 大型镜像拉取测试通过")
        print(f"    耗时: {result['elapsed']:.2f}s")
        if "speed_mbps" in result:
            print(f"    速度: {result['speed_mbps']:.2f} MB/s")
    
    def test_06_generate_report(self):
        """生成测试报告"""
        print("\n" + "=" * 80)
        print("生成测试报告")
        print("=" * 80)
        
        report = self.tester.generate_report()
        print(report)
        
        report_file = TESTS_DIR / "docker_test_report.txt"
        with open(report_file, "w", encoding="utf-8") as f:
            f.write(report)
        
        print(f"\n  ✓ 报告已保存到: {report_file}")


def main():
    """命令行入口"""
    import argparse
    
    parser = argparse.ArgumentParser(description="DevOpsAgent Docker 镜像速度测试")
    parser.add_argument("--connectivity-only", action="store_true", help="只测试连通性")
    parser.add_argument("--pull-small", action="store_true", help="测试拉取小型镜像")
    parser.add_argument("--pull-medium", action="store_true", help="测试拉取中型镜像")
    parser.add_argument("--pull-large", action="store_true", help="测试拉取大型镜像")
    parser.add_argument("--full", action="store_true", help="运行完整测试")
    
    args = parser.parse_args()
    
    tester = DockerSpeedTest()
    
    print("\n" + "=" * 80)
    print("DevOpsAgent Docker 镜像速度测试")
    print("=" * 80)
    
    tester.test_current_docker_config()
    
    if args.connectivity_only or args.full:
        tester.test_mirror_connectivity()
    
    if args.pull_small or args.full:
        tester.test_image_pull_speed("small")
    
    if args.pull_medium or args.full:
        tester.test_image_pull_speed("medium")
    
    if args.pull_large or args.full:
        tester.test_image_pull_speed("large")
    
    if not any([args.connectivity_only, args.pull_small, args.pull_medium, args.pull_large, args.full]):
        print("\n默认运行: 连通性测试 + 小型镜像拉取测试")
        tester.test_mirror_connectivity()
        tester.test_image_pull_speed("small")
    
    report = tester.generate_report()
    print(report)
    
    report_file = TESTS_DIR / "docker_test_report.txt"
    with open(report_file, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\n报告已保存到: {report_file}")


if __name__ == "__main__":
    main()
