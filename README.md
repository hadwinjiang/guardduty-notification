# GuardDuty 发现 → 企业微信 推送方案

## 1. 方案概述

GuardDuty 是**区域服务**：detector、发现、EventBridge 事件都只存在于所在区域。海外区（`aws`）和中国区（`aws-cn`）是两个隔离的分区，事件不能跨分区流转。

本方案采用 **"每个区域独立部署一整套"** 的方式：在 GuardDuty Delegated Administrator 账号中，每个启用了 GuardDuty 的区域都部署同一份模板。各区域互相独立，一个区域出问题不影响其他区域的告警。

```
              ┌──────────── 海外分区 (aws) ────────────┐   ┌───── 中国分区 (aws-cn) ─────┐
              │  us-east-1      ap-southeast-1   ...  │   │  cn-north-1   cn-northwest-1 │
成员账号 ──►  │  GuardDuty      GuardDuty             │   │  GuardDuty    GuardDuty      │
(自动汇聚到   │     │              │                  │   │     │            │           │
 Admin 账号)  │  EventBridge    EventBridge           │   │  EventBridge  EventBridge    │
              │     │              │                  │   │     │            │           │
              │  Lambda+DLQ     Lambda+DLQ            │   │  Lambda+DLQ   Lambda+DLQ     │
              └─────┼──────────────┼──────────────────┘   └─────┼────────────┼───────────┘
                    └──────────────┴────────────┬───────────────┴────────────┘
                                                ▼
                                企业微信群机器人 Webhook (qyapi.weixin.qq.com)
```

### 单区域内的处理链路

```
GuardDuty (本区域，含所有成员账号)
   │  GuardDuty Finding 事件
   ▼
EventBridge 默认事件总线
   │  规则: source=aws.guardduty, detail-type=GuardDuty Finding, severity >= 阈值
   ▼
Lambda (Python 3.12，仅依赖标准库)
   │  ① 从环境变量 WEBHOOK_URL 读取 webhook
   │  ② 格式化为 markdown（严重度颜色 / 账号 / 区域 / 资源 / 来源 IP / 控制台链接，≤4096 字节）
   │  ③ 高危(≥7) 补发 text 消息 @ 值班手机号
   ▼
企业微信群机器人 Webhook

失败链路: webhook 返回非 0 → 函数内指数退避重试（45009 限流 / 网络错误）
        → Lambda 异步重试 2 次 → SQS DLQ（保留 14 天）→ CloudWatch 告警
```

### 设计要点

| 设计点 | 说明 |
|---|---|
| 区域独立 | 每个区域一套完整资源，没有跨区域依赖，也没有单点故障；消息里标注了来源账号和区域 |
| 多账号 | 部署在 Delegated Admin 账号即可，同区域所有成员账号的发现会自动汇聚过来，不需要在成员账号部署 |
| 无服务器 | 全部是托管服务，按调用计费，每个区域月成本通常 < 1 USD |
| 凭据保护 | Webhook URL 等同于发消息的凭据。存放在 Lambda 环境变量（静态由 KMS 加密），模板参数 `NoEcho`，日志不打印。有 `lambda:GetFunctionConfiguration` 权限的人可以看到明文，需要收紧这个权限；URL 泄露后可在群里删掉机器人重建 |
| 噪音控制 | 阈值在 EventBridge 层过滤（默认 Medium 及以上），低危不触发 Lambda |
| 限流 | 企业微信机器人限 **20 条/分钟，按机器人计算，所有区域共用**。每个区域的预留并发（默认 5）加上 45009 退避重试，可以平滑突发；区域很多、发现很多时，建议按分区或按区域使用不同的机器人 |
| 不丢告警 | 投递失败就抛异常 → Lambda 重试 → DLQ + 告警，可以人工回放 |
| 分区兼容 | 同一份模板两个分区通用；自动识别 `aws-cn`，控制台链接用 `console.amazonaws.cn` |

## 2. 部署

### 2.1 前置条件（每个区域）

1. **在每个目标区域启用 GuardDuty**，并在该区域指定 Delegated Administrator、关联成员账号。GuardDuty 的这些设置是按区域配置的。
2. 在 Admin 账号里，把每个区域的 detector 的 `FindingPublishingFrequency` 设成需要的值（见 2.4）。
3. 企业微信群 → 群设置 → 群机器人 → 添加机器人，复制 Webhook 地址。
4. 本地装好 AWS CLI 和 SAM CLI，并有 Admin 账号的部署权限。海外区和中国区各需要一套凭据。

