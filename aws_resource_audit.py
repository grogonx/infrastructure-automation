#!/usr/bin/env python3
"""
aws_resource_audit.py
Description: Audits AWS resources across EC2, S3, and IAM.
             Flags untagged resources, public S3 buckets, unused IAM users,
             and stopped EC2 instances. Outputs a summary report.
Author:      Joshua Harvey

Requirements:
    pip install boto3
    AWS credentials configured via ~/.aws/credentials or environment variables.
"""

import boto3
import json
from datetime import datetime, timezone
from botocore.exceptions import ClientError, NoCredentialsError

# --- Configuration ---
REGION = "ca-central-1"
REQUIRED_TAGS = ["Environment", "Owner", "Project"]
INACTIVE_USER_DAYS = 90  # Flag IAM users inactive for this many days

# Initialise clients
try:
    ec2 = boto3.client("ec2", region_name=REGION)
    s3 = boto3.client("s3", region_name=REGION)
    iam = boto3.client("iam")
except NoCredentialsError:
    print("[ERROR] AWS credentials not found. Configure via ~/.aws/credentials or environment variables.")
    exit(1)


def print_section(title):
    print(f"\n{'=' * 55}")
    print(f"  {title}")
    print(f"{'=' * 55}")


# ---------------------------------------------------------------
# EC2 Audit
# ---------------------------------------------------------------
def audit_ec2():
    print_section("EC2 Instance Audit")
    report = {"stopped": [], "untagged": [], "running": 0}

    try:
        response = ec2.describe_instances()
    except ClientError as e:
        print(f"[ERROR] Could not retrieve EC2 instances: {e}")
        return report

    for reservation in response["Reservations"]:
        for instance in reservation["Instances"]:
            instance_id = instance["InstanceId"]
            state = instance["State"]["Name"]
            instance_type = instance["InstanceType"]
            tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
            name = tags.get("Name", "Unnamed")

            missing_tags = [t for t in REQUIRED_TAGS if t not in tags]

            if state == "running":
                report["running"] += 1

            if state == "stopped":
                print(f"  [STOPPED]  {instance_id} ({name}) — {instance_type}")
                report["stopped"].append(instance_id)

            if missing_tags:
                print(f"  [UNTAGGED] {instance_id} ({name}) — Missing: {', '.join(missing_tags)}")
                report["untagged"].append(instance_id)

    print(f"\n  Running instances : {report['running']}")
    print(f"  Stopped instances : {len(report['stopped'])}")
    print(f"  Untagged instances: {len(report['untagged'])}")
    return report


# ---------------------------------------------------------------
# S3 Audit
# ---------------------------------------------------------------
def audit_s3():
    print_section("S3 Bucket Audit")
    report = {"public": [], "unencrypted": []}

    try:
        buckets = s3.list_buckets().get("Buckets", [])
    except ClientError as e:
        print(f"[ERROR] Could not list S3 buckets: {e}")
        return report

    for bucket in buckets:
        name = bucket["Name"]

        # Check public access block settings
        try:
            public_access = s3.get_public_access_block(Bucket=name)
            config = public_access["PublicAccessBlockConfiguration"]
            is_public = not all([
                config.get("BlockPublicAcls", False),
                config.get("BlockPublicPolicy", False),
                config.get("IgnorePublicAcls", False),
                config.get("RestrictPublicBuckets", False),
            ])
            if is_public:
                print(f"  [PUBLIC]      {name} — public access not fully blocked")
                report["public"].append(name)
            else:
                print(f"  [OK]          {name} — public access blocked")
        except ClientError:
            print(f"  [WARNING]     {name} — could not retrieve public access settings")

        # Check encryption
        try:
            s3.get_bucket_encryption(Bucket=name)
        except ClientError as e:
            if e.response["Error"]["Code"] == "ServerSideEncryptionConfigurationNotFoundError":
                print(f"  [UNENCRYPTED] {name} — no server-side encryption configured")
                report["unencrypted"].append(name)

    print(f"\n  Total buckets    : {len(buckets)}")
    print(f"  Public buckets   : {len(report['public'])}")
    print(f"  Unencrypted      : {len(report['unencrypted'])}")
    return report


# ---------------------------------------------------------------
# IAM Audit
# ---------------------------------------------------------------
def audit_iam():
    print_section("IAM User Audit")
    report = {"inactive": [], "no_mfa": []}
    now = datetime.now(timezone.utc)

    try:
        users = iam.list_users().get("Users", [])
    except ClientError as e:
        print(f"[ERROR] Could not list IAM users: {e}")
        return report

    for user in users:
        username = user["UserName"]
        last_used = user.get("PasswordLastUsed")

        # Check for inactivity
        if last_used:
            days_inactive = (now - last_used).days
            if days_inactive >= INACTIVE_USER_DAYS:
                print(f"  [INACTIVE] {username} — last login {days_inactive} days ago")
                report["inactive"].append(username)
        else:
            print(f"  [INACTIVE] {username} — has never logged in")
            report["inactive"].append(username)

        # Check for MFA
        try:
            mfa_devices = iam.list_mfa_devices(UserName=username).get("MFADevices", [])
            if not mfa_devices:
                print(f"  [NO MFA]   {username} — MFA not enabled")
                report["no_mfa"].append(username)
        except ClientError:
            pass

    print(f"\n  Total users     : {len(users)}")
    print(f"  Inactive users  : {len(report['inactive'])}")
    print(f"  No MFA users    : {len(report['no_mfa'])}")
    return report


# ---------------------------------------------------------------
# Main — Generate Full Report
# ---------------------------------------------------------------
def main():
    print(f"\n  AWS Resource Audit — Region: {REGION}")
    print(f"  Run at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    ec2_report = audit_ec2()
    s3_report = audit_s3()
    iam_report = audit_iam()

    print_section("Summary")
    total_issues = (
        len(ec2_report["stopped"]) +
        len(ec2_report["untagged"]) +
        len(s3_report["public"]) +
        len(s3_report["unencrypted"]) +
        len(iam_report["inactive"]) +
        len(iam_report["no_mfa"])
    )
    print(f"  Total issues found: {total_issues}")

    # Save JSON report
    report = {
        "timestamp": datetime.now().isoformat(),
        "region": REGION,
        "ec2": ec2_report,
        "s3": s3_report,
        "iam": iam_report
    }
    output_file = f"aws_audit_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(output_file, "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"\n  Full report saved to: {output_file}")


if __name__ == "__main__":
    main()
