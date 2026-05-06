#!/usr/bin/env python3
# ============================================================
# 文件: webhook_listener.py
# 名称: 极简 Webhook 接收器
# 版本: 1.0.0 (Skill 架构版)
# 功能: 接收 Jenkins Webhook，触发 CI 自愈 Skill
#
# 说明:
# 这是一个极简的 HTTP 服务，只负责:
# 1. 接收 Jenkins 发送的 Webhook
# 2. 解析事件数据
# 3. 调用 CI 自愈核心逻辑 (ci_selfheal.process_event)
#
# 与旧版 Bridge 的区别:
# - 旧版 Bridge: 完整的中间件服务，包含所有自愈逻辑
# - 新版 Listener: 仅接收事件，逻辑在 Skill 中处理
# ============================================================

import os
import sys
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from typing import Dict, Any

# 添加当前目录到路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from ci_selfheal import process_event, Config, setup_logging
    HAS_SELFHEAL = True
except ImportError as e:
    print(f"警告: 无法导入 ci_selfheal: {e}")
    HAS_SELFHEAL = False


# ==================== 配置 ====================
LISTENER_PORT = int(os.getenv("WEBHOOK_PORT", "5000"))
LOG_FILE = os.getenv("WEBHOOK_LOG", "./webhook_listener.log")


# ==================== 日志 ====================
def setup_listener_logging():
    logger = logging.getLogger("webhook_listener")
    logger.setLevel(logging.DEBUG)

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)

    fmt = logging.Formatter('[%(asctime)s] [%(levelname)s] %(message)s')
    ch.setFormatter(fmt)

    if not logger.handlers:
        logger.addHandler(ch)
    
    return logger


LOG = setup_listener_logging()


# ==================== HTTP 请求处理器 ====================
class WebhookHandler(BaseHTTPRequestHandler):
    """Webhook 请求处理器"""
    
    def log_message(self, format, *args):
        # 覆盖默认日志，使用我们的 logger
        LOG.info(f"HTTP: {args[0]}")
    
    def _send_json(self, status_code: int, data: Dict[str, Any]):
        """发送 JSON 响应"""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))
    
    def do_OPTIONS(self):
        """处理 CORS 预检请求"""
        self.send_response(204)
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    
    def do_GET(self):
        """处理 GET 请求 (健康检查等)"""
        parsed = urlparse(self.path)
        
        if parsed.path == '/health':
            self._send_json(200, {
                "status": "healthy",
                "version": "1.0.0",
                "service": "webhook_listener",
                "skill_available": HAS_SELFHEAL,
                "max_retry": Config.MAX_RETRY if HAS_SELFHEAL else None
            })
        elif parsed.path == '/':
            self._send_json(200, {
                "message": "CI Self-Heal Webhook Listener",
                "endpoints": {
                    "POST /webhook/jenkins": "接收 Jenkins 构建事件",
                    "GET /health": "健康检查"
                }
            })
        else:
            self._send_json(404, {"error": "Not Found"})
    
    def do_POST(self):
        """处理 POST 请求 (Webhook)"""
        parsed = urlparse(self.path)
        
        if parsed.path == '/webhook/jenkins':
            self._handle_jenkins_webhook()
        else:
            self._send_json(404, {"error": "Not Found"})
    
    def _handle_jenkins_webhook(self):
        """处理 Jenkins Webhook"""
        try:
            # 读取请求体
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')
            
            # 解析 JSON
            try:
                event = json.loads(body)
            except json.JSONDecodeError:
                # 如果不是 JSON，尝试解析表单数据 (Jenkins Generic Webhook Trigger)
                LOG.warning("收到非 JSON 格式的 Webhook，尝试解析表单数据")
                event = self._parse_form_data(body)
            
            LOG.info(f"收到 Webhook 事件: {json.dumps(event, ensure_ascii=False)[:200]}")
            
            # 标准化事件格式
            normalized_event = self._normalize_event(event)
            
            if not normalized_event.get('jobName'):
                LOG.error("无法解析 Job 名称")
                self._send_json(400, {
                    "status": "error",
                    "message": "无法解析 Job 名称"
                })
                return
            
            # 处理事件
            if HAS_SELFHEAL:
                result = process_event(normalized_event)
                self._send_json(200, {
                    "status": "ok",
                    "event": normalized_event,
                    "result": result
                })
            else:
                # 没有自愈模块，只记录事件
                LOG.warning("ci_selfheal 模块不可用，仅记录事件")
                self._send_json(200, {
                    "status": "accepted",
                    "event": normalized_event,
                    "warning": "ci_selfheal module not available, event only logged"
                })
                
        except Exception as e:
            LOG.error(f"处理 Webhook 失败: {e}")
            self._send_json(500, {
                "status": "error",
                "message": str(e)
            })
    
    def _parse_form_data(self, body: str) -> Dict[str, Any]:
        """解析表单数据 (Jenkins Generic Webhook Trigger 格式)"""
        event = {}
        
        # 尝试解析 URL 编码的表单数据
        try:
            from urllib.parse import parse_qs
            params = parse_qs(body)
            for key, values in params.items():
                event[key] = values[0] if len(values) == 1 else values
        except Exception:
            pass
        
        return event
    
    def _normalize_event(self, event: Dict[str, Any]) -> Dict[str, Any]:
        """标准化事件格式
        
        支持多种格式:
        - 标准格式: {"jobName": "...", "buildNumber": ..., "status": "..."}
        - Jenkins Generic Webhook: {"job_name": "...", "build_number": ...}
        - 其他格式
        """
        normalized = {}
        
        # Job 名称
        for key in ['jobName', 'job_name', 'job', 'name', 'JOB_NAME']:
            if key in event:
                normalized['jobName'] = str(event[key])
                break
        
        # 构建号
        for key in ['buildNumber', 'build_number', 'build', 'number', 'BUILD_NUMBER']:
            if key in event:
                try:
                    normalized['buildNumber'] = int(event[key])
                except (ValueError, TypeError):
                    pass
                break
        
        # 构建状态
        for key in ['status', 'result', 'currentResult', 'STATUS', 'RESULT']:
            if key in event:
                normalized['status'] = str(event[key]).upper()
                break
        
        # 如果没有状态，默认为 FAILURE (因为通常是失败时触发)
        if 'status' not in normalized:
            normalized['status'] = 'FAILURE'
        
        # 复制其他字段
        for key, value in event.items():
            if key not in normalized:
                normalized[key] = value
        
        return normalized


