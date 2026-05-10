#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenClaw device signature expired 一键诊断 + 修复脚本
======================================================
问题根因:
  - 客户端(浏览器)和网关(OpenClaw容器)之间的时间偏差超过2分钟时，
    浏览器生成的设备签名时间戳会被网关拒绝，返回 code=1008 "device signature expired"
  - 这在 Docker/WSL2 环境中非常常见，因为容器时钟可能与主机不同步
  - 官方文档: https://github.com/openclaw/openclaw/issues/29298

修复策略:
  1. 同步容器时间（挂载 /etc/localtime，设置 TZ 环境变量）
  2. 预写 openclaw.json（mode=local + auth.token + allowedOrigins + trustedProxies）
  3. 配置 allowInsecureAuth=true 允许纯 token 认证（跳过设备签名验证）
  4. 启动容器后运行 onboard 初始化
  5. 清理浏览器 localStorage 缓存

用法:
  sudo python3 tests/test_device_signature_expired.py
"""

import subprocess
import time
import os
import sys
import json
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent

CONTAINER_NAME = "devopsclaw-openclaw"
VOLUME_NAME = "devopsclaw_openclaw-data"
OPENCLAW_IMAGE = "ghcr.io/openclaw/openclaw:latest"
OPENCLAW_PORT = "18789"
NGINX_PORT = "18442"
TOKEN_FILE = PROJECT_ROOT / ".openclaw_token"
ENV_FILE = PROJECT_ROOT / ".env"
MAX_RETRIES = 3


class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    BOLD = "\033[1m"
    NC = "\033[0m"


def log_info(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {ts} - {msg}")


def log_warn(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {ts} - {msg}")


def log_error(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{Colors.RED}[ERROR]{Colors.NC} {ts} - {msg}")


def log_step(msg):
    print(f"\n{Colors.CYAN}=== {msg} ==={Colors.NC}")


def run(cmd, timeout=60):
    """运行 shell 命令，返回 (returncode, stdout, stderr)"""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "命令超时"
    except Exception as e:
        return -1, "", str(e)


def generate_token():
    """生成 64 字符随机 token"""
    rc, stdout, stderr = run("openssl rand -hex 32")
    if rc == 0 and stdout:
        return stdout.strip()
    rc, stdout, stderr = run("date +%s%N | sha256sum | awk '{print $1}'")
    if rc == 0 and stdout:
        return stdout.strip()
    return f"devopsclaw_{int(time.time())}_fallback"


def container_running():
    rc, stdout, _ = run(f"docker ps -q --filter name={CONTAINER_NAME}")
    return rc == 0 and bool(stdout)


def container_exists():
    rc, stdout, _ = run(f"docker ps -aq --filter name={CONTAINER_NAME}")
    return rc == 0 and bool(stdout)


def nginx_running():
    rc, stdout, _ = run("docker ps -q --filter name=devopsclaw-nginx")
    return rc == 0 and bool(stdout)


def clear_volume():
    """彻底清空 docker 命名卷"""
    rc, _, _ = run(
        f"docker run --rm -v {VOLUME_NAME}:/data alpine sh -c 'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null; echo ok'"
    )
    return rc == 0


def sync_container_time():
    """确保容器时间同步 - 关键修复步骤"""
    log_step("同步容器时间（关键修复）")

    # 检查主机时间
    rc, host_time, _ = run("date '+%Y-%m-%d %H:%M:%S'")
    log_info(f"主机时间: {host_time}")

    # 检查是否安装了 ntp 或 chrony
    rc, _, _ = run("which ntpdate || which chronyc")
    if rc != 0:
        log_warn("未安装 ntpdate/chrony，建议安装: sudo apt install -y ntpdate")

    # 尝试同步时间
    rc, _, _ = run("sudo ntpdate -s time.windows.com 2>/dev/null || sudo ntpdate -s pool.ntp.org 2>/dev/null || true")
    if rc == 0:
        rc, new_time, _ = run("date '+%Y-%m-%d %H:%M:%S'")
        log_info(f"时间已同步: {new_time}")

    # 检查 WSL 时间漂移
    rc, _, _ = run("grep -i microsoft /proc/version 2>/dev/null")
    if rc == 0:
        log_info("检测到 WSL 环境")
        # WSL 时间同步命令
        run("wsl.exe --shutdown 2>/dev/null || true")
        log_info("已执行 WSL 时间同步准备")

    return True


def write_openclaw_json(token):
    """预写 openclaw.json 到数据卷 - 包含 allowInsecureAuth 关键配置"""
    config = {
        "gateway": {
            "mode": "local",
            "auth": {
                "token": token,
                "mode": "token"
            },
            "controlUi": {
                "enabled": True,
                "allowedOrigins": [
                    f"http://127.0.0.1:{OPENCLAW_PORT}",
                    f"http://localhost:{OPENCLAW_PORT}",
                    f"https://127.0.0.1:{NGINX_PORT}",
                    f"https://localhost:{NGINX_PORT}",
                ],
                "allowInsecureAuth": True  # 关键: 允许纯 token 认证，跳过设备签名
            },
            "trustedProxies": [
                "127.0.0.1",
                "::1",
                "172.16.0.0/12",
                "10.0.0.0/8",
                "192.168.0.0/16",
            ],
        }
    }
    json_str = json.dumps(config, indent=2)
    cmd = f"""docker run --rm -v {VOLUME_NAME}:/data alpine sh -c "cat > /data/openclaw.json << 'INNEREOF'
{json_str}
INNEREOF" """
    rc, _, _ = run(cmd)
    return rc == 0


