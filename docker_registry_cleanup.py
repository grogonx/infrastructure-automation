#!/usr/bin/env python3
"""
docker_registry_cleanup.py
Description: Cleans up old Docker Hub image tags for a given repository.
             Keeps the N most recent tags and deletes the rest, with
             support for tag pattern protection (e.g. never delete 'latest'
             or 'stable'). Outputs a summary and supports dry-run mode.
Author:      Joshua Harvey

Requirements:
    pip install requests

Usage:
    # Dry run — show what would be deleted
    python3 docker_registry_cleanup.py --repo myorg/myapp --keep 10 --dry-run

    # Delete old tags, keeping the 10 most recent
    python3 docker_registry_cleanup.py --repo myorg/myapp --keep 10

Environment variables:
    DOCKERHUB_USERNAME  - Docker Hub username
    DOCKERHUB_PASSWORD  - Docker Hub password or access token
"""

import argparse
import os
import sys
from datetime import datetime

import requests

# --- Configuration ---
DOCKERHUB_API  = "https://hub.docker.com/v2"
PROTECTED_TAGS = {"latest", "stable", "production", "main"}  # Never delete these


class DockerHubClient:
    def __init__(self, username: str, password: str):
        self.username = username
        self.session  = requests.Session()
        self.session.headers.update({"Content-Type": "application/json"})
        self._authenticate(username, password)

    def _authenticate(self, username: str, password: str):
        """Get a JWT token from Docker Hub."""
        response = self.session.post(
            f"{DOCKERHUB_API}/users/login",
            json={"username": username, "password": password},
            timeout=15
        )
        if response.status_code != 200:
            print(f"[ERROR] Authentication failed: {response.status_code} {response.text}")
            sys.exit(1)
        token = response.json().get("token")
        self.session.headers.update({"Authorization": f"JWT {token}"})
        print(f"[OK] Authenticated as: {username}")

    def get_tags(self, repo: str) -> list:
        """Fetch all tags for a repository, sorted by last_updated descending."""
        tags   = []
        url    = f"{DOCKERHUB_API}/repositories/{repo}/tags?page_size=100&ordering=last_updated"
        while url:
            response = self.session.get(url, timeout=15)
            if response.status_code != 200:
                print(f"[ERROR] Failed to fetch tags: {response.status_code}")
                break
            data = response.json()
            tags.extend(data.get("results", []))
            url = data.get("next")
        return tags

    def delete_tag(self, repo: str, tag: str) -> bool:
        """Delete a specific tag from a repository."""
        response = self.session.delete(
            f"{DOCKERHUB_API}/repositories/{repo}/tags/{tag}/",
            timeout=15
        )
        return response.status_code == 204


def format_size(bytes_val: int) -> str:
    """Format bytes into a human-readable string."""
    if bytes_val is None:
        return "unknown"
    for unit in ["B", "KB", "MB", "GB"]:
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f} TB"


def run_cleanup(repo: str, keep: int, dry_run: bool, protected_patterns: set):
    username = os.environ.get("DOCKERHUB_USERNAME", "")
    password = os.environ.get("DOCKERHUB_PASSWORD", "")

    if not username or not password:
        print("[ERROR] Set DOCKERHUB_USERNAME and DOCKERHUB_PASSWORD environment variables.")
        sys.exit(1)

    print("============================================")
    print(" Docker Registry Cleanup")
    print(f" Repository : {repo}")
    print(f" Keep       : {keep} most recent tags")
    print(f" Dry run    : {dry_run}")
    print(f" {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("============================================\n")

    client = DockerHubClient(username, password)
    tags   = client.get_tags(repo)

    if not tags:
        print("[INFO] No tags found.")
        return

    print(f"  Found {len(tags)} tag(s) total\n")

    # Sort by last_updated descending
    tags.sort(key=lambda t: t.get("last_updated", ""), reverse=True)

    kept    = []
    to_delete = []

    for tag in tags:
        name    = tag["name"]
        updated = tag.get("last_updated", "unknown")[:10]
        size    = format_size(tag.get("full_size"))

        is_protected = name in protected_patterns or any(
            name.startswith(p) for p in ["release-", "v1.", "v2."]
        )

        if is_protected or len(kept) < keep:
            kept.append((name, updated, size))
        else:
            to_delete.append((name, updated, size, tag))

    # Display kept tags
    print(f"  {'─'*50}")
    print(f"  Tags to KEEP ({len(kept)}):")
    print(f"  {'─'*50}")
    for name, updated, size in kept:
        protected = " [protected]" if name in protected_patterns else ""
        print(f"    {name:<35} {updated}  {size}{protected}")

    # Display tags to delete
    print(f"\n  {'─'*50}")
    print(f"  Tags to DELETE ({len(to_delete)}):")
    print(f"  {'─'*50}")

    if not to_delete:
        print("    None — nothing to clean up")
        return

    deleted = 0
    failed  = 0

    for name, updated, size, tag_obj in to_delete:
        if dry_run:
            print(f"    [DRY RUN] Would delete: {name:<30} {updated}  {size}")
        else:
            success = client.delete_tag(repo, name)
            if success:
                print(f"    [DELETED] {name:<35} {updated}  {size}")
                deleted += 1
            else:
                print(f"    [FAILED]  {name:<35} — could not delete")
                failed += 1

    print(f"\n  {'═'*50}")
    if dry_run:
        print(f"  Dry run complete. {len(to_delete)} tag(s) would be deleted.")
    else:
        print(f"  Deleted : {deleted}")
        print(f"  Failed  : {failed}")
        print(f"  Kept    : {len(kept)}")
    print(f"  {'═'*50}")


def main():
    parser = argparse.ArgumentParser(description="Clean up old Docker Hub image tags.")
    parser.add_argument("--repo",    required=True, help="Repository name (e.g. myorg/myapp)")
    parser.add_argument("--keep",    type=int, default=10, help="Number of recent tags to keep (default: 10)")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be deleted without deleting")
    parser.add_argument("--protect", nargs="*", default=[], help="Additional tag names to protect from deletion")
    args = parser.parse_args()

    protected = PROTECTED_TAGS | set(args.protect)
    run_cleanup(args.repo, args.keep, args.dry_run, protected)


if __name__ == "__main__":
    main()