# ==================== 启动 ====================
def run_server(port: int = LISTENER_PORT):
    """启动 Webhook 服务"""
    server = HTTPServer(('0.0.0.0', port), WebhookHandler)
    
    LOG.info(f"Webhook Listener 启动，端口: {port}")
    print(f"""
╔═══════════════════════════════════════════════════════════════╗
║         CI Self-Heal Webhook Listener v1.0.0                  ║
╠═══════════════════════════════════════════════════════════════╣
║  监听端口:    {str(port).ljust(48)}║
║  自愈模块:    {'可用 (HAS_SELFHEAL=True)' if HAS_SELFHEAL else '不可用'}.ljust(48)║
╠═══════════════════════════════════════════════════════════════╣
║  健康检查:    GET  http://127.0.0.1:{port}/health              ║
║  Webhook:     POST http://127.0.0.1:{port}/webhook/jenkins    ║
╚═══════════════════════════════════════════════════════════════╝
    """)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("Webhook Listener 已停止")
        server.shutdown()


def main():
    """命令行入口"""
    import argparse
    
    parser = argparse.ArgumentParser(
        description='CI 自愈 Webhook 接收器',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument('--port', type=int, default=LISTENER_PORT,
                        help=f'监听端口 (默认: {LISTENER_PORT})')
    parser.add_argument('--test-event', type=str,
                        help='测试事件 JSON 文件路径（不启动服务，直接处理）')
    
    args = parser.parse_args()
    
    if args.test_event:
        # 测试模式：不启动服务，直接处理事件
        with open(args.test_event, 'r', encoding='utf-8') as f:
            event = json.load(f)
        
        if HAS_SELFHEAL:
            result = process_event(event)
            print(json.dumps(result, indent=2, ensure_ascii=False))
        else:
            print("错误: ci_selfheal 模块不可用")
            sys.exit(1)
    else:
        # 启动服务
        run_server(args.port)


if __name__ == '__main__':
    main()
