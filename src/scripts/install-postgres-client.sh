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

# Machine images run apt jobs of their own right after boot. Wait for the dpkg
# lock instead of failing on it.
apt_get() {
  "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=300 -y -qq "$@"
}

apt_get update
apt_get install --no-install-recommends ca-certificates postgresql-common
"${sudo_cmd[@]}" /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
apt_get install --no-install-recommends "postgresql-client-${major}"

"/usr/lib/postgresql/${major}/bin/pg_dump" --version
