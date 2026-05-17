# DevOpsAgent

> **World's First pipecircle** - AI-powered CI/CD Self-Healing Pipeline
> 
> **Next-Generation CI/CD System**: Built on Highly Stable Jenkins + AI-Powered Agent with New Quality Productive Forces

---

## Quick Start

### One-Click Deployment

```bash
cd DevOpsAgent
cp .env.example .env
chmod +x deploy_all.sh
sudo ./deploy_all.sh
```

Deployment Modes:
- **[1] Full Deployment + Nginx** (Production)
- **[4] Core Deployment** (Local Development, Recommended)

### Docker Compose

```bash
cp .env.example .env
docker compose up -d
```

---

## Port Allocation

| Service | Port | Description |
|---------|------|-------------|
| Jenkins | 8081 | Web UI |
| Jenkins Agent | 50000 | Master-Slave Communication |
| Agent | 18789 | AI Platform |
| GitLab HTTP | 8082 | Web UI |
| GitLab SSH | 2222 | Git Operations |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Nginx (Reverse Proxy)              │
│         SSL Termination · Unified Logs · Port-based   │
│                        Forwarding                       │
└─────────────────────────────────────────────────────┘
                          │
                          ▼ HTTP
┌───────────┐ ┌───────────┐ ┌───────────┐
│  Agent │ │  Jenkins  │ │  GitLab   │
│   (AI)    │ │   (CI)    │ │  (Repo)   │
└───────────┘ └───────────┘ └───────────┘
```

### Self-Healing Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CI Build Failure Trigger                          │
│              Jenkins / GitLab CI / GitHub Actions                    │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  G0 · Security Gate                                                  │
│  · Whitelist check: repo + branch allowed?                           │
│  · Protected branches (main/release/*) → block directly              │
│  · Deduplication lock: same (repo + branch + error type)             │
└─────────────────┬───────────────┬───────────────────────────────────┘
                  │               │
           ✅ Pass         ❌ Block → notify + log
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  S1 · Information Collection                                         │
│  · Build logs (raw + parsed)                                         │
│  · Pipeline DSL / JJB YAML (read-only, no modification)              │
│  · Source diff + environment snapshot                                │
│  · Historical failure pattern matching + desensitization             │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  G1 · Failure Pre-check                                              │
│  Block non-self-healable scenarios:                                  │
│  · Infrastructure down / Flaky Test / Security gate / 3rd-party down │
│  · Business logic bugs (assertion failure / regression) → manual     │
│  · Self-healable: compile / dependency / config / env var missing    │
└─────────────────┬───────────────┬───────────────────────────────────┘
                  │               │
           ✅ Healable     ❌ Non-healable → diagnosis report → manual
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  S2 · AI Diagnosis                                                   │
│  Input: desensitized logs + DSL + diff + historical failures         │
│  Output: root cause + fix code + type tag + confidence (0.0~1.0)     │
│    · ≥ 0.85 → high confidence, auto-fix                              │
│    · 0.60~0.85 → medium confidence, needs verification               │
│    · < 0.60 → low confidence, degrade to suggestion only             │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  S3 · Fix Decision                                                   │
│                                                                      │
│  Decision Matrix (error type × Git permission × confidence):         │
│  ┌─────────────────┬──────────────────────┬─────────────────────┐    │
│  │  Error Type     │  ✅ Git + Write      │  ❌ No Git/No Write │    │
│  ├─────────────────┼──────────────────────┼─────────────────────┤    │
│  │ Compile/Dep/    │  Create fix branch   │  Generate Patch     │    │
│  │ Config          │  → commit → push     │  for manual apply   │    │
│  │                 │  → trigger rebuild   │                     │    │
│  │                 │  → create PR         │                     │    │
│  ├─────────────────┼──────────────────────┼─────────────────────┤    │
│  │ Test failure/   │  Generate Patch      │  Generate Patch     │    │
│  │ Logic change    │  → notify maintainer │  → notify ops       │    │
│  ├─────────────────┼──────────────────────┼─────────────────────┤    │
│  │ Environment/    │  Generate suggestion │  Generate suggestion│    │
│  │ Infrastructure  │  → notify ops        │  → notify ops       │    │
│  └─────────────────┴──────────────────────┴─────────────────────┘    │
│                                                                      │
│  Special: CANNOT_FIX_SRC (needs business code change) → stop, manual │
│  Confidence < 0.60 → degrade to diagnosis report regardless of type  │
└─────────────────────────────────────────────────────────────────────┘
                            │
                  ┌─────────┴─────────┐
                  │                   │
           Trigger auto-rebuild   Patch/Report output
            (branch path only)     → manual review
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  S4 · Verification Loop                                              │
│                                                                      │
│  Auto-rebuild path:                                                  │
│    ✅ Success → auto-create PR (fix→target) + AI diagnosis → Review  │
│    ❌ Failure → retry check (max 3 times) → carry historical Reward   │
│              → exceeded → circuit breaker → alert → manual fallback  │
│                                                                      │
│  Manual path:                                                        │
│    → review Patch → manual apply → trigger rebuild → record result   │
│                                                                      │
│  Feedback loop:                                                      │
│    PR result (accepted/rejected/modified) → store → Prompt optimize  │
└─────────────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════
  [ Foundation ] · Capabilities across all stages
  · 🔒 Concurrency control: one event per repo+branch (file lock/semaphore)
  · 📝 Audit log: full traceability of all AI decisions and auto-operations
  · 🔌 Extension points: G0 whitelist/G1 pre-check/S2 model/S3 matrix configurable
═══════════════════════════════════════════════════════════════════════
```

---

## Common Commands

```bash
# Deploy
sudo ./deploy_all.sh

# Docker Compose
docker compose up -d
docker compose ps
docker compose logs -f
docker compose down

# Get Passwords
docker exec devopsagent-jenkins cat /var/jenkins_home/secrets/initialAdminPassword
docker exec devopsagent-gitlab cat /etc/gitlab/initial_root_password

# SSL Certificates
./deploy_nginx/generate_certs.sh
```

---

## FAQ

### Q: Docker Compose Installation Failed

**If using Docker Desktop (WSL Integration):**
1. Settings → Resources → WSL Integration
2. Enable your distribution
3. Restart WSL: `wsl --shutdown`

**Manual Installation:**
```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install docker-compose-plugin
```

---

## Supported Environments

- ✅ WSL Ubuntu 22.04 / 24.04
- ✅ Native Ubuntu 22.04 / 24.04
- ✅ Docker / Docker Compose

---

## Documentation

- `doc/9deploy_ci_tool.md` - Complete Deployment Design (Chinese)
- `doc/3自愈式流水线.md` - Self-Healing Architecture (Chinese)
- `doc/5mvp_jenkins_rerun.md` - Version Iteration Notes (Chinese)

---

**中文版文档**: [README_zh.md](README_zh.md)

**Next Step**: Read `doc/9deploy_ci_tool.md` for detailed design.
