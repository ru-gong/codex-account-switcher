# v0.4.6-rc.1 — account switching and usage synchronization

## 简体中文

本预发布汇总此前的本地更新：支持新版 Codex 内嵌后端，改进切换失败与账号凭据失去同步时的处理，完整显示登录邮箱，并显示各额度窗口的剩余量、重置时间与失败原因。

- 切换前先验证目标，正常退出后再提交；退出失败、共享认证进程仍在运行或取消时停止，并保留必要的恢复状态。
- 同步 Codex 已更新的当前账号凭据；Google 和 Apple 登录按相同的账号与工作区身份规则处理。
- 每 15 分钟查询额度，后台遇到钥匙串权限问题时显示待授权，不主动弹密码窗口。备用账号登录过期仍需要重新登录。
- 支持官方签名的新版嵌套 `CodexCLI.app` 路径及旧版路径，操作前检查协议；不能保证未经测试的所有未来 Codex 版本兼容。

验证：Swift Debug/Release 各 134 项测试、两个配置各 6 项模拟进程验收、9 项发布门槛测试、4 个启动后中断恢复检查点和 7 项隐私测试通过。源码、可达 Git 历史及分发包经过隐私检查。

**这是候选版。** 本次未执行真实账号换号或最新 Codex 的在线验收。完整账号往返、Computer History 连续性、恢复、48 小时观察和另一台 Mac 验收尚未全部完成。支持 macOS 14+ / Apple Silicon；使用 ad-hoc 签名，未经 Apple 公证。安装和授权说明见 README。普通换号不覆盖任务、浏览器、记忆或 History 数据。

下载 App ZIP 和 `SHA256SUMS`，在同一目录运行 `shasum -a 256 -c SHA256SUMS`。源码位于本标签对应的提交。

## English

This pre-release collects the preceding local updates: support for the nested Codex backend, better handling of failed switches and credential synchronization, full local login email display, and remaining usage, reset times, and failure reasons for each usage window.

- Validate the target before requesting normal termination and committing credentials. Quit failures, shared-auth writers, and cancellation stop the flow and retain recovery state where needed.
- Synchronize credentials updated by Codex for an already-saved current account. Google and Apple logins share the same account/workspace identity checks.
- Query usage every 15 minutes. Background Keychain permission failures show an authorization-required state without requesting passwords. Expired inactive logins still require signing in again.
- Discover officially signed nested `CodexCLI.app` and legacy backend paths, with operation-level protocol checks. Compatibility with every untested future Codex version is not guaranteed.

Validation passed: 134 Swift tests in each of Debug/Release, 6 synthetic subprocess scenarios in each configuration, 9 release-gate tests, 4 post-startup interruption checkpoints, and 7 privacy tests. Public source, reachable Git history, and distribution assets were privacy-audited.

**Candidate only.** This publication did not exercise real-account switching or live acceptance against the newest Codex. Full account round trips, Computer History continuity, restore, a 48-hour observation, and second-Mac acceptance remain incomplete. Requires macOS 14+ / Apple Silicon; ad-hoc signed and not Apple-notarized. See the README for installation and authorization. Normal switching does not overwrite task, browser, memory, or History data.

Download the App ZIP and `SHA256SUMS`, then run `shasum -a 256 -c SHA256SUMS` in their directory. Source is available at the tagged commit.
