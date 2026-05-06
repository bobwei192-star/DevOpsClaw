flowchart LR
    A["❌ Jenkins 构建失败"] --> B["🔔 通知 OpenClaw"]
    B --> C["📋 收集信息<br/>日志 + Pipeline + 源码"]
    C --> D["🤖 AI 分析 & 修复<br/>三类代码生成"]

    D --> E{"有 Repo 信息?<br/>(研发代码)"}

    E -->|"✅ 有 Repo"| F["📝 写入仓库<br/>fix 分支"]
    E -->|"❌ 无 Repo<br/>(测试机器代码)"| G["🖥️ 直接改被测机器"]

    F --> H["🔄 触发 Jenkins 重建"]
    G --> H

    H --> I{"构建结果?"}
    I -->|"✅ 成功"| J{"有 Repo?"}
    I -->|"❌ 失败"| K{"重试 < 5?"}
    K -->|是| C
    K -->|否| L["🛑 熔断通知"]

    J -->|"✅ 有 Repo"| M["📦 自动提 PR<br/>附带修复说明"]
    J -->|"❌ 无 Repo"| N["📄 生成测试报告<br/>修复摘要 + 验证结果"]

    M --> O["👀 人工 Review & Merge"]
    N --> P["✅ 闭环完成"]

    style A fill:#ff6b6b,color:#fff
    style D fill:#7950f2,color:#fff
    style M fill:#339af0,color:#fff
    style N fill:#20c997,color:#fff
    style P fill:#51cf66,color:#fff
    style L fill:#ff922b,color:#fff