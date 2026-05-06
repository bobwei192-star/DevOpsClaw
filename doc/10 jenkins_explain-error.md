Jenkins

Blog
Success Stories
Contributor Spotlight
Documentation
Plugins
Community
Subprojects
Security
About
Support
Download
Explain Error
How to install
Documentation
Releases
Issues
Dependencies
Health Score
Explain Error Plugin

🤖 AI-powered plugin that explains Jenkins job failures with human-readable insights.

Jenkins Plugin GitHub Release Build Status License

🎥 Demo
👉 Watch the hands-on demo on YouTube — setup, run, and see how AI explains your Jenkins job failures.

Overview
Tired of digging through long Jenkins logs to understand what went wrong?

Explain Error Plugin leverages AI to automatically interpret job and pipeline failures—saving you time and helping you fix issues faster.

Whether it’s a compilation error, test failure, or deployment hiccup, this plugin turns confusing logs into human-readable insights.

Key Features
One-click error analysis on any console output
Pipeline-ready with a simple explainError() step
Workspace Context (opt-in) — include selected workspace files for more accurate explanations
AI auto-fix (experimental) — automatically opens a pull request on GitHub, GitLab, or Bitbucket with AI-generated code changes when a build fails
AI-powered explanations via OpenAI GPT models, Google Gemini, DeepSeek, Qwen, AWS Bedrock, local Ollama, or generic Okta-authenticated company AI gateways
Folder-level configuration so teams can use project-specific settings
Smart provider management — LangChain4j handles most providers automatically
Customizable: set provider, model, API endpoint, Okta token flow settings, log filters, and more
Quick Start
Prerequisites
Jenkins (2.528.3) or higher required
Java 17+
AI API Key (OpenAI or Google)
Installation
Install via Jenkins Plugin Manager:

Go to Manage Jenkins → Manage Plugins → Available
Search for "Explain Error Plugin"
Click Install and restart Jenkins
Manual Installation:

Download the .hpi file from releases
Upload via Manage Jenkins → Manage Plugins → Advanced
Configuration
Go to Manage Jenkins → Configure System
Find the "Explain Error Plugin Configuration" section
Configure the following settings:
Setting	Description	Default
Enable AI Error Explanation	Toggle plugin functionality	✅ Enabled
AI Provider	Choose between OpenAI, Google Gemini, DeepSeek, Qwen, AWS Bedrock, Ollama, or Custom Okta AI	OpenAI
API Key	Your AI provider API key	Used by OpenAI, Gemini, DeepSeek, and Qwen providers
API URL	AI service endpoint	Leave empty for official APIs where supported. Required for Custom Okta AI and Ollama providers.
AI Model	Model to use for analysis	Required. Specify the model name offered by your selected AI provider
Custom Context	Additional instructions or context for the AI (e.g., KB article links, organization-specific troubleshooting steps)	Optional. Can be overridden at the job level.
Custom Okta AI adds provider-specific fields for Okta Token URL, Client ID, Client Secret, and optional Scope, API Version, App Key, and custom access-token header settings. This is intended for generic company AI gateways that require an OAuth client-credentials exchange before the chat call.

Click "Test Configuration" to verify your setup
Save the configuration
Configuration

Folder-Level Configuration
Support for folder-level overrides allows different teams to use their own AI providers and models.

Click Configure on any folder
Set a custom AI Provider in "Explain Error Configuration"
Inherits from parent folders, overrides global defaults.

Quota and Metrics
The plugin supports request quotas and usage metrics for provider/model-level visibility. See AI Provider Call Quotas for configuration, collection, and dashboard guidance.

Configuration as Code (CasC)
This plugin supports Configuration as Code for automated setup. Use the explainError symbol in your YAML configuration:

OpenAI Configuration:

unclassified:
  explainError:
    aiProvider:
      openai:
        apiKey: "${AI_API_KEY}"
        model: "gpt-5"
        # url: "" # Optional, leave empty for default
    enableExplanation: true
    customContext: |
      Consider these additional instructions:
      - If the error is from SonarQube Scanner, link to: https://example.org/sonarqube-kb
      - If a Kubernetes manifest failed, remind about cluster-specific requirements
      - Check if the error might be caused by a builder crash and suggest restarting the pipeline
Environment Variable Example:

export AI_API_KEY="your-api-key-here"
Google Gemini Configuration:

unclassified:
  explainError:
    aiProvider:
      gemini:
        apiKey: "${AI_API_KEY}"
        model: "gemini-2.5-flash"
        # url: "" # Optional, leave empty for default
    enableExplanation: true
DeepSeek Configuration:

