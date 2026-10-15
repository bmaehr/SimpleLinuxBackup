#!/bin/bash

#set -euo pipefail

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

# Get hostname
HOST="${HOST:-$(hostname)}"

# Send result email
SEND_EMAIL="${SEND_EMAIL:-0}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-root@localhost}"
NOTIFY_SUBJECT="${NOTIFY_SUBJECT:-Backup Notification (${HOST})}"

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

# === Functions ===

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
}

function gen_email {
  NEW_LINE=$1
  LINE=$2
  if [[ "${NEW_LINE:-0}" == "1" ]]; then
    echo "${LINE}" >> ${TMP_MSG_FILE}
  else
    echo -n "${LINE}" >> ${TMP_MSG_FILE}
  fi
}

init_backup_dirs() {
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

  run_inner "${dump_cmd}" | env -u GZIP "${GZIP_COMMAND}" -9 > "$outfile"
  local pipe_status=("${PIPESTATUS[@]}")
  if [[ ${pipe_status[0]} -ne 0 || ${pipe_status[1]} -ne 0 ]]; then
    rm -f "$outfile"
    return 1
  fi
}

should_skip_db() {
  local db="$1"; shift
  for ig in "$@"; do
    [ "$db" = "$ig" ] && return 0
  done
  return 1
}

backup_databases() {
  shopt -s nullglob

  for conf in "${CONF_PATH}"/backup_mysql_*.conf "${CONF_PATH}"/backup_pgsql_*.conf "${CONF_PATH}"/backup_sqlite_*.conf; do
    [ -e "${conf}" ] || continue

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
        gen_email 1 "Skipping ${conf}: sqlite requires either DBS or SQLITE_DIR."
        echo "Skipping ${conf}: sqlite requires either DBS or SQLITE_DIR."
        continue
      fi

      echo "Getting databases for ${conf} ..."

      if ! DBS="$(discover_dbs "${discovery_cmd}")"; then
        gen_email 1 "Skipping ${conf}: ${type} discovery failed."
        echo "Skipping ${conf}: ${type} discovery failed."
        continue
      fi
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
      else
        NOTIFY_MESSAGE="Error while backing up ${type} database: ${DB} (took ${human})"
      fi
      gen_email 1 "${NOTIFY_MESSAGE}"
      echo "${NOTIFY_MESSAGE}"
    done
  done

  shopt -u nullglob || true
}

backup_filesystem() {
  if [ ! -f "${DIRS_FILE}" ]; then
    echo "Directory list file '${DIRS_FILE}' not found, skipping filesystem backup."
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
    else
      NOTIFY_MESSAGE="Successfully backed up directory: ${DIR} (took ${human})"
    fi
    gen_email 1 "${NOTIFY_MESSAGE}"
    echo "${NOTIFY_MESSAGE}"
  done < "${DIRS_FILE}"
}

upload_to_cloud() {
  if [[ -z "${CLOUD_TARGET}" ]]; then
    echo "CLOUD_TARGET is not configured, skipping cloud upload."
    return 0
  fi

  if [[ -z "${RCLONE_COMMAND}" ]]; then
    echo "Warning: rclone command not found, skipping cloud upload."
    gen_email 1 "Warning: rclone command not found, skipping cloud upload."
    return 1
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
    else
       NOTIFY_MESSAGE="Successfully uploaded file: ${BACKUPFILE} (took ${human})"
    fi	
    gen_email 1 "${NOTIFY_MESSAGE}"
    echo "${NOTIFY_MESSAGE}"
  done
}

log_times() {
  gen_email 1 ""
  echo ""

  echo "=== Database Timings ==="
  gen_email 1 "=== Database Timings ==="
  for entry in "${DB_TIMES[@]}"; do
    IFS=":" read -r type name secs <<< "${entry}"
    human="$((secs / 60)) minutes and $((secs % 60)) seconds."
    line="${type} database ${name} took ${human}"
    echo "${line}"
    gen_email 1 "${line}"
  done

  echo ""
  echo "=== Directory Timings ==="
  gen_email 1 "=== Directory Timings ==="
  for entry in "${DIR_TIMES[@]}"; do
    IFS=":" read -r path secs <<< "${entry}"
    human="$((secs / 60)) minutes and $((secs % 60)) seconds."
    line="directory ${path} took ${human}"
    echo "${line}"
    gen_email 1 "${line}"
  done

  echo ""
  echo "=== Upload Timings ==="
  gen_email 1 "=== Upload Timings ==="
  for entry in "${UPLOAD_TIMES[@]}"; do
    IFS=":" read -r file secs <<< "${entry}"
    human="$((secs / 60)) minutes and $((secs % 60)) seconds."
    line="upload ${file} took ${human}"
    echo "${line}"
    gen_email 1 "${line}"
  done

  gen_email 1 ""
  echo ""
}

delete_old_backups() {
  # Delete old backups
  if [ "${DELETE_OLD_BACKUPS}" -eq 1 ]; then
    "${FIND_COMMAND}" "${DEST}" -maxdepth 1 -mtime "+${DELETE_BACKUPS_OLDER_THAN_DAYS}" -type d | ${GREP_COMMAND} -v "^${DEST}$" | while read -r DIR; do
      gen_email 0 "Deleting: ${DIR}: "
      echo -n "Deleting: ${DIR}: "
      rm -rf "${DIR}" 
      ERR=$?
      if [ ${ERR} -ne 0 ]; then
        NOTIFY_MESSAGE="ERROR"
      else
        NOTIFY_MESSAGE="OK"
      fi
      gen_email 1 "${NOTIFY_MESSAGE}"
      echo "${NOTIFY_MESSAGE}"
    done
  fi

  # Empty line in email and stdout
  gen_email 1 ""
  echo ""
}

append_disk_stats() {
  # Add disk space stats of backup filesystem
  ${DF_COMMAND} -h "${DEST}" >> "${TMP_MSG_FILE}"  
  ${DF_COMMAND} -h "${DEST}"
}

send_notification() {
  # Sending notification email
  if [[ "${SEND_EMAIL:-0}" == "1" ]]; then
    if [[ -n "${MAIL_COMMAND}" ]]; then
      ${MAIL_COMMAND} -s "${NOTIFY_SUBJECT}" "${NOTIFY_EMAIL}" < "${TMP_MSG_FILE}"
    else
      echo "Warning: SEND_EMAIL is 1, but no mail command (mailx, mail, sendmail) was found."
    fi
  fi
  rm -f "${TMP_MSG_FILE}"
}


# === Main ===
acquire_lock
init_commands
init_backup_dirs
init_tmp_msg
backup_databases        
backup_filesystem
upload_to_cloud
log_times
delete_old_backups
append_disk_stats
send_notification
