# Release checklist / 发布检查

Publish from a clean checkout whose complete reachable Git history has been reviewed. Removing a file in the newest commit does not remove it from prior commits.

1. Keep real accounts, private evidence, backups, screenshots of real sessions, and local configuration outside the publish checkout.
2. Run `python3 scripts/privacy_audit.py .`. For a personal-identifier check, provide `--extra-deny-file` pointing to a private JSON list outside the checkout. Never commit that list.
3. Run the Swift tests and synthetic process acceptance. Record whether real-user acceptance is complete; do not replace it with synthetic test results.
4. Run `zsh scripts/package.sh`. The packager uses anonymous compiler path mappings, strips debug symbols, includes only reviewed public resources, and scans source and ZIP contents before returning.
5. Scan the exact assets again with `python3 scripts/privacy_audit.py dist/0.4.2/CodexAccountSwitcher-0.4.2-macOS-arm64.zip`. Inspect repository commit authors, messages, and filenames as well.
6. Upload only the App ZIP and `SHA256SUMS` to the GitHub Release. GitHub's source downloads come from the clean tagged commit. Never attach the entire working directory, `.git`, build logs, or private validation records.
7. For this candidate use a pre-release tag such as `v0.4.2-rc.1`. Do not mark the release stable until real-world acceptance is complete. Download the published assets again and compare SHA256.

No Developer account is required for the default ad-hoc, unnotarized distribution. Recipients may need to allow the individual app in macOS Privacy & Security. Never disable Gatekeeper globally or ask for passwords in an issue.

The optional `--release` packaging gate requires evidence tied to the current source ID; it is separate from putting a **candidate** in GitHub Releases. Optional `--distribution developer-id` also requires the owner's valid identity and notarization profile. No secrets belong in command arguments or repository settings text.

发布前同时检查源码、完整 Git 历史、App 内部文件、Mach-O 二进制及 ZIP。默认分发不要求开发者账号；候选成品放入 GitHub 的预发布 Release，并明确当前支持范围和未完成验收。发布后重新下载核对哈希。
