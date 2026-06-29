#!/bin/bash
# =============================================================================
# k8s_health_check.sh
# Description: Checks the health of a Kubernetes cluster — nodes, pods,
#              deployments, and persistent volumes. Flags anything that
#              isn't in a healthy state and outputs a summary report.
# Author:      Joshua Harvey
# =============================================================================

# --- Configuration ---
NAMESPACE="${1:-default}"   # Pass namespace as arg, defaults to 'default'
LOG_FILE="/var/log/k8s_health_check.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

ISSUES=0

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

section() {
    echo ""
    echo -e "${CYAN}>>> $1${NC}"
    echo "--------------------------------------------"
}

# --- Prerequisite check ---
if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}[ERROR] kubectl is not installed or not in PATH.${NC}"
    exit 1
fi

echo "============================================"
echo " Kubernetes Health Check"
echo " Namespace: ${NAMESPACE}"
echo " ${TIMESTAMP}"
echo "============================================"
log "--- K8s health check started | namespace: ${NAMESPACE} ---"

# --- Node Status ---
section "Node Status"
while IFS= read -r line; do
    NODE=$(echo "$line" | awk '{print $1}')
    STATUS=$(echo "$line" | awk '{print $2}')
    ROLES=$(echo "$line" | awk '{print $3}')
    VERSION=$(echo "$line" | awk '{print $5}')
    if [ "$STATUS" != "Ready" ]; then
        echo -e "${RED}[NOT READY] ${NODE} (${ROLES}) — ${VERSION}${NC}"
        log "ALERT - Node ${NODE} is ${STATUS}"
        ((ISSUES++))
    else
        echo -e "${GREEN}[Ready]     ${NODE} (${ROLES}) — ${VERSION}${NC}"
        log "OK - Node ${NODE} is Ready"
    fi
done < <(kubectl get nodes --no-headers 2>/dev/null)

# --- Pod Status ---
section "Pod Status (namespace: ${NAMESPACE})"
while IFS= read -r line; do
    POD=$(echo "$line" | awk '{print $1}')
    READY=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')
    RESTARTS=$(echo "$line" | awk '{print $4}')

    if [ "$STATUS" != "Running" ] && [ "$STATUS" != "Completed" ]; then
        echo -e "${RED}[${STATUS}] ${POD} — Restarts: ${RESTARTS}${NC}"
        log "ALERT - Pod ${POD} is ${STATUS} with ${RESTARTS} restarts"
        ((ISSUES++))
    elif [ "$RESTARTS" -gt 5 ] 2>/dev/null; then
        echo -e "${YELLOW}[WARNING]   ${POD} — Status: ${STATUS}, Restarts: ${RESTARTS}${NC}"
        log "WARN - Pod ${POD} has ${RESTARTS} restarts"
        ((ISSUES++))
    else
        echo -e "${GREEN}[Running]   ${POD} — Ready: ${READY}, Restarts: ${RESTARTS}${NC}"
    fi
done < <(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null)

# --- Deployment Readiness ---
section "Deployment Readiness (namespace: ${NAMESPACE})"
while IFS= read -r line; do
    DEPLOY=$(echo "$line" | awk '{print $1}')
    READY=$(echo "$line" | awk '{print $2}')
    DESIRED=$(echo "$line" | awk '{print $3}')

    if [ "$READY" != "$DESIRED" ]; then
        echo -e "${RED}[DEGRADED]  ${DEPLOY} — ${READY}/${DESIRED} replicas ready${NC}"
        log "ALERT - Deployment ${DEPLOY} is degraded (${READY}/${DESIRED})"
        ((ISSUES++))
    else
        echo -e "${GREEN}[OK]        ${DEPLOY} — ${READY}/${DESIRED} replicas ready${NC}"
    fi
done < <(kubectl get deployments -n "$NAMESPACE" --no-headers 2>/dev/null)

# --- Persistent Volume Claims ---
section "Persistent Volume Claims (namespace: ${NAMESPACE})"
while IFS= read -r line; do
    PVC=$(echo "$line" | awk '{print $1}')
    PVC_STATUS=$(echo "$line" | awk '{print $2}')
    CAPACITY=$(echo "$line" | awk '{print $4}')

    if [ "$PVC_STATUS" != "Bound" ]; then
        echo -e "${RED}[${PVC_STATUS}] ${PVC} — Capacity: ${CAPACITY}${NC}"
        log "ALERT - PVC ${PVC} is ${PVC_STATUS}"
        ((ISSUES++))
    else
        echo -e "${GREEN}[Bound]     ${PVC} — Capacity: ${CAPACITY}${NC}"
    fi
done < <(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null)

# --- Summary ---
echo ""
echo "============================================"
if [ "$ISSUES" -eq 0 ]; then
    echo -e "${GREEN}Cluster looks healthy. No issues detected.${NC}"
    log "Health check complete — no issues"
else
    echo -e "${RED}Health check complete — ${ISSUES} issue(s) found. Review log: ${LOG_FILE}${NC}"
    log "Health check complete — ${ISSUES} issue(s) found"
fi
echo "============================================"
