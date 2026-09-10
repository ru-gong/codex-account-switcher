# Privacy / 隐私

Normal switching reads the user's default Codex authentication file and writes a replacement only through the transaction engine after the required checks. Saved credentials live in macOS Keychain; local metadata lives in the switcher's private Application Support directory. A redacted diagnostic export uses an explicit field allowlist.

The App does not contain analytics or a telemetry upload feature. Official login and quota requests use the local Codex backend, which communicates with OpenAI. No third-party account-switching service receives credentials.

Background Keychain access is noninteractive. Only a deliberate authorization action allows a system dialog. The app does not collect the macOS password. Temporary official-login workspaces use private directories; normal completion or cancellation cleans owned temporary data.

Ordinary switching does not copy task databases, browser profiles, memories, or Computer History. The optional encrypted backup helper is a separate, explicitly initiated operation and does copy selected local data to its encrypted destination. Never publish a backup or its password.

The repository and Release assets exclude personal development history, account state, real credentials, private logs, and backups. Build paths are remapped before compilation, and binary / archive content is scanned before upload. The privacy audit is a preventive check, not a mathematical guarantee against every possible identifier: review the exact upload set as well.

普通换号只操作认证文件和切换器自身的数据；可选备份流程另行启动。仓库和发布包不包含真实账号库、登录令牌、浏览器数据、个人验收日志或加密备份。系统密码只应输入 macOS 系统授权窗口。
