#!/usr/bin/env bash
#
# Provision the AWS-side prerequisites for the lambda_microvm sandbox provider
# and build the MicroVM image. Idempotent-ish: safe to re-run, but role/bucket
# creation will error if they already exist (ignored).
#
# Prereqs: awscli v2, and boto3 >= 1.43 for the image-build steps (the
# `lambda-microvms` API is NOT in awscli v2.34.x yet — see README "CLI note").
#
# Usage:
#   ACCOUNT_ID=111122223333 REGION=us-east-1 \
#   ARTIFACT_BUCKET=omnigent-microvm-artifacts-111122223333 \
#     ./setup.sh
#
set -euo pipefail

: "${ACCOUNT_ID:?set ACCOUNT_ID}"
: "${REGION:=us-east-1}"
: "${ARTIFACT_BUCKET:=omnigent-microvm-artifacts-${ACCOUNT_ID}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IAM="${HERE}/iam"

render() { sed -e "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" -e "s/<REGION>/${REGION}/g" \
                -e "s/<ARTIFACT_BUCKET>/${ARTIFACT_BUCKET}/g" "$1"; }

echo "==> S3 artifact bucket: ${ARTIFACT_BUCKET}"
aws s3api create-bucket --bucket "${ARTIFACT_BUCKET}" --region "${REGION}" \
  $( [ "${REGION}" = us-east-1 ] || echo --create-bucket-configuration LocationConstraint="${REGION}" ) \
  2>/dev/null || echo "   (exists)"
aws s3api put-public-access-block --bucket "${ARTIFACT_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
# Tag the bucket to match the roles, so everything this script creates shares
# one tag (project=omnigent-microvm) for easy discovery and teardown.
aws s3api put-bucket-tagging --bucket "${ARTIFACT_BUCKET}" \
  --tagging 'TagSet=[{Key=project,Value=omnigent-microvm}]' 2>/dev/null || true

create_role() {  # name  trust-file  perms-file  inline-policy-name
  local name="$1" trust="$2" perms="$3" pol="$4"
  echo "==> IAM role: ${name}"
  aws iam create-role --role-name "${name}" \
    --assume-role-policy-document "$(render "${trust}")" \
    --tags Key=project,Value=omnigent-microvm 2>/dev/null || echo "   (exists)"
  aws iam put-role-policy --role-name "${name}" \
    --policy-name "${pol}" --policy-document "$(render "${perms}")"
}

create_role omnigent-microvm-build "${IAM}/build-role-trust.json" \
  "${IAM}/build-role-permissions.json" omnigent-microvm-build
create_role omnigent-microvm-exec  "${IAM}/exec-role-trust.json" \
  "${IAM}/exec-role-permissions.json"  omnigent-microvm-exec
create_role omnigent-microvm-operator "${IAM}/operator-role-trust.json" \
  "${IAM}/operator-caller-policy.json" omnigent-lambda-microvms-operator

echo "==> Package + upload build context"
( cd "${HERE}" && zip -j /tmp/omnigent-host-microvm.zip \
    Dockerfile hooks_server.py entrypoint.sh start_host.sh >/dev/null )
aws s3 cp /tmp/omnigent-host-microvm.zip "s3://${ARTIFACT_BUCKET}/omnigent-host-microvm.zip"

echo
echo "==> Build the image with build_image.py (needs boto3 >= 1.43):"
echo "    ACCOUNT_ID=${ACCOUNT_ID} REGION=${REGION} ARTIFACT_BUCKET=${ARTIFACT_BUCKET} \\"
echo "      python ${HERE}/build_image.py"
echo
echo "Done. Roles + bucket ready; build context uploaded."
