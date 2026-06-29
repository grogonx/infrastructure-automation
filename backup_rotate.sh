#!/bin/bash
# =============================================================================
# backup_rotate.sh
# Description: Creates a compressed, timestamped backup of one or more
#              directories and rotates old backups beyond a retention window.
#              Can optionally sync backups to an S3 bucket.
# Author:      Joshua Harvey
#
# Usage:
#   ./backup_rotate.sh                    # Uses config below
#   ./backup_rotate.sh /path/to/source    # Override source directory
# =============================================================================

set -euo pipefail

# --- Configuration ---
SOURCE_DIRS=("/etc" "/var/www" "/opt/app")   # Directories to back up
BACKUP_DEST="/mnt/backups"                   # Where backups are stored
RETAIN_DAYS=30                               # Delete backups older than this
S3_BUCKET=""                                 # Optional: "s3://my-bucket/backups"
LOG_FILE="/var/log/backup_rotate.log"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
DATE_LABEL=$(date '+%Y-%m-%d')

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "${RED}[FAIL]${NC}  $1"; log "FAIL - $1"; }

# Override source if passed as argument
if [ -n "${1:-}" ]; then
    SOURCE_DIRS=("$1")
fi

# Create backup destination if it doesn't exist
mkdir -p "$BACKUP_DEST"

echo "============================================"
echo " Backup & Rotate"
echo " ${TIMESTAMP}"
echo " Destination: ${BACKUP_DEST}"
echo " Retention  : ${RETAIN_DAYS} days"
echo "============================================"
log "--- Backup started ---"

TOTAL_SIZE=0

# --- Backup each source directory ---
for SOURCE in "${SOURCE_DIRS[@]}"; do
    if [ ! -d "$SOURCE" ]; then
        fail "Source directory not found: ${SOURCE} — skipping"
        continue
    fi

    DIR_NAME=$(basename "$SOURCE")
    ARCHIVE_NAME="${DIR_NAME}_${TIMESTAMP}.tar.gz"
    ARCHIVE_PATH="${BACKUP_DEST}/${ARCHIVE_NAME}"

    echo -e "\n${CYAN}Backing up: ${SOURCE}${NC}"
    log "Backing up ${SOURCE} -> ${ARCHIVE_PATH}"

    if tar -czf "$ARCHIVE_PATH" -C "$(dirname "$SOURCE")" "$DIR_NAME" 2>/dev/null; then
        SIZE=$(du -sh "$ARCHIVE_PATH" | cut -f1)
        ok "Created: ${ARCHIVE_NAME} (${SIZE})"
        log "OK - ${ARCHIVE_NAME} (${SIZE})"

        # Verify archive integrity
        if tar -tzf "$ARCHIVE_PATH" &>/dev/null; then
            ok "Integrity check passed"
        else
            fail "Integrity check failed for ${ARCHIVE_NAME}"
            rm -f "$ARCHIVE_PATH"
        fi
    else
        fail "Backup failed for ${SOURCE}"
    fi
done

# --- Rotate old backups ---
echo -e "\n${CYAN}Rotating backups older than ${RETAIN_DAYS} days...${NC}"
DELETED=0
while IFS= read -r OLD_FILE; do
    rm -f "$OLD_FILE"
    log "Deleted old backup: $(basename "$OLD_FILE")"
    ((DELETED++))
done < <(find "$BACKUP_DEST" -name "*.tar.gz" -mtime +"$RETAIN_DAYS" 2>/dev/null)

if [ "$DELETED" -gt 0 ]; then
    ok "Removed ${DELETED} old backup(s)"
else
    ok "No backups old enough to rotate"
fi

# --- Optional S3 Sync ---
if [ -n "$S3_BUCKET" ]; then
    echo -e "\n${CYAN}Syncing to S3: ${S3_BUCKET}${NC}"
    if command -v aws &>/dev/null; then
        aws s3 sync "$BACKUP_DEST" "$S3_BUCKET" \
            --exclude "*" --include "*.tar.gz" \
            --storage-class STANDARD_IA \
            --delete && ok "S3 sync complete" || fail "S3 sync failed"
        log "S3 sync to ${S3_BUCKET} complete"
    else
        fail "aws CLI not found — S3 sync skipped"
    fi
fi

# --- Backup inventory ---
echo -e "\n${CYAN}Current backups in ${BACKUP_DEST}:${NC}"
ls -lh "$BACKUP_DEST"/*.tar.gz 2>/dev/null || echo "  No backups found"

echo ""
echo "============================================"
echo -e " ${GREEN}Backup complete.${NC} Log: ${LOG_FILE}"
echo "============================================"
log "--- Backup complete ---"
