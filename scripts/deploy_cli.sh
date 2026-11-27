#!/usr/bin/env bash
# 用 AWS CLI 部署 GuardDuty -> 企业微信 推送（不依赖 CloudFormation / SAM）
# 可在 AWS CloudShell 或任何装有 AWS CLI v2 的机器上运行；可重复执行（已存在的资源会更新）。
#
# 用法:
#   REGION=ap-southeast-1 scripts/deploy_cli.sh            # 会提示输入 Webhook（输入不回显）
#
# 可选环境变量:
#   NAME                 资源名前缀，默认 guardduty-wecom-notify
#   WEBHOOK_URL          不设置则交互输入
#   MIN_SEVERITY         推送最低严重度，默认 4（Medium 及以上）
#   MENTION_MOBILES      高危 @ 的手机号，逗号分隔，默认空
#   MENTION_MIN_SEVERITY 触发 @ 的最低严重度，默认 7
#   RESERVED_CONCURRENCY Lambda 预留并发，默认 5；账号并发配额只有 10 时设为 0
#   WEBHOOK_URL_FILE     从文件读取 Webhook（非交互运行时推荐，key 不会出现在命令行和历史里）
set -euo pipefail
cd "$(dirname "$0")/.."

REGION=${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}}
: "${REGION:?请设置 REGION，例如 REGION=ap-southeast-1}"
NAME=${NAME:-guardduty-wecom-notify}
MIN_SEVERITY=${MIN_SEVERITY:-4}
MENTION_MOBILES=${MENTION_MOBILES:-}
MENTION_MIN_SEVERITY=${MENTION_MIN_SEVERITY:-7}
RESERVED_CONCURRENCY=${RESERVED_CONCURRENCY:-5}
if [ -z "${WEBHOOK_URL:-}" ] && [ -n "${WEBHOOK_URL_FILE:-}" ]; then
  WEBHOOK_URL=$(tr -d '[:space:]' < "$WEBHOOK_URL_FILE")
fi
if [ -z "${WEBHOOK_URL:-}" ]; then
  [ -t 0 ] || { echo "当前不是交互终端：请设置 WEBHOOK_URL_FILE（或 WEBHOOK_URL）" >&2; exit 1; }
  read -r -s -p "企业微信 Webhook URL: " WEBHOOK_URL; echo
fi
[[ "$WEBHOOK_URL" =~ ^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9-]+$ ]] \
  || { echo "Webhook URL 格式不正确"; exit 1; }

export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""   # AWS_REGION 优先级更高，两个都要设
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
PARTITION=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
FN=$NAME; ROLE=$NAME-role-$REGION;   # 角色是全局资源，带上区域避免多区域部署互相覆盖
 DLQ=$NAME-dlq; RULE=$NAME; ALARM=$NAME-dlq-alarm
LOG_GROUP=/aws/lambda/$FN

echo "账号: $ACCOUNT  区域: $REGION  资源前缀: $NAME"
echo "推送阈值: severity >= $MIN_SEVERITY  @手机号: ${MENTION_MOBILES:-无}  预留并发: $RESERVED_CONCURRENCY"
read -r -p "确认部署? [y/N] " ok || true; [ "${ok:-}" = "y" ] || { echo "未确认，已退出"; exit 1; }

det=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null || echo None)
[ "$det" = "None" ] && echo "⚠️  本区域未启用 GuardDuty，部署后不会收到发现"

step() { echo; echo "==> $*"; }

# 1. SQS 死信队列
step "1/7 SQS 死信队列 $DLQ"
DLQ_URL=$(aws sqs create-queue --queue-name "$DLQ" \
  --attributes MessageRetentionPeriod=1209600,SqsManagedSseEnabled=true --query QueueUrl --output text)
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)
echo "$DLQ_ARN"

# 2. IAM 角色
step "2/7 IAM 角色 $ROLE"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  NEW_ROLE=1
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn "arn:$PARTITION:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
aws iam put-role-policy --role-name "$ROLE" --policy-name SendToDLQ --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$DLQ_ARN\"}]}"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)
echo "$ROLE_ARN"

