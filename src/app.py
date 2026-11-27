"""
GuardDuty Finding -> 企业微信（WeCom）群机器人 推送 Lambda

触发源：EventBridge 规则（source=aws.guardduty, detail-type=GuardDuty Finding）
输出：  企业微信群机器人 Webhook（markdown 消息；高危可额外 @ 指定成员）

环境变量：
  WEBHOOK_URL          企业微信群机器人 webhook URL（必填）
  MENTION_MOBILES      高危时 @ 的手机号，逗号分隔；"@all" 表示全员（可选）
  MENTION_MIN_SEVERITY 触发 @ 的最低严重度，默认 7.0（High）
  HTTP_TIMEOUT         Webhook 请求超时秒数，默认 5
"""
import json
import logging
import os
import time
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

WECOM_MARKDOWN_MAX_BYTES = 4096          # 企业微信 markdown content 上限
WECOM_ERR_RATE_LIMIT = 45009             # 接口调用超过限制（20 条/分钟/机器人）
MAX_RETRIES = 3

# ---------------------------------------------------------------- 配置
def get_webhook_url():
    return os.environ["WEBHOOK_URL"]


# ---------------------------------------------------------------- 格式化
def severity_label(sev):
    # GuardDuty: 9.0-10.0 Critical(扩展威胁检测), 7.0-8.9 High, 4.0-6.9 Medium, 1.0-3.9 Low
    if sev >= 9.0:
        return "严重 Critical", "warning"
    if sev >= 7.0:
        return "高 High", "warning"
    if sev >= 4.0:
        return "中 Medium", "comment"
    return "低 Low", "info"


def console_url(region, finding_id):
    return (f"https://{region}.console.aws.amazon.com/guardduty/home?region={region}"
            f"#/findings?macros=current&fId={finding_id}")


