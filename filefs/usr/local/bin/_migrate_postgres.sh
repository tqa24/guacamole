#!/usr/bin/env bash

set -Eeuo pipefail

current_major="${PG_MAJOR:?}"
old_major="${OLD_PG_MAJOR:-13}"
pgdata="${PGDATA:?}"
postgres_user="${POSTGRES_USER:?}"
old_bindir="/opt/postgresql${old_major}/bin"
new_bindir="/usr/libexec/postgresql${current_major}"
backup_dir="${pgdata}-v${old_major}"
upgrade_root="/config/db_check/pg_upgrade-${old_major}-to-${current_major}"
socket_dir="/tmp/pg_upgrade"
success=0

if [ ! -s "${pgdata}/PG_VERSION" ]; then
    exit 0
fi

detected_major="$(cat "${pgdata}/PG_VERSION")"

if [ "${detected_major}" = "${current_major}" ]; then
    exit 0
fi

if [ "${detected_major}" != "${old_major}" ]; then
    echo "Unsupported PostgreSQL data version ${detected_major}. Expected ${old_major} or ${current_major}." >&2
    exit 1
fi

if [ -e "${backup_dir}" ]; then
    echo "Migration cannot continue because backup directory ${backup_dir} already exists." >&2
    echo "Resolve or remove that directory before retrying startup." >&2
    exit 1
fi

if [ ! -x "${old_bindir}/postgres" ] || [ ! -x "${new_bindir}/pg_upgrade" ] || [ ! -x "${new_bindir}/initdb" ]; then
    echo "Required PostgreSQL upgrade binaries are missing." >&2
    exit 1
fi

cleanup() {
    local exit_code=$?

    rm -rf "${socket_dir}"
    if [ -n "${pwfile:-}" ] && [ -f "${pwfile}" ]; then
        rm -f "${pwfile}"
    fi

    if [ "${success}" -ne 1 ]; then
        echo "PostgreSQL major upgrade failed. Restoring original PGDATA." >&2
        rm -rf "${pgdata}"
        if [ -d "${backup_dir}" ]; then
            mv "${backup_dir}" "${pgdata}"
        fi
    fi

    exit "${exit_code}"
}

trap cleanup EXIT

echo "Detected PostgreSQL ${old_major} data directory. Starting automated upgrade to ${current_major}."

mkdir -p "${upgrade_root}" "${socket_dir}"
chmod 700 "${socket_dir}"

# Cleanly shut down the old cluster if it's running or has stale state
# This is required for pg_upgrade to validate the source cluster
echo "Ensuring old PostgreSQL ${old_major} cluster is cleanly shut down..."
rm -f "${pgdata}/postmaster.pid" "${pgdata}/recovery.done"
rm -f "${pgdata}/standby.signal" "${pgdata}/recovery.signal"

# Try to use pg_ctl to clean shut down if the server is running
# If that doesn't work, use pg_resetwal to reset the WAL state
if ! "${old_bindir}/pg_ctl" -D "${pgdata}" -m fast stop &>/dev/null 2>&1; then
    # Server is not running, but cluster may be in inconsistent state
    # Use pg_resetwal to reset the WAL and allow pg_upgrade to proceed
    echo "Using pg_resetwal to reset WAL state on old cluster..."
    "${old_bindir}/pg_resetwal" -f "${pgdata}" &>/dev/null || true
fi

sleep 1
mv "${pgdata}" "${backup_dir}"
mkdir -p "${pgdata}"
chmod 700 "${pgdata}"

pwfile="$(mktemp)"
printf '%s\n' "${POSTGRES_PASSWORD:-}" > "${pwfile}"

"${new_bindir}/initdb" \
    --username="${postgres_user}" \
    --pwfile="${pwfile}" \
    -D "${pgdata}"

cd "${upgrade_root}"

"${new_bindir}/pg_upgrade" \
    --old-bindir="${old_bindir}" \
    --new-bindir="${new_bindir}" \
    --old-datadir="${backup_dir}" \
    --new-datadir="${pgdata}" \
    --username="${postgres_user}" \
    --jobs="$(getconf _NPROCESSORS_ONLN)" \
    --retain \
    --socketdir="${socket_dir}" \
    --old-options="-c listen_addresses='' -c unix_socket_directories=${socket_dir}" \
    --new-options="-c listen_addresses='' -c unix_socket_directories=${socket_dir}" \
    --verbose

success=1

echo "PostgreSQL upgrade completed successfully."
echo "Old PostgreSQL ${old_major} data remains at ${backup_dir} until you remove it."
if [ -f "${upgrade_root}/analyze_new_cluster.sh" ]; then
    echo "Analyze script generated at ${upgrade_root}/analyze_new_cluster.sh"
fi