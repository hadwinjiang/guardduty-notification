#!/usr/bin/env bash
# 删除 scripts/deploy_cli.sh 创建的全部资源（不会动 GuardDuty 本身）
# 用法: REGION=ap-southeast-1 [NAME=guardduty-wecom-notify] scripts/uninstall_cli.sh
set -uo pipefail
REGION=${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}}
: "${REGION:?请设置 REGION}"
NAME=${NAME:-guardduty-wecom-notify}
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "将删除 账号 $ACCOUNT / $REGION 中的以下资源："
echo "  EventBridge 规则 ${NAME}、Lambda ${NAME}、IAM 角色 $NAME-role-${REGION}、SQS $NAME-dlq（含其中消息）、"
echo "  告警 $NAME-dlq-alarm、日志组 /aws/lambda/${NAME}（含历史日志）"
read -r -p "输入 $NAME 确认删除: " ok; [ "$ok" = "$NAME" ] || { echo "已取消"; exit 1; }

aws events remove-targets --rule "$NAME" --ids NotifyFunction >/dev/null 2>&1 && echo "规则目标已移除"
aws events delete-rule --name "$NAME" 2>/dev/null && echo "规则已删除"
aws lambda delete-function --function-name "$NAME" 2>/dev/null && echo "Lambda 已删除"
aws cloudwatch delete-alarms --alarm-names "$NAME-dlq-alarm" 2>/dev/null && echo "告警已删除"
URL=$(aws sqs get-queue-url --queue-name "$NAME-dlq" --query QueueUrl --output text 2>/dev/null) && \
  aws sqs delete-queue --queue-url "$URL" && echo "DLQ 已删除"
aws logs delete-log-group --log-group-name "/aws/lambda/$NAME" 2>/dev/null && echo "日志组已删除"
aws iam detach-role-policy --role-name "$NAME-role-$REGION" --policy-arn \
  "arn:$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2):iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null
aws iam delete-role-policy --role-name "$NAME-role-$REGION" --policy-name SendToDLQ 2>/dev/null
aws iam delete-role --role-name "$NAME-role-$REGION" 2>/dev/null && echo "IAM 角色已删除"
echo "完成"
