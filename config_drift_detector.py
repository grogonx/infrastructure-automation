#!/usr/bin/env python3
"""
config_drift_detector.py
Description: Detects configuration drift by comparing the current state of
             key system files, installed packages, and running services
             against a saved baseline snapshot. Useful for catching
             unauthorized changes or environment inconsistencies.
Author:      Joshua Harvey

Usage:
    # Create a baseline snapshot
    python3 config_drift_detector.py --create-baseline

    # Check current state against baseline
    python3 config_drift_detector.py --check

    # Check and output a JSON report
    python3 config_drift_detector.py --check --report drift_report.json
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# --- Configuration ---
BASELINE_FILE = "/etc/drift_baseline.json"

# Files to hash and monitor for changes
MONITORED_FILES = [
    "/etc/passwd",
    "/etc/group",
    "/etc/shadow",
    "/etc/sudoers",
    "/etc/ssh/sshd_config",
    "/etc/hosts",
    "/etc/resolv.conf",
    "/etc/fstab",
    "/etc/sysctl.conf",
    "/etc/crontab",
]

# Services to track running state
MONITORED_SERVICES = [
    "sshd",
    "firewalld",
    "fail2ban",
    "chronyd",
    "auditd",
]

GREEN  = "\033[0;32m"
RED    = "\033[0;31m"
YELLOW = "\033[1;33m"
NC     = "\033[0m"


def hash_file(filepath: str) -> str:
    """Return SHA-256 hash of a file, or an error string if unreadable."""
    try:
        h = hashlib.sha256()
        with open(filepath, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        return h.hexdigest()
    except PermissionError:
        return "PERMISSION_DENIED"
    except FileNotFoundError:
        return "FILE_NOT_FOUND"


def get_installed_packages() -> dict:
    """Return a dict of installed packages and versions."""
    packages = {}
    # Try rpm first (RHEL/CentOS), fall back to dpkg (Debian/Ubuntu)
    for cmd, parser in [
        (["rpm", "-qa", "--queryformat", "%{NAME} %{VERSION}-%{RELEASE}\n"],
         lambda line: line.split(" ", 1)),
        (["dpkg-query", "-W", "-f=${Package} ${Version}\n"],
         lambda line: line.split(" ", 1)),
    ]:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                for line in result.stdout.strip().splitlines():
                    parts = parser(line)
                    if len(parts) == 2:
                        packages[parts[0].strip()] = parts[1].strip()
                break
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return packages


def get_service_states() -> dict:
    """Return running state for each monitored service."""
    states = {}
    for service in MONITORED_SERVICES:
        try:
            result = subprocess.run(
                ["systemctl", "is-active", service],
                capture_output=True, text=True, timeout=5
            )
            states[service] = result.stdout.strip()
        except (FileNotFoundError, subprocess.TimeoutExpired):
            states[service] = "unknown"
    return states


def capture_state() -> dict:
    """Capture the full current system state."""
    print("  Hashing monitored files...")
    file_hashes = {f: hash_file(f) for f in MONITORED_FILES}

    print("  Collecting installed packages...")
    packages = get_installed_packages()

    print("  Checking service states...")
    services = get_service_states()

    return {
        "captured_at": datetime.now().isoformat(),
        "hostname":    os.uname().nodename,
        "files":       file_hashes,
        "packages":    packages,
        "services":    services,
    }


def create_baseline(baseline_path: str):
    """Capture and save a new baseline."""
    print(f"\n  Creating baseline snapshot...")
    state = capture_state()

    with open(baseline_path, "w") as f:
        json.dump(state, f, indent=2)

    print(f"\n{GREEN}[OK]{NC} Baseline saved to: {baseline_path}")
    print(f"     Captured at : {state['captured_at']}")
    print(f"     Files       : {len(state['files'])}")
    print(f"     Packages    : {len(state['packages'])}")
    print(f"     Services    : {len(state['services'])}")


def check_drift(baseline_path: str, report_path: str = ""):
    """Compare current state to baseline and report drift."""
    if not Path(baseline_path).exists():
        print(f"{RED}[ERROR]{NC} Baseline not found: {baseline_path}")
        print("  Run with --create-baseline first.")
        sys.exit(1)

    with open(baseline_path) as f:
        baseline = json.load(f)

    print(f"\n  Baseline from : {baseline['captured_at']}")
    print(f"  Baseline host : {baseline['hostname']}")
    print(f"  Checking now  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")

    current = capture_state()
    drift = {"files": [], "packages_added": [], "packages_removed": [],
             "packages_changed": [], "services": []}
    total_issues = 0

    # --- File drift ---
    print(f"{'─'*55}")
    print("  File Integrity")
    print(f"{'─'*55}")
    for filepath, baseline_hash in baseline["files"].items():
        current_hash = current["files"].get(filepath, "FILE_NOT_FOUND")
        if current_hash != baseline_hash:
            status = f"{RED}[CHANGED]{NC}" if current_hash not in ("FILE_NOT_FOUND", "PERMISSION_DENIED") else f"{YELLOW}[MISSING]{NC}"
            print(f"  {status} {filepath}")
            drift["files"].append({"path": filepath, "baseline": baseline_hash, "current": current_hash})
            total_issues += 1
        else:
            print(f"  {GREEN}[OK]{NC}      {filepath}")

    # --- Package drift ---
    print(f"\n{'─'*55}")
    print("  Package Changes")
    print(f"{'─'*55}")
    baseline_pkgs = baseline.get("packages", {})
    current_pkgs  = current["packages"]

    added   = set(current_pkgs) - set(baseline_pkgs)
    removed = set(baseline_pkgs) - set(current_pkgs)
    changed = {p for p in current_pkgs if p in baseline_pkgs and current_pkgs[p] != baseline_pkgs[p]}

    if not added and not removed and not changed:
        print(f"  {GREEN}[OK]{NC} No package changes detected")
    for pkg in sorted(added):
        print(f"  {YELLOW}[ADDED]{NC}   {pkg} {current_pkgs[pkg]}")
        drift["packages_added"].append(pkg)
        total_issues += 1
    for pkg in sorted(removed):
        print(f"  {RED}[REMOVED]{NC} {pkg} {baseline_pkgs[pkg]}")
        drift["packages_removed"].append(pkg)
        total_issues += 1
    for pkg in sorted(changed):
        print(f"  {YELLOW}[UPDATED]{NC} {pkg}: {baseline_pkgs[pkg]} → {current_pkgs[pkg]}")
        drift["packages_changed"].append({"package": pkg, "from": baseline_pkgs[pkg], "to": current_pkgs[pkg]})

    # --- Service drift ---
    print(f"\n{'─'*55}")
    print("  Service States")
    print(f"{'─'*55}")
    for svc, baseline_state in baseline.get("services", {}).items():
        current_state = current["services"].get(svc, "unknown")
        if current_state != baseline_state:
            print(f"  {RED}[CHANGED]{NC} {svc}: was '{baseline_state}', now '{current_state}'")
            drift["services"].append({"service": svc, "baseline": baseline_state, "current": current_state})
            total_issues += 1
        else:
            print(f"  {GREEN}[OK]{NC}      {svc}: {current_state}")

    # --- Summary ---
    print(f"\n{'═'*55}")
    if total_issues == 0:
        print(f"  {GREEN}No drift detected. System matches baseline.{NC}")
    else:
        print(f"  {RED}{total_issues} drift issue(s) detected.{NC}")
    print(f"{'═'*55}")

    if report_path:
        report = {"checked_at": current["captured_at"], "baseline_at": baseline["captured_at"],
                  "total_issues": total_issues, "drift": drift}
        with open(report_path, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\n  Report saved to: {report_path}")

    return total_issues


def main():
    parser = argparse.ArgumentParser(description="Detect configuration drift against a baseline.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--create-baseline", action="store_true", help="Capture and save a new baseline")
    group.add_argument("--check",           action="store_true", help="Check for drift against baseline")
    parser.add_argument("--baseline", default=BASELINE_FILE, help=f"Baseline file path (default: {BASELINE_FILE})")
    parser.add_argument("--report",   default="",            help="Save drift report to JSON file")
    args = parser.parse_args()

    print("============================================")
    print(" Configuration Drift Detector")
    print(f" {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("============================================")

    if args.create_baseline:
        create_baseline(args.baseline)
    elif args.check:
        issues = check_drift(args.baseline, args.report)
        sys.exit(1 if issues > 0 else 0)


if __name__ == "__main__":
    main()
