#!/usr/bin/env bash
set -euo pipefail

inventory_path="${1:-inventories/nonprod/azure_rm.yml}"

ansible-inventory -i "$inventory_path" --graph
