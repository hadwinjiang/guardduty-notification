#!/usr/bin/env bash
# 在多个区域各部署一整套 GuardDuty -> 企业微信 推送栈（方案 A：每区域独立）
#
# 用法:
#   export WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx'
#   scripts/deploy_all_regions.sh "us-east-1 ap-southeast-1 eu-central-1"            # 海外分区
#   AWS_PROFILE=geely-cn scripts/deploy_all_regions.sh "cn-north-1 cn-northwest-1"  # 中国分区
#
# 可选环境变量: STACK_NAME MIN_SEVERITY MENTION_MOBILES MENTION_MIN_SEVERITY RESERVED_CONCURRENCY
set -euo pipefail
cd "$(dirname "$0")/.."

REGIONS=${1:?"请传入区域列表，例如 \"us-east-1 ap-southeast-1\""}
: "${WEBHOOK_URL:?请先 export WEBHOOK_URL}"
STACK_NAME=${STACK_NAME:-guardduty-wecom-notify}
MIN_SEVERITY=${MIN_SEVERITY:-4}
MENTION_MOBILES=${MENTION_MOBILES:-}
MENTION_MIN_SEVERITY=${MENTION_MIN_SEVERITY:-7}
RESERVED_CONCURRENCY=${RESERVED_CONCURRENCY:-5}

echo "账号: $(aws sts get-caller-identity --query Account --output text)  栈: $STACK_NAME"
echo "区域: $REGIONS"
read -r -p "确认部署? [y/N] " ok; [ "$ok" = "y" ] || exit 1

declare -a RESULT
for r in $REGIONS; do
  echo; echo "==================== $r"
  det=$(aws guardduty list-detectors --region "$r" --query 'DetectorIds[0]' --output text 2>/dev/null || echo None)
  [ "$det" = "None" ] && echo "⚠️  $r 未启用 GuardDuty detector，栈仍会部署，但不会收到发现"
  if sam deploy --region "$r" --stack-name "$STACK_NAME" --resolve-s3 \
      --capabilities CAPABILITY_IAM --no-confirm-changeset --no-fail-on-empty-changeset \
      --parameter-overrides "WebhookUrl=$WEBHOOK_URL" "MinSeverity=$MIN_SEVERITY" \
        "MentionMobiles=$MENTION_MOBILES" "MentionMinSeverity=$MENTION_MIN_SEVERITY" \
        "ReservedConcurrency=$RESERVED_CONCURRENCY" > "/tmp/gd-wecom-deploy-$r.log" 2>&1; then
    RESULT+=("$r ✅")
  else
    RESULT+=("$r ❌ 见 /tmp/gd-wecom-deploy-$r.log")
  fi
  tail -n 2 "/tmp/gd-wecom-deploy-$r.log"
done

echo; echo "==================== 汇总"
printf '%s\n' "${RESULT[@]}"
