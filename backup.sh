#!/bin/bash

#set -euo pipefail

# Get hostname early so it is available when expanding variables in .env
HOST="${HOST:-$(hostname)}"

# === Load Environment File (.env) ===
ENV_FILE="${ENV_FILE:-}"
if [[ -z "${ENV_FILE}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env"
  elif [[ -f "${CONF_PATH:-/etc/backup}/.env" ]]; then
    ENV_FILE="${CONF_PATH:-/etc/backup}/.env"
  elif [[ -f "./.env" ]]; then
    ENV_FILE="./.env"
  fi
fi

if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

# Configuration path
CONF_PATH="${CONF_PATH:-/etc/backup}"

# Owner and group of backup directory
OWNER="${OWNER:-root}"
GROUP="${GROUP:-root}"

# Destination directory for backups
DEST="${DEST:-/var/backups}"

# Filesystem backup lists
DIRS_FILE="${DIRS_FILE:-${CONF_PATH}/backup_dirs.lst}"
DIRS_EXCLUDE_FILE="${DIRS_EXCLUDE_FILE:-${CONF_PATH}/backup_dirs_exclude.lst}"

# Hostname
HOST="${HOST:-$(hostname)}"

# Send result email
SEND_EMAIL="${SEND_EMAIL:-0}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-root@localhost}"
NOTIFY_SUBJECT="${NOTIFY_SUBJECT:-Backup Notification (${HOST})}"
if [[ "${NOTIFY_SUBJECT}" == *"()"* ]]; then
  NOTIFY_SUBJECT="${NOTIFY_SUBJECT//()/\(${HOST}\)}"
fi

# Delete old backups
DELETE_OLD_BACKUPS="${DELETE_OLD_BACKUPS:-1}"
DELETE_BACKUPS_OLDER_THAN_DAYS="${DELETE_BACKUPS_OLDER_THAN_DAYS:-5}"

# Cloud target (rclone remote:path, optional)
CLOUD_TARGET="${CLOUD_TARGET:-}"

# Lock file to prevent overlapping runs
LOCK_FILE="${LOCK_FILE:-/run/lock/simplelinuxbackup.lock}"

# Get date in yyyy-mm-dd format
NOW="${NOW:-$(date +"%Y%m%d")}"

DB_TIMES=()
DIR_TIMES=()
UPLOAD_TIMES=()
DB_RESULTS=()
FS_RESULTS=()
UPLOAD_RESULTS=()
DELETED_DIRS=()
ERROR_MSGS=()
ERROR_COUNT=0
TOTAL_START_TS=0

# Parse CLI arguments
VERIFY_CONFIG="${VERIFY_CONFIG:-0}"
for arg in "$@"; do
  case "${arg}" in
    --verify-config|--check|-t)
      VERIFY_CONFIG=1
      ;;
    -h|--help)
      echo "Usage: $0 [--verify-config]"
      echo "  --verify-config: Test and verify commands, directories, and database logins without creating backups."
      exit 0
      ;;
  esac
done

# === Functions ===

format_duration() {
  local secs="${1:-0}"
  if [ "${secs}" -lt 60 ]; then
    echo "${secs}s"
  else
    local mins=$((secs / 60))
    local rem=$((secs % 60))
    echo "${mins}m ${rem}s"
  fi
}

log_error() {
  local msg="$1"
  ERROR_COUNT=$((ERROR_COUNT + 1))
  ERROR_MSGS+=("${msg}")
  echo "${msg}" >&2
}

gen_email() {
  local newline="${1:-1}"
  local line="$2"
  if [[ "${newline}" == "1" ]]; then
    echo "${line}" >> "${TMP_MSG_FILE}"
  else
    echo -n "${line}" >> "${TMP_MSG_FILE}"
  fi
}

