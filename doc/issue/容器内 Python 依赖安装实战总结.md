适用场景：无 root、无 pip、无 venv、文件系统受限的 Debian/Ubuntu 容器，以及向 OpenClaw Hub 发布自研 Skill 时的依赖管理。
1. 问题概述
在 node@3c2640357efe 容器中启动 ci-selfheal Skill 时，遇到以下连锁问题：
ModuleNotFoundError: No module named 'yaml' —— 缺少 Python 依赖
No module named pip —— 系统未安装 pip
externally-managed-environment —— Debian 12 禁止全局 pip 安装
Read-only file system: '/app/.venv' —— /app 目录只读，无法创建虚拟环境
Read-only file system: '/home/node/.local' —— 用户目录也受限
ensurepip is not available —— 连 python3 -m venv 都跑不了
结论：这是一个被重度裁剪的容器，所有常规 Python 包管理手段全部失效。
2. 踩坑记录：为什么常见方案都失败了
Table
方案	执行命令	失败原因
直接 pip 安装	python3 -m pip install -r requirements.txt	系统根本没有 pip
ensurepip 安装 pip	python3 -m ensurepip --upgrade	Python 裁剪掉了 ensurepip 模块
get-pip.py 安装到用户目录	python3 get-pip.py --user	~/.local 是只读文件系统
虚拟环境	python3 -m venv .venv	缺少 python3.11-venv 包，且 /app 只读
--break-system-packages	pip install --break-system-packages	pip 本身都没有，无法执行
apt 安装	apt install python3-yaml	无 sudo，且容器通常没 apt 缓存
3. 最终方案：零权限安装 Python 依赖
3.1 核心思路
既然系统 Python 和文件系统都被锁死，唯一可控的可写目录是 /tmp，且 Python 标准库（urllib、zipfile、json）完全可用，那么可以：
用标准库查询 PyPI API，获取依赖包的 wheel 文件列表
下载 wheel 到 /tmp（唯一可写位置）
用 zipfile 解压 wheel 到 /tmp/selfheal-deps（wheel 本质就是 zip）
通过 PYTHONPATH 强制让 Python 加载 /tmp/selfheal-deps
3.2 关键区分：两种 Wheel 类型
Table
类型	文件名特征	适用包	说明
平台相关	cp311-cp311-manylinux_xxx.whl	PyYAML、charset-normalizer	预编译二进制，带 C 扩展
纯 Python	py3-none-any.whl	requests、urllib3、idna、certifi	跨平台通用，无编译依赖
脚本必须优先匹配平台相关 wheel，若未命中则回退到纯 Python wheel。
3.3 完整安装脚本
bash
Copy
#!/bin/bash
set -e

cat > /tmp/get_deps.py << 'PYEOF'
import sys, json, urllib.request, platform, os, zipfile

PYVER = f"cp{sys.version_info.major}{sys.version_info.minor}"
ARCH = platform.machine()
TARGET = "/tmp/selfheal-deps"
os.makedirs(TARGET, exist_ok=True)

def install(pkg_name):
    url = f"https://pypi.org/pypi/{pkg_name}/json"
    data = json.loads(urllib.request.urlopen(url).read())

    whl = None
    # 1. 优先找平台相关预编译 wheel（如 PyYAML）
    for f in data["urls"]:
        if f["packagetype"] != "bdist_wheel":
            continue
        if PYVER in f["filename"] and "manylinux" in f["filename"]:
            whl = f
            break

    # 2. 回退到纯 Python wheel（如 requests、urllib3）
    if not whl:
        for f in data["urls"]:
            if f["packagetype"] != "bdist_wheel":
                continue
            if "py3-none-any" in f["filename"] or "py2.py3-none-any" in f["filename"]:
                whl = f
                break

    if not whl:
        print(f"⚠️  跳过 {pkg_name}（未找到可用 wheel）")
        return

    path = f"/tmp/{whl['filename']}"
    print(f"下载 {whl['filename']}...")
    urllib.request.urlretrieve(whl["url"], path)

    with zipfile.ZipFile(path, 'r') as z:
        z.extractall(TARGET)
    print(f"✅ {pkg_name} -> {TARGET}")

# ==========================================
# 在此处维护你的依赖列表
# ==========================================
DEPENDENCIES = [
    "PyYAML",
    "requests",
    "urllib3",
    "charset-normalizer",
    "idna",
    "certifi",
    # 如需新增依赖，直接在此追加包名
]

for pkg in DEPENDENCIES:
    install(pkg)