# 3. Lambda 函数
step "3/7 Lambda 函数 $FN"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp src/app.py "$TMP/app.py"
(cd "$TMP" && python3 -c "import zipfile; z=zipfile.ZipFile('code.zip','w',zipfile.ZIP_DEFLATED); z.write('app.py'); z.close()")
ENV_JSON=$(WEBHOOK_URL="$WEBHOOK_URL" MENTION_MOBILES="$MENTION_MOBILES" MENTION_MIN_SEVERITY="$MENTION_MIN_SEVERITY" python3 -c '
import json, os
print(json.dumps({"Variables": {k: os.environ[k] for k in ("WEBHOOK_URL", "MENTION_MOBILES", "MENTION_MIN_SEVERITY")}}))')
echo "$ENV_JSON" > "$TMP/env.json"   # 通过文件传入，避免 Webhook 出现在进程参数里

if aws lambda get-function --function-name "$FN" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$TMP/code.zip" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FN"
  aws lambda update-function-configuration --function-name "$FN" --role "$ROLE_ARN" \
    --runtime python3.12 --handler app.lambda_handler --timeout 30 --memory-size 128 \
    --environment "file://$TMP/env.json" >/dev/null
else
  [ "${NEW_ROLE:-0}" = 1 ] && { echo "等待 IAM 角色生效..."; sleep 10; }
  for i in 1 2 3 4 5 6; do   # 新建角色需要几秒钟才能被 Lambda 使用
    if aws lambda create-function --function-name "$FN" --role "$ROLE_ARN" \
        --runtime python3.12 --handler app.lambda_handler --timeout 30 --memory-size 128 \
        --zip-file "fileb://$TMP/code.zip" --environment "file://$TMP/env.json" >/dev/null 2>"$TMP/err"; then
      break
    fi
    grep -q "cannot be assumed" "$TMP/err" || { cat "$TMP/err"; exit 1; }
    [ $i = 6 ] && { cat "$TMP/err"; exit 1; }
    echo "角色尚未生效，10 秒后重试 ($i/5)"; sleep 10
  done
fi
aws lambda wait function-updated-v2 --function-name "$FN"
FN_ARN=$(aws lambda get-function --function-name "$FN" --query Configuration.FunctionArn --output text)
if [ "$RESERVED_CONCURRENCY" -gt 0 ]; then
  # 预留后账号剩余的非预留并发不能低于 10（新账号总配额常常只有 10）
  UNRESERVED=$(aws lambda get-account-settings --query AccountLimit.UnreservedConcurrentExecutions --output text)
  CUR=$(aws lambda get-function-concurrency --function-name "$FN" --query ReservedConcurrentExecutions --output text)
  [ "$CUR" = "None" ] && CUR=0
  if [ $(( UNRESERVED + CUR - RESERVED_CONCURRENCY )) -lt 10 ]; then
    echo "⚠️  账号并发配额不足（非预留剩余 ${UNRESERVED}），跳过预留并发。可在 Service Quotas 申请提升后重新执行"
    RESERVED_CONCURRENCY=0
  fi
fi
if [ "$RESERVED_CONCURRENCY" -gt 0 ]; then
  aws lambda put-function-concurrency --function-name "$FN" --reserved-concurrent-executions "$RESERVED_CONCURRENCY" >/dev/null
else
  aws lambda delete-function-concurrency --function-name "$FN" 2>/dev/null || true
fi
echo "$FN_ARN"

# 4. 异步调用：重试 2 次，失败进 DLQ
step "4/7 异步调用配置（重试 2 次 → DLQ）"
aws lambda put-function-event-invoke-config --function-name "$FN" \
  --maximum-retry-attempts 2 --maximum-event-age-in-seconds 3600 \
  --destination-config "{\"OnFailure\":{\"Destination\":\"$DLQ_ARN\"}}" >/dev/null
echo ok

# 5. 日志组保留期
step "5/7 日志组 ${LOG_GROUP}（保留 90 天）"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 90
echo ok

# 6. EventBridge 规则
step "6/7 EventBridge 规则 $RULE"
RULE_ARN=$(aws events put-rule --name "$RULE" --state ENABLED \
  --description "GuardDuty findings to WeCom" \
  --event-pattern "{\"source\":[\"aws.guardduty\"],\"detail-type\":[\"GuardDuty Finding\"],\"detail\":{\"severity\":[{\"numeric\":[\">=\",$MIN_SEVERITY]}]}}" \
  --query RuleArn --output text)
aws events put-targets --rule "$RULE" --targets \
  "[{\"Id\":\"NotifyFunction\",\"Arn\":\"$FN_ARN\",\"RetryPolicy\":{\"MaximumRetryAttempts\":10,\"MaximumEventAgeInSeconds\":3600}}]" \
  --query FailedEntryCount --output text | grep -qx 0 || { echo "规则目标设置失败"; exit 1; }
aws lambda remove-permission --function-name "$FN" --statement-id eventbridge-invoke 2>/dev/null || true
aws lambda add-permission --function-name "$FN" --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn "$RULE_ARN" >/dev/null
echo "$RULE_ARN"

# 7. DLQ 告警
step "7/7 CloudWatch 告警 $ALARM"
aws cloudwatch put-metric-alarm --alarm-name "$ALARM" \
  --alarm-description "GuardDuty -> WeCom 推送失败（消息进入 DLQ），请检查 webhook 或网络" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible --dimensions Name=QueueName,Value="$DLQ" \
  --statistic Maximum --period 300 --evaluation-periods 1 --threshold 0 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching
echo ok

echo
echo "✅ 部署完成"
echo "   函数: $FN   规则: $RULE   DLQ: $DLQ_URL"
echo "   告警通知: 可在 CloudWatch 控制台给 $ALARM 配置 SNS 主题"
