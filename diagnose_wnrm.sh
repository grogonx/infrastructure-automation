#!/bin/bash

IP_FILE="ssh_ips.txt"
CREDS_FILE="login.conf"
LOG_FILE="diagnose_winrm_ssh_$(date +%Y%m%d_%H%M%S).log"

source "$CREDS_FILE"

run_ssh() {
    local IP="$1"
    local CMD="$2"

    /bin/expect <<EOF
set timeout 30
log_user 0
spawn ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 $SSH_USER@$IP "$CMD"
expect {
    "*yes/no*" {
        send "yes\r"
        exp_continue
    }
    "*assword:*" {
        send "$SSH_PASS\r"
        exp_continue
    }
    "Permission denied*" {
        puts "SSH_AUTH_FAILED"
        exit 10
    }
    timeout {
        puts "SSH_TIMEOUT"
        exit 11
    }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
}

echo "Diagnostic started: $(date)" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

while read -r IP; do
    [[ -z "$IP" ]] && continue

    echo "===== $IP =====" | tee -a "$LOG_FILE"

    nc -z -w 3 "$IP" 22
    if [[ $? -ne 0 ]]; then
        echo "SSH_PORT_22: FAIL - closed/filtered/unreachable" | tee -a "$LOG_FILE"
        echo "FINAL_RESULT: NO_SSH_ACCESS" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    echo "SSH_PORT_22: PASS" | tee -a "$LOG_FILE"

    BASIC_TEST=$(run_ssh "$IP" "echo SSH_CONNECTED")
    echo "SSH_BASIC_TEST: $BASIC_TEST" | tee -a "$LOG_FILE"

    if echo "$BASIC_TEST" | grep -q "SSH_AUTH_FAILED"; then
        echo "FINAL_RESULT: SSH_AUTH_FAILED" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    if ! echo "$BASIC_TEST" | grep -q "SSH_CONNECTED"; then
        echo "FINAL_RESULT: SSH_CONNECTED_BUT_COMMAND_FAILED" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    OS_TEST=$(run_ssh "$IP" "powershell.exe -NoProfile -Command \"try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { 'NOT_WINDOWS_OR_POWERSHELL_FAILED' }\"")
    echo "OS_TEST: $OS_TEST" | tee -a "$LOG_FILE"

    if echo "$OS_TEST" | grep -q "NOT_WINDOWS_OR_POWERSHELL_FAILED"; then
        echo "FINAL_RESULT: NOT_WINDOWS_OR_POWERSHELL_FAILED" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    if ! echo "$OS_TEST" | grep -qi "Windows"; then
        echo "FINAL_RESULT: NOT_CONFIRMED_WINDOWS" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    ADMIN_TEST=$(run_ssh "$IP" "powershell.exe -NoProfile -Command \"net session >\$null 2>&1; if (\$LASTEXITCODE -eq 0) { 'LOCAL_ADMIN: PASS' } else { 'LOCAL_ADMIN: FAIL' }\"")
    echo "$ADMIN_TEST" | tee -a "$LOG_FILE"

    WINRM_TEST=$(run_ssh "$IP" "powershell.exe -NoProfile -Command \"Get-Service WinRM | Select-Object -ExpandProperty Status\"")
    echo "WINRM_SERVICE_STATUS: $WINRM_TEST" | tee -a "$LOG_FILE"

    LISTEN_TEST=$(run_ssh "$IP" "powershell.exe -NoProfile -Command \"\$p=Get-NetTCPConnection -LocalPort 5985 -State Listen -ErrorAction SilentlyContinue; if (\$p) { 'LOCAL_5985_LISTEN: PASS' } else { 'LOCAL_5985_LISTEN: FAIL' }\"")
    echo "$LISTEN_TEST" | tee -a "$LOG_FILE"

    FW_TEST=$(run_ssh "$IP" "powershell.exe -NoProfile -Command \"\$fw=Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue | Where-Object { \$_.Enabled -eq 'True' -and \$_.Action -eq 'Allow' }; if (\$fw) { 'WINRM_FIREWALL_RULE: PASS' } else { 'WINRM_FIREWALL_RULE: FAIL' }\"")
    echo "$FW_TEST" | tee -a "$LOG_FILE"

    nc -z -w 3 "$IP" 5985
    if [[ $? -eq 0 ]]; then
        echo "REMOTE_5985_FROM_LINUX: PASS" | tee -a "$LOG_FILE"
    else
        echo "REMOTE_5985_FROM_LINUX: FAIL" | tee -a "$LOG_FILE"
    fi

    echo "FINAL_RESULT: DIAGNOSTIC_COMPLETE" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

done < "$IP_FILE"

echo "Done. Review: $LOG_FILE"