### 2.2 批量部署到多个区域

```bash
export WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx'
export MENTION_MOBILES='138xxxx0000'          # 可选

# 海外分区（使用海外 Admin 账号的凭据）
AWS_PROFILE=geely-global scripts/deploy_all_regions.sh "us-east-1 ap-southeast-1 eu-central-1"

# 中国分区（使用中国区 Admin 账号的凭据）
AWS_PROFILE=geely-cn scripts/deploy_all_regions.sh "cn-north-1 cn-northwest-1"
```

脚本会对每个区域执行 `sam deploy`：自动在该区域创建代码桶，检查该区域有没有启用 GuardDuty，最后汇总每个区域的部署结果。新增区域时，把区域加进列表重新执行即可；已经部署过的区域没有变化时会自动跳过。

### 2.3 单区域部署 / 参数

```bash
sam deploy --region ap-southeast-1 --stack-name guardduty-wecom-notify --resolve-s3 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
     WebhookUrl='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx' \
     MinSeverity=4 MentionMobiles='138xxxx0000' MentionMinSeverity=7 ReservedConcurrency=5
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `WebhookUrl` | – | 企业微信机器人地址（必填） |
| `MinSeverity` | 4 | 推送的最低严重度：4 表示 Medium 及以上，7 表示 High 及以上 |
| `MentionMobiles` | 空 | 高危时 @ 的手机号，逗号分隔；`@all` 表示全员 |
| `MentionMinSeverity` | 7 | 达到这个严重度才 @ |
| `ReservedConcurrency` | 5 | Lambda 预留并发。账号 Lambda 并发配额较低时（新账号可能只有 10），预留会导致部署失败，这时填 0 表示不预留 |

### 2.4 通知频率建议

- **新发现**：GuardDuty 近实时发送到 EventBridge，不能调整。
- **同一发现的后续出现**：按 detector 的 `FindingPublishingFrequency` 聚合后发送，默认 6 小时，可以设为 15 分钟或 1 小时。只有 Admin 账号能设，而且**每个区域要分别设置**。

群里重复消息太多时，保持 6 小时，或者把 `MinSeverity` 调到 7。

## 3. 验证

### 3.1 本地模拟（36/36 通过）

```bash
python3 tests/run_simulation.py
```

脚本会启动一个本地 Mock 企业微信 Webhook（只绑定 127.0.0.1），按官方协议校验 key、msgtype 和 4096 字节上限，也能模拟 45009 限流。样例事件用 EventBridge 的真实格式（`detail` 为 GetFindings API 原始 JSON，字段名是 camelCase）。

| 场景 | 样例 | 预期 / 结果 |
|---|---|---|
| 攻击序列 Critical 9.5 + 超长描述 | attack_sequence_critical.json | 推送，截断到 ≤4096 字节，@ 值班 ✅ |
| EC2 挖矿 High 8（中国区） | ec2_cryptomining_high.json | 推送，解析出实例 ID / 实例名 / 域名，使用中国区控制台链接，@ 值班 ✅ |
| 凭据外泄 Medium 5（样例发现） | iam_anomalous_medium.json | 推送，标题标 [样例]，解析出 IAM 主体和来源 IP，不 @ ✅ |
| 真实 GuardDuty 样例发现（从 API 获取） | real_sample_bitcoin.json | 推送，识别 [样例]，解析出实例和行为 ✅ |
| S3 策略 Low 2 | s3_policy_low.json | 被 EventBridge 规则过滤 ✅ |
| 限流 45009 两次 | – | 退避后成功 ✅ |
| 持续限流 / 错误 key | – | 抛异常，进入 Lambda 重试 / DLQ ✅ |
| 非 GuardDuty 事件 | – | 忽略 ✅ |

另外：EventBridge 规则已经用 `aws events test-event-pattern` 在真实 API 上校验过（3 条匹配，Low 不匹配）；模板通过了 `sam validate --lint`。

### 3.2 云上验证（测试账号 us-east-1）

| 环节 | 结果 |
|---|---|
| 部署（Lambda / 规则 / DLQ / 告警 / 日志组） | ✅ |
| Lambda → 真实企业微信 API | ✅ 从 AWS 公网出口访问到 qyapi.weixin.qq.com；测试用的是无效 key，返回 93000，符合预期 |
| 失败 → 重试 2 次 → DLQ | ✅ DLQ 消息标记为 `RetriesExhausted`，原始事件完整保留 |
| GuardDuty 样例发现 → EventBridge | ⏳ 样例发现生成后 35 分钟内，规则匹配数为 0，待复测 |

**复测方法**（换成真实 Webhook，在每个新部署的区域执行）：

```bash
DET=$(aws guardduty list-detectors --region <region> --query 'DetectorIds[0]' --output text)
aws guardduty create-sample-findings --region <region> --detector-id $DET \
  --finding-types "CryptoCurrency:EC2/BitcoinTool.B!DNS"
