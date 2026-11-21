#!/usr/bin/env bash
# Runs `backupdrill backup`, `backupdrill drill`, or a backup followed by a
# drill of that same snapshot, with the settings from the orb parameters and
# the job's environment (contexts and project variables).
set -euo pipefail

fail() {
  echo "$1" >&2
  exit 1
}

# The Supabase credentials. Only `backupdrill backup` gets them.
source_variables=(
  BACKUPDRILL_DATABASE_URL
  BACKUPDRILL_SUPABASE_STORAGE_ENDPOINT
  BACKUPDRILL_SUPABASE_STORAGE_REGION
  BACKUPDRILL_SUPABASE_STORAGE_ACCESS_KEY_ID
  BACKUPDRILL_SUPABASE_STORAGE_SECRET_ACCESS_KEY
  BACKUPDRILL_SUPABASE_STORAGE_BUCKETS
)

mode="${BACKUPDRILL_ORB_COMMAND:-}"
version="${BACKUPDRILL_ORB_CLI_VERSION:-}"

case "$mode" in
  backup | drill | backup-and-drill) ;;
  *) fail "Unknown backupdrill command: '${mode}'" ;;
esac
if ! [[ "$version" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  fail "cli_version must be latest or a full version such as 2.11.0, got: '${version}'"
fi

# The CLI falls back to DATABASE_URL when BACKUPDRILL_DATABASE_URL isn't set.
# In CI, DATABASE_URL usually points at the app's test database, so it is
# never passed on.
unset DATABASE_URL
# A drill on its own never touches Supabase. Drop its credentials before
# anything else runs.
if [ "$mode" = "drill" ]; then
  unset "${source_variables[@]}"
fi

# A parameter you set wins. An empty one changes nothing, so a variable of the
# same name from a context or the project settings still applies. Exporting an
# empty value instead would make the CLI file snapshots under an empty name.
if [ -n "${BACKUPDRILL_ORB_BUCKET:-}" ]; then export BACKUPDRILL_S3_BUCKET="$BACKUPDRILL_ORB_BUCKET"; fi
if [ -n "${BACKUPDRILL_ORB_S3_ENDPOINT:-}" ]; then export BACKUPDRILL_S3_ENDPOINT="$BACKUPDRILL_ORB_S3_ENDPOINT"; fi
if [ -n "${BACKUPDRILL_ORB_S3_REGION:-}" ]; then export BACKUPDRILL_S3_REGION="$BACKUPDRILL_ORB_S3_REGION"; fi
if [ -n "${BACKUPDRILL_ORB_PROJECT_NAME:-}" ]; then export BACKUPDRILL_PROJECT_NAME="$BACKUPDRILL_ORB_PROJECT_NAME"; fi

# Everything before the CLI itself (nvm, npm, node) runs with a minimal
# environment, so no BACKUPDRILL_* secret reaches those processes.
clean_env=(env -i "PATH=$PATH" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}")
for proxy_variable in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do
  if [ -n "${!proxy_variable:-}" ]; then clean_env+=("${proxy_variable}=${!proxy_variable}"); fi
done

# The CLI needs Node.js 20 or newer. The node executor has it. Machine images
# keep their Node.js versions in nvm, and the default one may be older.
node_major() {
  "${clean_env[@]}" node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
}
if [ "$(node_major)" -lt 20 ]; then
  nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  [ -s "${nvm_dir}/nvm.sh" ] || fail "backupdrill needs Node.js 20 or newer. This executor has neither that nor nvm to install it."
  echo "Installing Node.js 24 with nvm"
  # shellcheck disable=SC2016 # expanded by the inner bash, not this one
  node_bin="$("${clean_env[@]}" "NVM_DIR=$nvm_dir" bash -c \
    '. "$NVM_DIR/nvm.sh" >/dev/null && nvm install 24 >/dev/null && dirname "$(nvm which 24)"')" ||
    fail "nvm could not install Node.js 24."
  PATH="${node_bin}:$PATH"
  clean_env[2]="PATH=$PATH"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Install the CLI from the public npm registry, with npm started outside the
# checkout and both npmrc files replaced by empty ones. An .npmrc in the
# repository or the home directory could otherwise point npm at another
# registry and run a different package under the backupdrill name, with the
# database and bucket credentials in its environment. Install scripts are off;
# the CLI doesn't need any. npm won't load the same file twice, so the global
# config gets its own empty file.
echo "Installing backupdrill@${version} from npm"
: >"${work_dir}/empty-global.npmrc"
if ! (
  cd "$work_dir"
  "${clean_env[@]}" \
    npm_config_userconfig=/dev/null \
    npm_config_globalconfig="${work_dir}/empty-global.npmrc" \
    npm_config_update_notifier=false \
    npm install --prefix "$work_dir" --ignore-scripts --no-audit --no-fund --loglevel=error \
    --registry https://registry.npmjs.org/ "backupdrill@${version}"
); then
  fail "Could not install backupdrill@${version} from npm."
fi
cli="${work_dir}/node_modules/.bin/backupdrill"
echo "backupdrill $("${clean_env[@]}" "$cli" --version)"

# Settings come from the parameters and the environment only. A
# backupdrill.config.json in a checked-out repository could otherwise fill in a
# database or bucket the pipeline never named. A --config path that doesn't
# exist makes the CLI skip the file.
no_config="${work_dir}/no-config.json"

# The CLI writes its progress and result summary to stderr, which goes to the
# job log. On stdout it prints one JSON line; for a backup that is the whole
# manifest, with every table name and Storage file path, so it stays out of
# the log.
if [ "$mode" = "drill" ]; then
  "$cli" drill --config "$no_config" >"${work_dir}/drill.json"
  exit 0
fi

"$cli" backup --config "$no_config" >"${work_dir}/backup.json"
[ "$mode" = "backup-and-drill" ] || exit 0

# Drill exactly the snapshot this backup wrote, not whatever is newest in the
# bucket by the time the drill starts. The dump key is
# <prefix>/<project>/<snapshot>/<file>, and the snapshot folder name is what
# `backupdrill drill --snapshot` takes.
snapshot="$("${clean_env[@]}" node -e '
  const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
  const key = JSON.parse(lines[lines.length - 1]).manifest?.dump?.key;
  const name = typeof key === "string" ? key.split("/").at(-2) : "";
  if (!/^[0-9A-Za-z._-]+$/.test(name || "")) process.exit(1);
  console.log(name);
' "${work_dir}/backup.json")" || fail "The backup finished, but its snapshot name could not be read from the CLI result."

echo "Restore drill of snapshot ${snapshot}"
unset "${source_variables[@]}"
"$cli" drill --config "$no_config" --snapshot "$snapshot" >"${work_dir}/drill.json"
