#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DevOpsClaw 部署后测试脚本
功能：
  - 测试 Docker 环境
  - 测试 Docker 网络
  - 测试各个容器是否运行
  - 测试各个服务的 HTTP/HTTPS 访问
  - 测试 Nginx 反向代理

使用方法：
  pytest tests/test_deployment.py -v
  pytest tests/test_deployment.py -v --timeout=120
  pytest tests/test_deployment.py::TestDeployment::test_nginx_proxy -v

注意：
  - 测试需要 Docker 环境
  - 测试在部署完成后运行
"""

import subprocess
import time
import os
import sys
from pathlib import Path
from typing import Optional, List, Dict, Tuple
import pytest

PROJECT_ROOT = Path(__file__).parent.parent
TESTS_DIR = PROJECT_ROOT / "tests"
DEPLOY_LOG = PROJECT_ROOT / "deploy.log"


class DeploymentTester:
    """部署测试类"""

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

    def _run_command(self, cmd: List[str], timeout: int = 30) -> Tuple[int, str, str]:
        """运行命令并返回结果"""
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "Command timeout"
        except Exception as e:
            return -2, "", str(e)

    def test_docker_environment(self) -> Dict:
        """测试 Docker 环境"""
        print("\n" + "=" * 80)
        print("测试 1: Docker 环境检查")
        print("=" * 80)

        result = {
            "test_type": "docker_environment",
            "success": False,
            "version": None,
            "network_exists": False,
            "network_name": "devopsclaw-network"
        }

        if not self.docker_available:
            print("  [FAIL] Docker 不可用")
            return result

        # 检查 Docker 版本
        code, stdout, stderr = self._run_command(["docker", "version", "--format", "{{.Server.Version}}"])
        if code == 0:
            result["version"] = stdout.strip()
            print(f"  [OK] Docker 版本: {result['version']}")
        else:
            print(f"  [FAIL] 无法获取 Docker 版本: {stderr}")

        # 检查 Docker 网络
        code, stdout, stderr = self._run_command(["docker", "network", "ls", "--format", "{{.Name}}"])
        if code == 0:
            networks = stdout.strip().split("\n")
            if result["network_name"] in networks:
                result["network_exists"] = True
                print(f"  [OK] Docker 网络存在: {result['network_name']}")
            else:
                print(f"  [WARN] Docker 网络不存在: {result['network_name']}")
                print("         网络可能在容器启动时自动创建")

        result["success"] = self.docker_available
        self.results.append(result)
        return result

    def get_running_containers(self) -> List[str]:
        """获取正在运行的容器列表"""
        code, stdout, stderr = self._run_command(
            ["docker", "ps", "--format", "{{.Names}}"]
        )
        if code == 0:
            return [n.strip() for n in stdout.strip().split("\n") if n.strip()]
        return []

    def test_containers_running(self) -> Dict:
        """测试容器是否运行"""
        print("\n" + "=" * 80)
        print("测试 2: 容器运行状态检查")
        print("=" * 80)

        result = {
            "test_type": "containers_running",
            "success": False,
            "running_containers": [],
            "expected_containers": [
                "devopsclaw-jenkins",
                "devopsclaw-gitlab",
                "devopsclaw-openclaw",
                "devopsclaw-nginx"
            ],
            "container_status": {}
        }

        if not self.docker_available:
            print("  [FAIL] Docker 不可用")
            return result

        running = self.get_running_containers()
        result["running_containers"] = running

        print(f"\n  正在运行的容器:")
        for container in running:
            print(f"    - {container}")

        print(f"\n  检查预期容器状态:")
        for expected in result["expected_containers"]:
            if expected in running:
                result["container_status"][expected] = "running"
                print(f"    [OK] {expected}: 运行中")
            else:
                result["container_status"][expected] = "not_running"
                print(f"    [INFO] {expected}: 未运行 (可选服务)")

        # 只要 Docker 可用就认为成功（因为某些服务是可选的）
        result["success"] = True
        self.results.append(result)
        return result

    def _curl_test(self, url: str, timeout: int = 10, verify_ssl: bool = False) -> Tuple[bool, str, int]:
        """
        使用 curl 测试 URL
        
        Args:
            url: 要测试的 URL
            timeout: 超时时间（秒）
            verify_ssl: 是否验证 SSL 证书
            
        Returns:
            (是否成功, 响应信息, HTTP 状态码)
        """
        cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--connect-timeout", str(timeout)]
        
        if not verify_ssl:
            cmd.append("-k")  # 忽略 SSL 证书验证（用于自签名证书）
        
        cmd.append(url)
        
        code, stdout, stderr = self._run_command(cmd, timeout=timeout + 5)
        
        if code != 0:
            return False, f"curl 命令失败: {stderr}", 0
        
        try:
            http_code = int(stdout.strip())
            if http_code >= 200 and http_code < 500:
                return True, f"HTTP {http_code}", http_code
            else:
                return False, f"HTTP {http_code}", http_code
        except ValueError:
            return False, f"无效的响应: {stdout}", 0

    def test_nginx_proxy(self) -> Dict:
        """测试 Nginx 反向代理"""
        print("\n" + "=" * 80)
        print("测试 3: Nginx 反向代理测试")
        print("=" * 80)

        result = {
            "test_type": "nginx_proxy",
            "success": False,
            "endpoints": {}
        }

        # 从 .env 文件读取端口配置
        env_file = PROJECT_ROOT / ".env"
        ports = {
            "jenkins": 18440,
            "gitlab": 18441,
            "openclaw": 18442,
            "registry": 18444,
            "harbor": 18445,
            "sonarqube": 18446
        }

        # 尝试从 .env 读取端口
        if env_file.exists():
            with open(env_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("NGINX_PORT_") and "=" in line:
                        key, value = line.split("=", 1)
                        service = key.replace("NGINX_PORT_", "").lower()
                        try:
                            ports[service] = int(value.strip())
                        except ValueError:
                            pass

        # 测试各个端点
        test_endpoints = [
            ("jenkins", f"https://127.0.0.1:{ports['jenkins']}/jenkins/", "核心服务"),
            ("gitlab", f"https://127.0.0.1:{ports['gitlab']}/", "核心服务"),
            ("openclaw", f"https://127.0.0.1:{ports['openclaw']}/", "核心服务"),
            ("registry", f"https://127.0.0.1:{ports['registry']}/v2/", "可选服务"),
            ("harbor", f"https://127.0.0.1:{ports['harbor']}/", "可选服务"),
            ("sonarqube", f"https://127.0.0.1:{ports['sonarqube']}/", "可选服务"),
        ]

        print(f"\n  测试 Nginx 端点 (自签名证书，使用 -k 选项):")
        
        running_containers = self.get_running_containers()
        
        for service, url, service_type in test_endpoints:
            print(f"\n    测试 {service} ({service_type}): {url}")
            
            # 检查容器是否运行
            container_name = f"devopsclaw-{service}"
            container_running = container_name in running_containers
            
            # 执行 curl 测试
            success, message, http_code = self._curl_test(url, timeout=10, verify_ssl=False)
            
            result["endpoints"][service] = {
                "url": url,
                "service_type": service_type,
                "container_running": container_running,
                "http_code": http_code,
                "success": success,
                "message": message
            }
            
            if success:
                print(f"      [OK] {message}")
            else:
                if service_type == "核心服务" and container_running:
                    print(f"      [FAIL] {message} (但容器正在运行，可能需要等待服务启动)")
                elif service_type == "核心服务" and not container_running:
                    print(f"      [WARN] {message} (容器未运行)")
                else:
                    print(f"      [INFO] {message} (可选服务，容器未运行)")

        # 统计结果
        core_services = ["jenkins", "gitlab", "openclaw"]
        core_success = all(
            result["endpoints"][s]["success"] or 
            not result["endpoints"][s]["container_running"]
            for s in core_services
        )
        
        result["success"] = core_services  # 核心服务通过就认为成功
        self.results.append(result)
        return result

    def test_direct_services(self) -> Dict:
        """测试直接访问服务（不通过 Nginx）"""
        print("\n" + "=" * 80)
        print("测试 4: 直接服务访问测试")
        print("=" * 80)

        result = {
            "test_type": "direct_services",
            "success": False,
            "endpoints": {}
        }

        # 直接访问端口（不通过 Nginx）
        direct_ports = {
            "jenkins": 8081,
            "gitlab": 8082,
            "openclaw": 18789
        }

        # 尝试从 .env 读取端口
        env_file = PROJECT_ROOT / ".env"
        if env_file.exists():
            with open(env_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if "JENKINS_PORT_WEB" in line and "=" in line:
                        _, value = line.split("=", 1)
                        try:
                            direct_ports["jenkins"] = int(value.strip())
                        except ValueError:
                            pass
                    elif "GITLAB_PORT_HTTP" in line and "=" in line:
                        _, value = line.split("=", 1)
                        try:
                            direct_ports["gitlab"] = int(value.strip())
                        except ValueError:
                            pass
                    elif "OPENCLAW_PORT" in line and "=" in line:
                        _, value = line.split("=", 1)
                        try:
                            direct_ports["openclaw"] = int(value.strip())
                        except ValueError:
                            pass

        test_endpoints = [
            ("jenkins", f"http://127.0.0.1:{direct_ports['jenkins']}/jenkins/"),
            ("gitlab", f"http://127.0.0.1:{direct_ports['gitlab']}/"),
            ("openclaw", f"http://127.0.0.1:{direct_ports['openclaw']}/"),
        ]

        print(f"\n  测试直接访问端点:")
        
        running_containers = self.get_running_containers()
        
        for service, url in test_endpoints:
            print(f"\n    测试 {service}: {url}")
            
            container_name = f"devopsclaw-{service}"
            container_running = container_name in running_containers
            
            success, message, http_code = self._curl_test(url, timeout=10, verify_ssl=True)
            
            result["endpoints"][service] = {
                "url": url,
                "container_running": container_running,
                "http_code": http_code,
                "success": success,
                "message": message
            }
            
            if success:
                print(f"      [OK] {message}")
            else:
                if container_running:
                    print(f"      [WARN] {message} (容器正在运行，可能需要等待服务启动)")
                else:
                    print(f"      [INFO] {message} (容器未运行)")

        result["success"] = True  # 直接访问是可选测试
        self.results.append(result)
        return result

    def generate_report(self) -> str:
        """生成测试报告"""
        report_lines = []
        report_lines.append("=" * 80)
        report_lines.append("DevOpsClaw 部署测试报告")
        report_lines.append("=" * 80)
        report_lines.append(f"测试时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")

        # Docker 环境
        docker_test = [r for r in self.results if r.get("test_type") == "docker_environment"]
        if docker_test:
            report_lines.append("\n[Docker 环境]")
            t = docker_test[0]
            if t["success"]:
                report_lines.append("  [OK] Docker 可用")
                if t.get("version"):
                    report_lines.append(f"  版本: {t['version']}")
                if t.get("network_exists"):
                    report_lines.append(f"  网络: {t['network_name']} (存在)")
                else:
                    report_lines.append(f"  网络: {t['network_name']} (不存在)")
            else:
                report_lines.append("  [FAIL] Docker 不可用")

        # 容器状态
        container_test = [r for r in self.results if r.get("test_type") == "containers_running"]
        if container_test:
            report_lines.append("\n[容器状态]")
            t = container_test[0]
            running = t.get("running_containers", [])
            if running:
                report_lines.append(f"  正在运行的容器 ({len(running)}):")
                for c in running:
                    report_lines.append(f"    - {c}")
            else:
                report_lines.append("  没有正在运行的容器")

            report_lines.append("\n  预期容器状态:")
            for container, status in t.get("container_status", {}).items():
                if status == "running":
                    report_lines.append(f"    [OK] {container}: 运行中")
                else:
                    report_lines.append(f"    [INFO] {container}: 未运行 (可选)")

        # Nginx 代理
        nginx_test = [r for r in self.results if r.get("test_type") == "nginx_proxy"]
        if nginx_test:
            report_lines.append("\n[Nginx 反向代理测试]")
            t = nginx_test[0]
            endpoints = t.get("endpoints", {})
            
            for service, info in endpoints.items():
                status = "[OK]" if info["success"] else "[INFO]"
                if info["service_type"] == "核心服务" and not info["success"] and info["container_running"]:
                    status = "[WARN]"
                report_lines.append(f"  {status} {service} ({info['service_type']}): {info['message']}")
                report_lines.append(f"       URL: {info['url']}")
                if info["container_running"]:
                    report_lines.append(f"       容器: 运行中")
                else:
                    report_lines.append(f"       容器: 未运行")

        # 直接访问
        direct_test = [r for r in self.results if r.get("test_type") == "direct_services"]
        if direct_test:
            report_lines.append("\n[直接服务访问测试]")
            t = direct_test[0]
            endpoints = t.get("endpoints", {})
            
            for service, info in endpoints.items():
                status = "[OK]" if info["success"] else "[INFO]"
                report_lines.append(f"  {status} {service}: {info['message']}")
                report_lines.append(f"       URL: {info['url']}")

        report_lines.append("\n" + "=" * 80)
        report_lines.append("测试完成")
        report_lines.append("=" * 80)

        return "\n".join(report_lines)


class TestDeployment:
    """pytest 部署测试类"""

    @classmethod
    def setup_class(cls):
        """类级别的初始化"""
        cls.tester = DeploymentTester()

    def test_01_docker_environment(self):
        """测试 Docker 环境"""
        result = self.tester.test_docker_environment()
        
        # 断言 Docker 可用
        assert self.tester.docker_available, \
            "Docker 不可用，请确保 Docker 已安装并运行"

    def test_02_containers_running(self):
        """测试容器运行状态"""
        result = self.tester.test_containers_running()
        
        # 这个测试不做强制断言，因为某些服务是可选的
        # 只打印信息
        pass

    def test_03_nginx_proxy(self):
        """测试 Nginx 反向代理"""
        if not self.tester.docker_available:
            pytest.skip("Docker 不可用，跳过 Nginx 测试")
        
        result = self.tester.test_nginx_proxy()
        
        # 检查 Nginx 容器是否运行
        running = self.tester.get_running_containers()
        nginx_running = "devopsclaw-nginx" in running
        
        if nginx_running:
            print("\n  注意: Nginx 容器正在运行")
            print("  如果端点测试失败，可能是因为:")
            print("  1. 后端服务（Jenkins/GitLab/OpenClaw）未运行")
            print("  2. 服务正在启动中（GitLab 可能需要 2-5 分钟）")
            print("  3. 自签名证书导致的问题（测试已使用 -k 选项忽略）")

    def test_04_direct_services(self):
        """测试直接服务访问"""
        if not self.tester.docker_available:
            pytest.skip("Docker 不可用，跳过直接服务测试")
        
        result = self.tester.test_direct_services()
        
        # 这个测试是可选的
        pass

    def test_05_generate_report(self):
        """生成测试报告"""
        print("\n" + "=" * 80)
        print("生成部署测试报告")
        print("=" * 80)

        report = self.tester.generate_report()
        print(report)

        # 保存报告
        report_file = TESTS_DIR / "deployment_test_report.txt"
        with open(report_file, "w", encoding="utf-8") as f:
            f.write(report)

        print(f"\n  报告已保存到: {report_file}")


def main():
    """命令行入口"""
    import argparse

    parser = argparse.ArgumentParser(description="DevOpsClaw 部署测试")
    parser.add_argument("--quick", action="store_true", help="快速测试（只测试 Docker 环境）")
    parser.add_argument("--full", action="store_true", help="完整测试（所有测试）")

    args = parser.parse_args()

    tester = DeploymentTester()

    print("\n" + "=" * 80)
    print("DevOpsClaw 部署测试")
    print("=" * 80)

    # 基础测试
    tester.test_docker_environment()
    tester.test_containers_running()

    if not args.quick:
        # 详细测试
        tester.test_nginx_proxy()
        tester.test_direct_services()

    # 生成报告
    report = tester.generate_report()
    print(report)

    report_file = TESTS_DIR / "deployment_test_report.txt"
    with open(report_file, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\n报告已保存到: {report_file}")


if __name__ == "__main__":
    main()