init_commands() {
  LIST_COMMAND_MYSQL="$(which mysql 2>/dev/null || true)"
  LIST_COMMAND_PGSQL="$(which psql 2>/dev/null || true)"
  DUMP_COMMAND_MYSQL="$(which mysqldump 2>/dev/null || true)"
  DUMP_COMMAND_PGSQL="$(which pg_dump 2>/dev/null || true)"
  DUMP_COMMAND_SQLITE="$(which sqlite3 2>/dev/null || true)"
  GREP_COMMAND="$(which grep)"
  CHOWN_COMMAND="$(which chown)"
  CHMOD_COMMAND="$(which chmod)"
  GZIP_COMMAND="$(which gzip)"
  TAR_COMMAND="$(which tar)"
  MAIL_COMMAND="$(which mailx || which mail || which sendmail)"
  FIND_COMMAND="$(which find)"
  DF_COMMAND="$(which df)"
  RCLONE_COMMAND="$(which rclone)"
  DOCKER_COMMAND="$(which docker)"

  export LIST_COMMAND_MYSQL LIST_COMMAND_PGSQL DUMP_COMMAND_MYSQL DUMP_COMMAND_PGSQL DUMP_COMMAND_SQLITE \
    GREP_COMMAND CHOWN_COMMAND CHMOD_COMMAND GZIP_COMMAND TAR_COMMAND MAIL_COMMAND FIND_COMMAND DF_COMMAND RCLONE_COMMAND DOCKER_COMMAND

  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "--- Core Utilities ---"
    local core_cmds=(
      "${GREP_COMMAND:-grep}"
      "${CHOWN_COMMAND:-chown}"
      "${CHMOD_COMMAND:-chmod}"
      "${GZIP_COMMAND:-gzip}"
      "${TAR_COMMAND:-tar}"
      "${FIND_COMMAND:-find}"
      "${DF_COMMAND:-df}"
    )
    for cmd in "${core_cmds[@]}"; do
      if command -v "${cmd}" &>/dev/null; then
        echo "  [OK] Found $(basename "${cmd}")"
      else
        echo "  [FAIL] Missing core utility: ${cmd}" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
    done
    if [[ "${SEND_EMAIL:-0}" == "1" ]]; then
      if [[ -n "${MAIL_COMMAND}" ]]; then
        echo "  [OK] Found mail binary: ${MAIL_COMMAND}"
      else
        echo "  [FAIL] SEND_EMAIL=1 but no mail command (mailx, mail, sendmail) found." >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
    fi
    echo ""
  fi
}

init_backup_dirs() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "--- Storage & Destination ---"
    if [ -d "${DEST}" ]; then
      if [ -w "${DEST}" ]; then
        echo "  [OK] Destination '${DEST}' exists and is writable."
      else
        echo "  [FAIL] Destination '${DEST}' exists but is NOT writable." >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
    else
      local parent_dir
      parent_dir="$(dirname "${DEST}")"
      if [ -d "${parent_dir}" ] && [ -w "${parent_dir}" ]; then
        echo "  [OK] Destination '${DEST}' does not exist yet, but parent directory '${parent_dir}' is writable."
      else
        echo "  [FAIL] Cannot create destination '${DEST}'. Parent directory '${parent_dir}' does not exist or is not writable." >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
    fi
    echo ""
    return 0
  fi

  # Main directory where backup will be stored
  if [ ! -d ${DEST} ]; then 
    mkdir -p ${DEST}
    # Only ${OWNER}.${GROUP} can access it!
    ${CHOWN_COMMAND} ${OWNER}:${GROUP} -R ${DEST}
    ${CHMOD_COMMAND} 0750 ${DEST}
  fi

  # Create backup directory
  MBD="${DEST}/${NOW}"
  if [ ! -d "${MBD}" ]; then
    mkdir "${MBD}"
    # Only ${OWNER}.${GROUP} can access it!
    ${CHOWN_COMMAND} ${OWNER}:${GROUP} -R ${MBD}
    ${CHMOD_COMMAND} 0750 ${MBD}
  fi
}

acquire_lock() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    return 0
  fi

  if command -v flock &>/dev/null; then
    local lock_dir
    lock_dir="$(dirname "${LOCK_FILE}")"
    if [[ ! -d "${lock_dir}" || ! -w "${lock_dir}" ]]; then
      LOCK_FILE="/tmp/simplelinuxbackup.lock"
    fi
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
      echo "Error: Another instance of simplelinuxbackup is already running. Exiting." >&2
      exit 1
    fi
  fi
}

cleanup() {
  if [[ -n "${TMP_MSG_FILE:-}" && -f "${TMP_MSG_FILE}" ]]; then
    rm -f "${TMP_MSG_FILE}"
  fi
  if [[ -n "${CURRENT_EXCLUDE_FILE:-}" && -f "${CURRENT_EXCLUDE_FILE}" ]]; then
    rm -f "${CURRENT_EXCLUDE_FILE}"
  fi
  if [[ -n "${CURRENT_DUMP_ERR_FILE:-}" && -f "${CURRENT_DUMP_ERR_FILE}" ]]; then
    rm -f "${CURRENT_DUMP_ERR_FILE}"
  fi
}

init_tmp_msg() {
  if command -v mktemp &>/dev/null; then
    TMP_MSG_FILE="$(mktemp /tmp/backup.XXXXXX.msg)"
  else
    TMP_MSG_FILE="/tmp/backup.$$.${RANDOM}.msg"
    : > "${TMP_MSG_FILE}"
  fi

  export TMP_MSG_FILE
  trap cleanup EXIT INT TERM
}

