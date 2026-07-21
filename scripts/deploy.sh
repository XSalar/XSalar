#!/usr/bin/env bash
# =====================================================================
# One-command deploy wrapper around the Ansible play.
#
#   scripts/deploy.sh check              # dry-run (--check --diff)
#   scripts/deploy.sh primary            # deploy only the primary node
#   scripts/deploy.sh all                # deploy both nodes
#   scripts/deploy.sh all --autoconfirm  # also auto-confirm firewall
#
# Prereqs: ansible-core installed on YOUR machine; ansible/inventory.ini
# and ansible/group_vars/all.yml filled in (copy the .example files).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/../ansible"

target="${1:-check}"; shift || true
EXTRA=()
[[ "${1:-}" == "--autoconfirm" ]] && EXTRA+=(-e smartdns_fw_autoconfirm=true)

command -v ansible-playbook >/dev/null || { echo "install ansible-core first"; exit 1; }
[[ -f inventory.ini ]] || { echo "copy inventory.ini.example -> inventory.ini and edit"; exit 1; }
[[ -f group_vars/all.yml ]] || { echo "copy group_vars/all.yml.example -> group_vars/all.yml and edit"; exit 1; }

case "$target" in
  check) ansible-playbook site.yml --check --diff "${EXTRA[@]}" ;;
  primary) ansible-playbook site.yml --limit primary "${EXTRA[@]}" ;;
  secondary) ansible-playbook site.yml --limit secondary "${EXTRA[@]}" ;;
  all) ansible-playbook site.yml "${EXTRA[@]}" ;;
  *) echo "usage: deploy.sh {check|primary|secondary|all} [--autoconfirm]"; exit 1 ;;
esac
