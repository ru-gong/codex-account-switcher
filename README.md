# Codex 账号切换台

[English](README.en.md) · 简体中文

一个原生 macOS 菜单栏工具，用于保存多个 Codex 账号、查看额度，并在退出 Codex 后切换账号。

**当前版本：0.4.2 候选版。** GitHub 中的 `v0.4.2-rc.1` 为预发布，不代表完整实机验收完成。应用界面目前为简体中文。

![使用假账号和假额度渲染的菜单栏界面](docs/images/menu-preview.png)

## 功能

- 在一个菜单栏面板查看账号、套餐和各时间窗口的剩余额度。
- 通过 OpenAI 官方浏览器登录添加账号，支持改名、重新登录和删除备用账号。
- 凭据保存在 macOS 钥匙串；需要系统授权时显示“待授权”，后台不主动弹密码窗口。
- 退出 Codex、共享认证的 CLI / IDE 后进行切换，完成后自动打开 Codex。
- 切换中断时保留事务和凭据代次，支持检查后回退及脱敏诊断。

## 下载与安装

从本仓库 [Releases](https://github.com/ru-gong/codex-account-switcher/releases) 下载：

- `CodexAccountSwitcher-0.4.2-macOS-arm64.zip`：可运行的 App 及中英文安装说明。
- `SHA256SUMS`：文件完整性校验。

把两者下载到同一目录，可执行 `shasum -a 256 -c SHA256SUMS` 校验。解压 ZIP，将 `CodexAccountSwitcher.app` 拖到“应用程序”，然后打开；图标显示在菜单栏，不显示 Dock 窗口。

本包使用本地 ad-hoc 签名，**没有 Developer ID，也未经 Apple 公证**。若首次启动被拦截，先尝试打开，再在“系统设置 → 隐私与安全性”中为本 App 选择“仍要打开”。这是 Apple 提供的单应用允许流程，不需要全局关闭 Gatekeeper。[Apple 安装说明](https://support.apple.com/zh-cn/102445)

升级前先退出旧切换台，再替换 App。账号库默认保留。新构建可能再次需要首次打开许可或一次钥匙串显式授权。

## 兼容范围

| 项目 | 当前范围 |
| --- | --- |
| 系统与架构 | macOS 14+，当前成品仅 Apple Silicon / arm64 |
| Codex 安装位置 | `/Applications/Codex.app` |
| 已适配 Codex | `26.908.40834 (8881)`（后端 `0.154.0-alpha.6.2`）；保留 `26.903.61454 (8378)` / `26.903.71938 (8576)`（后端 `0.153.4`） |
| 认证存储 | 默认 `~/.codex`，file 后端 |
| 不支持 | 其他版本、受管认证、非默认 profile、keyring / auto / ephemeral 后端或认证网关覆盖 |

程序会检查 Codex 版本和供应商签名，不满足条件时停止写入。额度接口依赖固定版本的内部、不稳定协议；后续 Codex 更新可能需要重新适配。遇到未知版本时，面板会明确提示兼容性问题并暂停查询与切换。

“额度数据待更新”只表示缓存超过 15 分钟，不表示额度用完或登录过期。真正的登录失效会单独提示重新登录。新版后端明确返回不允许使用包含额度时，会显示该状态，不根据百分比推断恢复。

## 使用

1. 首次打开后点“保存当前账号”，再通过右上角 `+` 添加备用账号。
2. 默认每 15 分钟自动刷新额度，启动、唤醒和打开面板时会补查过期结果；“更多设置”可关闭，设置会在重启后保留。右上角按钮可手动刷新，每个账号显示上次更新时间与失败原因。相同百分比不代表不同套餐的相同绝对额度。
3. 需要钥匙串授权时，点击该账号的“授权此账号”，只在 macOS 系统窗口输入密码，授权成功会立即更新该账号额度。后台不弹授权窗口；若显示“登录已过期”，需重新登录，钥匙串授权不能延长令牌有效期。
4. 正常退出 Codex 及共享登录的 CLI / IDE。关闭窗口不等于退出。点击目标账号的“切换”。
5. 自动重开 Codex 后核对实际账号与工作区，再回切换台点“我已核对账号与工作区”。

**新账号首次切换仍属于候选版验收流程。** 默认模式会阻止切到尚未记录连续性核验的账号。完成备份准备后，可显式启动验收模式：

```sh
open -a /Applications/CodexAccountSwitcher.app --args --live-acceptance
```

若程序已运行，先退出再执行。`--live-acceptance` 仅放行首次能力验证，**不创建隔离环境**，会使用当前系统用户的真实 Codex 账号库。核验任务、已登录浏览器站点和 Computer History 后，在“更多设置 → 验收工具”保存连续性核验记录。验收工具仅在验收模式显示，记录人工观察，不监测或控制 Computer History。

## 数据、隐私与恢复

- 普通账号切换仅受控替换 `~/.codex/auth.json`，不切换或覆盖任务数据库、浏览器 profile、记忆或 Computer History 数据。
- 账号凭据存于 Keychain 服务 `local.codex-account-switcher.credentials.v1`；别名、额度和事务存于 `~/Library/Application Support/CodexAccountSwitcher`。
- 已读取的不可变凭据会在进程内缓存；休眠或用户会话失活时清空。没有钥匙串凭据的明文回退库。
- 登录和额度通过本地官方 Codex 后端通信。额度查询不向子进程传递 refresh token；工具不会在后台主动轮换 refresh token。
- 中断后不会自动重试切换。需要回退时，先退出 Codex，再使用“更多设置 → 退出 Codex 后回退”；回退前保留目标账号启动后的新凭据代次。
- 回退针对认证，不会用整目录备份覆盖新任务或浏览器数据。可选的备份辅助脚本会按用户主动操作复制本地数据到加密镜像，它与日常切换是独立流程。

卸载 App 默认保留账号库；需要移除备用账号时可先在工具内删除。详细边界见 [隐私说明](docs/PRIVACY.md)。

## 当前验证与限制

84 项 Swift 自动测试已在 Debug、Release 配置通过，覆盖事务、并发、故障恢复和禁止后台授权。另有子进程崩溃、合成 Keychain 条目与打包条件测试。

这些结果不代替真实账户验收。完整菜单操作、反复切换、功能恢复、48 小时观察和另一台 Mac 安装尚未全部完成；Computer History 的持续运行仍待验证。不能承诺每个账号或每个版本的 History 都不中断。[验收状态](docs/ACCEPTANCE.md)

## 构建与测试

需要 Xcode / Swift 6 以上和 Python 3。本项目没有第三方 Swift 包依赖。

```sh
git clone https://github.com/ru-gong/codex-account-switcher.git
cd codex-account-switcher
swift test
swift test -c release
python3 scripts/process_acceptance.py
python3 scripts/test_release_gate.py
zsh scripts/package.sh
```

产物位于 `dist/0.4.2/`，同版本目录已存在时拒绝覆盖。`open -n dist/0.4.2/CodexAccountSwitcher.app --args --demo` 使用临时假账号库演示，不连接真实账号。

打包会重映射构建路径、去除调试符号并扫描成品。发布前请执行 [发布与隐私检查流程](docs/RELEASING.md)，不要上传自己的 `evidence/`、账号文件、备份或本机开发历史。

## 项目性质与许可

独立项目，非 OpenAI 官方产品，不包含 Codex 本体。目前未另行授予开源许可。第三方与来源说明见 [NOTICE.md](NOTICE.md)。
