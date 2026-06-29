#!/bin/bash
# =============================================================================
# system_health_check.sh
# Description: Monitors CPU, memory, disk usage, and critical services.
#              Logs results and sends an alert if thresholds are exceeded.
# Author:      Joshua Harvey
# =============================================================================

# --- Configuration ---
CPU_THRESHOLD=85
MEM_THRESHOLD=80
DISK_THRESHOLD=90
LOG_FILE="/var/log/health_check.log"
ALERT_EMAIL="admin@example.com"
SERVICES=("sshd" "httpd" "kubelet" "chronyd")

# --- Colours for terminal output ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No colour

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)
ALERTS=()

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# --- CPU Usage ---
check_cpu() {
    CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'.' -f1)
    CPU_USAGE=$((100 - CPU_IDLE))
    if [ "$CPU_USAGE" -ge "$CPU_THRESHOLD" ]; then
        echo -e "${RED}[ALERT] CPU usage is at ${CPU_USAGE}% (threshold: ${CPU_THRESHOLD}%)${NC}"
        log "ALERT - CPU usage: ${CPU_USAGE}%"
        ALERTS+=("CPU usage at ${CPU_USAGE}%")
    else
        echo -e "${GREEN}[OK]    CPU usage: ${CPU_USAGE}%${NC}"
        log "OK - CPU usage: ${CPU_USAGE}%"
    fi
}

# --- Memory Usage ---
check_memory() {
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$(( (MEM_USED * 100) / MEM_TOTAL ))
    if [ "$MEM_PERCENT" -ge "$MEM_THRESHOLD" ]; then
        echo -e "${RED}[ALERT] Memory usage is at ${MEM_PERCENT}% (${MEM_USED}MB / ${MEM_TOTAL}MB)${NC}"
        log "ALERT - Memory usage: ${MEM_PERCENT}%"
        ALERTS+=("Memory usage at ${MEM_PERCENT}%")
    else
        echo -e "${GREEN}[OK]    Memory usage: ${MEM_PERCENT}% (${MEM_USED}MB / ${MEM_TOTAL}MB)${NC}"
        log "OK - Memory usage: ${MEM_PERCENT}%"
    fi
}

# --- Disk Usage ---
check_disk() {
    while IFS= read -r line; do
        USAGE=$(echo "$line" | awk '{print $5}' | tr -d '%')
        MOUNT=$(echo "$line" | awk '{print $6}')
        if [ "$USAGE" -ge "$DISK_THRESHOLD" ]; then
            echo -e "${RED}[ALERT] Disk usage on ${MOUNT} is at ${USAGE}%${NC}"
            log "ALERT - Disk usage on ${MOUNT}: ${USAGE}%"
            ALERTS+=("Disk ${MOUNT} at ${USAGE}%")
        else
            echo -e "${GREEN}[OK]    Disk usage on ${MOUNT}: ${USAGE}%${NC}"
            log "OK - Disk on ${MOUNT}: ${USAGE}%"
        fi
    done < <(df -h | grep '^/dev/' | awk '{print $5, $6}' | sed 's/%//')
}

# --- Service Status ---
check_services() {
    for SERVICE in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$SERVICE"; then
            echo -e "${GREEN}[OK]    Service running: ${SERVICE}${NC}"
            log "OK - Service ${SERVICE} is running"
        else
            echo -e "${RED}[ALERT] Service is DOWN: ${SERVICE}${NC}"
            log "ALERT - Service ${SERVICE} is NOT running"
            ALERTS+=("Service ${SERVICE} is DOWN")
        fi
    done
}

# --- Send Alert Email ---
send_alert() {
    if [ ${#ALERTS[@]} -gt 0 ]; then
        BODY="Health check alert on ${HOSTNAME} at ${TIMESTAMP}:\n\n"
        for ALERT in "${ALERTS[@]}"; do
            BODY+="  - ${ALERT}\n"
        done
        echo -e "$BODY" | mail -s "[ALERT] System Health Warning - ${HOSTNAME}" "$ALERT_EMAIL"
        log "Alert email sent to ${ALERT_EMAIL}"
    fi
}

# --- Main ---
echo "============================================"
echo " System Health Check — ${HOSTNAME}"
echo " ${TIMESTAMP}"
echo "============================================"
log "--- Health check started on ${HOSTNAME} ---"

check_cpu
check_memory
check_disk
check_services
send_alert

echo "============================================"
if [ ${#ALERTS[@]} -eq 0 ]; then
    echo -e "${GREEN}All checks passed. No alerts.${NC}"
    log "Health check completed — no alerts"
else
    echo -e "${YELLOW}Health check complete. ${#ALERTS[@]} alert(s) triggered.${NC}"
    log "Health check completed — ${#ALERTS[@]} alert(s)"
fi
