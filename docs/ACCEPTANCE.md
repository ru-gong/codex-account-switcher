# Acceptance status / 验收状态

`0.4.6` (build `408`, tag `v0.4.6-rc.1`) is a **public pre-release candidate**. Full login emails are stored and displayed locally, outside sanitized diagnostics and public source. It is not a declaration of full production acceptance.

## Publication checks: 2026-11-21 / 本次发布检查

| Check | Status |
| --- | --- |
| Swift unit tests | Debug 134/134 and Release 134/134 passed |
| Synthetic subprocess recovery | Debug 6/6 and Release 6/6 passed |
| Release gate | 9/9 passed with mocked signing identities |
| Crash after startup / credential refresh | All 4 synthetic checkpoints passed |
| Privacy scanner tests | 7/7 passed |
| Public source and reachable Git history | Privacy audit passed; generic contributor identity |
| Real accounts, native Keychain, and current Codex live compatibility | Not exercised for this publication |

These checks were rerun against the current application code. Publication changes only the package version and public documentation; prior live observations below are not promoted to new live acceptance.

## Recorded baseline: 0.4.6-local.1 / 前一候选的验收记录

The results below belong to `0.4.6-local.1` (build `406`), checked against Codex `26.1021.31345 (21828)` and backend `0.164.0-alpha.11.1`. They have not been relabeled as new checks for `0.4.6`.

| Check | Status |
| --- | --- |
| Swift unit tests | 134 passed in Debug and 134 passed in Release |
| New official backend layout | Nested `CodexCLI.app` and legacy executable paths; desktop and backend signature checks; unexpected files and symlinks rejected |
| Quota display and identity | Remaining percentage, server reset date, and countdown displayed; response `accountId`, when present, must match the requested account |
| Current-account live quota probe | Passed through the isolated official backend using access token only; primary remaining usage and reset time present, secondary window absent; main auth unchanged |
| Automatic quota refresh | Preference persistence, scheduling, partial failures, approval retry, cancellation, and synchronization of an already-saved current account covered by synthetic tests |
| Switch orchestration | Target validation before quit, quit refusal, remaining writers, cancellation, launch failure, and recovery status covered by synthetic tests; no force-kill or automatic retry |
| Synthetic subprocess recovery | 6 Release scenarios passed |
| Crash after startup / credential refresh | Existing synthetic harness retained; no result recorded in this baseline |
| Keychain no-prompt policy | Synthetic native Keychain test passed: foreign identity returned authorization-required without a prompt, and the synthetic item was removed |
| Two Google accounts and one Apple account | Login-provider-neutral identity handling implemented; full real-account round-trip and quota acceptance not complete |
| Native menu interaction | Not fully accepted |
| Computer History continuity | Not fully accepted |
| Functional backup restore | Not fully accepted |
| 48-hour observation | Not complete |
| Installation and upgrade on a second Mac | Not complete |

这些自动测试不能代替真实账号与系统行为验收。当前仅为公开预发布候选，尚未完成两个 Google 登录账号和一个 Apple 登录账号的完整往返切换与额度核对。请勿把打包成功或已有 GitHub Release 视为完整功能验收通过。

## Real-account acceptance still required / 待完成的真实账号验收

1. Record the three saved account aliases and expected Codex account/workspace locally. Do not publish email addresses, account IDs, credentials, or screenshots containing them. Google and Apple login use the same account/workspace identity checks.
2. Refresh each account and compare its remaining usage and reset time with Codex. A failed query must retain an explicitly stale value or show the failure; missing reset times must not be invented. An expired inactive account needs explicit sign-in.
3. Let Codex renew the current saved account's credentials, then refresh. Confirm the same saved entry is updated and usable without duplicating the account. An unknown current account must not be silently imported.
4. Save work and exit shared-auth CLI / IDE processes. Select each target, confirm **退出并切换**, and observe target validation, normal quit, credential commit, and reopen in sequence. Confirm the actual account and workspace in Codex before marking the transaction complete. Complete a round trip through all three accounts.
5. Verify refusal and cancellation: an invalid target must not quit Codex; a refused quit or remaining CLI / IDE writer must not commit. Cancellation before commit must leave credentials unchanged. Failure after commit must retain actionable recovery state and must not automatically retry or roll back.
6. Recheck tasks, browser login state, and Computer History after the round trip, without assuming account-plan eligibility guarantees History continuity. Complete the separate restore, observation-period, and second-Mac checks before declaring full release acceptance.

第三至六项涉及真实系统行为，必须用实际结果记录通过、失败或未完成；“已启动”“待核对”均不等于换号成功。日常换号不修改任务、浏览器或 History 数据，但这些功能的连续性仍需单独观察。

Private development evidence, account identifiers, business-site sessions, screenshots of real accounts, and host-specific crash reports are deliberately excluded. The public tests generate synthetic data. This document records validation scope without publishing an individual's activity history.
