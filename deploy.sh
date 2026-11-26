#!/usr/bin/env bash
# One-click Ghost deployment on AWS: no inbound ports, admin via SSM Session Manager,
# public access via Tailscale Funnel.
# Usage: ./deploy.sh   (settings come from .env or the environment, see .env.example)
set -Eeuo pipefail
cd "$(dirname "$0")"
. ./common.sh

INSTANCE_TYPE=${INSTANCE_TYPE:-t3.small}
TS_HOSTNAME=${TS_HOSTNAME:-ghost}
GHOST_ADMIN_EMAIL=${GHOST_ADMIN_EMAIL:-admin@example.com}
BLOG_TITLE=${BLOG_TITLE:-My Ghost Blog}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1200}
FUNNEL_TIMEOUT=${FUNNEL_TIMEOUT:-900}

print_failure_events() {
  awsq cloudformation describe-stack-events --stack-name "$STACK_NAME" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
    --output text 2>/dev/null | head -n 10 >&2 || true
}

# Embed bootstrap.sh into the template's UserData placeholder, keeping its indentation.
package_template() {
  mkdir -p "$BUILD_DIR"
  awk -v f=bootstrap.sh '
    /^ *__BOOTSTRAP__ *$/ {
      ind = $0; sub(/__BOOTSTRAP__.*/, "", ind)
      while ((getline line < f) > 0) { sub(/\r$/, "", line); print (line == "" ? "" : ind line) }
      next
    }
    { sub(/\r$/, ""); print }
  ' template.yaml > "$BUILD_DIR/template.yaml"
}

for cmd in aws jq curl awk; do command -v "$cmd" >/dev/null || die "'$cmd' is required"; done
command -v session-manager-plugin >/dev/null || warn "session-manager-plugin not found: deploy works, 'aws ssm start-session' will not"
ACCOUNT=$(awsq sts get-caller-identity --query Account --output text) || die "AWS credentials are not working"
log "Account $ACCOUNT, region $AWS_REGION, stack $STACK_NAME"

STATUS=$(stack_status)
case "$STATUS" in
  NONE)
    if [ -z "${TS_AUTHKEY:-}" ]; then
      [ -t 0 ] || die "TS_AUTHKEY is not set (add it to .env)"
      read -rsp "Tailscale auth key (tskey-auth-...): " TS_AUTHKEY; echo
    fi
    [[ "$TS_AUTHKEY" == tskey-* ]] || die "That does not look like a Tailscale auth key"

    log "Storing Tailscale auth key in SSM ($PREFIX/ts-authkey, SecureString)"
    aws ssm put-parameter --name "$PREFIX/ts-authkey" --type SecureString --overwrite \
      --value "$TS_AUTHKEY" >/dev/null
    aws ssm delete-parameter --name "$PREFIX/status" >/dev/null 2>&1 || true

    package_template
    log "Creating CloudFormation stack (about 3 min)"
    if ! aws cloudformation deploy \
        --stack-name "$STACK_NAME" \
        --template-file "$BUILD_DIR/template.yaml" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
          "InstanceType=$INSTANCE_TYPE" \
          "TsHostname=$TS_HOSTNAME" \
          "AdminEmail=$GHOST_ADMIN_EMAIL" \
          "BlogTitle=$BLOG_TITLE" \
        --tags "Project=$STACK_NAME" >/dev/null; then
      print_failure_events
      die "Stack creation failed. Run ./destroy.sh before retrying."
    fi
    ;;
  CREATE_COMPLETE|UPDATE_COMPLETE)
    log "Stack already exists ($STATUS), nothing to create; checking its status (run ./destroy.sh to redeploy from scratch)"
    ;;
  *)
    die "Stack is in state $STATUS. Wait for it to settle, or run ./destroy.sh"
    ;;
esac

INSTANCE_ID=$(stack_output InstanceId)
[ -n "$INSTANCE_ID" ] || die "Stack has no InstanceId output"

log "Waiting for $INSTANCE_ID to install Docker, join the tailnet and start Ghost (5-10 min)"
deadline=$((SECONDS + BOOT_TIMEOUT))
last=""
while :; do
  raw=$(awsq ssm get-parameter --name "$PREFIX/status" --query Parameter.Value --output text 2>/dev/null || true)
  if [ -n "$raw" ] && [ "$(jqq -r .instance <<<"$raw")" = "$INSTANCE_ID" ]; then
    state=$(jqq -r .state <<<"$raw")
    msg=$(jqq -r .message <<<"$raw")
    [ "$msg" != "$last" ] && { log "  instance: $msg"; last=$msg; }
    case "$state" in
      ready) break ;;
      failed)
        die "Bootstrap failed: $msg
    Debug: aws ssm start-session --target $INSTANCE_ID
           sudo tail -n 100 /var/log/cloud-init-output.log" ;;
    esac
  fi
  [ "$SECONDS" -lt "$deadline" ] || die "Timed out waiting for bootstrap. Debug: aws ssm start-session --target $INSTANCE_ID"
  sleep 10
done

URL=$(jqq -r .url <<<"$raw")
ADMIN_EMAIL=$(jqq -r .admin <<<"$raw")

# Public DoH resolution tests the Funnel path even from a machine inside the tailnet.
log "Checking $URL through the public internet (Funnel DNS can take a few minutes)"
deadline=$((SECONDS + FUNNEL_TIMEOUT))
code=""
while [ "$SECONDS" -lt "$deadline" ]; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-redirs 5 --max-time 15 \
    --doh-url https://1.1.1.1/dns-query "$URL" 2>/dev/null || true)
  [ "$code" = 200 ] && break
  sleep 15
done
if [ "$code" = 200 ]; then
  log "Public check passed (HTTP 200)"
else
  warn "Public check did not return HTTP 200 (last: ${code:-no response}). Funnel DNS may still be propagating, retry in the browser."
fi

cat <<EOF

  Blog:      $URL
  Admin:     $URL/ghost/
  Login:     $ADMIN_EMAIL
  Password:  MSYS_NO_PATHCONV=1 aws ssm get-parameter --region $AWS_REGION --name $PREFIX/admin-password --with-decryption --query Parameter.Value --output text
  Shell:     aws ssm start-session --region $AWS_REGION --target $INSTANCE_ID
  Verify:    ./verify.sh

EOF