unclassified:
  explainError:
    aiProvider:
      deepseek:
        apiKey: "${DEEPSEEK_API_KEY}"
        model: "deepseek-v4-flash"
        # url: "https://api.deepseek.com" # Optional, defaults to the official endpoint
    enableExplanation: true
Qwen Configuration:

unclassified:
  explainError:
    aiProvider:
      qwen:
        apiKey: "${DASHSCOPE_API_KEY}"
        model: "qwen-plus"
        # url: "https://dashscope.aliyuncs.com/compatible-mode/v1" # Optional, defaults to China Beijing
    enableExplanation: true
Ollama Configuration:

unclassified:
  explainError:
    aiProvider:
      ollama:
        model: "gemma3:1b"
        url: "http://localhost:11434" # Required for Ollama
    enableExplanation: true
AWS Bedrock Configuration:

unclassified:
  explainError:
    aiProvider:
      bedrock:
        model: "anthropic.claude-3-5-sonnet-20240620-v1:0"
        region: "us-east-1" # Optional, uses AWS SDK default if not specified
    enableExplanation: true
Custom Okta AI Configuration:

unclassified:
  explainError:
    aiProvider:
      customOkta:
        url: "https://chat-ai.example.com/openai/deployments/{model}/chat/completions" # Required
        tokenUrl: "https://id.example.com/oauth2/default/v1/token"                     # Required
        model: "gpt-5-nano"                                                            # Required
        clientId: "${OKTA_CLIENT_ID}"                                                  # Required
        clientSecret: "${OKTA_CLIENT_SECRET}"                                          # Required
        scope: "custom.scope"                                                          # Optional
        apiVersion: "2025-04-01-preview"                                               # Optional
        accessTokenHeader: "api-key"                                                   # Optional (default: Authorization)
        accessTokenPrefix: ""                                                          # Optional (default: empty; sends raw token)
        appKey: "${CUSTOM_AI_APP_KEY}"                                                 # Optional
        userId: "svc-jenkins"                                                          # Optional
        timeoutSeconds: 180                                                            # Optional (default: 180)
    enableExplanation: true
Use tokenUrl for the Okta OAuth exchange and url for the actual chat completions endpoint. This matches providers that separate authentication from inference, such as gateways where the access token is fetched from one URL and the model is invoked on another.

This allows you to manage the plugin configuration alongside your other Jenkins settings in version control.

Supported AI Providers
OpenAI
Models: gpt-4, gpt-4-turbo, gpt-3.5-turbo, etc.
API Key: Get from OpenAI Platform
Endpoint: Leave empty for official OpenAI API, or specify custom URL for OpenAI-compatible services
Best for: Comprehensive error analysis with excellent reasoning
Custom Okta AI
Models: Any model exposed by your company AI gateway
Authentication: Okta OAuth client credentials (client_id + client_secret)
Token URL: Required and separate from the chat completions URL
Chat Endpoint: Required. Supports endpoint templates such as .../deployments/{model}/chat/completions
App Key Support: Optional appKey and userId fields populate the OpenAI-style user metadata payload for providers that require an application key
Access Token Delivery: Configurable header name and optional prefix so the same provider can support Authorization: Bearer ..., api-key: ..., and similar patterns
Best for: Generic company AI providers that use Okta for authentication before invoking a custom chat endpoint
Google Gemini
Models: gemini-2.0-flash, gemini-2.0-flash-lite, gemini-2.5-flash, etc.
API Key: Get from Google AI Studio
Endpoint: Leave empty for official Google AI API, or specify custom URL for Gemini-compatible services
Best for: Fast, efficient analysis with competitive quality
DeepSeek
Models: deepseek-v4-flash, deepseek-v4-pro, etc.
API Key: Get from DeepSeek Platform
Endpoint: Defaults to https://api.deepseek.com, or specify a custom DeepSeek-compatible endpoint
Best for: OpenAI-compatible DeepSeek model access
Qwen
Models: qwen-plus, qwen-flash, qwen3-max, etc.
API Key: Get from Alibaba Cloud Model Studio / DashScope
Endpoint: Defaults to the China Beijing endpoint https://dashscope.aliyuncs.com/compatible-mode/v1; override it for Singapore, US, or Hong Kong regions
Best for: Alibaba Cloud Model Studio Qwen models through the OpenAI-compatible API
AWS Bedrock
Models: anthropic.claude-3-5-sonnet-20240620-v1:0, eu.anthropic.claude-3-5-sonnet-20240620-v1:0 (EU cross-region), meta.llama3-8b-instruct-v1:0, us.amazon.nova-lite-v1:0, etc.
API Key: Not required — uses AWS credential chain (instance profiles, environment variables, etc.)
Region: AWS region (e.g., us-east-1, eu-west-1). Optional — defaults to AWS SDK region resolution
Best for: Enterprise AWS environments, data residency compliance, using Claude models with AWS infrastructure
Ollama (Local/Private LLM)
Models: gemma3:1b, gpt-oss, deepseek-r1, and any model available in your Ollama instance
API Key: Not required by default (unless your Ollama server is secured)
Endpoint: http://localhost:11434 (or your Ollama server URL)
Best for: Private, local, or open-source LLMs; no external API usage or cost
Usage
Method 1: Pipeline Step
No pipeline changes are required for Custom Okta AI. Once the provider is configured globally or at the folder level, existing explainError() calls continue to work unchanged.

