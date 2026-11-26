# Ghost on AWS with no public SSH

One command deploys a [Ghost](https://ghost.org) blog to AWS EC2 with **zero inbound ports**:

- **Admin access** goes through AWS SSM Session Manager. There is no SSH key, `sshd` is disabled, and the security group has no inbound rules.
- **Public access** goes through Tailscale Funnel at `https://<host>.<tailnet>.ts.net`, with TLS handled by Tailscale.

```
Internet ──HTTPS──> Tailscale Funnel ──tunnel──> tailscaled (EC2) ──> 127.0.0.1:2368 Ghost ──> MySQL 8.4
You ──aws ssm start-session──> SSM agent (EC2, outbound 443 only)
```

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | One-click deploy: stores the auth key in SSM, creates the stack, waits for bootstrap, checks the public URL |
| `verify.sh` | Post-deploy PASS/FAIL checks (see below) |
| `destroy.sh` | Deletes the stack and its SSM parameters |
| `template.yaml` | CloudFormation: VPC, security group, IAM role, EC2 |
| `bootstrap.sh` | Instance setup. `deploy.sh` embeds it into the template's UserData |
| `common.sh` | Shared helpers and `.env` loading |
| `.env.example` | Settings template |

## What gets created

| Resource | Notes |
|---|---|
| VPC, public subnet, IGW | Public IP is used for outbound only: SSM, Tailscale, image pulls |
| Security group | **No inbound rules** |
| EC2 `t3.small`, Ubuntu 24.04 | IMDSv2 only, encrypted gp3, 2 GB swap, `sshd` disabled |
| IAM role | `AmazonSSMManagedInstanceCore`, plus read/write on `/<stack>/*` SSM parameters only |
| Docker Compose | `ghost:6-alpine` + `mysql:8.4`. Ghost listens on loopback only |

## Prerequisites

1. AWS CLI v2 configured with admin credentials, `jq`, `curl`, and the Session Manager plugin. On Windows, run the scripts from Git Bash.
2. Tailscale:
   - MagicDNS and HTTPS certificates enabled (**DNS** page).
   - Access controls allow Funnel for a tag:
     ```jsonc
     "tagOwners": { "tag:ghost": ["autogroup:admin"] },
     "nodeAttrs": [ { "target": ["tag:ghost"], "attr": ["funnel"] } ]
     ```
   - An auth key (**Settings → Keys**) that is **reusable** with tag **`tag:ghost`**. Tagged nodes have key expiry disabled, so the blog does not go offline after 180 days.

## Configure

```bash
cp .env.example .env    # then set TS_AUTHKEY and GHOST_ADMIN_EMAIL
```

All scripts load `.env` automatically. Variables already set in the environment take precedence, e.g. `STACK_NAME=test ./deploy.sh`.

| Variable | Default | |
|---|---|---|
| `TS_AUTHKEY` | — | Required for the first deploy. If it is missing, `deploy.sh` prompts for it |
| `GHOST_ADMIN_EMAIL` | `admin@example.com` | Ghost owner login |
| `BLOG_TITLE` | `My Ghost Blog` | |
| `STACK_NAME` | `ghost-blog` | Also the SSM parameter prefix |
| `AWS_REGION` | from `aws configure` | |
| `INSTANCE_TYPE` | `t3.small` | 2 GB minimum for Ghost + MySQL |
| `TS_HOSTNAME` | `ghost` | Tailscale machine name, i.e. the first label of the URL |

`.env` is git-ignored.

## Deploy

```bash
./deploy.sh
```

It takes about 5–10 minutes. At the end the script prints the blog URL, admin URL, login, and the command that fetches the admin password from Parameter Store. The password itself is never printed:

```bash
MSYS_NO_PATHCONV=1 aws ssm get-parameter --name /ghost-blog/admin-password \
  --with-decryption --query Parameter.Value --output text
```

`MSYS_NO_PATHCONV=1` is only needed in Git Bash on Windows and is harmless elsewhere.

`deploy.sh` is idempotent. Run against an existing stack, it creates nothing: it re-checks the instance and the public URL and prints the details again. To change settings, run `./destroy.sh` and deploy again.

## Verify

```bash
./verify.sh
```

Expected output:

```
PASS Security group(s) sg-... have no inbound rules
PASS Port 22 on <public-ip> does not respond
PASS Port 2368 on <public-ip> does not respond
PASS SSM send-command runs on the instance
PASS Ghost and MySQL containers are up
PASS sshd is not listening on the instance
PASS Ghost (2368) is bound to loopback only
PASS GET https://ghost.<tailnet>.ts.net/ returns 200 via public DNS
PASS GET https://ghost.<tailnet>.ts.net/ghost/ returns 200 via public DNS
PASS Repeated deploy creates nothing (same stack, same resources, same instance)

10 passed, 0 failed
```

How each check works:

- **Inbound rules:** counts `IpPermissions` across every security group attached to the instance. The count must be 0.
- **Ports 22 and 2368:** opens a TCP connection to the instance's public IP from your machine. The check passes if the connection fails or times out.
- **SSM:** sends `AWS-RunShellScript` through `ssm send-command` with no SSH involved. Its output is reused for three more checks: the containers are up, nothing listens on `:22`, and Ghost is bound to `127.0.0.1` only.
- **HTTP 200:** requests `/` and `/ghost/`, resolving the hostname through public DNS-over-HTTPS (1.1.1.1). This tests the real Funnel path even when your machine is in the same tailnet.
- **Idempotency:** snapshots the stack's resources (logical ID, physical ID, status) and its status / last-update time. It then re-runs `./deploy.sh`, takes the snapshot again and requires it to be identical. It also confirms that no auth key parameter was re-created. The re-run's log goes to `.build/redeploy.log`.

`verify.sh` exits non-zero if any check fails.

## Admin access

```bash
aws ssm start-session --target <instance-id>
sudo docker compose -f /opt/ghost/docker-compose.yml logs -f ghost
```

## Destroy

```bash
./destroy.sh          # asks for confirmation; --yes to skip
```

Afterwards, remove the offline machine in the Tailscale admin console. Otherwise the next deploy is named `ghost-1`.

## How it works / security notes

- `deploy.sh` puts the auth key into SSM Parameter Store as a SecureString, not into UserData, which anyone with `ec2:Describe*` can read. The instance reads the key once and deletes the parameter.
- The Ghost owner account is created through the Admin API **before** Funnel is switched on. Nobody can claim `/ghost/#/setup` in the window between "Ghost is up" and "you open the browser". The generated password goes straight into SSM (SecureString) and is never shown in script output.
- The instance reports progress to the `/<stack>/status` SSM parameter, which `deploy.sh` polls. The deploy needs no shell access at all.
- No SMTP is configured, so Ghost's emailed new-device login codes are disabled (`security__staffDeviceVerification=false`). Member signup emails will not work until SMTP is added.
- Data lives on the root EBS volume and is deleted together with the stack.
