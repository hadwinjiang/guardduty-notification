# GuardDuty 发现（Finding）分类与关键字段

本文整理 GuardDuty 会产生哪几类发现、分别通过哪些字段体现，用于配置推送过滤和分群路由。
内容以 AWS 官方文档为准（2026-11-27 查阅），每条结论后用 `[S#]` 标注来源，来源列表见文末。
`[样例]` 表示来自本项目 `tests/events/` 中的事件，或 GuardDuty 实际生成的样例发现。

---

## 1. 字段位置速查

EventBridge 收到的 GuardDuty 事件中，`detail` 就是单条 finding 的完整 JSON，结构与 `GetFindings` API 的返回一致 [S5]：

```json
{
  "source": "aws.guardduty",
  "detail-type": "GuardDuty Finding",
  "region": "us-east-1",
  "account": "111122223333",
  "detail": { ...单条 finding... }
}
```

| 字段 | 体现的分类维度 | 来源 |
|---|---|---|
| `detail.type` | **发现类型**：同时包含威胁目的、资源类型、威胁家族、检测机制 | [S1] |
| `detail.severity` | 严重度数值，范围 1.0–10.0 | [S2] |
| `detail.resource.resourceType` | 受影响资源的类型 | [S6] |
| `detail.resource.*Details` | 受影响资源的具体信息，例如 `instanceDetails`、`accessKeyDetails` | [S6] |
| `detail.service.featureName` | 产生这条发现的 GuardDuty 功能（数据源） | [S7] |
| `detail.service.action.actionType` | 触发这条发现的活动类型 | [S8] |
| `detail.service.count` | 这条发现累计出现的次数 | [S7] |
| `detail.service.additionalInfo` | 附加信息；样例发现会带 `sample: true` | [S7]、[样例] |
| `detail.accountId` | 发现所属账号；多账号环境下用来区分成员账号 | [S5] |

---

## 2. 按发现类型分类：`detail.type`

### 2.1 命名格式 [S1]

```
ThreatPurpose:ResourceTypeAffected/ThreatFamilyName.DetectionMechanism!Artifact
```

| 部分 | 含义 | 例子 |
|---|---|---|
| ThreatPurpose | 威胁的主要目的、攻击类型或攻击阶段 | `Recon`、`Backdoor` |
| ResourceTypeAffected | 被攻击的资源类型 | `EC2`、`IAMUser`、`S3` |
| ThreatFamilyName | 检测到的具体威胁 | `NetworkPortUnusual`、`BitcoinTool` |
| DetectionMechanism | 检测方式。`.Custom` 表示命中你自己上传的威胁列表；`.Reputation` 表示由域名信誉模型检测 | `DenialOfService.Tcp` / `.Udp` |
| Artifact（可选） | 恶意活动用到的资源 | `!DNS` 表示通过 DNS 请求发现 |

例如 `CryptoCurrency:EC2/BitcoinTool.B!DNS`：EC2 实例在访问已知的比特币相关域名 [S1]。

### 2.2 威胁目的（ThreatPurpose）：官方共 17 种 [S1]

| ThreatPurpose | 含义（据官方说明翻译） | 是否对应 MITRE ATT&CK 战术 |
|---|---|---|
| `Backdoor` | 资源已被攻陷，并被改造为能连接攻击者的 C&C 服务器 | |
| `Behavior` | 活动偏离了资源的既有基线 | |
| `CredentialAccess` | 窃取密码、用户名、访问密钥等凭据 | ✔ |
| `CryptoCurrency` | 资源上运行着加密货币相关软件 | |
| `DefenseEvasion` | 规避检测 | ✔ |
| `Discovery` | 探查系统和内部网络 | ✔ |
| `Execution` | 试图运行或已经运行恶意代码 | ✔ |
| `Exfiltration` | 试图窃取数据 | ✔ |
| `Impact` | 试图操纵、中断或破坏系统和数据 | ✔ |
| `InitialAccess` | 攻击初期，试图获得进入环境的入口 | ✔ |
| `PenTest` | 活动特征与已知渗透测试工具（如 Kali）相似 | |
| `Persistence` | 试图维持访问，例如额外创建新的 IAM 用户 | ✔ |
| `Policy` | 账号行为违反安全最佳实践，例如使用 root 凭据、S3 被设为公开 | |
| `PrivilegeEscalation` | 提升权限 | ✔ |
| `Recon` | 侦察：端口探测、API 调用、枚举用户等 | |
| `Stealth` | 主动隐藏行为，例如使用匿名代理、关闭日志 | |
| `Trojan` | 使用木马程序 | |
| `UnauthorizedAccess` | 未经授权的人员在进行可疑活动 | |

