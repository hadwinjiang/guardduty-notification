# 部署指南（CLI / 控制台）

两种方式任选一种，部署出来的资源完全一样：

| 方式 | 需要的工具 | 耗时 |
|---|---|---|
| **方式一：AWS CLI 脚本（推荐）** | AWS CloudShell，或者任何装有 AWS CLI v2 和 python3 的机器 | 约 2 分钟 |
| 方式二：控制台逐个创建资源 | 只需浏览器 | 约 20 分钟 |

前置条件：
- 目标区域已经启用 GuardDuty。多账号时，在 Delegated Admin 账号部署。
- 已在企业微信群添加机器人，并拿到 Webhook 地址。

会创建的资源（默认名称前缀 `guardduty-wecom-notify`）：

| 资源 | 名称 |
|---|---|
| SQS 死信队列 | `guardduty-wecom-notify-dlq` |
| IAM 角色 | `guardduty-wecom-notify-role-<区域>`（例如 `guardduty-wecom-notify-role-ap-southeast-1`） |
| Lambda 函数 | `guardduty-wecom-notify` |
| CloudWatch 日志组 | `/aws/lambda/guardduty-wecom-notify` |
| EventBridge 规则 | `guardduty-wecom-notify` |
| CloudWatch 告警 | `guardduty-wecom-notify-dlq-alarm` |

---

## 方式一：AWS CLI 脚本

最简单的做法是在 **AWS CloudShell** 中执行：先在控制台右上角切换到目标区域，再打开 CloudShell。CloudShell 自带 CLI 和登录凭据。

1. 把项目文件上传到 CloudShell（操作 → 上传文件，上传项目的 zip 包，再执行 `unzip`），然后进入项目目录。
2. 执行：

```bash
REGION=ap-southeast-1 MENTION_MOBILES=138xxxx0000 scripts/deploy_cli.sh
# 按提示粘贴 Webhook URL（输入时不显示），再输入 y 确认
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `REGION` | `AWS_REGION` / CLI 当前区域 | GuardDuty 所在区域 |
| `NAME` | `guardduty-wecom-notify` | 资源名前缀 |
| `WEBHOOK_URL` | 不设置就交互输入 | 企业微信机器人地址 |
| `WEBHOOK_URL_FILE` | 空 | 从文件读取 Webhook，适合非交互运行，key 不会出现在命令行里 || `MIN_SEVERITY` | 4 | 推送的最低严重度：4 表示 Medium 及以上，7 表示 High 及以上 |
| `MENTION_MOBILES` | 空 | 高危时 @ 的手机号，逗号分隔；`@all` 表示全员 |
| `MENTION_MIN_SEVERITY` | 7 | 达到这个严重度才 @ |
| `RESERVED_CONCURRENCY` | 5 | Lambda 预留并发；账号并发配额不足时脚本会自动跳过并提示 |

脚本可以重复执行：已有的资源会更新，没有的会新建。**更新代码或修改参数时，直接重新执行即可。**

所需权限：`sqs:CreateQueue/GetQueueAttributes`、`iam:CreateRole/GetRole/AttachRolePolicy/PutRolePolicy/PassRole`、`lambda:*Function*/PutFunctionConcurrency/PutFunctionEventInvokeConfig/AddPermission/RemovePermission`、`logs:CreateLogGroup/PutRetentionPolicy`、`events:PutRule/PutTargets`、`cloudwatch:PutMetricAlarm`、`guardduty:ListDetectors`。

**卸载：** `REGION=ap-southeast-1 scripts/uninstall_cli.sh`。需要输入资源前缀确认；只删除上表中的资源，不影响 GuardDuty。

---

## 方式二：控制台逐个创建资源

按下面的顺序创建，后面的步骤会用到前面创建的资源。建议使用上表中的名称，这样 `scripts/delivery_status.sh` 可以直接使用。

### 1. SQS 死信队列（DLQ）

SQS 控制台 → **创建队列**
- 类型：标准；名称：`guardduty-wecom-notify-dlq`
- 消息保留期：**14 天**
- 加密：保持默认（SSE-SQS）
- 创建后，记下队列的 **ARN**

### 2. IAM 角色

IAM 控制台 → 角色 → **创建角色**
- 可信实体：AWS 服务 → **Lambda**
- 权限策略：勾选 `AWSLambdaBasicExecutionRole`
- 角色名：`guardduty-wecom-notify-role-<区域>`
- 创建后进入角色 → **添加权限 → 创建内联策略**（JSON）。把 `<DLQ ARN>` 换成第 1 步记下的 ARN：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "sqs:SendMessage", "Resource": "<DLQ ARN>" }
  ]
}
```

