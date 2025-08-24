#!/bin/bash

#set -euo pipefail

# Modify the variables below to your need
CONF_PATH="/etc/backup"

# Owner of backup dir
OWNER="root"
# Group of backup dir
GROUP="root"
# Backup Dest directory, change this if you have someother location
DEST="/root/backup/vserver"

# Filesystem
DIRS_FILE="${CONF_PATH}/backup_dirs.lst"
DIRS_EXCLUDE_FILE="${CONF_PATH}/backup_dirs_exclude.lst"

# Send Result EMail
SEND_EMAIL=1
NOTIFY_EMAIL="root@bmaehr.com"
NOTIFY_SUBJECT="Backup Notification"

# Delete old backups
DELETE_OLD_BACKUPS=1
DELETE_BACKUPS_OLDER_THAN_DAYS=5

# Cloud
CLOUD_TARGET=encrypted_gdrive_backup_machine:vserver

# Get hostname
HOST="$(hostname)"

# Get data in yyyy-mm-dd format
NOW="$(date +"%Y%m%d")"

DB_TIMES=()
DIR_TIMES=()
UPLOAD_TIMES=()

# === Functions ===

init_commands() {
  LIST_COMMAND_MYSQL="$(which mysql)"
  LIST_COMMAND_PGSQL="$(which psql)"
  DUMP_COMMAND_MYSQL="$(which mysqldump)"
  DUMP_COMMAND_PGSQL="$(which pg_dump)"
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

  export LIST_COMMAND_MYSQL LIST_COMMAND_DEFAULT_PGSQL DUMP_COMMAND_MYSQL DUMP_COMMAND_DEFAULT_PGSQL \
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

init_tmp_msg() {
  # Temp Message file
  TMP_MSG_FILE="/tmp/${RANDOM}.msg"

  export TMP_MSG_FILE
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

  if ! run_inner "${dump_cmd}" | env -u GZIP "${GZIP_COMMAND}" -9 > "$outfile"; then
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

  for conf in "${CONF_PATH}"/backup_mysql_*.conf "${CONF_PATH}"/backup_pgsql_*.conf; do
    [ -e "${conf}" ] || continue

    # detect type from filename
    local type
    case "$(basename -- "${conf}")" in
      backup_mysql_*.conf)      type="mysql" ;;
      backup_pgsql_*.conf)      type="pgsql" ;;
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
    if [ "${type}" = "mysql" ]; then
      LIST_COMMAND="${LIST_COMMAND_MYSQL}"
      DUMP_COMMAND="${DUMP_COMMAND_MYSQL}"
      DUMP_OPTS="-Q --skip-lock-tables --single-transaction"
      IGNORED_DBS="information_schema performance_schema mysql sys"
    else
      LIST_COMMAND="${LIST_COMMAND_PGSQL}"
      DUMP_COMMAND="${DUMP_COMMAND_PGSQL}"
      DUMP_OPTS=""
      IGNORED_DBS="template0 template1 postgres"
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
    else
     if [[ -n "${AUTH_FILE}" ]]; then
       AUTH_ADD="PGPASSFILE='${AUTH_FILE}'"
     else
       if [[ -n "${AUTH_PASSWORD}" ]]; then
         AUTH_ADD="PGPASSWORD='${AUTH_PASSWORD}'"
       fi
     fi
     discovery_cmd="${AUTH_ADD} ${LIST_COMMAND} -w -U '${AUTH_USERNAME}' -h '${DB_HOST}' -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false;\""
    fi

    # determine DB list (explicit or discovered; docker-aware)
    if [[ -z "${DBS:-}" ]]; then
      echo "Getting databases for ${conf} ..."

      if ! DBS="$(discover_dbs "${discovery_cmd}")"; then
        gen_email "${SEND_EMAIL}" "${TMP_MSG_FILE}" 1 "Skipping ${conf}: ${type} discovery failed."
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

      outfile="${MBD}/db.${type}.${DB}.gz"
      ok=0
      start_ts=$(date +%s)
      echo "Compressing database ${DB} ..."

      if [[ "$type" == "mysql" ]]; then
        dump_cmd="${DUMP_COMMAND} ${AUTH_ADD} ${DUMP_OPTS} -h '${DB_HOST}' '${DB}'"
      else
        dump_cmd="${AUTH_ADD} ${DUMP_COMMAND} ${DUMP_OPTS} -U '${AUTH_USERNAME}' -h '${DB_HOST}' '${DB}'"
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
  while IFS= read -r DIR || [ -n "${DIR}" ]; do
    # skip empty lines and comments
    [ -z "${DIR}" ] && continue
    [[ "${DIR}" =~ ^# ]] && continue

    start_ts=$(date +%s)
    echo "Compressing directory ${DIR} ..."

    LAST_DIR_NAME=${DIR##*/}
    ${TAR_COMMAND} -cpzf ${MBD}/${LAST_DIR_NAME}.tar.gz --exclude-from=${DIRS_EXCLUDE_FILE} --one-file-system ${DIR}
    ERR=$?
    
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
  for BACKUPFILE in ${MBD}/*.gz; do
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
  if [ ${DELETE_OLD_BACKUPS} -eq 1 ]; then
    "${FIND_COMMAND}" "${DEST}" -maxdepth 1 -mtime +${DELETE_BACKUPS_OLDER_THAN_DAYS} -type d | ${GREP_COMMAND} -v "^${DEST}$" | while read DIR; do
      gen_email 0 "Deleting: ${DIR}: "
      echo -n "Deleting: ${DIR}: "
      rm -rf "${DIR}" 
      ERR=$?
      if [ ${ERR} != 0 ]; then
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
    ${MAIL_COMMAND} -s "${NOTIFY_SUBJECT}" "${NOTIFY_EMAIL}" < "${TMP_MSG_FILE}"
  fi
  rm -f "${TMP_MSG_FILE}"
}


# === Main ===
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