> 说明：官方页面把这两个值写成 `Cryptocurrency` 和 `Pentest`，但实际发现类型中的写法是 `CryptoCurrency`、`PenTest`，例如 `CryptoCurrency:EC2/BitcoinTool.B!DNS`、`PenTest:IAMUser/KaliLinux` [S3]。在 EventBridge 中做前缀匹配时要区分大小写，以实际类型名为准。

### 2.3 官方 ThreatPurpose 列表之外的两种前缀

| 前缀 | 说明 | 来源 |
|---|---|---|
| `AttackSequence:` | Extended Threat Detection 把多个信号关联成一条攻击链，严重度均为 **Critical**。例如 `AttackSequence:IAM/CompromisedCredentials`、`AttackSequence:S3/CompromisedData`、`AttackSequence:EKS/CompromisedCluster`、`AttackSequence:ECS/CompromisedCluster`、`AttackSequence:EC2/CompromisedInstanceGroup` | [S3] |
| `Object:` | Malware Protection for S3 在对象中发现恶意文件：`Object:S3/MaliciousFile` | [S3] |

---

## 3. 按数据来源 / 保护计划分类

开启了哪些保护计划，就会收到对应的哪几类发现。官方的活跃发现类型总表就是按这个维度分组的 [S3]：

| 来源 | 需要开启 | 涉及资源 | 代表性发现类型 |
|---|---|---|---|
| CloudTrail 管理事件 | 基础检测（开启 GuardDuty 即包含） | IAM、S3（配置类） | `UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS`、`Policy:IAMUser/RootCredentialUsage`、`Stealth:IAMUser/CloudTrailLoggingDisabled`、`Policy:S3/BucketPublicAccessGranted` |
| DNS 日志 | 基础检测 | EC2 | `CryptoCurrency:EC2/BitcoinTool.B!DNS`、`Backdoor:EC2/C&CActivity.B!DNS`、`Trojan:EC2/DNSDataExfiltration` |
| VPC Flow Logs | 基础检测 | EC2 | `Recon:EC2/PortProbeUnprotectedPort`、`UnauthorizedAccess:EC2/SSHBruteForce`、`Backdoor:EC2/DenialOfService.Tcp`、`UnauthorizedAccess:EC2/TorClient` |
| 多个数据源关联 | Extended Threat Detection | 攻击链涉及的多个资源 | `AttackSequence:*`（Critical） |
| S3 数据事件 | S3 Protection | S3 | `Exfiltration:S3/AnomalousBehavior`、`Impact:S3/AnomalousBehavior.Delete`、`Discovery:S3/MaliciousIPCaller` |
| EKS 审计日志 | EKS Protection | Kubernetes | `CredentialAccess:Kubernetes/SuccessfulAnonymousAccess`、`Policy:Kubernetes/AdminAccessToDefaultServiceAccount`、`PrivilegeEscalation:Kubernetes/AnomalousBehavior.WorkloadDeployed!PrivilegedContainer` |
| 运行时代理 | Runtime Monitoring | EC2 实例、EKS、ECS、容器 | `Execution:Runtime/ReverseShell`、`PrivilegeEscalation:Runtime/RuncContainerEscape`、`Impact:Runtime/CryptoMinerExecuted` |
| EBS 卷扫描 | Malware Protection for EC2 | EC2、容器、ECS、Kubernetes | `Execution:EC2/MaliciousFile`、`Execution:Container/SuspiciousFile` |
| S3 对象扫描 | Malware Protection for S3 | S3 对象 | `Object:S3/MaliciousFile` |
| 备份扫描 | Malware Protection for Backup | EBS 快照、AMI、AWS Backup 恢复点 | `Execution:EC2/MaliciousFile!Snapshot`、`Execution:EC2/MaliciousFile!AMI`、`Execution:S3/MaliciousFile!RecoveryPoint` |
| RDS 登录活动、DB 活动 | RDS Protection | Aurora、RDS | `CredentialAccess:RDS/AnomalousBehavior.SuccessfulBruteForce`、`Exfiltration:RDS/MaliciousIPCaller`、`Impact:RDS/AnomalousBehavior.Drop` |
| Lambda 网络活动 | Lambda Protection | Lambda | `CryptoCurrency:Lambda/BitcoinTool.B`、`Backdoor:Lambda/C&CActivity.B` |
| Bedrock 调用 | AI Protection | IAM | `Impact:IAMUser/PromptInjection.Direct`、`Impact:IAMUser/CostHarvesting` |