### 3. Lambda 函数

Lambda 控制台 → **创建函数** → 从头开始编写
- 函数名：`guardduty-wecom-notify`
- 运行时：**Python 3.12**；架构：x86_64
- 执行角色：使用现有角色 → `guardduty-wecom-notify-role-<区域>`

创建后依次配置：

| 位置 | 配置 |
|---|---|
| **代码** 页签 | 打开 `lambda_function.py`，清空内容，粘贴 `src/app.py` 的全部内容，点 **Deploy** |
| **代码** 页签 → 运行时设置 → 编辑 | 处理程序改为 `lambda_function.lambda_handler`（默认值就是这个，确认一下即可） |
| 配置 → 常规配置 | 超时 **30 秒**，内存 128 MB |
| 配置 → 环境变量 | `WEBHOOK_URL` = 机器人地址（必填）<br>`MENTION_MOBILES` = 手机号，逗号分隔（可选）<br>`MENTION_MIN_SEVERITY` = `7`（可选） |
| 配置 → 并发 | 预留并发 **5**。账号配额只有 10 时跳过这一项 |
| 配置 → 异步调用 → 编辑 | 最大事件期限 **1 小时**；重试次数 **2** |
| 配置 → 目标 → 添加目标 | 源：**异步调用**；条件：**失败时**；目标类型：**SQS 队列**；选择第 1 步的 DLQ |

**日志保留期（建议）：** 函数第一次运行后，到 CloudWatch → 日志组 `/aws/lambda/guardduty-wecom-notify` → 操作 → 编辑保留期 → **90 天**。

### 4. EventBridge 规则

EventBridge 控制台 → 规则 → **创建规则**
- 名称：`guardduty-wecom-notify`；事件总线：**default**；规则类型：具有事件模式的规则
- 事件源：其他（或 AWS 事件）→ 创建方法：**自定义模式（JSON 编辑器）**，粘贴下面的模式。`4` 是最低严重度，只要高危就改成 `7`：

```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Finding"],
  "detail": { "severity": [{ "numeric": [">=", 4] }] }
}
```

- 目标：AWS 服务 → **Lambda 函数** → `guardduty-wecom-notify`
- 其他设置 → 重试策略：最大事件期限 **1 小时**，重试次数 **10**
- 创建。控制台会自动给 Lambda 加上允许 EventBridge 调用的权限。

### 5. CloudWatch 告警（DLQ 有积压时告警）

CloudWatch 控制台 → 告警 → **创建告警** → 选择指标
- SQS → 队列指标 → `guardduty-wecom-notify-dlq` → **ApproximateNumberOfMessagesVisible**
- 统计：最大值；周期：5 分钟
- 条件：**大于 0**；缺失数据：视为**正常**（未超出阈值）
- 通知：选择或新建一个 SNS 主题，用来接收告警（建议配置）
- 名称：`guardduty-wecom-notify-dlq-alarm`

---

## 部署后验证（两种方式通用）

**1. 测试 Lambda 到企业微信这一段：** Lambda 控制台 → 函数 → **测试** 页签 → 新建事件，把 `tests/events/ec2_cryptomining_high.json` 的内容粘贴进去 → **测试**。
- 群里收到一条 "GuardDuty 安全告警" 就说明成功。
- 执行结果里如果有 `errcode` 不为 0 的错误，对照 README「查看投递情况」里的常见 errcode 排查。

**2. 测试完整链路：** GuardDuty 控制台 → 设置 → **示例发现 → 生成示例发现**。几分钟后群里会收到标题带 **[样例]** 的消息。
- 注意：这一步会生成上百条示例发现，会触发机器人 20 条/分钟的限流。超出的消息会自动重试，最终仍失败的进入 DLQ。只想测一两条时，用 CloudShell 执行：

```bash
DET=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)
aws guardduty create-sample-findings --detector-id $DET --finding-types "CryptoCurrency:EC2/BitcoinTool.B!DNS"
```

**3. 查看投递记录：** 参考 README 第 4 节「查看投递情况」。

---

## 更新代码

- 方式一：重新执行 `scripts/deploy_cli.sh`。
- 方式二：到 Lambda 控制台 → 代码 页签，重新粘贴 `src/app.py` 的内容，然后点 **Deploy**。
