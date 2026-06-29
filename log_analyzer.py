#!/usr/bin/env python3
"""
log_analyzer.py
Description: Parses system or application log files to identify errors,
             warnings, and patterns. Outputs a summary and can optionally
             send an alert if error thresholds are exceeded.
Author:      Joshua Harvey

Usage:
    python3 log_analyzer.py --log /var/log/syslog
    python3 log_analyzer.py --log /var/log/app.log --alert-threshold 10
"""

import re
import argparse
from datetime import datetime
from collections import Counter, defaultdict
from pathlib import Path

# --- Patterns to match ---
PATTERNS = {
    "ERROR":   re.compile(r"\b(error|ERROR|Error|CRITICAL|critical|FATAL|fatal)\b"),
    "WARNING": re.compile(r"\b(warn|WARN|warning|WARNING)\b"),
    "AUTH":    re.compile(r"\b(authentication failure|Failed password|Invalid user|FAILED LOGIN)\b"),
    "OOM":     re.compile(r"\b(Out of memory|oom_kill|OOM)\b"),
    "TIMEOUT": re.compile(r"\b(timeout|timed out|connection refused|TIMEOUT)\b"),
}

# Regex to extract timestamp (common syslog format + ISO 8601)
TIMESTAMP_PATTERNS = [
    re.compile(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})"),  # ISO 8601
    re.compile(r"([A-Z][a-z]{2}\s+\d{1,2}\s\d{2}:\d{2}:\d{2})"),  # syslog: Jan  1 12:00:00
]


def extract_timestamp(line):
    for pattern in TIMESTAMP_PATTERNS:
        match = pattern.search(line)
        if match:
            return match.group(1)
    return None


def analyze_log(filepath, alert_threshold):
    path = Path(filepath)
    if not path.exists():
        print(f"[ERROR] File not found: {filepath}")
        return

    print(f"\n{'=' * 60}")
    print(f"  Log Analyzer")
    print(f"  File     : {filepath}")
    print(f"  Run time : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'=' * 60}")

    matches = defaultdict(list)
    line_count = 0
    hourly_errors = Counter()

    with open(path, "r", errors="replace") as f:
        for line in f:
            line_count += 1
            for label, pattern in PATTERNS.items():
                if pattern.search(line):
                    matches[label].append(line.strip())
                    if label == "ERROR":
                        ts = extract_timestamp(line)
                        if ts:
                            # Bucket by hour
                            hour = ts[:13]
                            hourly_errors[hour] += 1

    # --- Summary ---
    print(f"\n  Total lines parsed: {line_count:,}")
    print()
    for label, lines in matches.items():
        symbol = "[!]" if label == "ERROR" else "[~]"
        print(f"  {symbol} {label:<10}: {len(lines):>6} occurrences")

    # --- Top 5 most common error lines ---
    if matches["ERROR"]:
        print(f"\n{'─' * 60}")
        print("  Top 5 Most Common Errors:")
        print(f"{'─' * 60}")
        error_counter = Counter(matches["ERROR"])
        for msg, count in error_counter.most_common(5):
            truncated = (msg[:80] + "...") if len(msg) > 80 else msg
            print(f"  [{count:>4}x] {truncated}")

    # --- Auth failures ---
    if matches["AUTH"]:
        print(f"\n{'─' * 60}")
        print(f"  Authentication Failures: {len(matches['AUTH'])}")
        # Extract unique IPs or usernames
        ip_pattern = re.compile(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b")
        ips = Counter()
        for line in matches["AUTH"]:
            for ip in ip_pattern.findall(line):
                ips[ip] += 1
        if ips:
            print("  Top offending IPs:")
            for ip, count in ips.most_common(5):
                print(f"    {ip} — {count} attempts")

    # --- Hourly error trend ---
    if hourly_errors:
        print(f"\n{'─' * 60}")
        print("  Hourly Error Trend (top 5 hours):")
        print(f"{'─' * 60}")
        for hour, count in hourly_errors.most_common(5):
            bar = "█" * min(count, 40)
            print(f"  {hour}  {bar} {count}")

    # --- Alert threshold ---
    total_errors = len(matches["ERROR"])
    if total_errors >= alert_threshold:
        print(f"\n  ⚠  ALERT: {total_errors} errors found — threshold is {alert_threshold}")
        print("     Consider investigating or escalating.")
    else:
        print(f"\n  ✓  Error count ({total_errors}) is below alert threshold ({alert_threshold}).")

    # --- Save flagged lines ---
    output_file = f"log_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
    with open(output_file, "w") as out:
        out.write(f"Log Analysis Report — {filepath}\n")
        out.write(f"Generated: {datetime.now().isoformat()}\n\n")
        for label, lines in matches.items():
            out.write(f"\n--- {label} ({len(lines)} occurrences) ---\n")
            for line in lines:
                out.write(f"{line}\n")
    print(f"\n  Detailed report saved to: {output_file}")


def main():
    parser = argparse.ArgumentParser(description="Analyze log files for errors and patterns.")
    parser.add_argument("--log", required=True, help="Path to the log file to analyze")
    parser.add_argument("--alert-threshold", type=int, default=50,
                        help="Number of errors before triggering an alert (default: 50)")
    args = parser.parse_args()
    analyze_log(args.log, args.alert_threshold)


if __name__ == "__main__":
    main()