###############################################################################
# run_inner: executes a command locally or inside a docker container
# Args:
#   1:command string
###############################################################################
run_inner() {
  local cmd="$1"

  if [[ -n "${DOCKER_CONTAINER}" ]]; then
    if [[ -n "${DOCKER_USER}" ]]; then
      ${DOCKER_COMMAND} exec -u "${DOCKER_USER}" ${DOCKER_OPTS} "${DOCKER_CONTAINER}" "${DOCKER_SHELL:-/bin/sh}" -lc "${cmd}"
    else
      ${DOCKER_COMMAND} exec ${DOCKER_OPTS} "${DOCKER_CONTAINER}" "${DOCKER_SHELL:-/bin/sh}" -lc "${cmd}"
    fi
  else
    bash -lc "${cmd}"
  fi
}

###############################################################################
# discover_dbs: run a prepared discovery command and print DB names
# Args:
#   1:discovery_cmd
###############################################################################
discover_dbs() {
  local discovery_cmd="$1" 
  local out
  if ! out="$(run_inner "${discovery_cmd}" 2>&1)"; then
    echo "ERROR(discovery) got '${out}' for command '${discovery_cmd}'" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

###############################################################################
# backup_db: run a prepared dump command, gzip the stream to outfile
# Args:
#   1:dump_cmd
#   2:outfile
###############################################################################
backup_db() {
  local dump_cmd="$1" outfile="${2:?}"
  LAST_DB_ERROR=""

  if command -v mktemp &>/dev/null; then
    CURRENT_DUMP_ERR_FILE="$(mktemp /tmp/backup_dump_err.XXXXXX)"
  else
    CURRENT_DUMP_ERR_FILE="/tmp/backup_dump_err.$$.${RANDOM}"
  fi

  run_inner "${dump_cmd}" 2>"${CURRENT_DUMP_ERR_FILE}" | env -u GZIP "${GZIP_COMMAND}" -9 > "$outfile"
  local pipe_status=("${PIPESTATUS[@]}")
  if [[ ${pipe_status[0]} -ne 0 || ${pipe_status[1]} -ne 0 ]]; then
    if [ -s "${CURRENT_DUMP_ERR_FILE}" ]; then
      LAST_DB_ERROR="$(head -n 2 "${CURRENT_DUMP_ERR_FILE}" | tr -d '\r' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    fi
    rm -f "$outfile" "${CURRENT_DUMP_ERR_FILE}"
    CURRENT_DUMP_ERR_FILE=""
    return 1
  fi
  rm -f "${CURRENT_DUMP_ERR_FILE}"
  CURRENT_DUMP_ERR_FILE=""
  return 0
}

should_skip_db() {
  local db="$1"; shift
  for ig in "$@"; do
    [ "$db" = "$ig" ] && return 0
  done
  return 1
}

backup_databases() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "--- Database Configurations & Logins ---"
  fi
  shopt -s nullglob
  local db_confs=("${CONF_PATH}"/backup_mysql_*.conf "${CONF_PATH}"/backup_pgsql_*.conf "${CONF_PATH}"/backup_sqlite_*.conf)
  shopt -u nullglob

  if [ ${#db_confs[@]} -eq 0 ]; then
    if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
      echo "  [INFO] No database configuration files found in '${CONF_PATH}'."
      echo ""
    fi
    return 0
  fi

  for conf in "${db_confs[@]}"; do
    [ -e "${conf}" ] || continue

    if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
      echo "Checking: $(basename "${conf}")"
    fi

    # detect type from filename
    local type
    case "$(basename -- "${conf}")" in
      backup_mysql_*.conf)      type="mysql" ;;
      backup_pgsql_*.conf)      type="pgsql" ;;
      backup_sqlite_*.conf)     type="sqlite" ;;
      *)                        continue ;;
    esac

    # defaults per conf (overridable in the conf)
    local DB_HOST="localhost"
    local AUTH_FILE="${CONF_PATH}/auth_${type}.conf"
    local AUTH_USERNAME="backup"
    local AUTH_PASSWORD=""
    local LIST_COMMAND=""
    local DUMP_COMMAND=""
    local DUMP_OPTS=""
    local IGNORED_DBS=""
    local SQLITE_DIR=""
    if [ "${type}" = "mysql" ]; then
      LIST_COMMAND="${LIST_COMMAND_MYSQL}"
      DUMP_COMMAND="${DUMP_COMMAND_MYSQL}"
      DUMP_OPTS="-Q --skip-lock-tables --single-transaction"
      IGNORED_DBS="information_schema performance_schema mysql sys"
    elif [ "${type}" = "pgsql" ]; then
      LIST_COMMAND="${LIST_COMMAND_PGSQL}"
      DUMP_COMMAND="${DUMP_COMMAND_PGSQL}"
      DUMP_OPTS=""
      IGNORED_DBS="template0 template1 postgres"
    else
      LIST_COMMAND=""
      DUMP_COMMAND="${DUMP_COMMAND_SQLITE:-sqlite3}"
      DUMP_OPTS=""
      IGNORED_DBS=""
      SQLITE_DIR=""
    fi
    local DBS=""
    # optional Docker knobs (per conf)
    local DOCKER_CONTAINER=""
    local DOCKER_USER=""
    local DOCKER_SHELL="${DOCKER_SHELL:-/bin/sh}"
    local DOCKER_OPTS=""

    # shellcheck disable=SC1090
    . "${conf}"

    # Check Docker Container if configured
    if [[ -n "${DOCKER_CONTAINER}" ]]; then
      if command -v docker &>/dev/null; then
        if docker ps --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}$"; then
          if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
            echo "  [OK] Docker container '${DOCKER_CONTAINER}' is running."
          fi
        else
          local msg="Skipping ${conf}: Docker container '${DOCKER_CONTAINER}' is NOT running!"
          log_error "${msg}"
          continue
        fi
      else
        local msg="Skipping ${conf}: Docker CLI not found on host, but DOCKER_CONTAINER='${DOCKER_CONTAINER}' is configured."
        log_error "${msg}"
        continue
      fi
    fi

    # Verify required database binaries are available
    if [[ -z "${DOCKER_CONTAINER}" ]]; then
      if [[ "$type" == "sqlite" && -z "${DUMP_COMMAND_SQLITE}" ]]; then
        local msg="Skipping ${conf}: sqlite3 is not installed on the host. Please install it (e.g. 'apt install sqlite3')."
        log_error "${msg}"
        continue
      elif [[ "$type" == "mysql" && -z "${DUMP_COMMAND_MYSQL}" ]]; then
        local msg="Skipping ${conf}: mysqldump is not installed on the host."
        log_error "${msg}"
        continue
      elif [[ "$type" == "pgsql" && -z "${DUMP_COMMAND_PGSQL}" ]]; then
        local msg="Skipping ${conf}: pg_dump is not installed on the host."
        log_error "${msg}"
        continue
      fi
    else
      local check_bin=""
      if [[ "$type" == "sqlite" ]]; then
        check_bin="${DUMP_COMMAND:-sqlite3}"
      elif [[ "$type" == "mysql" ]]; then
        check_bin="${DUMP_COMMAND:-mysqldump}"
      elif [[ "$type" == "pgsql" ]]; then
        check_bin="${DUMP_COMMAND:-pg_dump}"
      fi
      if ! run_inner "command -v '${check_bin}'" &>/dev/null; then
        local msg="Skipping ${conf}: '${check_bin}' is not installed inside Docker container '${DOCKER_CONTAINER}'."
        log_error "${msg}"
        continue
      fi
    fi

    local AUTH_ADD=""
    local discovery_cmd=""
    if [[ "$type" == "mysql" ]]; then
      if [[ -n "${AUTH_FILE}" ]]; then
        AUTH_ADD="--defaults-extra-file='${AUTH_FILE}'"
      else
        if [[ -n "${AUTH_USERNAME}" ]]; then
          if [[ -n "${AUTH_PASSWORD}" ]]; then
            AUTH_ADD="-u '${AUTH_USERNAME}' -p'${AUTH_PASSWORD}'"
          else
            AUTH_ADD="-u '${AUTH_USERNAME}'"
          fi
        fi
      fi
      discovery_cmd="${LIST_COMMAND} ${AUTH_ADD} -h '${DB_HOST}' -Bse 'SHOW DATABASES'"
    elif [[ "$type" == "pgsql" ]]; then
      if [[ -n "${AUTH_FILE}" ]]; then
        AUTH_ADD="PGPASSFILE='${AUTH_FILE}'"
      else
        if [[ -n "${AUTH_PASSWORD}" ]]; then
          AUTH_ADD="PGPASSWORD='${AUTH_PASSWORD}'"
        fi
      fi
      discovery_cmd="${AUTH_ADD} ${LIST_COMMAND} -w -U '${AUTH_USERNAME}' -h '${DB_HOST}' -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false;\""
    else
      if [[ -n "${SQLITE_DIR}" ]]; then
        discovery_cmd="find '${SQLITE_DIR}' -maxdepth 3 -type f \\( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \\)"
      fi
    fi

    # determine DB list (explicit or discovered; docker-aware)
    if [[ -z "${DBS:-}" ]]; then
      if [[ "$type" == "sqlite" && -z "${SQLITE_DIR:-}" ]]; then
        log_error "Skipping ${conf}: sqlite requires either DBS or SQLITE_DIR."
        continue
      fi

      echo "Getting databases for ${conf} ..."

      if ! DBS="$(discover_dbs "${discovery_cmd}")"; then
        log_error "Skipping ${conf}: ${type} discovery failed."
        continue
      fi
    fi

    # In verification mode, validate databases and skip backup dumps
    if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
      if [[ "$type" == "sqlite" ]]; then
        local sqlite_bin="${DUMP_COMMAND:-sqlite3}"
        for DB in ${DBS}; do
          echo "  Testing SQLite database: ${DB}..."
          local query_out
          query_out="$(run_inner "${sqlite_bin} '${DB}' 'PRAGMA integrity_check(1);'" 2>&1)"
          if [ $? -eq 0 ]; then
            if [[ "${query_out}" == *"ok"* ]]; then
              echo "    [OK] SQLite database accessible and valid: ${DB}"
            else
              echo "    [WARN] SQLite query returned: ${query_out}"
            fi
          else
            echo "    [FAIL] Failed to access SQLite database '${DB}': ${query_out}" >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
          fi
        done
      else
        echo "  [OK] ${type} connection & discovery successful for $(basename "${conf}")."
        local db_count
        db_count=$(echo "${DBS}" | wc -w)
        echo "       Databases found (${db_count}): $(echo "${DBS}" | tr '\n' ' ')"
      fi
      continue
    fi

    # process each DB with its own timer
    local DB outfile ok start_ts end_ts diff human
    for DB in ${DBS}; do
      if should_skip_db "${DB}" ${IGNORED_DBS}; then
        continue
      fi

      if [[ "$type" == "sqlite" ]]; then
        local db_clean
        db_clean="${DB#/}"
        db_clean="${db_clean//\//_}"
        outfile="${MBD}/db.${type}.${db_clean}.gz"
      else
        outfile="${MBD}/db.${type}.${DB}.gz"
      fi

      ok=0
      start_ts=$(date +%s)
      echo "Compressing database ${DB} ..."

      if [[ "$type" == "mysql" ]]; then
        dump_cmd="${DUMP_COMMAND} ${AUTH_ADD} ${DUMP_OPTS} -h '${DB_HOST}' '${DB}'"
      elif [[ "$type" == "pgsql" ]]; then
        dump_cmd="${AUTH_ADD} ${DUMP_COMMAND} ${DUMP_OPTS} -U '${AUTH_USERNAME}' -h '${DB_HOST}' '${DB}'"
      else
        local sqlite_bin="${DUMP_COMMAND:-sqlite3}"
        dump_cmd="${sqlite_bin} ${DUMP_OPTS} '${DB}' .dump"
      fi

      if backup_db "${dump_cmd}" "${outfile}" ; then
        ok=1
      else
        ok=0
      fi

      end_ts=$(date +%s); diff=$((end_ts - start_ts))
      human="$((diff / 60)) minutes and $((diff % 60)) seconds."

      # store in global
      DB_TIMES+=("${type}:${DB}:${diff}")

      if [ ${ok} -eq 1 ]; then
        NOTIFY_MESSAGE="Successfully backed up ${type} database: ${DB} (took ${human})"
        echo "${NOTIFY_MESSAGE}"
        DB_RESULTS+=("OK|${type}|${DB}|${diff}")
      else
        if [[ -n "${LAST_DB_ERROR:-}" ]]; then
          NOTIFY_MESSAGE="Error while backing up ${type} database: ${DB} (took ${human}): ${LAST_DB_ERROR}"
        else
          NOTIFY_MESSAGE="Error while backing up ${type} database: ${DB} (took ${human})"
        fi
        log_error "${NOTIFY_MESSAGE}"
        DB_RESULTS+=("FAIL|${type}|${DB}|${diff}|${LAST_DB_ERROR:-}")
      fi
    done
  done

  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo ""
  fi

  shopt -u nullglob || true
}

