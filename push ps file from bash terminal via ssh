#!/usr/bin/env bash
set -u

IP_LIST="$HOME/Desktop/ips.txt"
PS1_LOCAL="$HOME/Documents/PUSH_script.ps1"
WIN_USER="wlo"
WIN_PASS='1qaz@wsx'

REMOTE_PS1='C:/Windows/Temp/PUSH_script.ps1'
REMOTE_LOG='C:/Windows/Temp/PUSH_script.log'

LOGFILE="$HOME/fuhw_push.log"
FAILED_LIST="$HOME/failed_targets.txt"
SUCCESS_LIST="$HOME/success_targets.txt"
PER_HOST_LOG_DIR="$HOME/PUSH_script_host_logs"

MAX_JOBS=3
IDLE_LIMIT=240
POLL_INTERVAL=5
MAX_RUNTIME=3600

[ -f "$IP_LIST" ] || { echo "IP list not found: $IP_LIST"; exit 1; }
[ -f "$PS1_LOCAL" ] || { echo "PowerShell script not found: $PS1_LOCAL"; exit 1; }

mkdir -p "$PER_HOST_LOG_DIR"
: > "$FAILED_LIST"
: > "$SUCCESS_LIST"
: > "$LOGFILE"

ASKPASS_SCRIPT="$(mktemp)"
trap 'rm -f "$ASKPASS_SCRIPT"' EXIT

cat > "$ASKPASS_SCRIPT" <<EOF
#!/usr/bin/env bash
echo '$WIN_PASS'
EOF
chmod 700 "$ASKPASS_SCRIPT"

export SSH_ASKPASS="$ASKPASS_SCRIPT"
export SSH_ASKPASS_REQUIRE=force
export DISPLAY=:0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

ssh_run() {
    local ip="$1"
    local cmd="$2"
    setsid -w ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        "${WIN_USER}@${ip}" "$cmd" </dev/null
}

scp_copy() {
    local ip="$1"
    setsid -w scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "$PS1_LOCAL" "${WIN_USER}@${ip}:${REMOTE_PS1}" </dev/null
}

run_one() {
    local ip="$1"
    local hostlog="$PER_HOST_LOG_DIR/${ip}.log"
    local last_size=0
    local idle_time=0
    local elapsed=0

    {
        log "===== [$ip] START ====="

        log "[$ip] Copying PowerShell script..."
        if ! scp_copy "$ip"; then
            log "[$ip] ERROR: Copy failed"
            echo "$ip" >> "$FAILED_LIST"
            exit 1
        fi

        log "[$ip] Copy successful"

        log "[$ip] Starting remote script..."
        if ! ssh_run "$ip" "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Remove-Item -Path '$REMOTE_LOG' -ErrorAction SilentlyContinue; powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$REMOTE_PS1' *> '$REMOTE_LOG'\""; then
            log "[$ip] ERROR: Failed to launch remote script"
            echo "$ip" >> "$FAILED_LIST"
            exit 2
        fi

        log "[$ip] Script started, monitoring..."

        while true; do
            sleep "$POLL_INTERVAL"
            elapsed=$((elapsed + POLL_INTERVAL))

            remote_state="$(ssh_run "$ip" "powershell.exe -Command \"if (Test-Path '$REMOTE_LOG') { \$f = Get-Item '$REMOTE_LOG'; Write-Output ('SIZE=' + \$f.Length); Write-Output '---LOGSTART---'; Get-Content '$REMOTE_LOG' -Tail 20; Write-Output '---LOGEND---' } else { Write-Output 'SIZE=0'; Write-Output '---LOGSTART---'; Write-Output 'Waiting for log file...'; Write-Output '---LOGEND---' }\"" 2>/dev/null)"

            current_size="$(printf '%s\n' "$remote_state" | awk -F= '/^SIZE=/{print $2; exit}')"
            log_block="$(printf '%s\n' "$remote_state" | awk '/---LOGSTART---/{flag=1;next}/---LOGEND---/{flag=0}flag')"

            echo "[$ip] --- remote log ---"
            printf '%s\n' "$log_block"
            echo "[$ip] ------------------"

            if [ "$current_size" -gt "$last_size" ]; then
                last_size="$current_size"
                idle_time=0
            else
                idle_time=$((idle_time + POLL_INTERVAL))
            fi

            if printf '%s\n' "$log_block" | grep -q "Script completed successfully."; then
                log "[$ip] SUCCESS"
                echo "$ip" >> "$SUCCESS_LIST"
                exit 0
            fi

            if printf '%s\n' "$log_block" | grep -q "Fatal error:"; then
                log "[$ip] ERROR: Script failed"
                echo "$ip" >> "$FAILED_LIST"
                exit 3
            fi

            if [ "$idle_time" -ge "$IDLE_LIMIT" ]; then
                log "[$ip] ERROR: No progress for ${IDLE_LIMIT}s"
                echo "$ip" >> "$FAILED_LIST"
                exit 4
            fi

            if [ "$elapsed" -ge "$MAX_RUNTIME" ]; then
                log "[$ip] ERROR: Timeout reached"
                echo "$ip" >> "$FAILED_LIST"
                exit 5
            fi
        done
    } 2>&1 | tee "$hostlog" | sed "s/^/[$ip] /"
}

wait_for_slot() {
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do
        sleep 1
    done
}

while IFS= read -r ip || [ -n "$ip" ]; do
    ip="$(printf '%s' "$ip" | tr -d '\r' | xargs)"
    [ -z "$ip" ] && continue
    case "$ip" in \#*) continue ;; esac

    wait_for_slot
    run_one "$ip" &
done < "$IP_LIST"

wait

TOTAL=$(grep -v '^[[:space:]]*$' "$IP_LIST" | grep -vc '^[[:space:]]*#')
SUCCESS=$(wc -l < "$SUCCESS_LIST")
FAILED=$(wc -l < "$FAILED_LIST")

log "===== SUMMARY ====="
log "Total:   $TOTAL"
log "Success: $SUCCESS"
log "Failed:  $FAILED"
log "Success list: $SUCCESS_LIST"
log "Failed list:  $FAILED_LIST"
log "Logs: $PER_HOST_LOG_DIR"
