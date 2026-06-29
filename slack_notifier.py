#!/usr/bin/env python3
"""
slack_notifier.py
Description: Reusable Slack notification module and CLI tool.
             Sends formatted alerts to a Slack channel via Incoming Webhook.
             Supports plain messages, alerts, success/failure notifications,
             and rich block-formatted messages with context fields.
Author:      Joshua Harvey

Requirements:
    pip install requests

Usage (CLI):
    python3 slack_notifier.py --message "Deployment complete" --level success
    python3 slack_notifier.py --message "Disk usage at 92%" --level warning
    python3 slack_notifier.py --message "Service is down" --level error

Usage (as module):
    from slack_notifier import SlackNotifier
    notifier = SlackNotifier(webhook_url="https://hooks.slack.com/...")
    notifier.send_alert("Backup failed on server01", level="error")
"""

import os
import argparse
import json
import socket
from datetime import datetime

import requests

# --- Configuration ---
# Set SLACK_WEBHOOK_URL as an environment variable or pass it directly
WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")

LEVEL_CONFIG = {
    "info":    {"emoji": ":information_source:", "color": "#36a64f"},
    "success": {"emoji": ":white_check_mark:",   "color": "#2eb886"},
    "warning": {"emoji": ":warning:",            "color": "#f0a500"},
    "error":   {"emoji": ":rotating_light:",     "color": "#e01e5a"},
}


class SlackNotifier:
    def __init__(self, webhook_url: str = ""):
        self.webhook_url = webhook_url or WEBHOOK_URL
        if not self.webhook_url:
            raise ValueError(
                "Slack webhook URL is required. Set SLACK_WEBHOOK_URL environment variable "
                "or pass it to SlackNotifier()."
            )

    def send(self, payload: dict) -> bool:
        """Send a raw payload to Slack. Returns True on success."""
        try:
            response = requests.post(
                self.webhook_url,
                data=json.dumps(payload),
                headers={"Content-Type": "application/json"},
                timeout=10
            )
            if response.status_code == 200:
                return True
            else:
                print(f"[ERROR] Slack returned {response.status_code}: {response.text}")
                return False
        except requests.exceptions.RequestException as e:
            print(f"[ERROR] Failed to send Slack notification: {e}")
            return False

    def send_message(self, message: str, channel: str = "") -> bool:
        """Send a plain text message."""
        payload = {"text": message}
        if channel:
            payload["channel"] = channel
        return self.send(payload)

    def send_alert(
        self,
        message: str,
        level: str = "info",
        title: str = "",
        fields: dict = None,
        channel: str = ""
    ) -> bool:
        """
        Send a formatted alert with colour coding and context fields.

        Args:
            message : Main alert body text
            level   : 'info', 'success', 'warning', or 'error'
            title   : Optional bold title above the message
            fields  : Optional dict of key/value pairs shown as context
            channel : Optional channel override
        """
        config = LEVEL_CONFIG.get(level, LEVEL_CONFIG["info"])
        hostname = socket.gethostname()
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        attachment = {
            "color": config["color"],
            "fallback": message,
            "text": f"{config['emoji']}  {message}",
            "footer": f"{hostname} | {timestamp}",
        }

        if title:
            attachment["title"] = title

        if fields:
            attachment["fields"] = [
                {"title": k, "value": v, "short": True}
                for k, v in fields.items()
            ]

        payload = {"attachments": [attachment]}
        if channel:
            payload["channel"] = channel

        return self.send(payload)

    def send_deployment_notification(
        self,
        service: str,
        version: str,
        environment: str,
        status: str,
        triggered_by: str = "automated pipeline"
    ) -> bool:
        """Send a standardised deployment notification."""
        level = "success" if status.lower() == "success" else "error"
        title = f"Deployment {'Succeeded' if level == 'success' else 'Failed'}: {service}"
        message = f"*{service}* `{version}` deployed to *{environment}*"

        fields = {
            "Service":     service,
            "Version":     version,
            "Environment": environment,
            "Status":      status.upper(),
            "Triggered by": triggered_by,
        }

        return self.send_alert(message, level=level, title=title, fields=fields)


# --- CLI Entry Point ---
def main():
    parser = argparse.ArgumentParser(description="Send a Slack notification.")
    parser.add_argument("--message", required=True, help="Message text to send")
    parser.add_argument(
        "--level",
        choices=["info", "success", "warning", "error"],
        default="info",
        help="Alert severity level (default: info)"
    )
    parser.add_argument("--title", default="", help="Optional alert title")
    parser.add_argument("--channel", default="", help="Optional channel override")
    parser.add_argument(
        "--webhook",
        default="",
        help="Slack webhook URL (overrides SLACK_WEBHOOK_URL env var)"
    )
    args = parser.parse_args()

    try:
        notifier = SlackNotifier(webhook_url=args.webhook)
        success = notifier.send_alert(
            message=args.message,
            level=args.level,
            title=args.title,
            channel=args.channel
        )
        if success:
            print(f"[OK] Notification sent ({args.level}): {args.message}")
        else:
            print("[ERROR] Notification failed.")
            exit(1)
    except ValueError as e:
        print(f"[ERROR] {e}")
        exit(1)


if __name__ == "__main__":
    main()
