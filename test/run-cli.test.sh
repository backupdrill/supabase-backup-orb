#!/usr/bin/env bash
# Tests src/scripts/run-cli.sh against a stand-in npm and CLI, without a
# database, a bucket or network access. Needs bash and Node.js 20 or newer.
# Usage: bash test/run-cli.test.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/src/scripts/run-cli.sh"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
failures=0

check() { # <description> <command...>
  if "${@:2}"; then echo "ok - $1"; else echo "not ok - $1"; failures=$((failures + 1)); fi
}

# The stand-in npm installs a stand-in CLI that records its arguments and the
# names of the BACKUPDRILL_* and DATABASE_URL variables it was given. npm runs
# with only PATH, HOME and TMPDIR, so each run's HOME is its log directory.
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/npm" <<'NPM'
#!/usr/bin/env bash
env | cut -d= -f1 | grep -E '^(BACKUPDRILL_|DATABASE_URL$)' >"$HOME/npm.env" || true
prefix=""
while [ $# -gt 0 ]; do
  case "$1" in --prefix) prefix="$2"; shift ;; esac
  shift
done
mkdir -p "$prefix/node_modules/.bin"
cp "$(dirname "$HOME")/fake-cli" "$prefix/node_modules/.bin/backupdrill"
chmod +x "$prefix/node_modules/.bin/backupdrill"
NPM
chmod +x "$sandbox/bin/npm"
cat >"$sandbox/fake-cli" <<'CLI'
#!/usr/bin/env bash
command="$1"
env | cut -d= -f1 | grep -E '^(BACKUPDRILL_|DATABASE_URL$)' | sort >"$HOME/$command.env" || true
echo "$*" >"$HOME/$command.args"
case "$command" in
  --version) echo "2.11.1" ;;
  backup)
    if [ -n "${FAKE_BACKUP_STDOUT:-}" ]; then echo "$FAKE_BACKUP_STDOUT"; exit 0; fi
    echo '{"ok":true,"manifest":{"dump":{"key":"backupdrill/acme/2026-11-21T03-00-00-000Z/dump.pgcustom"}}}'
    ;;
  drill) echo '{"ok":true,"report":{"pass":true}}' ;;
esac
CLI

run() { # <log dir> <mode> [VAR=value...]
  local log="$1" mode="$2"
  shift 2
  mkdir -p "$log"
  env -i PATH="$sandbox/bin:$PATH" HOME="$log" \
    BACKUPDRILL_ORB_COMMAND="$mode" BACKUPDRILL_ORB_CLI_VERSION=2.11.1 \
    BACKUPDRILL_DATABASE_URL=postgresql://source BACKUPDRILL_S3_SECRET_ACCESS_KEY=bucket-secret \
    BACKUPDRILL_SUPABASE_STORAGE_SECRET_ACCESS_KEY=storage-secret DATABASE_URL=postgresql://test-db \
    BACKUPDRILL_PING_URL=https://hc-ping.example/check "$@" \
    bash "$script" >"$log/out.txt" 2>&1
}

# backup-and-drill drills the snapshot its backup wrote, and only the drill pings.
run "$sandbox/both" backup-and-drill BACKUPDRILL_ORB_BUCKET=my-bucket
check "backup-and-drill drills the snapshot it wrote" \
  grep -qx -- "drill --config .*no-config.json --snapshot 2026-11-21T03-00-00-000Z" "$sandbox/both/drill.args"
check "the backup gets the database URL" grep -qx BACKUPDRILL_DATABASE_URL "$sandbox/both/backup.env"
check "the bucket parameter reaches the CLI" grep -qx BACKUPDRILL_S3_BUCKET "$sandbox/both/backup.env"
check "the drill gets no Supabase credentials" bash -c "! grep -qE 'DATABASE_URL|SUPABASE_STORAGE' '$sandbox/both/drill.env'"
check "DATABASE_URL never reaches the CLI" bash -c "! grep -qx DATABASE_URL '$sandbox/both/backup.env'"
check "npm runs without any BACKUPDRILL_* variable" bash -c "[ ! -s '$sandbox/both/npm.env' ]"
check "only the drill pings in backup-and-drill" \
  bash -c "! grep -qx BACKUPDRILL_PING_URL '$sandbox/both/backup.env' && grep -qx BACKUPDRILL_PING_URL '$sandbox/both/drill.env'"
check "the backup JSON stays out of the log" bash -c "! grep -q manifest '$sandbox/both/out.txt'"

# A drill on its own gets the bucket keys and nothing that reaches Supabase.
run "$sandbox/drill" drill
check "drill gets the bucket secret" grep -qx BACKUPDRILL_S3_SECRET_ACCESS_KEY "$sandbox/drill/drill.env"
check "drill gets no Supabase credentials" bash -c "! grep -qE 'DATABASE_URL|SUPABASE_STORAGE' '$sandbox/drill/drill.env'"

# A backup result that isn't JSON fails the job without echoing it.
if run "$sandbox/bad" backup-and-drill FAKE_BACKUP_STDOUT='{"manifest": storage/private/report.pdf'; then
  check "a malformed backup result fails the job" false
else
  check "a malformed backup result fails the job" true
fi
check "the malformed result isn't echoed" bash -c "! grep -q private/report.pdf '$sandbox/bad/out.txt'"
check "no drill runs after a malformed result" bash -c "[ ! -e '$sandbox/bad/drill.args' ]"

# Versions other than latest or x.y.z are refused before anything is installed.
if run "$sandbox/version" backup BACKUPDRILL_ORB_CLI_VERSION='2.11.1 --registry=http://evil'; then
  check "a malformed cli_version is refused" false
else
  check "a malformed cli_version is refused" true
fi
check "nothing is installed for a refused version" bash -c "[ ! -e '$sandbox/version/npm.env' ]"

# Releases before 2.11.1 are refused; 2.11.1, newer ones and latest install.
for old in 2.11.0 2.10.1 1.99.99; do
  if run "$sandbox/old-$old" backup BACKUPDRILL_ORB_CLI_VERSION="$old"; then
    check "cli_version $old is refused" false
  else
    check "cli_version $old is refused" bash -c "grep -q '2.11.1 or newer' '$sandbox/old-$old/out.txt' && [ ! -e '$sandbox/old-$old/npm.env' ]"
  fi
done
for ok in 2.11.1 2.12.0 3.0.0 latest; do
  check "cli_version $ok is accepted" run "$sandbox/ok-$ok" backup BACKUPDRILL_ORB_CLI_VERSION="$ok"
done

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
