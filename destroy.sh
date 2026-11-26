#!/usr/bin/env bash
# Tears down everything deploy.sh created. Usage: ./destroy.sh [--yes]
set -Eeuo pipefail
cd "$(dirname "$0")"
. ./common.sh

if [ "${1:-}" != "--yes" ]; then
  read -rp "Delete stack '$STACK_NAME' in $AWS_REGION, including all blog data? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 1
fi

log "Deleting CloudFormation stack $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

log "Deleting SSM parameters under $PREFIX"
aws ssm delete-parameters --names "$PREFIX/status" "$PREFIX/admin-password" "$PREFIX/ts-authkey" >/dev/null

log "Done."
echo "    The Tailscale node stays in your tailnet as offline: remove it at"
echo "    https://login.tailscale.com/admin/machines so the next deploy gets the same hostname."
