#!/usr/bin/env python3
"""
k8s_pod_monitor.py
Description: Continuously monitors Kubernetes pods across namespaces.
             Detects crash-looping pods, pods stuck in Pending/Error states,
             and excessive restart counts. Sends Slack alerts when issues
             are detected and resolves them when pods recover.
Author:      Joshua Harvey

Requirements:
    pip install kubernetes requests

Usage:
    # Monitor all namespaces, check every 60 seconds
    python3 k8s_pod_monitor.py

    # Monitor specific namespace with custom interval
    python3 k8s_pod_monitor.py --namespace production --interval 30

    # Dry run (print alerts, don't send to Slack)
    python3 k8s_pod_monitor.py --dry-run
"""

import argparse
import time
import os
from datetime import datetime
from collections import defaultdict

from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

# Optional Slack integration — reuses slack_notifier module if available
try:
    from slack_notifier import SlackNotifier
    SLACK_AVAILABLE = True
except ImportError:
    SLACK_AVAILABLE = False

# --- Configuration ---
RESTART_THRESHOLD = 5       # Alert if pod has restarted more than this many times
CHECK_INTERVAL    = 60      # Seconds between checks
ALERT_COOLDOWN    = 300     # Seconds before re-alerting on the same pod

BAD_STATES = {"Error", "CrashLoopBackOff", "OOMKilled", "ImagePullBackOff",
              "ErrImagePull", "CreateContainerConfigError", "Pending"}


def load_k8s_config():
    """Load kubeconfig — tries in-cluster first, falls back to local."""
    try:
        config.load_incluster_config()
        print("[INFO] Loaded in-cluster Kubernetes config")
    except config.ConfigException:
        config.load_kube_config()
        print("[INFO] Loaded local kubeconfig (~/.kube/config)")


def get_pod_status_summary(pod) -> dict:
    """Extract a clean status summary from a pod object."""
    name      = pod.metadata.name
    namespace = pod.metadata.namespace
    phase     = pod.status.phase or "Unknown"

    container_statuses = pod.status.container_statuses or []
    total_restarts = 0
    waiting_reasons = []

    for cs in container_statuses:
        total_restarts += cs.restart_count or 0
        if cs.state and cs.state.waiting:
            waiting_reasons.append(cs.state.waiting.reason or "Unknown")

    return {
        "name":            name,
        "namespace":       namespace,
        "phase":           phase,
        "restarts":        total_restarts,
        "waiting_reasons": waiting_reasons,
        "ready":           all(cs.ready for cs in container_statuses) if container_statuses else False,
    }


def check_pods(v1: client.CoreV1Api, namespace: str, alert_state: dict,
               notifier, dry_run: bool) -> dict:
    """Check all pods and return updated alert state."""
    now = datetime.now()

    try:
        if namespace == "all":
            pods = v1.list_pod_for_all_namespaces(watch=False).items
        else:
            pods = v1.list_namespaced_pod(namespace, watch=False).items
    except ApiException as e:
        print(f"[ERROR] Failed to list pods: {e}")
        return alert_state

    current_issues = set()

    for pod in pods:
        summary = get_pod_status_summary(pod)
        pod_key = f"{summary['namespace']}/{summary['name']}"

        is_bad_phase    = summary["phase"] in BAD_STATES
        is_bad_state    = any(r in BAD_STATES for r in summary["waiting_reasons"])
        high_restarts   = summary["restarts"] > RESTART_THRESHOLD
        issue           = is_bad_phase or is_bad_state or high_restarts

        if not issue:
            # Pod recovered — clear from alert state
            if pod_key in alert_state:
                print(f"[RESOLVED] {pod_key} has recovered")
                del alert_state[pod_key]
            continue

        current_issues.add(pod_key)

        # Determine if we should send a new alert (new issue or cooldown expired)
        last_alert = alert_state.get(pod_key, {}).get("last_alert")
        cooldown_expired = (
            last_alert is None or
            (now - last_alert).total_seconds() > ALERT_COOLDOWN
        )

        if cooldown_expired:
            reasons = summary["waiting_reasons"] or [summary["phase"]]
            message = (
                f"Pod issue detected: *{summary['name']}* "
                f"in namespace *{summary['namespace']}*\n"
                f"Reason: `{'`, `'.join(reasons)}`  |  Restarts: `{summary['restarts']}`"
            )

            print(f"[ALERT] {pod_key} — {', '.join(reasons)} | Restarts: {summary['restarts']}")

            if not dry_run and notifier:
                notifier.send_alert(
                    message=message,
                    level="error",
                    title="Kubernetes Pod Alert",
                    fields={
                        "Namespace": summary["namespace"],
                        "Pod":       summary["name"],
                        "Phase":     summary["phase"],
                        "Restarts":  str(summary["restarts"]),
                        "Reason":    ", ".join(reasons),
                    }
                )

            alert_state[pod_key] = {"last_alert": now, "reasons": reasons}

    return alert_state


def main():
    parser = argparse.ArgumentParser(description="Monitor Kubernetes pod health.")
    parser.add_argument("--namespace", default="all",
                        help="Namespace to monitor (default: all)")
    parser.add_argument("--interval", type=int, default=CHECK_INTERVAL,
                        help=f"Check interval in seconds (default: {CHECK_INTERVAL})")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print alerts without sending to Slack")
    args = parser.parse_args()

    print("============================================")
    print(" Kubernetes Pod Monitor")
    print(f" Namespace : {args.namespace}")
    print(f" Interval  : {args.interval}s")
    print(f" Dry run   : {args.dry_run}")
    print("============================================\n")

    load_k8s_config()
    v1 = client.CoreV1Api()

    notifier = None
    if SLACK_AVAILABLE and not args.dry_run:
        webhook = os.environ.get("SLACK_WEBHOOK_URL", "")
        if webhook:
            notifier = SlackNotifier(webhook_url=webhook)
            print("[INFO] Slack notifications enabled")
        else:
            print("[WARN] SLACK_WEBHOOK_URL not set — alerts will print only")

    alert_state = {}

    while True:
        print(f"\n[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Checking pods...")
        alert_state = check_pods(v1, args.namespace, alert_state, notifier, args.dry_run)
        active = len(alert_state)
        print(f"  Active issues: {active}")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
