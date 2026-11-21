# Privacy / 隐私

Normal switching reads the user's default Codex authentication file and writes a replacement only through the transaction engine after the required checks. Saved credentials live in macOS Keychain; local metadata lives in the switcher's private Application Support directory. A redacted diagnostic export uses an explicit field allowlist.

Full login email addresses are stored in that local metadata and displayed in the account list to help distinguish accounts. They are excluded from sanitized diagnostic exports, the public source tree, and distribution artifacts. Screenshots of the local list can contain those emails and should not be treated as sanitized evidence.

Quota refresh may copy newly refreshed credentials from the default Codex file into the same already-saved current account. It does not import an unknown account or rotate inactive accounts' refresh tokens. Login-provider labels and email addresses are not used as the account identity.

The separate `switch-attempt.json` status file stores only the last stage, outcome, timestamp, whether credentials may have changed, and an allowlisted error code. It contains no account identifiers, email addresses, or tokens, and it never authorizes recovery in place of the transaction journal.

The App does not contain analytics or a telemetry upload feature. Official login and quota requests use the local Codex backend, which communicates with OpenAI. No third-party account-switching service receives credentials.

Background Keychain access is noninteractive. Only a deliberate authorization action allows a system dialog. The app does not collect the macOS password. Temporary official-login workspaces use private directories; normal completion or cancellation cleans owned temporary data.

Ordinary switching does not copy task databases, browser profiles, memories, or Computer History. The optional encrypted backup helper is a separate, explicitly initiated operation and does copy selected local data to its encrypted destination. Never publish a backup or its password.

The repository and Release assets exclude personal development history, account state, real credentials, private logs, and backups. Build paths are remapped before compilation, and binary / archive content is scanned before upload. The privacy audit is a preventive check, not a mathematical guarantee against every possible identifier: review the exact upload set as well.

普通换号只操作认证文件和切换器自身的数据；可选备份流程另行启动。仓库和发布包不包含真实账号库、登录令牌、浏览器数据、个人验收日志或加密备份。系统密码只应输入 macOS 系统授权窗口。

完整登录邮箱保存在本机账号元数据中，并在账号列表中完整显示，便于区分账号；脱敏诊断、公开源码与分发成品均不包含这些邮箱。本机列表截图可能带有完整邮箱，不能直接视为脱敏证据。
