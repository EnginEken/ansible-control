#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <inventory> <limit> [playbook]" >&2
  exit 64
fi

inventory_path="$1"
target_limit="$2"
playbook_path="${3:-playbooks/baseline/common.yml}"

ansible-playbook -i "$inventory_path" "$playbook_path" --limit "$target_limit"