官方还单独列出了 Custom Detection Rules 发现类型 [S3]，本文没有展开。

### 关于 `detail.service.featureName`

API 文档只定义它是“产生这条发现的功能名称”，**没有给出取值列表** [S7]。目前只确认过一个值：GuardDuty 生成的真实样例发现 `CryptoCurrency:EC2/BitcoinTool.B!DNS` 里是 `DnsQueryLogs` [样例]。如果要按这个字段路由，建议先生成对应保护计划的样例发现，确认实际取值后再写规则。按数据源分类时，用 `detail.type` 更可靠。

---

## 4. 按资源分类：`detail.resource`

`resourceType` 表示受影响资源的类型，API 文档同样没有给出取值列表 [S6]。按资源区分时，可以看 `resource` 下面存在哪个 `*Details` 子对象 [S6]：

| 子对象 | 对应资源 |
|---|---|
| `instanceDetails` | EC2 实例 |
| `accessKeyDetails` | IAM 用户或访问密钥 |
| `s3BucketDetails` | S3 桶（数组） |
| `eksClusterDetails`、`kubernetesDetails` | EKS 集群、Kubernetes 用户和工作负载 |
| `ecsClusterDetails`、`containerDetails` | ECS 集群、容器 |
| `ebsVolumeDetails`、`ebsSnapshotDetails`、`ec2ImageDetails`、`recoveryPointDetails` | 恶意软件扫描对象：EBS 卷、快照、AMI、备份恢复点 |
| `rdsDbInstanceDetails`、`rdsDbUserDetails`、`rdsLimitlessDbDetails` | RDS / Aurora 实例和数据库用户 |
| `lambdaDetails` | Lambda 函数 |
| `bedrockGuardrailDetails`、`modelDetails` | AI Protection 涉及的 Bedrock guardrail 和模型 |

本项目样例中实际出现过的 `resourceType` 值：`Instance`（EC2）、`AccessKey`（IAM）、`S3Bucket`（S3）[样例]。

---

## 5. 按活动类型分类：`detail.service.action.actionType`

每种活动类型都有对应的子对象，里面记录远端 IP、API 名称等细节 [S8]：

| actionType | 子对象 |
|---|---|
| `AWS_API_CALL` | `awsApiCallAction` |
| `DNS_REQUEST` | `dnsRequestAction` |
| `NETWORK_CONNECTION` | `networkConnectionAction` |
| `PORT_PROBE` | `portProbeAction` |
| `RDS_LOGIN_ATTEMPT` | `rdsLoginAttemptAction` |
| （Kubernetes API 调用） | `kubernetesApiCallAction` 等 |

`src/app.py` 就是根据 `actionType` 从对应子对象中取出远端 IP、国家和组织的。

---

## 6. 严重度：`detail.severity` [S2]

