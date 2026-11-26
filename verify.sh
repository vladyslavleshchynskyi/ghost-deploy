#!/usr/bin/env bash
# Post-deploy checks with PASS/FAIL output. Exits non-zero if any check fails.
# Usage: ./verify.sh
set -Euo pipefail
cd "$(dirname "$0")"
. ./common.sh

PASSED=0
FAILED=0
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '\033[1;31mFAIL\033[0m %s%s\n' "$1" "${2:+  ($2)}"; FAILED=$((FAILED + 1)); }

STATUS=$(stack_status)
[[ "$STATUS" == CREATE_COMPLETE || "$STATUS" == UPDATE_COMPLETE ]] || die "Stack $STACK_NAME is not deployed (state: $STATUS)"
INSTANCE_ID=$(stack_output InstanceId)
PUBLIC_IP=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
read -ra SG_IDS <<<"$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)"
URL=$(awsq ssm get-parameter --name "$PREFIX/status" --query Parameter.Value --output text 2>/dev/null \
  | jqq -r '.url // empty' || true)
log "Stack $STACK_NAME, instance $INSTANCE_ID, public IP $PUBLIC_IP, URL ${URL:-<unknown>}"

rules=$(awsq ec2 describe-security-groups --group-ids "${SG_IDS[@]}" \
  --query 'length(SecurityGroups[].IpPermissions[])' --output text)
if [ "$rules" = 0 ]; then
  pass "Security group(s) ${SG_IDS[*]} have no inbound rules"
else
  fail "Security group(s) ${SG_IDS[*]} have no inbound rules" "$rules inbound rule(s) found"
fi

for port in 22 2368; do
  if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = None ]; then
    fail "Port $port on public IP does not respond" "instance has no public IP to test"
  elif timeout 5 bash -c "exec 3<>/dev/tcp/$PUBLIC_IP/$port" 2>/dev/null; then
    fail "Port $port on $PUBLIC_IP does not respond" "connection accepted"
  else
    pass "Port $port on $PUBLIC_IP does not respond"
  fi
done

mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/ssm-params.json" <<'EOF'
{"commands": [
  "systemctl is-active docker",
  "docker ps --format 'CONTAINER:{{.Names}}={{.Status}}'",
  "echo LISTEN: $(ss -Htln | awk '{print $4}' | grep -E ':(22|2368)$' | tr '\\n' ' ')"
]}
EOF
output=""
cmd_id=$(awsq ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --comment "ghost verify.sh" --parameters "file://$BUILD_DIR/ssm-params.json" \
  --query Command.CommandId --output text 2>&1)
if [[ "$cmd_id" =~ ^[0-9a-f-]{36}$ ]]; then
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null
  inv_status=$(awsq ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null)
  output=$(awsq ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text 2>/dev/null)
  if [ "$inv_status" = Success ]; then
    pass "SSM send-command runs on the instance"
  else
    fail "SSM send-command runs on the instance" "status: ${inv_status:-unknown}"
  fi
else
  fail "SSM send-command runs on the instance" "$cmd_id"
fi

if [ -n "$output" ]; then
  if grep -q '^CONTAINER:ghost-ghost-1=Up' <<<"$output" && grep -q '^CONTAINER:ghost-db-1=Up' <<<"$output"; then
    pass "Ghost and MySQL containers are up"
  else
    fail "Ghost and MySQL containers are up" "$(grep '^CONTAINER:' <<<"$output" | tr '\n' ' ')"
  fi
  listen=" $(grep '^LISTEN:' <<<"$output" | cut -d: -f2-) "
  if grep -qE ' [^ ]*:22 ' <<<"$listen"; then
    fail "sshd is not listening on the instance" "listeners:$listen"
  else
    pass "sshd is not listening on the instance"
  fi
  if grep -qE ' 127\.0\.0\.1:2368 ' <<<"$listen" && ! grep -qE ' (0\.0\.0\.0|\[::\]|\*):2368 ' <<<"$listen"; then
    pass "Ghost (2368) is bound to loopback only"
  else
    fail "Ghost (2368) is bound to loopback only" "listeners:$listen"
  fi
fi

for path in / /ghost/; do
  code=""
  if [ -n "$URL" ]; then
    for _ in 1 2 3; do
      code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-redirs 5 --max-time 20 \
        --doh-url https://1.1.1.1/dns-query "$URL$path" 2>/dev/null || true)
      [ "$code" = 200 ] && break
      sleep 5
    done
  fi
  if [ "$code" = 200 ]; then
    pass "GET $URL$path returns 200 via public DNS"
  else
    fail "GET ${URL:-<unknown>}$path returns 200 via public DNS" "HTTP ${code:-no response}"
  fi
done

snapshot() {
  awsq cloudformation describe-stack-resources --stack-name "$STACK_NAME" \
    --query 'StackResources[].[LogicalResourceId,PhysicalResourceId,ResourceStatus]' --output text | sort
  awsq cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].[StackStatus,LastUpdatedTime]' --output text
}
log "Re-running deploy.sh to check idempotency (output: $BUILD_DIR/redeploy.log)"
before=$(snapshot)
if ./deploy.sh </dev/null >"$BUILD_DIR/redeploy.log" 2>&1; then
  after=$(snapshot)
  if [ "$before" != "$after" ]; then
    fail "Repeated deploy creates nothing" "stack resources changed"
  elif aws ssm get-parameter --name "$PREFIX/ts-authkey" >/dev/null 2>&1; then
    fail "Repeated deploy creates nothing" "auth key parameter was re-created"
  else
    pass "Repeated deploy creates nothing (same stack, same resources, same instance)"
  fi
else
  fail "Repeated deploy creates nothing" "deploy.sh exited non-zero, see $BUILD_DIR/redeploy.log"
fi

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