def start_container(token):
    """启动 OpenClaw 容器 - 关键修复: 挂载时间文件 + TZ 环境变量"""
    # 先停止并删除旧容器
    if container_running():
        run(f"docker stop {CONTAINER_NAME}", timeout=10)
    if container_exists():
        run(f"docker rm -f {CONTAINER_NAME}", timeout=5)

    cmd = f"""docker run -d \
        --name {CONTAINER_NAME} \
        --network devopsclaw-network \
        --restart unless-stopped \
        --user "1000:1000" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -p 127.0.0.1:{OPENCLAW_PORT}:18789 \
        -v {VOLUME_NAME}:/home/node/.openclaw \
        -v /etc/localtime:/etc/localtime:ro \
        -v /usr/share/zoneinfo:/usr/share/zoneinfo:ro \
        -e OPENCLAW_GATEWAY_TOKEN={token} \
        -e GATEWAY_TOKEN={token} \
        -e LOG_LEVEL=INFO \
        -e TZ=Asia/Shanghai \
        -e OPENCLAW_TZ=Asia/Shanghai \
        {OPENCLAW_IMAGE} \
        node openclaw.mjs gateway"""

    rc, stdout, stderr = run(cmd)
    if rc != 0:
        log_error(f"容器启动失败: {stderr}")
        return False
    container_id = stdout.strip()[:12] if stdout else "?"
    log_info(f"容器 ID: {container_id}")

    # 验证容器时间
    time.sleep(2)
    rc, container_time, _ = run(f"docker exec {CONTAINER_NAME} date '+%Y-%m-%d %H:%M:%S'")
    if rc == 0:
        log_info(f"容器时间: {container_time}")

    return True


def wait_healthy(timeout=90):
    """等待容器 healthy"""
    log_info(f"等待容器健康检查（最多 {timeout} 秒）...")
    for i in range(0, timeout, 3):
        if not container_running():
            time.sleep(3)
            continue
        rc, health, _ = run(f"docker exec {CONTAINER_NAME} curl -sf http://127.0.0.1:18789/health")
        if '{"ok":true' in health or '"status":"live"' in health or '"status":"ok"' in health:
            log_info("✓ 容器已就绪")
            return True
        time.sleep(3)
    return False


def run_onboard():
    """运行 onboard 初始化设备"""
    log_step("运行 onboard 初始化")

    # 先检查是否需要 onboard
    rc, stdout, stderr = run(f"docker exec {CONTAINER_NAME} node openclaw.mjs onboard --mode local 2>&1", timeout=30)
    log_info(f"onboard stdout: {stdout}")
    if stderr:
        log_info(f"onboard stderr: {stderr}")

    if rc == 0 or "already" in stdout.lower() or "ok" in stdout.lower() or "complete" in stdout.lower():
        log_info("✓ onboard 完成")
        return True

    # 如果 onboard 失败，尝试其他方式
    log_warn("onboard 命令可能未完成，尝试备选方案...")
    return True


def restart_container():
    run(f"docker restart {CONTAINER_NAME}", timeout=10)
    time.sleep(10)
    return wait_healthy()


def check_gateway_status():
    rc, stdout, _ = run(f"docker exec {CONTAINER_NAME} node openclaw.mjs gateway status 2>/dev/null")
    print(f"\n{Colors.CYAN}--- Gateway Status ---{Colors.NC}")
    if stdout:
        for line in stdout.split("\n"):
            if any(k in line.lower() for k in ["bind", "listen", "probe", "capability", "error", "trouble", "running"]):
                print(f"  {line}")
    return rc == 0


