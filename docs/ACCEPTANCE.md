# Acceptance status / 验收状态

The release is a **candidate / pre-release**. It is available for evaluation within the documented compatibility range, not a declaration of full production acceptance.

| Check | Status |
| --- | --- |
| Swift unit tests | 67 passed in Debug and Release |
| Synthetic subprocess recovery | 6 scenarios per build configuration passed |
| Crash after startup / credential refresh | Synthetic recovery passed |
| Keychain no-prompt policy | Mocked tests and a synthetic native Keychain test passed |
| Real-account repeated switching | Not fully accepted |
| Native menu interaction | Not fully accepted |
| Computer History continuity | Not fully accepted |
| Functional backup restore | Not fully accepted |
| 48-hour observation | Not complete |
| Installation and upgrade on a second Mac | Not complete |

这些自动测试不能代替真实账号与系统行为验收。请勿把 GitHub Release 的存在视为完整功能验收通过。

Private development evidence, account identifiers, business-site sessions, screenshots of real accounts, and host-specific crash reports are deliberately excluded. The public tests generate synthetic data. This document records validation scope without publishing an individual's activity history.