def _camel(obj):
    """EventBridge 中 detail 为 GetFindings API 原始 JSON（camelCase）；
    CLI/boto3 输出为 PascalCase。统一转成 camelCase，两种来源都能解析。"""
    if isinstance(obj, dict):
        return {(k[:1].lower() + k[1:]): _camel(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_camel(v) for v in obj]
    return obj


def _is_sample(service):
    info = service.get("additionalInfo") or {}
    if info.get("sample") is True:
        return True
    try:  # 真实格式：{"value": "{\"sample\":true,...}", "type": "default"}
        return json.loads(info.get("value") or "{}").get("sample") is True
    except (TypeError, ValueError, AttributeError):
        return False


def _resource_summary(resource):
    """提取受影响资源的关键信息（不同 finding 类型资源结构不同）。"""
    lines = [f"资源类型：{resource.get('resourceType', 'Unknown')}"]
    inst = resource.get("instanceDetails") or {}
    if inst.get("instanceId"):
        lines.append(f"实例：{inst['instanceId']}")
        name_tag = next((t.get("value") for t in inst.get("tags") or [] if t.get("key") == "Name"), None)
        if name_tag:
            lines.append(f"实例名称：{name_tag}")
    ak = resource.get("accessKeyDetails") or {}
    if ak.get("userName"):
        lines.append(f"IAM 主体：{ak['userName']} ({ak.get('userType', '')})")
    if ak.get("accessKeyId"):
        lines.append(f"AccessKey：{ak['accessKeyId']}")
    for b in (resource.get("s3BucketDetails") or [])[:3]:
        lines.append(f"S3 桶：{b.get('name')}")
    eks = resource.get("eksClusterDetails") or {}
    if eks.get("name"):
        lines.append(f"EKS 集群：{eks['name']}")
    return lines


def _action_summary(service):
    action = service.get("action") or {}
    atype = action.get("actionType")
    if not atype:
        return []
    lines = [f"行为：{atype}"]
    remote = None
    if atype == "NETWORK_CONNECTION":
        remote = (action.get("networkConnectionAction") or {}).get("remoteIpDetails")
    elif atype == "AWS_API_CALL":
        api = action.get("awsApiCallAction") or {}
        lines.append(f"API：{api.get('serviceName', '')} / {api.get('api', '')}")
        remote = api.get("remoteIpDetails")
    elif atype == "PORT_PROBE":
        details = (action.get("portProbeAction") or {}).get("portProbeDetails") or [{}]
        remote = details[0].get("remoteIpDetails")
    elif atype == "DNS_REQUEST":
        lines.append(f"域名：{(action.get('dnsRequestAction') or {}).get('domain', '')}")
    if remote and remote.get("ipAddressV4"):
        country = (remote.get("country") or {}).get("countryName", "")
        org = (remote.get("organization") or {}).get("org", "")
        lines.append(f"来源 IP：{remote['ipAddressV4']} {country} {org}".rstrip())
    return lines


def build_markdown(event):
    d = _camel(event["detail"])
    sev = float(d.get("severity", 0))
    label, color = severity_label(sev)
    region = d.get("region") or event.get("region", "")
    account = d.get("accountId") or event.get("account", "")
    service = d.get("service") or {}
    count = service.get("count", 1)
    is_sample = _is_sample(service)

    url = console_url(region, d.get("id", ""))

    title = d.get("title", "GuardDuty Finding")
    header = f"## {'[样例] ' if is_sample else ''}GuardDuty 安全告警"
    lines = [
        header,
        f"> 严重度：<font color=\"{color}\">{label} ({sev})</font>",
        f"> 类型：{d.get('type', '')}",
        f"> 账号：{account}",
        f"> 区域：{region}",
        f"> 次数：{count}　首次：{service.get('eventFirstSeen', d.get('createdAt', ''))}",
        f"> 最近：{service.get('eventLastSeen', d.get('updatedAt', ''))}",
        "",
        f"**{title}**",
    ]
    lines += [f"> {x}" for x in _resource_summary(d.get("resource") or {})]
    lines += [f"> {x}" for x in _action_summary(service)]
    desc = d.get("description", "")
    footer = f"\n[在控制台查看]({url})"

    body = "\n".join(lines) + "\n\n" + desc
    # 截断到 4096 字节以内（按 UTF-8 字节计算，保留 footer）
    budget = WECOM_MARKDOWN_MAX_BYTES - len(footer.encode()) - 16
    raw = body.encode()
    if len(raw) > budget:
        body = raw[:budget].decode("utf-8", errors="ignore") + "…(已截断)"
    return body + footer, sev


# ---------------------------------------------------------------- 发送
def post_wecom(payload):
    url = get_webhook_url()
    data = json.dumps(payload, ensure_ascii=False).encode()
    timeout = float(os.environ.get("HTTP_TIMEOUT", "5"))
    for attempt in range(1, MAX_RETRIES + 1):
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                result = json.loads(resp.read().decode() or "{}")
        except OSError as e:  # URLError/超时/连接重置 均为 OSError 子类
            logger.warning("webhook network error attempt=%s err=%s", attempt, e)
            result = {"errcode": -1, "errmsg": str(e)}
        logger.info("DELIVERY msgtype=%s attempt=%s errcode=%s errmsg=%s",
                    payload.get("msgtype"), attempt, result.get("errcode"), str(result.get("errmsg"))[:120])
        if result.get("errcode") == 0:
            return result
        if attempt < MAX_RETRIES and result.get("errcode") in (WECOM_ERR_RATE_LIMIT, -1):
            time.sleep(2 ** attempt)  # 2s, 4s
            continue
        # 抛出异常 -> Lambda 异步重试，最终进入 DLQ，不会静默丢告警
        raise RuntimeError(f"WeCom webhook failed: {result}")


def lambda_handler(event, context):
    if event.get("detail-type") != "GuardDuty Finding":
        logger.info("ignore non-guardduty event: %s", event.get("detail-type"))
        return {"status": "ignored"}

    content, sev = build_markdown(event)
    logger.info("finding id=%s type=%s severity=%s",
                event["detail"].get("id"), event["detail"].get("type"), sev)
    post_wecom({"msgtype": "markdown", "markdown": {"content": content}})

    # markdown 消息不支持 @，高危时补发一条 text 消息 @ 值班人员
    mobiles = [m.strip() for m in os.environ.get("MENTION_MOBILES", "").split(",") if m.strip()]
    if mobiles and sev >= float(os.environ.get("MENTION_MIN_SEVERITY", "7")):
        post_wecom({
            "msgtype": "text",
            "text": {
                "content": f"⚠️ GuardDuty 高危告警：{event['detail'].get('type')}，请立即处理",
                "mentioned_mobile_list": mobiles,
            },
        })
    return {"status": "sent", "severity": sev}
