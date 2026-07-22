#!/usr/bin/env python3
"""
Build the Omnigent MicroVM image via the ``lambda-microvms`` control plane.

Why this exists (and why the README's one-liner is not enough): the image MUST
be created with lifecycle ``hooks`` ENABLED. Without them, the image builds and
reports ``CREATED`` fine, but the first ``RunMicrovm`` fails with::

    ValidationException: The run hook must be enabled in the MicroVM image to
    pass the run hook payload

The provider delivers per-launch identity (host id, token, server URL) through
the ``/run`` hook payload, so run/resume/suspend/terminate hooks all have to be
ENABLED at image-create time. These are ENABLED/DISABLED enum toggles, not path
strings — the platform serves the hooks on the fixed port below.

Requires boto3 >= 1.43 (the ``lambda-microvms`` service is newer than awscli
v2.34.x). Assumes the operator role created by ``setup.sh``.

Usage:
    ACCOUNT_ID=111122223333 REGION=us-east-1 \
    ARTIFACT_BUCKET=omnigent-microvm-artifacts-111122223333 \
      python build_image.py
"""

from __future__ import annotations

import os
import sys
import time

import boto3

ACCOUNT_ID = os.environ["ACCOUNT_ID"]
REGION = os.environ.get("REGION", "us-east-1")
ARTIFACT_BUCKET = os.environ.get(
    "ARTIFACT_BUCKET", f"omnigent-microvm-artifacts-{ACCOUNT_ID}"
)
IMAGE_NAME = os.environ.get("IMAGE_NAME", "omnigent-host")
HOOKS_PORT = 9000  # the image's hooks_server.py listens here


def _operator_client():
    creds = boto3.client("sts", region_name=REGION).assume_role(
        RoleArn=f"arn:aws:iam::{ACCOUNT_ID}:role/omnigent-microvm-operator",
        RoleSessionName="omnigent-microvm-build",
    )["Credentials"]
    return boto3.client(
        "lambda-microvms",
        region_name=REGION,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def main() -> int:
    lm = _operator_client()
    image_arn = f"arn:aws:lambda:{REGION}:{ACCOUNT_ID}:microvm-image:{IMAGE_NAME}"

    print(f"==> create_microvm_image {IMAGE_NAME} (hooks ENABLED)")
    try:
        lm.create_microvm_image(
            name=IMAGE_NAME,
            baseImageArn=f"arn:aws:lambda:{REGION}:aws:microvm-image:al2023-1",
            buildRoleArn=f"arn:aws:iam::{ACCOUNT_ID}:role/omnigent-microvm-build",
            codeArtifact={"uri": f"s3://{ARTIFACT_BUCKET}/omnigent-host-microvm.zip"},
            # THE FIX: enable the lifecycle hooks the provider relies on. Omitting
            # this is what makes RunMicrovm fail with the run-hook ValidationException.
            hooks={
                "port": HOOKS_PORT,
                "microvmImageHooks": {"ready": "ENABLED"},
                "microvmHooks": {
                    "run": "ENABLED",
                    "resume": "ENABLED",
                    "suspend": "ENABLED",
                    "terminate": "ENABLED",
                },
            },
        )
    except lm.exceptions.ConflictException:
        # Re-run against an image that already exists: skip creation and just
        # poll/report the current state. To rebuild from scratch, delete the
        # image (or its last version) first — note delete→recreate hits a
        # ~40s ConflictException window while the old image drains.
        print(f"    image {IMAGE_NAME} already exists — polling current state "
              "(delete it first to rebuild)")

    print("==> polling for build completion (up to ~30 min; typically 5-15)")
    for _ in range(120):
        img = lm.get_microvm_image(imageIdentifier=image_arn)
        state = img.get("state")
        if state == "CREATED":
            print(f"    CREATED, version {img.get('latestActiveImageVersion')}")
            print(f"    image_identifier: {image_arn}")
            return 0
        if state in {"FAILED", "DELETE_FAILED"}:
            print(f"    build FAILED: {img}", file=sys.stderr)
            return 1
        print(f"    state={state} ...")
        time.sleep(15)

    print("    timed out waiting for build", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
