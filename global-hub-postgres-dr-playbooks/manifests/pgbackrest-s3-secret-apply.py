#!/usr/bin/env python3
# Apply a pgBackRest S3 credentials Secret from an AWS credentials INI file.
# Does not print access keys. Used by *-pgbackrest-s3-secret.sh wrappers.
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def parse_aws_ini(path: Path) -> tuple[str, str]:
    access_key = secret_key = None
    text = path.read_text()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("[") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key == "aws_access_key_id":
            access_key = value
        elif key == "aws_secret_access_key":
            secret_key = value
    if not access_key or not secret_key:
        raise SystemExit(f"{path}: expected aws_access_key_id and aws_secret_access_key")
    return access_key, secret_key


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply pgBackRest S3 secret from AWS INI file")
    parser.add_argument("--credentials-file", type=Path, required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--secret-name", required=True)
    parser.add_argument(
        "--pg-repo",
        required=True,
        help="PGO repo name (Secret keys use <repo>-s3-key / <repo>-s3-key-secret)",
    )
    parser.add_argument(
        "--kubectl",
        default="kubectl",
        help="kubectl or oc",
    )
    args = parser.parse_args()

    if not args.credentials_file.is_file():
        raise SystemExit(f"credentials file not found: {args.credentials_file}")

    access_key, secret_key = parse_aws_ini(args.credentials_file)
    s3_conf = (
        "[global]\n"
        f"{args.pg_repo}-s3-key={access_key}\n"
        f"{args.pg_repo}-s3-key-secret={secret_key}\n"
    )
    yaml = subprocess.run(
        [
            args.kubectl,
            "create",
            "secret",
            "generic",
            args.secret_name,
            "-n",
            args.namespace,
            f"--from-literal=s3.conf={s3_conf}",
            "--dry-run=client",
            "-o",
            "yaml",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    subprocess.run(
        [args.kubectl, "apply", "-f", "-"],
        input=yaml,
        text=True,
        check=True,
    )


if __name__ == "__main__":
    main()
