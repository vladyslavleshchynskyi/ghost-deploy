# Shared setup for deploy.sh, destroy.sh and verify.sh. Source it from the repo root.

# Git Bash on Windows: keep "/stack/param" names from being rewritten into Windows paths.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' AWS_PAGER=""

# Load KEY=value pairs from .env. Variables already set in the environment win.
load_env() {
  local file=${1:-.env} line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[2]}
    val=${BASH_REMATCH[3]}
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
    [ -n "${!key+x}" ] || export "$key=$val"
  done < "$file"
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
# aws.exe and jq.exe on Windows emit CRLF; strip it everywhere.
awsq() { aws "$@" | tr -d '\r'; }
jqq() { jq "$@" | tr -d '\r'; }

stack_status() {
  awsq cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE
}

stack_output() {
  awsq cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

load_env
STACK_NAME=${STACK_NAME:-ghost-blog}
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null | tr -d '\r' || true)}
[ -n "$AWS_REGION" ] || die "AWS region is not set (aws configure, AWS_REGION or .env)"
export STACK_NAME AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
PREFIX="/$STACK_NAME"
BUILD_DIR=.build
