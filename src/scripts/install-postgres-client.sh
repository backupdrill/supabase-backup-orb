#!/usr/bin/env bash
# Installs pg_dump, pg_restore and psql of one PostgreSQL major version from the
# PostgreSQL apt repository. Debian and Ubuntu ship an older client than the
# Postgres that Supabase runs, and pg_dump refuses to dump a newer server.
# Works as root (Docker executor) and with sudo (machine executor).
set -euo pipefail

major="${BACKUPDRILL_ORB_POSTGRES_VERSION:-}"
case "$major" in
  "" | *[!0-9]*)
    echo "postgres_version must be a major version such as 17, got: '${major}'" >&2
    exit 1
    ;;
esac

if [ -x "/usr/lib/postgresql/${major}/bin/pg_dump" ] && [ -x "/usr/lib/postgresql/${major}/bin/pg_restore" ]; then
  echo "PostgreSQL ${major} client is already installed."
  exit 0
fi

sudo_cmd=()
if [ "$(id -u)" -ne 0 ]; then
  sudo_cmd=(sudo)
fi

# Machine images run apt jobs of their own right after boot. DPkg::Lock::Timeout
# waits for the dpkg lock; `apt-get update` (also the one inside the PGDG
# helper) takes the package-list lock, which that option doesn't cover, so
# every apt step gets a few tries.
retry() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    "$@" && return 0
    [ "$attempt" -eq 6 ] && break
    echo "Retrying in 20s (attempt ${attempt} of 6 failed, apt may be locked by another update)"
    sleep 20
  done
  return 1
}
apt_get() {
  "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=300 -y -qq "$@"
}

retry apt_get update
retry apt_get install --no-install-recommends ca-certificates postgresql-common
retry "${sudo_cmd[@]}" /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
retry apt_get install --no-install-recommends "postgresql-client-${major}"

"/usr/lib/postgresql/${major}/bin/pg_dump" --version
