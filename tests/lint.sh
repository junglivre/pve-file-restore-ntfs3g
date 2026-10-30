#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

missing=0
if ! command -v shellcheck >/dev/null 2>&1; then
    echo 'shellcheck is required; install shellcheck 0.10.0' >&2
    missing=1
fi
if ! command -v actionlint >/dev/null 2>&1; then
    echo 'actionlint is required; install actionlint 1.7.7' >&2
    missing=1
fi
[ "$missing" -eq 0 ] || exit 1

mapfile -d '' shell_files < <(git ls-files -z -- '*.sh')
while IFS= read -r file; do
    shell_files+=("$file")
done < <(find scripts tests -type f -name '*.sh' -print)
shell_files+=(packaging/pve-file-restore-ntfs3g/pve-file-restore-ntfs3g-check)

declare -A seen=()
unique_shell_files=()
for file in "${shell_files[@]}"; do
    if [ -z "${seen[$file]+set}" ]; then
        seen[$file]=1
        unique_shell_files+=("$file")
    fi
done

for file in "${unique_shell_files[@]}"; do
    echo "== bash -n: $file"
    bash -n "$file"
    echo "== shellcheck: $file"
    shellcheck -x "$file"
done

echo '== actionlint'
for workflow in .github/workflows/*.yml; do
    echo "== actionlint: $workflow"
    actionlint "$workflow"
done

echo 'lint passed'