# 群里会收到带 [样例] 标识的消息；也可以运行：
scripts/delivery_status.sh guardduty-wecom-notify <region> 1
```

不带 `--finding-types` 会一次生成全部类型（上百条），会触发机器人限流，所以验证时请只指定少量类型。

## 4. 查看投递情况

**一键查看（只读）：** `scripts/delivery_status.sh [栈名] [区域] [小时数]`，会输出各环节的计数和最近 20 条投递记录。各区域独立，需要按区域分别查看。

```
== 最近 24 小时 (guardduty-wecom-notify / us-east-1)
EventBridge 规则匹配 (MatchedEvents) 0
Lambda 调用次数 (含重试)              3.0
Lambda 错误次数                       3.0
DLQ 当前积压 (最终投递失败)           1
2026-11-27 04:36:20  ❌ RuntimeError: WeCom webhook failed: {'errcode': 93000, ...}
2026-11-27 04:36:19  收到 finding  16afba5c5c43  CryptoCurrency:EC2/BitcoinTool.B!DNS  sev=8.0
```

| 想看什么 | 控制台位置（先切到对应区域） | 指标 / 关键字 |
|---|---|---|
| GuardDuty 事件有没有进 EventBridge | EventBridge → 规则 → `...GuardDutyFinding...` → 监控 | `MatchedEvents`、`FailedInvocations` |
| Lambda 有没有被调用、有没有报错 | Lambda → 函数 → 监控 | `Invocations`、`Errors`、`AsyncEventsDropped` |
| 每条消息投递到企业微信的结果 | CloudWatch → 日志组 `/aws/lambda/<函数名>` | `finding id=`（收到哪条发现）、`DELIVERY ... errcode=0`（成功）、`RuntimeError`（失败） |
| 最终投递失败的消息 | SQS → `...NotifyDLQ...` → 发送和接收消息 | 消息体里有原始事件和失败原因 `RetriesExhausted` |
| 主动告警 | CloudWatch → 告警 → `DLQAlarm` | DLQ 里有消息就进入 ALARM；建议给它配 SNS 通知 |

Logs Insights 查询（CloudWatch → Logs Insights，选上面的日志组）：

```
fields @timestamp, @message
| filter @message like /finding id=|DELIVERY|RuntimeError/
| sort @timestamp desc | limit 50
```

常见 errcode：`0` 成功；`93000` webhook key 无效（机器人被删除，或 URL 写错）；`45009` 超过频率限制（20 条/分钟）；`40058` 内容过长。

## 5. 文件

```
template.yaml                SAM 模板（Lambda / EventBridge 规则 / DLQ / 告警 / 日志组），每个区域部署一份
src/app.py                   Lambda 代码（仅依赖 Python 标准库）
scripts/deploy_all_regions.sh  多区域批量部署
scripts/delivery_status.sh   查看投递情况（只读）
tests/run_simulation.py      本地模拟验证
tests/events/*.json          GuardDuty 样例事件（EventBridge 实际格式）
```

## 6. 可选扩展

- **按严重度分群**：同一个区域部署两个栈（栈名不同），使用不同的 Webhook，`MinSeverity` 分别设为 7 和 4。
- **按分区分群**：海外区和中国区使用不同的机器人，各自分担 20 条/分钟的限额。
- **聚合降噪**：发现很多时可改为 EventBridge → SQS → Lambda 批量消费，每分钟合并成一条摘要。
- **私网出口**：Lambda 默认使用 AWS 托管的公网出口。如果要求放在 VPC 内运行，需要配置 NAT 网关，并在出口放行 `qyapi.weixin.qq.com:443`。
