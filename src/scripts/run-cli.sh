#!/usr/bin/env bash
# Runs `backupdrill backup` or `backupdrill drill` with the settings from the
# orb parameters and the job's environment (contexts and project variables).
set -euo pipefail

fail() {
  echo "$1" >&2
  exit 1
}

command_name="${BACKUPDRILL_ORB_COMMAND:-}"
version="${BACKUPDRILL_ORB_CLI_VERSION:-}"

case "$command_name" in
  backup | drill) ;;
  *) fail "Unknown backupdrill command: '${command_name}'" ;;
esac
if ! [[ "$version" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  fail "cli_version must be latest or a full version such as 2.11.0, got: '${version}'"
fi

# A parameter you set wins. An empty one changes nothing, so a variable of the
# same name from a context or the project settings still applies. Exporting an
# empty value instead would make the CLI file snapshots under an empty name.
if [ -n "${BACKUPDRILL_ORB_BUCKET:-}" ]; then export BACKUPDRILL_S3_BUCKET="$BACKUPDRILL_ORB_BUCKET"; fi
if [ -n "${BACKUPDRILL_ORB_S3_ENDPOINT:-}" ]; then export BACKUPDRILL_S3_ENDPOINT="$BACKUPDRILL_ORB_S3_ENDPOINT"; fi
if [ -n "${BACKUPDRILL_ORB_S3_REGION:-}" ]; then export BACKUPDRILL_S3_REGION="$BACKUPDRILL_ORB_S3_REGION"; fi
if [ -n "${BACKUPDRILL_ORB_PROJECT_NAME:-}" ]; then export BACKUPDRILL_PROJECT_NAME="$BACKUPDRILL_ORB_PROJECT_NAME"; fi

# The CLI needs Node.js 20 or newer. The node executor has it. Machine images
# keep their Node.js versions in nvm, and the default one may be older.
node_major() {
  node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
}
if [ "$(node_major)" -lt 20 ]; then
  nvm_script="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  [ -s "$nvm_script" ] || fail "backupdrill needs Node.js 20 or newer. This executor has neither that nor nvm to install it."
  echo "Installing Node.js 24 with nvm"
  # nvm.sh isn't written for set -eu.
  set +eu
  # shellcheck disable=SC1090
  . "$nvm_script"
  nvm install 24 >/dev/null
  nvm_status=$?
  set -eu
  [ "$nvm_status" -eq 0 ] || fail "nvm could not install Node.js 24."
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
  npm_config_userconfig=/dev/null \
    npm_config_globalconfig="${work_dir}/empty-global.npmrc" \
    npm_config_update_notifier=false \
    npm install --prefix "$work_dir" --ignore-scripts --no-audit --no-fund --loglevel=error \
    --registry https://registry.npmjs.org/ "backupdrill@${version}"
); then
  fail "Could not install backupdrill@${version} from npm."
fi
cli="${work_dir}/node_modules/.bin/backupdrill"
"$cli" --version

# The CLI falls back to DATABASE_URL when BACKUPDRILL_DATABASE_URL isn't set.
# In CI, DATABASE_URL usually points at the app's test database, so it is
# never passed on.
unset DATABASE_URL

if [ "$command_name" = "drill" ]; then
  # The drill only reads the bucket. It gets nothing that can reach the
  # Supabase database or its Storage.
  unset BACKUPDRILL_DATABASE_URL \
    BACKUPDRILL_SUPABASE_STORAGE_ENDPOINT \
    BACKUPDRILL_SUPABASE_STORAGE_REGION \
    BACKUPDRILL_SUPABASE_STORAGE_ACCESS_KEY_ID \
    BACKUPDRILL_SUPABASE_STORAGE_SECRET_ACCESS_KEY \
    BACKUPDRILL_SUPABASE_STORAGE_BUCKETS
fi

# Settings come from the parameters and the environment only. A
# backupdrill.config.json in a checked-out repository could otherwise fill in a
# database or bucket the pipeline never named. A --config path that doesn't
# exist makes the CLI skip the file.
no_config="${work_dir}/no-config.json"

# The CLI writes its progress and result summary to stderr, which goes to the
# job log. On stdout it prints one JSON line; for a backup that is the whole
# manifest, with every table name and Storage file path, so it stays out of
# the log.
"$cli" "$command_name" --config "$no_config" >"${work_dir}/result.json"