| 级别 | 数值范围 | 官方含义 |
|---|---|---|
| Critical | 9.0 – 10.0 | 攻击序列可能正在进行或刚刚发生 |
| High | 7.0 – 8.9 | 资源已被攻陷，正在被用于未授权用途 |
| Medium | 4.0 – 6.9 | 可疑活动偏离正常行为，可能意味着资源已被攻陷 |
| Low | 1.0 – 3.9 | 可疑活动的尝试，未造成攻陷，例如端口扫描 |

同一种发现类型的严重度会随上下文变化。总表中带 `*` 的类型就是可变严重度 [S2]、[S3]。

---

## 7. 推送频率（影响企业微信收到消息的节奏）[S5]

- **新发现**（新的 finding ID）：近实时发送到 EventBridge，频率不能修改。
- **同一发现的后续重复**：默认**每 6 小时**合并成一个事件发送。管理员账号可以改为 15 分钟或 1 小时，修改对成员账号同样生效。
- 被**抑制规则自动归档**的发现**不会**发送到 EventBridge；手动归档的发现仍会继续发送。

所以同一个 finding ID 可能被推送多次，`detail.service.count` 会逐次增加。

---

## 8. 在 EventBridge 规则中按分类过滤

EventBridge 支持对字符串做前缀匹配 `prefix`、对数值做范围匹配 `numeric` [S9]。官方也说明 finding JSON 中的任意属性都可以用于过滤 [S5]。

只推送挖矿和攻击链两类：

```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Finding"],
  "detail": { "type": [{ "prefix": "CryptoCurrency:" }, { "prefix": "AttackSequence:" }] }
}
```

本项目默认规则：Medium 及以上：

```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Finding"],
  "detail": { "severity": [{ "numeric": [">=", 4] }] }
}
```

多账号环境：只推送指定成员账号的发现：

```json
{ "source": ["aws.guardduty"], "detail": { "accountId": ["123456789012"] } }
```

---

## 9. 本项目样例事件对照 [样例]

| 文件 | `type` | ThreatPurpose | `resourceType` | `actionType` | `severity` |
|---|---|---|---|---|---|
| `attack_sequence_critical.json` | `AttackSequence:IAM/CompromisedCredentials` | （攻击序列） | AccessKey | – | 9.5 |
| `ec2_cryptomining_high.json` | `CryptoCurrency:EC2/BitcoinTool.B!DNS` | CryptoCurrency | Instance | DNS_REQUEST | 8 |
| `real_sample_bitcoin.json` | `CryptoCurrency:EC2/BitcoinTool.B!DNS` | CryptoCurrency | Instance | DNS_REQUEST | 8.0 |
| `iam_anomalous_medium.json` | `UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS` | UnauthorizedAccess | AccessKey | AWS_API_CALL | 5.0 ※ |
| `s3_policy_low.json` | `Policy:S3/BucketBlockPublicAccessDisabled` | Policy | S3Bucket | AWS_API_CALL | 2.0 |

※ 这条是为了测试 Medium 档位而构造的数据。官方总表中这个类型的默认严重度是 High [S3]。

---

## 来源

| 编号 | 文档 |
|---|---|
| S1 | GuardDuty finding format — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-format.html |
| S2 | Severity levels of GuardDuty findings — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_findings-severity.html |
| S3 | GuardDuty finding types（活跃发现类型总表）— https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-active.html |
| S4 | Extended Threat Detection — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty-extended-threat-detection.html |
| S5 | Processing GuardDuty findings with Amazon EventBridge — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_findings_eventbridge.html |
| S6 | API Reference: Resource — https://docs.aws.amazon.com/guardduty/latest/APIReference/API_Resource.html |
| S7 | API Reference: Service — https://docs.aws.amazon.com/guardduty/latest/APIReference/API_Service.html |
| S8 | API Reference: Action — https://docs.aws.amazon.com/guardduty/latest/APIReference/API_Action.html |
| S9 | EventBridge comparison operators — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-pattern-operators.html |

S4 只作为 S3 中攻击序列部分的延伸阅读，本文没有单独引用其中的内容。
