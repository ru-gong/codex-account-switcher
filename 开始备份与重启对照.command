#!/bin/zsh
set -uo pipefail
cd "${0:A:h}" || exit 1
if python3 scripts/backup_before_control.py; then
    switcher_result=0
else
    switcher_result=$?
fi
if [[ -t 0 ]]; then
    read -r "switcher_done?结果已保留在上方。按回车结束此窗口。"
fi
exit "$switcher_result"
