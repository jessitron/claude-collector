#!/usr/bin/env bash
# Creates the IAM user that lets this collector write raw traces into the
# takeout-telemetry S3 bucket, and appends its access key to .env.
#
# Idempotent-ish: re-running reuses the user and policy, but always mints a
# fresh access key (IAM allows 2 per user; delete old ones in the console if
# this fails with LimitExceeded).
#
# Usage: scripts/create-s3-supplier-user.sh [bucket] [prefix]
set -euo pipefail
cd "$(dirname "$0")/.."

# Deliberately NOT honoring $AWS_PROFILE: jessitron's shell exports one for a
# different account, and that once created this user in the wrong place.
PROFILE="${SUPPLIER_AWS_PROFILE:-really-devrel-sandbox}"
BUCKET="${1:-devrel-takeout-telemetry-dev-6a8ca705}"
PREFIX="${2:-claude-code}"
USER_NAME="takeout-telemetry-supplier"
POLICY_NAME="takeout-telemetry-supplier-put-${PREFIX}"

aws() { command aws --profile "$PROFILE" --output text "$@"; }

echo "Ensuring IAM user $USER_NAME exists..."
aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1 \
  || aws iam create-user --user-name "$USER_NAME" \
       --tags Key=purpose,Value="claude-collector writes raw traces to s3://$BUCKET/$PREFIX/" >/dev/null

echo "Attaching inline policy $POLICY_NAME (PutObject on s3://$BUCKET/$PREFIX/* only)..."
POLICY_DOC=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PutRawTelemetry",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/${PREFIX}/*"
    }
  ]
}
JSON
)
aws iam put-user-policy --user-name "$USER_NAME" --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC"

echo "Creating access key..."
read -r KEY_ID SECRET < <(aws iam create-access-key --user-name "$USER_NAME" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]')

touch .env
# Drop any previous AWS lines so re-running replaces rather than duplicates.
grep -vE '^(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_REGION|S3_BUCKET|S3_PREFIX)=' .env > .env.tmp || true
{
  cat .env.tmp
  echo "AWS_ACCESS_KEY_ID=$KEY_ID"
  echo "AWS_SECRET_ACCESS_KEY=$SECRET"
  echo "AWS_REGION=us-east-1"
  echo "S3_BUCKET=$BUCKET"
  echo "S3_PREFIX=$PREFIX"
} > .env
rm .env.tmp

echo "Done. Access key $KEY_ID written to .env (secret not shown)."
