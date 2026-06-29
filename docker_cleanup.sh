#!/bin/bash
# =============================================================================
# docker_cleanup.sh
# Description: Cleans up unused Docker resources — stopped containers,
#              dangling images, unused volumes, and unused networks.
#              Reports disk space reclaimed before and after.
# Author:      Joshua Harvey
# =============================================================================

set -euo pipefail

DRY_RUN=false
LOG_FILE="/var/log/docker_cleanup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo "[$TIMESTAMP] $1" >> "$LOG_FILE"; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Usage: $0 [--dry-run]"; exit 1 ;;
    esac
done

# --- Check Docker is available ---
if ! command -v docker &>/dev/null; then
    echo "[ERROR] Docker is not installed or not in PATH."
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "[ERROR] Docker daemon is not running."
    exit 1
fi

echo "============================================"
echo " Docker Cleanup"
echo " ${TIMESTAMP}"
[ "$DRY_RUN" = true ] && echo -e " ${YELLOW}DRY RUN — no changes will be made${NC}"
echo "============================================"
log "--- Docker cleanup started (dry_run=${DRY_RUN}) ---"

# --- Disk usage before ---
echo -e "\n${CYAN}Disk usage before cleanup:${NC}"
docker system df

BEFORE=$(docker system df --format '{{.Size}}' 2>/dev/null | tail -1 || echo "unknown")

# --- Stopped containers ---
echo -e "\n${CYAN}[1/4] Stopped containers:${NC}"
STOPPED=$(docker ps -aq --filter status=exited --filter status=dead)
if [ -n "$STOPPED" ]; then
    COUNT=$(echo "$STOPPED" | wc -l)
    echo "  Found ${COUNT} stopped container(s)"
    if [ "$DRY_RUN" = false ]; then
        docker rm $STOPPED
        echo -e "  ${GREEN}Removed ${COUNT} container(s)${NC}"
        log "Removed ${COUNT} stopped containers"
    else
        echo "  [DRY RUN] Would remove: $STOPPED"
    fi
else
    echo "  No stopped containers found"
fi

# --- Dangling images ---
echo -e "\n${CYAN}[2/4] Dangling images (untagged):${NC}"
DANGLING=$(docker images -q --filter dangling=true)
if [ -n "$DANGLING" ]; then
    COUNT=$(echo "$DANGLING" | wc -l)
    echo "  Found ${COUNT} dangling image(s)"
    if [ "$DRY_RUN" = false ]; then
        docker rmi $DANGLING
        echo -e "  ${GREEN}Removed ${COUNT} image(s)${NC}"
        log "Removed ${COUNT} dangling images"
    else
        echo "  [DRY RUN] Would remove: $DANGLING"
    fi
else
    echo "  No dangling images found"
fi

# --- Unused volumes ---
echo -e "\n${CYAN}[3/4] Unused volumes:${NC}"
VOLUMES=$(docker volume ls -q --filter dangling=true)
if [ -n "$VOLUMES" ]; then
    COUNT=$(echo "$VOLUMES" | wc -l)
    echo "  Found ${COUNT} unused volume(s)"
    if [ "$DRY_RUN" = false ]; then
        docker volume rm $VOLUMES
        echo -e "  ${GREEN}Removed ${COUNT} volume(s)${NC}"
        log "Removed ${COUNT} unused volumes"
    else
        echo "  [DRY RUN] Would remove: $VOLUMES"
    fi
else
    echo "  No unused volumes found"
fi

# --- Unused networks ---
echo -e "\n${CYAN}[4/4] Unused networks:${NC}"
if [ "$DRY_RUN" = false ]; then
    BEFORE_NETS=$(docker network ls -q | wc -l)
    docker network prune -f > /dev/null
    AFTER_NETS=$(docker network ls -q | wc -l)
    REMOVED=$(( BEFORE_NETS - AFTER_NETS ))
    echo -e "  ${GREEN}Removed ${REMOVED} unused network(s)${NC}"
    log "Removed ${REMOVED} unused networks"
else
    UNUSED_NETS=$(docker network ls --filter dangling=true -q | wc -l)
    echo "  [DRY RUN] Would remove ${UNUSED_NETS} network(s)"
fi

# --- Disk usage after ---
echo -e "\n${CYAN}Disk usage after cleanup:${NC}"
docker system df
echo ""
echo "============================================"
echo -e " ${GREEN}Cleanup complete.${NC} Log: ${LOG_FILE}"
echo "============================================"
log "--- Docker cleanup complete ---"