print(f"
🎉 全部安装完成")
print(f"启动命令：")
print(f"  PYTHONPATH={TARGET}:$(pwd) python3 -m infra.webhook_listener --host 0.0.0.0 --port 8080")
PYEOF

python3 /tmp/get_deps.py
3.4 启动命令
bash
Copy
cd ~/.openclaw/workspace/skills/ci-selfheal
source .env 2>/dev/null || true
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m infra.webhook_listener --host 0.0.0.0 --port 8080
3.5 保存快捷启动脚本
bash
Copy
cat > ~/run-webhook.sh << 'EOF'
#!/bin/bash
cd ~/.openclaw/workspace/skills/ci-selfheal
source .env 2>/dev/null || true
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m infra.webhook_listener --host 0.0.0.0 --port 8080
EOF
chmod +x ~/run-webhook.sh
以后直接执行 ~/run-webhook.sh 即可。
4. 向 OpenClaw Hub 发布 Skill 的建议
如果 Skill 的目标运行环境可能是这种受限容器，不要让用户手动解决依赖，应在 Skill 内部自举。
4.1 推荐做法：自带安装脚本
在 Skill 根目录放置 install.sh，用户只需执行一次：
bash
Copy
./install.sh   # 自动下载 wheel 到 /tmp
./run.sh       # 启动服务
4.2 进阶做法：Vendor 预置依赖（零网络依赖）
对于完全离线或无外网的容器，将 wheel 文件直接放入 Skill 仓库的 vendor/ 目录：
plain
Copy
ci-selfheal/
├── vendor/
│   ├── PyYAML-6.0.3-cp311-cp311-manylinux_2_28_x86_64.whl
│   ├── requests-2.34.0-py3-none-any.whl
│   └── ...
├── install.sh      # 解压 vendor/*.whl 到 /tmp
└── run.sh
install.sh 只需用 unzip 把 vendor/ 里的 wheel 解压到 /tmp/selfheal-deps，无需联网。
4.3 避免使用 pyproject.toml 的误区
pyproject.toml + pip install . 是标准做法，但在受限容器里完全走不通（没有 pip，无法构建）。因此：
开发环境：使用 pyproject.toml 管理依赖，方便本地开发
生产/容器环境：提供 install.sh 作为兜底，用标准库自举
5. 环境诊断速查表
遇到新容器时，按以下顺序诊断：
bash
Copy
# 1. 检查 pip
python3 -m pip --version          # 没有？继续

# 2. 检查 venv
python3 -m venv /tmp/test-venv    # 失败？继续

# 3. 检查可写目录
touch /tmp/test-write             # 成功 → 用 /tmp 方案
touch ~/.local/test-write         # 失败 → 用户目录也受限

# 4. 检查网络
curl -I https://pypi.org          # 成功 → 走 PyPI 下载
Table
诊断结果	推荐方案
有 pip	pip install -r requirements.txt
无 pip，但 ~/.local 可写	get-pip.py --user + pip install --user
无 pip，~/.local 只读，/tmp 可写	本文档方案：标准库下载 wheel 到 /tmp
完全离线	Vendor 预置 wheel，本地解压
6. 常见错误与解决
Table
错误信息	原因	解决
No module named 'yaml'	PyYAML 未安装	运行安装脚本
No module named 'requests'	requests 未安装	在 DEPENDENCIES 列表中添加 requests
Read-only file system	目标目录不可写	改用 /tmp 作为安装目标
externally-managed-environment	Debian 12 安全机制	不碰系统 Python，用 PYTHONPATH 隔离
Unable to find acceptable character detection dependency	charset-normalizer 未装或版本不兼容	确保 charset-normalizer 在依赖列表中
7. 总结
在极端受限的容器环境中，Python 标准库是唯一可靠的武器。通过 urllib + zipfile 手动处理 wheel 文件，可以完全绕过 pip、venv、apt 等被裁剪或锁死的工具。配合 PYTHONPATH 运行时注入，即可在不污染系统 Python 的前提下，成功启动依赖复杂的自研 Skill。
核心口诀：
没 pip 不用慌，标准库来帮忙。Wheel 丢进 /tmp，PYTHONPATH 指方向。 cat > /tmp/get_deps.py << 'PYEOF'
import sys, json, urllib.request, platform, os, zipfile

PYVER = f"cp{sys.version_info.major}{sys.version_info.minor}"
ARCH = platform.machine()
TARGET = "/tmp/selfheal-deps"
os.makedirs(TARGET, exist_ok=True)

def install(pkg_name):
    url = f"https://pypi.org/pypi/{pkg_name}/json"
    data = json.loads(urllib.request.urlopen(url).read())

    whl = None
    for f in data["urls"]:
        if f["packagetype"] != "bdist_wheel": continue
        
        # 1. 优先找平台相关的预编译 wheel（如 numpy 这种）
        if PYVER in f["filename"] and "manylinux" in f["filename"]:
            whl = f; break

    # 2. 如果没找到，退而求其次找纯 Python wheel（requests、urllib3 等）
    if not whl:
        for f in data["urls"]:
            if f["packagetype"] != "bdist_wheel": continue
            if "py3-none-any" in f["filename"] or "py2.py3-none-any" in f["filename"]:
                whl = f; break

    if not whl:
        print(f"⚠️  跳过 {pkg_name}（没找到 wheel）"); return

    path = f"/tmp/{whl['filename']}"
    print(f"下载 {whl['filename']}...")
    urllib.request.urlretrieve(whl["url"], path)

    with zipfile.ZipFile(path, 'r') as z: z.extractall(TARGET)
    print(f"✅ {pkg_name} -> {TARGET}")

# 把你 requirements.txt 里的包名都列在这里
for pkg in ["PyYAML", "requests", "urllib3", "charset-normalizer", "idna", "certifi"]:
    install(pkg)

print(f"\n安装完成。启动命令：")
print(f"  PYTHONPATH={TARGET}:$(pwd) python3 -m infra.webhook_listener --host 0.0.0.0 --port 8080")
PYEOF

python3 /tmp/get_deps.py