backup_filesystem() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "--- Filesystem Backup Directories ---"
  fi

  if [ ! -f "${DIRS_FILE}" ]; then
    echo "Directory list file '${DIRS_FILE}' not found, skipping filesystem backup."
    [ "${VERIFY_CONFIG:-0}" -eq 1 ] && echo ""
    return 0
  fi

  local base_tar_opts=()
  if [ -n "${DEST}" ]; then
    base_tar_opts+=("--exclude=${DEST}")
  fi

  while IFS= read -r DIR || [ -n "${DIR}" ]; do
    # skip empty lines and comments
    [ -z "${DIR}" ] && continue
    [[ "${DIR}" =~ ^# ]] && continue

    # Strip trailing slashes (except for root "/")
    while [[ "${DIR}" != "/" && "${DIR}" == */ ]]; do
      DIR="${DIR%/}"
    done

    # In verification mode, check directory existence and skip archiving
    if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
      if [ -d "${DIR}" ]; then
        echo "  [OK] Directory exists: ${DIR}"
      else
        echo "  [WARN] Directory does not exist on host: ${DIR}"
      fi
      continue
    fi

    start_ts=$(date +%s)
    echo "Compressing directory ${DIR} ..."

    if [[ "${DIR}" == "/" ]]; then
      LAST_DIR_NAME="root_fs"
    else
      LAST_DIR_NAME="${DIR##*/}"
    fi

    local current_tar_opts=("${base_tar_opts[@]}")

    # Build per-directory exclude list to prevent parent exclusions from suppressing subdirectories
    if [ -f "${DIRS_EXCLUDE_FILE}" ]; then
      if command -v mktemp &>/dev/null; then
        CURRENT_EXCLUDE_FILE="$(mktemp /tmp/backup_exclude.XXXXXX)"
      else
        CURRENT_EXCLUDE_FILE="/tmp/backup_exclude.$$.${RANDOM}"
      fi

      while IFS= read -r pattern || [ -n "${pattern}" ]; do
        [ -z "${pattern}" ] && continue
        [[ "${pattern}" =~ ^# ]] && continue

        local clean_pattern="${pattern%/}"
        # If the directory being backed up is equal to or inside the excluded path,
        # skip this exclude rule so it does not suppress the target directory
        if [[ "${DIR}" == "${clean_pattern}" || "${DIR}" == "${clean_pattern}"/* ]]; then
          continue
        fi
        echo "${pattern}" >> "${CURRENT_EXCLUDE_FILE}"
      done < "${DIRS_EXCLUDE_FILE}"

      current_tar_opts+=("--exclude-from=${CURRENT_EXCLUDE_FILE}")
    fi

    ${TAR_COMMAND} -cpzf "${MBD}/${LAST_DIR_NAME}.tar.gz" "${current_tar_opts[@]}" --one-file-system "${DIR}"
    ERR=$?

    if [ -n "${CURRENT_EXCLUDE_FILE:-}" ] && [ -f "${CURRENT_EXCLUDE_FILE}" ]; then
      rm -f "${CURRENT_EXCLUDE_FILE}"
      CURRENT_EXCLUDE_FILE=""
    fi
    
    end_ts=$(date +%s)
    diff=$(( end_ts - start_ts ))
    human="$((diff / 60)) minutes and $((diff % 60)) seconds."

    # store in global
    DIR_TIMES+=("${DIR}:${diff}")

    if [ ${ERR} -ne 0 ]; then
      NOTIFY_MESSAGE="Error: ${ERR}, while backing up directory: ${DIR} (took ${human})"
      log_error "${NOTIFY_MESSAGE}"
      FS_RESULTS+=("FAIL|${DIR}|${diff}")
    else
      NOTIFY_MESSAGE="Successfully backed up directory: ${DIR} (took ${human})"
      echo "${NOTIFY_MESSAGE}"
      FS_RESULTS+=("OK|${DIR}|${diff}")
    fi
  done < "${DIRS_FILE}"

  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    if [ -n "${DIRS_EXCLUDE_FILE}" ]; then
      if [ -f "${DIRS_EXCLUDE_FILE}" ]; then
        echo "  [OK] Exclusion list found: ${DIRS_EXCLUDE_FILE}"
      else
        echo "  [INFO] Exclusion list '${DIRS_EXCLUDE_FILE}' not found (optional)."
      fi
    fi
    echo ""
  fi
}

upload_to_cloud() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "--- Cloud Upload Target ---"
  fi

  if [[ -z "${CLOUD_TARGET}" ]]; then
    echo "CLOUD_TARGET is not configured, skipping cloud upload."
    [ "${VERIFY_CONFIG:-0}" -eq 1 ] && echo ""
    return 0
  fi

  if [[ -z "${RCLONE_COMMAND}" ]]; then
    log_error "Warning: rclone command not found, skipping cloud upload."
    [ "${VERIFY_CONFIG:-0}" -eq 1 ] && echo ""
    return 1
  fi

  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "  Checking cloud target '${CLOUD_TARGET}'..."
    local rclone_err
    rclone_err="$(${RCLONE_COMMAND} lsd "${CLOUD_TARGET}" --max-depth 1 2>&1)"
    if [ $? -eq 0 ]; then
      echo "  [OK] Successfully connected to cloud target '${CLOUD_TARGET}'."
    else
      echo "  [WARN] Could not connect to cloud target '${CLOUD_TARGET}': ${rclone_err}"
    fi
    echo ""
    return 0
  fi

  shopt -s nullglob
  local backup_files=("${MBD}"/*.gz)
  shopt -u nullglob

  if [[ ${#backup_files[@]} -eq 0 ]]; then
    echo "No backup files found in ${MBD} to upload."
    return 0
  fi

  for BACKUPFILE in "${backup_files[@]}"; do
    start_ts=$(date +%s)
    echo "Uploading file ${BACKUPFILE} to cloud ..."

    ${RCLONE_COMMAND} copy "${BACKUPFILE}" "${CLOUD_TARGET}"
    ERR=$?
    end_ts=$(date +%s)
    diff=$(( end_ts - start_ts ))
    human="$((diff / 60)) minutes and $((diff % 60)) seconds."

    # store in global
    UPLOAD_TIMES+=("${BACKUPFILE}:${diff}")

    if [ ${ERR} -ne 0 ]; then
       NOTIFY_MESSAGE="Error: ${ERR}, while uploading file: ${BACKUPFILE} (took ${human})"
       log_error "${NOTIFY_MESSAGE}"
       UPLOAD_RESULTS+=("FAIL|$(basename "${BACKUPFILE}")|${diff}")
    else
       NOTIFY_MESSAGE="Successfully uploaded file: ${BACKUPFILE} (took ${human})"
       echo "${NOTIFY_MESSAGE}"
       UPLOAD_RESULTS+=("OK|$(basename "${BACKUPFILE}")|${diff}")
    fi	
  done
}

delete_old_backups() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    return 0
  fi

  # Delete old backups
  if [ "${DELETE_OLD_BACKUPS}" -eq 1 ]; then
    while read -r DIR; do
      echo -n "Deleting old backup: ${DIR}: "
      rm -rf "${DIR}" 
      ERR=$?
      if [ ${ERR} -ne 0 ]; then
        log_error "Failed to delete old backup directory: ${DIR}"
        echo "ERROR"
      else
        DELETED_DIRS+=("${DIR}")
        echo "OK"
      fi
    done < <("${FIND_COMMAND}" "${DEST}" -maxdepth 1 -mtime "+${DELETE_BACKUPS_OLDER_THAN_DAYS}" -type d | ${GREP_COMMAND} -v "^${DEST}$")
  fi
  echo ""
}

generate_report() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    return 0
  fi

  local total_end_ts diff_total total_human
  total_end_ts=$(date +%s)
  diff_total=$(( total_end_ts - TOTAL_START_TS ))
  total_human="$(format_duration "${diff_total}")"
  local now_formatted
  now_formatted="$(date +"%Y-%m-%d %H:%M:%S")"

  local status_str="SUCCESS (0 errors)"
  if [ "${ERROR_COUNT:-0}" -gt 0 ]; then
    status_str="FAILED (${ERROR_COUNT} error(s) occurred)"
  fi

  local db_ok=0 db_fail=0
  for item in "${DB_RESULTS[@]}"; do
    if [[ "${item}" == OK* ]]; then db_ok=$((db_ok + 1)); else db_fail=$((db_fail + 1)); fi
  done

  local fs_ok=0 fs_fail=0
  for item in "${FS_RESULTS[@]}"; do
    if [[ "${item}" == OK* ]]; then fs_ok=$((fs_ok + 1)); else fs_fail=$((fs_fail + 1)); fi
  done

  local up_ok=0 up_fail=0
  for item in "${UPLOAD_RESULTS[@]}"; do
    if [[ "${item}" == OK* ]]; then up_ok=$((up_ok + 1)); else up_fail=$((up_fail + 1)); fi
  done

  # Assemble formatted report into TMP_MSG_FILE
  : > "${TMP_MSG_FILE}"

  {
    echo "======================================================================"
    echo " SimpleLinuxBackup Report - ${HOST}"
    echo "======================================================================"
    echo " Host:        ${HOST}"
    echo " Date:        ${now_formatted}"
    echo " Total Time:  ${total_human}"
    echo " Destination: ${MBD:-${DEST}}"
    echo " Status:      ${status_str}"
    echo "======================================================================"

    if [ "${#ERROR_MSGS[@]}" -gt 0 ]; then
      echo ""
      echo "--- ERRORS & WARNINGS ---"
      for err in "${ERROR_MSGS[@]}"; do
        echo " [!] ${err}"
      done
    fi

    echo ""
    echo "--- SUMMARY ---"
    if [ $((db_ok + db_fail)) -gt 0 ]; then
      echo " Databases:   ${db_ok} successful, ${db_fail} failed"
    else
      echo " Databases:   none"
    fi

    if [ $((fs_ok + fs_fail)) -gt 0 ]; then
      echo " Filesystem:  ${fs_ok} directories backed up, ${fs_fail} failed"
    else
      echo " Filesystem:  none"
    fi

    if [[ -n "${CLOUD_TARGET}" ]]; then
      echo " Cloud:       ${up_ok} uploaded, ${up_fail} failed (${CLOUD_TARGET})"
    else
      echo " Cloud:       disabled"
    fi

    if [ "${#DELETED_DIRS[@]}" -gt 0 ]; then
      echo " Cleaned:     ${#DELETED_DIRS[@]} old backup directory(ies) removed"
    else
      echo " Cleaned:     none"
    fi

    if [ "${#DB_RESULTS[@]}" -gt 0 ] || [ "${#FS_RESULTS[@]}" -gt 0 ] || [ "${#UPLOAD_RESULTS[@]}" -gt 0 ]; then
      echo ""
      echo "--- DETAILS & TIMINGS ---"

      if [ "${#DB_RESULTS[@]}" -gt 0 ]; then
        echo " Databases:"
        for entry in "${DB_RESULTS[@]}"; do
          IFS="|" read -r st type name secs err_detail <<< "${entry}"
          local dur
          dur="$(format_duration "${secs}")"
          if [ "${st}" = "OK" ]; then
            printf "   [OK]   %-8s %-28s (%s)\n" "${type}" "${name}" "${dur}"
          else
            printf "   [FAIL] %-8s %-28s (%s)\n" "${type}" "${name}" "${dur}"
            if [ -n "${err_detail}" ]; then
              echo "          -> ${err_detail}"
            fi
          fi
        done
      fi

      if [ "${#FS_RESULTS[@]}" -gt 0 ]; then
        echo " Filesystem:"
        for entry in "${FS_RESULTS[@]}"; do
          IFS="|" read -r st path secs <<< "${entry}"
          local dur
          dur="$(format_duration "${secs}")"
          if [ "${st}" = "OK" ]; then
            printf "   [OK]   %-37s (%s)\n" "${path}" "${dur}"
          else
            printf "   [FAIL] %-37s (%s)\n" "${path}" "${dur}"
          fi
        done
      fi

      if [ "${#UPLOAD_RESULTS[@]}" -gt 0 ]; then
        echo " Cloud Upload:"
        for entry in "${UPLOAD_RESULTS[@]}"; do
          IFS="|" read -r st file secs <<< "${entry}"
          local dur
          dur="$(format_duration "${secs}")"
          if [ "${st}" = "OK" ]; then
            printf "   [OK]   %-37s (%s)\n" "${file}" "${dur}"
          else
            printf "   [FAIL] %-37s (%s)\n" "${file}" "${dur}"
          fi
        done
      fi
    fi

    if [ "${#DELETED_DIRS[@]}" -gt 0 ]; then
      echo ""
      echo "--- OLD BACKUPS REMOVED ---"
      for d in "${DELETED_DIRS[@]}"; do
        echo "   - ${d}"
      done
    fi

    if [ -n "${DEST}" ] && [ -d "${DEST}" ]; then
      echo ""
      echo "--- DISK USAGE ---"
      ${DF_COMMAND} -h "${DEST}"
    fi

    echo ""
    echo "======================================================================"
  } >> "${TMP_MSG_FILE}"

  echo ""
  cat "${TMP_MSG_FILE}"
}

send_notification() {
  if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
    echo "============================================================"
    if [ "${ERROR_COUNT:-0}" -eq 0 ]; then
      echo " Verification Result: ALL CHECKS PASSED [OK]"
      echo "============================================================"
      exit 0
    else
      echo " Verification Result: ${ERROR_COUNT} ERROR(S) DETECTED [FAIL]"
      echo "============================================================"
      exit 1
    fi
  fi

  local subject="${NOTIFY_SUBJECT}"
  if [ "${ERROR_COUNT:-0}" -gt 0 ]; then
    subject="ERROR: ${subject}"
  fi

  # Sending notification email
  if [[ "${SEND_EMAIL:-0}" == "1" ]]; then
    if [[ -n "${MAIL_COMMAND}" ]]; then
      ${MAIL_COMMAND} -s "${subject}" "${NOTIFY_EMAIL}" < "${TMP_MSG_FILE}"
    else
      echo "Warning: SEND_EMAIL is 1, but no mail command (mailx, mail, sendmail) was found."
    fi
  fi
  rm -f "${TMP_MSG_FILE}"
}


# === Main ===
if [ "${VERIFY_CONFIG:-0}" -eq 1 ]; then
  echo "============================================================"
  echo " SimpleLinuxBackup - Configuration & Environment Verification"
  echo "============================================================"
  echo ""
fi

TOTAL_START_TS=$(date +%s)

acquire_lock
init_commands
init_backup_dirs
init_tmp_msg
backup_databases        
backup_filesystem
upload_to_cloud
delete_old_backups
generate_report
send_notification