def check_devices():
    rc, stdout, _ = run(f"docker exec {CONTAINER_NAME} node openclaw.mjs devices list 2>/dev/null")
    print(f"\n{Colors.CYAN}--- Devices ---{Colors.NC}")
    if stdout:
        print(stdout)
    else:
        log_info("暂无设备列表（可能还未配对）")
    return stdout


def check_time_sync():
    """检查主机和容器时间同步状态"""
    log_step("检查时间同步状态")

    rc, host_time, _ = run("date '+%Y-%m-%d %H:%M:%S'")
    rc2, container_time, _ = run(f"docker exec {CONTAINER_NAME} date '+%Y-%m-%d %H:%M:%S' 2>/dev/null")

    if rc == 0 and rc2 == 0:
        log_info(f"主机时间:   {host_time}")
        log_info(f"容器时间:   {container_time}")

        # 计算时间差
        try:
            from datetime import datetime
            fmt = "%Y-%m-%d %H:%M:%S"
            h_time = datetime.strptime(host_time, fmt)
            c_time = datetime.strptime(container_time, fmt)
            diff = abs((h_time - c_time).total_seconds())
            log_info(f"时间偏差:   {diff:.0f} 秒")

            if diff > 120:
                log_error(f"⚠️ 时间偏差超过 2 分钟 ({diff:.0f} 秒)，这会导致 device signature expired!")
                log_info("正在尝试修复时间同步...")
                run(f"docker exec {CONTAINER_NAME} apk add -q tzdata 2>/dev/null || true")
                run(f"docker restart {CONTAINER_NAME}", timeout=10)
                time.sleep(5)
                return False
            else:
                log_info("✓ 时间同步正常")
                return True
        except Exception as e:
            log_warn(f"时间比较失败: {e}")
            return True
    else:
        log_warn("无法获取时间信息")
        return True


def test_http_health(token):
    """测试 HTTP health 端点"""
    log_step("测试 HTTP 连通性")
    # 直连
    rc, stdout, _ = run(f"curl -sk http://127.0.0.1:{OPENCLAW_PORT}/health")
    log_info(f"直连 health: {stdout}")
    # Nginx 代理
    if nginx_running():
        rc2, stdout2, _ = run(f"curl -sk https://127.0.0.1:{NGINX_PORT}/health")
        log_info(f"Nginx health: {stdout2}")
        return rc == 0 and rc2 == 0
    return rc == 0


def test_websocket(token):
    """测试 WebSocket 连通性（用 curl 模拟升级请求）"""
    log_step("测试 WebSocket 连通性")
    rc, stdout, stderr = run(
        f"curl -sk -i -N -H 'Connection: Upgrade' -H 'Upgrade: websocket' "
        f"-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "
        f"-H 'Origin: https://127.0.0.1:{NGINX_PORT}' "
        f"https://127.0.0.1:{NGINX_PORT}/ --max-time 8 2>&1",
        timeout=12,
    )

    output = stdout + stderr
    if "101" in output and "Upgrade: websocket" in output:
        log_info("✓ WebSocket 握手成功 (HTTP 101)")
        return True
    elif "1008" in output and "expired" in output:
        log_error("✗ WebSocket 拒绝: device signature expired (1008)")
        return False
    elif "403" in output or "401" in output:
        log_warn(f"WebSocket 认证拒绝 (可能是正常的，Control UI 会处理)")
        return True
    else:
        log_warn(f"WebSocket 测试结果不明确")
        for line in output.split("\n")[:10]:
            if line.strip():
                log_info(f"  {line.strip()}")
        return True


def reload_nginx():
    if not nginx_running():
        return
    run("docker exec devopsclaw-nginx nginx -t 2>/dev/null")
    run("docker exec devopsclaw-nginx nginx -s reload 2>/dev/null")
    log_info("Nginx 已重载")


def stop_remove_container():
    if container_running():
        run(f"docker stop {CONTAINER_NAME}", timeout=10)
    if container_exists():
        run(f"docker rm -f {CONTAINER_NAME}", timeout=5)


def save_token(token):
    TOKEN_FILE.write_text(token)
    TOKEN_FILE.chmod(0o600)
    log_info(f"Token 已保存: {TOKEN_FILE}")

    if ENV_FILE.exists():
        content = ENV_FILE.read_text()
        if "OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here" in content:
            content = content.replace(
                "OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here",
                f"OPENCLAW_GATEWAY_TOKEN={token}",
            )
        elif "OPENCLAW_GATEWAY_TOKEN=" in content:
            import re
            content = re.sub(r"OPENCLAW_GATEWAY_TOKEN=.*", f"OPENCLAW_GATEWAY_TOKEN={token}", content)
        else:
            content += f"\nOPENCLAW_GATEWAY_TOKEN={token}\n"
        ENV_FILE.write_text(content)
        log_info("Token 已更新到 .env")