Use explainError() in your pipeline (e.g., in a post block):

pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                script {
                    // Your build steps here
                    sh 'make build'
                }
            }
        }
    }
    post {
        failure {
            // Automatically explain errors when build fails
            explainError()
        }
    }
}
✨ NEW: Return Value Support - The step now returns the AI explanation as a string, enabling integration with notifications and alerting:

post {
    failure {
        script {
            // Capture the AI explanation
            def explanation = explainError()
            
            // Use it in notifications
            slackSend(
                color: 'danger',
                message: "Build Failed!\n\nAI Analysis:\n${explanation}"
            )
            
            // Or send to email, webhook, etc.
            emailext body: "Error Analysis:\n${explanation}"
        }
    }
}
Optional parameters:
Parameter	Description	Default
maxLines	Max log lines to analyze (trims from the end)	100
logPattern	Regex pattern to filter relevant log lines	'' (no filtering)
language	Language for the explanation	'English'
customContext	Additional instructions or context for the AI. Overrides global custom context if specified.	Uses global configuration
collectDownstreamLogs	Whether to include logs from failed downstream jobs discovered via the build step or Cause.UpstreamCause	false
downstreamJobPattern	Regular expression matched against downstream job full names. Used only when downstream collection is enabled.	'' (collect none)
includeWorkspaceContext	Include selected workspace files as supporting context for the AI	false
workspaceContextPaths	Comma-separated file paths or glob patterns to include when workspace context is enabled	Common build/config files
workspaceContextMaxBytes	Maximum total bytes of workspace context to include	20000
autoFix	Enable AI auto-fix: the plugin will attempt to generate and commit a code fix, then open a pull request	false
autoFixCredentialsId	Jenkins credentials ID for a personal access token with write access to the repository	''
autoFixScmType	SCM type override: github, gitlab, or bitbucket. Required for self-hosted instances whose hostname is not github.com, gitlab.com, or bitbucket.org	Auto-detected from remote URL
autoFixGithubEnterpriseUrl	Base URL of your GitHub Enterprise instance (e.g. https://github.company.com)	'' (uses api.github.com)
autoFixGitlabUrl	Base URL of your self-hosted GitLab instance (e.g. https://gitlab.company.com)	'' (uses gitlab.com)
autoFixBitbucketUrl	Base URL of your self-hosted Bitbucket instance	'' (uses api.bitbucket.org)
autoFixAllowedPaths	Comma-separated list of file glob patterns the AI is permitted to modify	pom.xml,build.gradle,*.yml,*.yaml,...
autoFixDraftPr	Open the pull request as a draft (GitHub only)	false
autoFixTimeoutSeconds	Maximum seconds to wait for the auto-fix to complete	60
autoFixPrTemplate	Custom Markdown template for the PR body. Supports {jobName}, {buildNumber}, {explanation}, {changesSummary}, {fixType}, {confidence} placeholders	Built-in template
explainError(
  maxLines: 500,
  logPattern: '(?i)(error|failed|exception)',
  language: 'English', // or 'Spanish', 'French', '中文', '日本語', 'Español', etc.
  customContext: '''
    Additional context for this specific job:
    - This is a payment service build
    - Check PCI compliance requirements if deployment fails
    - Contact security team for certificate issues
  '''
)
To include downstream failures, opt in explicitly and limit collection with a regex:

explainError(
  collectDownstreamLogs: true,
  downstreamJobPattern: 'team-folder/.*/deploy-.*'
)
This keeps the default behavior fast and predictable on large controllers. Only downstream jobs whose full name matches downstreamJobPattern are scanned and included in the AI analysis.

To include selected files from the build workspace, opt in with Workspace Context:

explainError(
  includeWorkspaceContext: true,
  workspaceContextPaths: 'pom.xml,Jenkinsfile,src/test/**/*.java',
  workspaceContextMaxBytes: 30000
)
Workspace Context only reads explicitly configured paths and skips common secret or generated paths such as .env*, credentials*, target/, build/, dist/, node_modules/, and .git/.

Output appears in the sidebar of the failed job.

Side Panel - AI Error Explanation

Auto-Fix: Automatic Pull Request Creation (Experimental)
⚠️ Experimental feature. Auto-fix is opt-in and disabled by default. AI-generated diffs can be incorrect or incomplete — always review the PR before merging. See docs/auto-fix.md for a full setup guide, supported SCM providers, limitations, and best practices.

When autoFix: true is set, the plugin goes one step further than explaining the error — it asks the AI to generate a code fix, commits the changes to a new branch, and opens a pull request for your review.

Quick start:

post {
    failure {
        explainError(
            autoFix: true,
            autoFixCredentialsId: 'github-pat'  // Jenkins credential with repo write access
        )
    }
}
The pull request is created on the same repository the build checks out from. The URL appears in the Jenkins build sidebar as soon as the PR is opened.

Self-hosted SCM (GitHub Enterprise / GitLab self-managed / Bitbucket Server / Data Center):

// GitHub Enterprise
explainError(
    autoFix: true,
    autoFixCredentialsId: 'github-pat',
    autoFixScmType: 'github',
    autoFixGithubEnterpriseUrl: 'https://github.company.com'
)

// GitLab self-managed
explainError(
    autoFix: true,
    autoFixCredentialsId: 'gitlab-pat',
    autoFixScmType: 'gitlab',
    autoFixGitlabUrl: 'https://gitlab.company.com'
)

// Bitbucket Server / Data Center
explainError(
    autoFix: true,
    autoFixCredentialsId: 'bitbucket-server-pat',
    autoFixScmType: 'bitbucketserver',
    autoFixBitbucketUrl: 'https://bitbucket.company.com'
)
Restrict which files the AI may change (recommended for production):

explainError(
    autoFix: true,
    autoFixCredentialsId: 'github-pat',
    autoFixAllowedPaths: 'pom.xml,build.gradle,*.properties'
)
The AI will only propose changes to files matching the glob patterns. Any attempt to modify files outside the list is rejected before a branch is created.

Note: Auto-fix requires a personal access token (PAT) with write access to the repository. It does not use the SSH key used to check out the repository.

Method 2: Manual Console Analysis
Works with Freestyle, Declarative, or any job type.

Go to the failed build’s console output
Click Explain Error button in the top
View results directly under the button
AI Error Explanation

Troubleshooting
Issue	Solution
API key not set	Add your key in Jenkins global config
Auth or rate limit error	Check key validity, quota, and provider plan. See AI Provider Call Quotas
Button not visible	Ensure Jenkins version ≥ 2.528.3, restart Jenkins after installation
Enable debug logs:

Manage Jenkins → System Log → Add logger for io.jenkins.plugins.explain_error

Best Practices
Use explainError() in post { failure { ... } } blocks
Apply logPattern to focus on relevant errors
Monitor usage metrics and quota outcomes to control costs (see AI Provider Call Quotas)
Keep plugin updated regularly
Support & Community
GitHub Issues for bug reports and feature requests
Contributing Guide if you'd like to help
Security concerns? Email security@jenkins.io
License
Licensed under the MIT License.

Acknowledgments
Built with ❤️ for the Jenkins community. If you find it useful, please ⭐ us on GitHub!

Version: 159.v1284e4f2fdb_b_
Released: 2 days ago
Requires Jenkins 2.528.3
ID: explain-error
No usage data available
Links
GitHub
Open issues (Github)
Report an issue (Github)
Pipeline Step Reference
Extension Points
Javadoc
Labels
ai
Maintainers
Xinapeng Shen
Help us improve this page!
To propose a change submit a pull request to the plugin page on GitHub.


Creative Commons Attribution-ShareAlike license

The content driving this site is licensed under the Creative Commons Attribution-ShareAlike 4.0 license.

Resources
Downloads
Blog
Documentation
Plugins
Security
Contributing
Project
Structure and governance
Issue tracker
Roadmap
GitHub
Jenkins on Jenkins
Statistics
Community
Forum
Events
Mailing lists
Chats
Special Interest Groups
𝕏 (formerly Twitter)
LinkedIn
Bluesky
Mastodon
Youtube
Reddit
Other
Code of Conduct
Press information
Merchandise
Artwork
Awards
Copyright © 2026 CD Foundation The Linux Foundation®. All rights reserved. The Linux Foundation has registered trademarks and uses trademarks. For a list of trademarks of The Linux Foundation, please see our Trademark Usage page. Linux is a registered trademark of Linus Torvalds. Privacy Policy and Terms of Use.

