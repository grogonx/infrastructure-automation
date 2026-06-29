#!/bin/bash
# =============================================================================
# ssl_cert_checker.sh
# Description: Checks SSL certificate expiry for a list of domains.
#              Warns if a certificate expires within the warning threshold
#              and alerts if it is already expired.
# Author:      Joshua Harvey
# =============================================================================

# --- Configuration ---
WARNING_DAYS=30
DOMAINS_FILE="${1:-domains.txt}"   # Pass a file path as arg, or create domains.txt
LOG_FILE="/var/log/ssl_cert_check.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

EXPIRED=()
WARNING=()

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

check_cert() {
    local DOMAIN=$1
    local PORT="${2:-443}"

    # Fetch the certificate expiry date
    EXPIRY=$(echo | openssl s_client -servername "$DOMAIN" \
        -connect "${DOMAIN}:${PORT}" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | cut -d= -f2)

    if [ -z "$EXPIRY" ]; then
        echo -e "${RED}[ERROR]   ${DOMAIN} — could not retrieve certificate${NC}"
        log "ERROR - Could not retrieve cert for ${DOMAIN}"
        return
    fi

    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

    if [ "$DAYS_LEFT" -lt 0 ]; then
        echo -e "${RED}[EXPIRED] ${DOMAIN} — expired ${DAYS_LEFT#-} days ago (${EXPIRY})${NC}"
        log "EXPIRED - ${DOMAIN} expired on ${EXPIRY}"
        EXPIRED+=("$DOMAIN")
    elif [ "$DAYS_LEFT" -le "$WARNING_DAYS" ]; then
        echo -e "${YELLOW}[WARNING] ${DOMAIN} — expires in ${DAYS_LEFT} days (${EXPIRY})${NC}"
        log "WARNING - ${DOMAIN} expires in ${DAYS_LEFT} days"
        WARNING+=("$DOMAIN")
    else
        echo -e "${GREEN}[OK]      ${DOMAIN} — expires in ${DAYS_LEFT} days (${EXPIRY})${NC}"
        log "OK - ${DOMAIN} expires in ${DAYS_LEFT} days"
    fi
}

# --- Main ---
if [ ! -f "$DOMAINS_FILE" ]; then
    echo -e "${RED}[ERROR] Domains file not found: ${DOMAINS_FILE}${NC}"
    echo "Create a file with one domain per line, e.g.:"
    echo "  example.com"
    echo "  api.example.com"
    echo "  internal.example.com:8443"
    exit 1
fi

echo "============================================"
echo " SSL Certificate Checker"
echo " ${TIMESTAMP}"
echo " Warning threshold: ${WARNING_DAYS} days"
echo "============================================"
log "--- SSL cert check started ---"

while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    DOMAIN=$(echo "$line" | cut -d: -f1)
    PORT=$(echo "$line" | cut -d: -f2 -s)
    check_cert "$DOMAIN" "${PORT:-443}"
done < "$DOMAINS_FILE"

echo "============================================"
echo -e "  Expired  : ${RED}${#EXPIRED[@]}${NC}"
echo -e "  Warning  : ${YELLOW}${#WARNING[@]}${NC}"
echo "============================================"
log "--- SSL cert check complete | Expired: ${#EXPIRED[@]} | Warning: ${#WARNING[@]} ---"
