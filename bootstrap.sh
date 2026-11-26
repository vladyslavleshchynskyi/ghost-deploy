# Instance bootstrap. Embedded into EC2 UserData by deploy.sh; the template
# prepends a header that sets the variables checked below.
set -Eeuo pipefail

: "${STACK_NAME:?}" "${AWS_REGION:?}" "${TS_HOSTNAME:?}" "${ADMIN_EMAIL:?}" "${BLOG_TITLE:?}"
export AWS_DEFAULT_REGION="$AWS_REGION" DEBIAN_FRONTEND=noninteractive PATH="$PATH:/snap/bin"
PREFIX="/$STACK_NAME"
GHOST_DIR=/opt/ghost

imds() {
  local token
  token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
  curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}
INSTANCE_ID=$(imds instance-id)

# Progress goes to SSM so deploy.sh can follow it without shell access.
report() { # report <state> <message> [url]
  local body
  body=$(printf '{"instance":"%s","state":"%s","message":"%s","url":"%s","admin":"%s"}' \
    "$INSTANCE_ID" "$1" "$2" "${3:-}" "$ADMIN_EMAIL")
  aws ssm put-parameter --name "$PREFIX/status" --type String --overwrite --value "$body" >/dev/null || true
}
die() { report failed "$1"; echo "FATAL: $1" >&2; exit 1; }
trap 'report failed "bootstrap failed at line $LINENO, see /var/log/cloud-init-output.log"' ERR

echo "==> Disabling sshd (admin access is SSM Session Manager only)"
systemctl disable --now ssh.socket ssh.service 2>/dev/null || true

echo "==> Adding swap"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> Installing packages"
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 jq curl openssl
snap wait system seed.loaded
snap list aws-cli >/dev/null 2>&1 || snap install aws-cli --classic
systemctl enable --now docker
report bootstrapping "packages installed"

echo "==> Joining tailnet"
curl -fsSL https://tailscale.com/install.sh | sh
TS_AUTHKEY=$(aws ssm get-parameter --name "$PREFIX/ts-authkey" --with-decryption \
  --query Parameter.Value --output text) || die "cannot read $PREFIX/ts-authkey"
aws ssm delete-parameter --name "$PREFIX/ts-authkey" || true
tailscale up --auth-key="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" || die "tailscale up failed (auth key invalid or expired?)"
unset TS_AUTHKEY

TS_FQDN=""
for _ in $(seq 60); do
  TS_FQDN=$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
  [ -n "$TS_FQDN" ] && break
  sleep 2
done
[ -n "$TS_FQDN" ] || die "no MagicDNS name assigned (is MagicDNS enabled?)"
# Fail fast: without the funnel nodeAttr the final step would hang until timeout.
tailscale status --json | jq -e '.Self.CapMap // {} | has("funnel") and has("https")' >/dev/null \
  || die "node is not allowed to use Funnel (tags: $(tailscale status --json | jq -c '.Self.Tags')). Use an auth key tagged tag:ghost and grant the funnel nodeAttr to that tag"
GHOST_URL="https://$TS_FQDN"
report bootstrapping "joined tailnet as $TS_FQDN"

echo "==> Starting Ghost at $GHOST_URL"
mkdir -p "$GHOST_DIR"
cd "$GHOST_DIR"
if [ ! -f .env ]; then
  (umask 077; cat > .env <<EOF
GHOST_URL=$GHOST_URL
DB_PASSWORD=$(openssl rand -hex 24)
DB_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
  )
fi

cat > docker-compose.yml <<'EOF'
services:
  db:
    image: mysql:8.4
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/mysql
    healthcheck:
      # TCP ping only succeeds once the real server is up (the init server runs without networking).
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "--silent"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s

  ghost:
    image: ghost:6-alpine
    restart: always
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:2368:2368"
    environment:
      url: ${GHOST_URL}
      database__client: mysql
      database__connection__host: db
      database__connection__user: ghost
      database__connection__password: ${DB_PASSWORD}
      database__connection__database: ghost
      # No SMTP configured, so emailed login codes for new devices cannot be delivered.
      security__staffDeviceVerification: "false"
    volumes:
      - ghost-content:/var/lib/ghost/content

volumes:
  db-data:
  ghost-content:
EOF

for _ in 1 2 3; do docker compose pull && break; sleep 10; done
docker compose up -d

# Talk to Ghost as if the request came through the HTTPS proxy, otherwise it redirects to $GHOST_URL.
ghost_api() {
  curl -sS -H "Host: $TS_FQDN" -H "X-Forwarded-Proto: https" -H "Origin: $GHOST_URL" \
    -H 'Content-Type: application/json' "http://127.0.0.1:2368/ghost/api/admin/$1" "${@:2}"
}

SETUP=""
for _ in $(seq 120); do
  SETUP=$(ghost_api authentication/setup/ 2>/dev/null) && jq -e '.setup[0]' <<<"$SETUP" >/dev/null 2>&1 && break
  SETUP=""
  sleep 5
done
[ -n "$SETUP" ] || die "Ghost did not become ready, see: docker compose -f $GHOST_DIR/docker-compose.yml logs"

# Create the owner account before the site goes public, so nobody else can claim /ghost/#/setup.
if [ "$(jq -r '.setup[0].status' <<<"$SETUP")" != "true" ]; then
  echo "==> Creating Ghost owner account"
  ADMIN_PASSWORD=$(openssl rand -hex 16)
  aws ssm put-parameter --name "$PREFIX/admin-password" --type SecureString --overwrite \
    --value "$ADMIN_PASSWORD" >/dev/null
  payload=$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg t "$BLOG_TITLE" \
    '{setup: [{name: "Admin", email: $e, password: $p, blogTitle: $t}]}')
  code=$(ghost_api authentication/setup/ -X POST -d "$payload" -o /tmp/ghost-setup.json -w '%{http_code}')
  rm -f /tmp/ghost-setup.json
  [[ "$code" == 2?? ]] || die "Ghost owner setup failed (HTTP $code)"
fi

echo "==> Publishing via Tailscale Funnel"
timeout 120 tailscale funnel --bg 2368 \
  || die "tailscale funnel failed: check HTTPS certs are enabled and the policy grants the funnel nodeAttr to this node"

report ready "Ghost is live" "$GHOST_URL"
echo "==> Done: $GHOST_URL"