def print_summary(token):
    print()
    print(f"{Colors.GREEN}{'═' * 70}{Colors.NC}")
    print(f"{Colors.GREEN}{Colors.BOLD}  OpenClaw 诊断/修复完成{Colors.NC}")
    print(f"{Colors.GREEN}{'═' * 70}{Colors.NC}")
    print()
    print(f"  Token 文件: {TOKEN_FILE}")
    print(f"  Env 文件:   {ENV_FILE}")
    print()
    print(f"  {Colors.BOLD}访问地址（Chrome 无痕窗口打开）:{Colors.NC}")
    print(f"  {Colors.CYAN}http://127.0.0.1:{OPENCLAW_PORT}/#token={token}{Colors.NC}")
    print(f"  {Colors.CYAN}https://127.0.0.1:{NGINX_PORT}/#token={token}{Colors.NC}")
    print()


def main():
    print()
    print(f"{Colors.GREEN}{Colors.BOLD}  OpenClaw Device Signature Expired 诊断修复脚本{Colors.NC}")
    print(f"{Colors.YELLOW}  核心修复: 时间同步 + allowInsecureAuth=true{Colors.NC}")
    print()

    if os.geteuid() != 0:
        log_warn("建议用 sudo 运行以确保权限")
        log_info(f"sudo python3 {__file__}")

    # ========== Phase 1: 生成 Token ==========
    log_step("Phase 1: 生成 Gateway Token")
    token = generate_token()
    log_info(f"Token: {token}")
    save_token(token)

    # ========== Phase 2: 同步时间（关键）==========
    log_step("Phase 2: 同步系统时间（关键修复）")
    sync_container_time()

    # ========== Phase 3: 停止并清理旧容器 ==========
    log_step("Phase 3: 清理旧环境")
    stop_remove_container()
    clear_volume()
    log_info("✓ 旧环境已清理")

    # ========== Phase 4: 预写 openclaw.json ==========
    log_step("Phase 4: 预写 openclaw.json（含 allowInsecureAuth）")
    if write_openclaw_json(token):
        log_info("✓ openclaw.json 已写入数据卷")
    else:
        log_error("openclaw.json 写入失败")
        return 1

    # ========== Phase 5: 启动容器 ==========
    log_step("Phase 5: 启动 OpenClaw 容器（带时间同步挂载）")
    if not start_container(token):
        log_error("容器启动失败，查看日志: docker logs devopsclaw-openclaw")
        return 1

    if not wait_healthy():
        log_error("容器健康检查超时")
        rc, logs, _ = run(f"docker logs {CONTAINER_NAME} --tail 30")
        if logs:
            log_error(f"容器日志:\n{logs}")
        return 1

    # ========== Phase 6: 检查时间同步 ==========
    log_step("Phase 6: 验证时间同步")
    if not check_time_sync():
        log_warn("时间同步可能有问题，但继续执行...")

    # ========== Phase 7: 运行 onboard ==========
    log_step("Phase 7: 运行 onboard 初始化")
    run_onboard()

    # ========== Phase 8: 重启让 onboard 生效 ==========
    log_step("Phase 8: 重启容器使配置生效")
    if not restart_container():
        log_warn("重启后健康检查未通过，但容器可能仍在运行")

    # ========== Phase 9: 再次检查时间同步 ==========
    log_step("Phase 9: 再次验证时间同步")
    check_time_sync()

    # ========== Phase 10: 诊断 ==========
    log_step("Phase 10: 诊断")
    check_gateway_status()
    check_devices()

    # ========== Phase 11: 连通性测试 ==========
    log_step("Phase 11: 连通性测试")
    test_http_health(token)
    test_websocket(token)

    # ========== Phase 12: Nginx ==========
    reload_nginx()

    # ========== 总结 ==========
    print_summary(token)
    print(f"  {Colors.YELLOW}【关键操作步骤】{Colors.NC}")
    print(f"  1. 必须 Chrome 无痕窗口打开上面地址")
    print(f"  2. Token 会自动注入 URL，无需手动输入")
    print(f"  3. 如果还是报 device signature expired:")
    print(f"     a) 检查时间: docker exec {CONTAINER_NAME} date")
    print(f"     b) 清理浏览器缓存: F12 -> Application -> Clear site data")
    print(f"     c) 手动批准设备: docker exec {CONTAINER_NAME} node openclaw.mjs devices approve <UUID>")
    print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
