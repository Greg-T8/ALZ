#!/usr/bin/env bash
# Read-only baseline check for a reusable Azure IaC runner or agent VM.
set -Eeuo pipefail

errors=0
for tool in git pwsh az terraform jq curl tar sha256sum; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '[OK] %-14s %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '[MISSING] %s\n' "$tool"
    ((errors+=1))
  fi
done

for host in login.microsoftonline.com management.azure.com; do
  if getent hosts "$host" >/dev/null 2>&1; then
    printf '[OK] DNS %s\n' "$host"
  else
    printf '[MISSING] DNS %s\n' "$host"
    ((errors+=1))
  fi
done
printf 'Network access to GitHub/Azure DevOps, the selected tenant and the actual Blob backend must be tested separately.\n'
printf 'No Azure login, runner registration, or infrastructure change was performed.\n'
if ((errors)); then
  printf 'Baseline check: %d missing items.\n' "$errors"
  exit 1
fi
printf 'Baseline check: complete.\n'
