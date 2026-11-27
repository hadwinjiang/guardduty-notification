#!/usr/bin/env bash
# 查看 GuardDuty -> 企业微信 投递情况（只读）
# 用法: scripts/delivery_status.sh [资源名前缀，默认 guardduty-wecom-notify] [region] [最近N小时，默认24]
set -euo pipefail
STACK=${1:-guardduty-wecom-notify}; REGION=${2:-us-east-1}; HOURS=${3:-24}
START=$(( $(date +%s) - HOURS*3600 ))
ISO_START=$(date -u -r $START +%FT%TZ 2>/dev/null || date -u -d @$START +%FT%TZ)
ISO_END=$(date -u +%FT%TZ)

FN=$STACK; RULE=$STACK
DLQ=$(aws sqs get-queue-url --region $REGION --queue-name "$STACK-dlq" --query QueueUrl --output text)

sum() { aws cloudwatch get-metric-statistics --region $REGION --namespace $1 --metric-name $2 --dimensions Name=$3,Value=$4 \
        --start-time $ISO_START --end-time $ISO_END --period $((HOURS*3600)) --statistics Sum --query 'Datapoints[0].Sum' --output text | sed 's/None/0/'; }

echo "== 最近 ${HOURS} 小时 ($STACK / $REGION)"
printf "%-36s %s\n" "EventBridge 规则匹配 (MatchedEvents)" "$(sum AWS/Events MatchedEvents RuleName $RULE)"
printf "%-36s %s\n" "EventBridge 调用 Lambda 失败"        "$(sum AWS/Events FailedInvocations RuleName $RULE)"
printf "%-36s %s\n" "Lambda 调用次数 (含重试)"            "$(sum AWS/Lambda Invocations FunctionName $FN)"
printf "%-36s %s\n" "Lambda 错误次数"                      "$(sum AWS/Lambda Errors FunctionName $FN)"
printf "%-36s %s\n" "DLQ 当前积压 (最终投递失败)" \
  "$(aws sqs get-queue-attributes --region $REGION --queue-url $DLQ --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text)"

echo; echo "== 最近 20 条投递记录 (Logs Insights)"
QID=$(aws logs start-query --region $REGION --log-group-name /aws/lambda/$FN --start-time $START --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message
| filter @message like /finding id=|DELIVERY|RuntimeError/
| parse @message "finding id=* type=* severity=*" as fid, ftype, sev
| parse @message "DELIVERY msgtype=* attempt=* errcode=* errmsg=*" as msgtype, attempt, errcode, errmsg
| display @timestamp, fid, ftype, sev, msgtype, attempt, errcode, errmsg, @message
| sort @timestamp desc | limit 20' --query queryId --output text)
for _ in $(seq 1 20); do
  OUT=$(aws logs get-query-results --region $REGION --query-id $QID --output json)
  [ "$(echo "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')" = "Complete" ] && break; sleep 1
done
read -r -d '' PY <<'PYEOF' || true
import json, sys
for r in json.load(sys.stdin)["results"]:
    d = {f["field"]: f["value"] for f in r}
    t = d.get("@timestamp", "")[:19]
    if d.get("fid"):
        print(f"{t}  收到 finding  {d['fid'][:12]}  {d.get('ftype', '')}  sev={d.get('sev', '')}")
    elif d.get("msgtype"):
        ok = "✅" if d["errcode"] == "0" else "❌ " + d.get("errmsg", "")
        print(f"{t}  投递 {d['msgtype']:<8} 第{d['attempt']}次  errcode={d['errcode']}  {ok}")
    else:
        m = d.get("@message", "").strip().split("\t")[-1]
        print(f"{t}  ❌ {m[:150]}")
PYEOF
echo "$OUT" | python3 -c "$PY"
