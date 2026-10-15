# SimpleLinuxBackup

A modular, lightweight Bash backup solution for Linux servers supporting filesystem archiving, multi-database dumps (MySQL/MariaDB, PostgreSQL, SQLite) either locally or inside Docker containers, automated cloud uploads via rclone, retention pruning, and status notifications.

---

## Features

* **Database Backups:**
  * Supports **MySQL / MariaDB**, **PostgreSQL**, and **SQLite**.
  * Executes either locally on the host or inside **Docker containers** via `docker exec`.
  * Automatic database discovery (`SHOW DATABASES`, `pg_database`, or filesystem scan for SQLite `.sqlite`, `.sqlite3`, `.db`) with built-in exclusion of system schemas (`information_schema`, `template1`, etc.).
  * Direct stream compression (`gzip -9`) with pipeline exit code verification.
* **Filesystem Backups:**
  * Archives specified directories into `.tar.gz`.
  * Supports exclude patterns via `--exclude-from`.
  * Respects filesystem boundaries (`--one-file-system`).
* **Cloud Storage Sync:**
  * Optional upload to any cloud provider supported by [`rclone`](https://rclone.org/) (S3, Google Drive, Backblaze B2, SFTP, etc.).
* **Retention & Pruning:**
  * Automated cleanup of backup directories older than a configurable number of days.
* **Safety & Concurrency:**
  * Process locking via `flock` to prevent overlapping runs.
  * Destination folder (`$DEST`) is automatically excluded from filesystem tar operations to prevent recursion.
  * Temporary files use `mktemp` with `EXIT`/`TERM`/`INT` traps for guaranteed cleanup.
* **Reporting & Notifications:**
  * Detailed execution timing metrics per database, directory, and upload.
  * Disk usage overview (`df -h`).
  * Email notification delivery via `mailx`, `mail`, or `sendmail`.

---

## Requirements

The script automatically detects required tools on `$PATH`:

* Core utilities: `bash`, `tar`, `gzip`, `find`, `df`, `grep`, `chmod`, `chown`, `flock`, `mktemp`
* Database clients (optional, needed if backing up local databases): `mysql`, `mysqldump`, `psql`, `pg_dump`, `sqlite3`
* Docker CLI (optional, needed if backing up containerized databases): `docker`
* Remote sync (optional, needed for cloud upload): `rclone`
* Mail utility (optional, needed for email alerts): `mailx`, `mail`, or `sendmail`

---

## Configuration

### Environment File (`.env`)

SimpleLinuxBackup automatically loads a `.env` file if present. It checks the following locations in order:
1. Custom path specified via `ENV_FILE` (e.g. `ENV_FILE=/path/to/.env ./backup.sh`)
2. Script directory (`<script_dir>/.env`)
3. Configuration directory (`${CONF_PATH}/.env` or `/etc/backup/.env`)
4. Current working directory (`./.env`)

A template is provided in [`examples/.env.example`](examples/.env.example).

### Environment Variables

All parameters can be configured via `.env` or set directly in your environment:

| Variable | Description | Default |
|---|---|---|
| `CONF_PATH` | Path containing configuration and list files | `/etc/backup` |
| `DEST` | Local directory where backups are stored | `/var/backups` |
| `OWNER` | User owner of the backup destination | `root` |
| `GROUP` | Group owner of the backup destination | `root` |
| `DIRS_FILE` | File containing directories to archive | `${CONF_PATH}/backup_dirs.lst` |
| `DIRS_EXCLUDE_FILE` | File containing tar exclusion patterns | `${CONF_PATH}/backup_dirs_exclude.lst` |
| `LOCK_FILE` | Concurrency lock file | `/run/lock/simplelinuxbackup.lock` |
| `HOST` | Hostname included in notifications | `$(hostname)` |
| `SEND_EMAIL` | Set to `1` to enable email reporting | `0` |
| `NOTIFY_EMAIL` | Target email address for backup reports | `root@localhost` |
| `NOTIFY_SUBJECT` | Email subject line | `Backup Notification (${HOST})` |
| `DELETE_OLD_BACKUPS` | Set to `1` to enable pruning of old backups | `1` |
| `DELETE_BACKUPS_OLDER_THAN_DAYS` | Retention duration in days | `5` |
| `CLOUD_TARGET` | Rclone remote destination (e.g. `remote:bucket/path`) | *(empty, disabled)* |
| `NOW` | Backup date folder format (`YYYYMMDD`) | `$(date +"%Y%m%d")` |
| `ENV_FILE` | Path to an explicit `.env` file to load | *(optional)* |

---

## Setup & File Formats

Template files are available in the [examples/](examples/) directory.

### 1. Filesystem Configuration

* **`backup_dirs.lst`**: List absolute directories to back up (one per line):
  ```text
  /etc
  /var/www
  /home
  ```
* **`backup_dirs_exclude.lst`**: (Optional) Patterns to exclude from tar:
  ```text
  *.log
  *.tmp
  cache/
  node_modules/
  ```

### 2. Database Configurations

The script scans for configuration files matching:
* `${CONF_PATH}/backup_mysql_*.conf` (MySQL / MariaDB)
* `${CONF_PATH}/backup_pgsql_*.conf` (PostgreSQL)
* `${CONF_PATH}/backup_sqlite_*.conf` (SQLite)

Multiple instances can be backed up by creating multiple `.conf` files (e.g. `backup_mysql_app1.conf`, `backup_sqlite_app2.conf`).

#### Example: Local MySQL (`backup_mysql_local.conf`)
```bash
DB_HOST="localhost"
AUTH_FILE="/etc/backup/auth_mysql.conf"
AUTH_USERNAME="backup"
AUTH_PASSWORD=""
DUMP_OPTS="-Q --skip-lock-tables --single-transaction"
IGNORED_DBS="information_schema performance_schema mysql sys"
DBS=""  # Leave empty to auto-discover all databases
```

#### Example: Dockerized PostgreSQL (`backup_pgsql_docker.conf`)
```bash
DOCKER_CONTAINER="postgres-db"
DOCKER_USER="postgres"
DOCKER_SHELL="/bin/sh"
DOCKER_OPTS=""

DB_HOST="127.0.0.1"
AUTH_FILE=""
AUTH_USERNAME="postgres"
AUTH_PASSWORD="secretpassword"
IGNORED_DBS="template0 template1 postgres"
DBS=""
```

#### Example: Local SQLite (`backup_sqlite_local.conf`)
```bash
# Automatically discover *.sqlite, *.sqlite3, *.db in a directory:
SQLITE_DIR="/var/lib/sqlite"

# Or explicitly specify database file paths (space-separated):
# DBS="/var/lib/sqlite/app.db /var/www/site/data.sqlite3"
DBS=""
```

#### Example: Dockerized SQLite (`backup_sqlite_docker.conf`)
```bash
DOCKER_CONTAINER="app-container"
DOCKER_SHELL="/bin/sh"

# Path inside the container to scan:
SQLITE_DIR="/app/data"
DBS=""
```

#### Example: Vaultwarden SQLite (`backup_sqlite_vaultwarden.conf`)
```bash
# When running on host:
DBS="/srv/vaultwarden/data/db.sqlite3"

# When running inside Docker container:
# DOCKER_CONTAINER="vaultwarden"
# DOCKER_SHELL="/bin/sh"
# DBS="/data/db.sqlite3"
```

### 3. Authentication Files

Protect database credentials with secure file permissions (`chmod 600`):

* **MySQL (`auth_mysql.conf`)**:
  ```ini
  [client]
  user=backup
  password="your_password_here"
  ```
* **PostgreSQL (`auth_pgsql.conf`)**:
  ```text
  # hostname:port:database:username:password
  localhost:5432:*:postgres:your_password_here
  ```

---

## Usage

### Direct Execution

```bash
# Run using .env file or default settings
./backup.sh

# Run with an explicit .env file
ENV_FILE="/etc/backup/production.env" ./backup.sh

# Run with inline environment variables
DEST="/mnt/storage/backups" SEND_EMAIL=1 NOTIFY_EMAIL="admin@example.com" ./backup.sh
```

### Automated Scheduling

#### Option A: Systemd Timer (Recommended)

Systemd timers provide structured journal logging (`journalctl -u simplelinuxbackup`), automatic retry handling, and missed-schedule execution when hosts are offline.

1. Copy the script to `/usr/local/bin/backup.sh` and make it executable:
   ```bash
   sudo cp backup.sh /usr/local/bin/backup.sh
   sudo chmod 755 /usr/local/bin/backup.sh
   ```
2. Copy the unit files from `systemd/` to `/etc/systemd/system/`:
   ```bash
   sudo cp systemd/simplelinuxbackup.service /etc/systemd/system/
   sudo cp systemd/simplelinuxbackup.timer /etc/systemd/system/
   ```
3. Reload systemd and enable the timer:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now simplelinuxbackup.timer
   ```
4. Verify timer status:
   ```bash
   systemctl list-timers simplelinuxbackup.timer
   ```

#### Option B: Cron Job

To run daily at 02:00 AM via cron, add a line to `/etc/crontab` or `crontab -e`:

```cron
0 2 * * * root /usr/local/bin/backup.sh > /var/log/backup.log 2>&1
```

---

## License

This project is licensed under the [MIT License](LICENSE).

