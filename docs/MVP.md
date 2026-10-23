# 可运行的最小工作流

moon-usage 的最小交付是离线计量与计价库，以及一个能使用文件输入、输出账单和重新核算的本地客户端。用户是需要给 API 调用量、容量快照或累计读数出账的开发者；输入是事件和显式价目表，产物是包含完整原始输入、定价规则及计算明细的账单档案。

## 五分钟复现

需要 MoonBit、Node.js、Python 3.10+ 在 PATH 中，无第三方 Python 依赖，无账号或 API 密钥。以下命令从仓库根目录运行：

```sh
python scripts/verify_mvp.py _build/mvp-demo
```

指定目录必须不存在；重跑时换一个新目录。脚本通过真实客户端进程执行导入、出账、存档、独立载入、报告、迟到补算及改价比较。数据和价格均为虚构；客户端不将计算委托给网络服务。

| 可检查的产物 | 预期结果 |
| --- | --- |
| `initial.bill.json`、`initial.report.txt` | 两次相同投递去重，用量 10；10×3+5=35 分 |
| `late.bill.json` | 加入迟到 5 单位后用量 15；10×3+5×2+5=45 分；差额 +10 分 |
| `repriced.bill.json` | 完整输入重新按新价格计算：10×2+5×1+5=30 分；差额 −15 分 |
| `evidence.json` | 记录上述核对结果及冲突、未知配置、非法格式、被改动账单的拒绝原因 |

前三种非法输入应返回退出码 2，且不创建对应 `*.bill.json`。`tampered.bill.json` 是脚本主动构造的错误账单，读取报告时必须拒绝，不能当成有效账单展示。`passed: true` 表示这组行为与预期一致，不代表官方审核结果。

## 使用自己的数据

CSV 首行固定为 `id,account,meter,time,value`，UTF-8，可带 BOM，支持标准 CSV 引号。`time` 是非负 Int32 相对时间刻度，`value` 是非负整数用量；不要填日期、带小数的金额或 Unix 毫秒。保留相同 ID 的重投可验证幂等；同 ID 不同内容会拒绝。该入口只处理一个账户和计量项，行内身份必须与配置相同，避免意外漏算其他账户。累计表模式允许周期前基线和周期外读数，周期语义仍为 `[start,end)`。

复制 `integrations/ledger/fixtures/config.json`，填写账户、计量项、周期、输入/价格版本、聚合策略和全部价格档位。它是 `BillInput` 去掉 `events` 的完整配置；未知字段、未知枚举、重复键及非整数字面量拒绝，不静默使用默认计价策略。

```sh
python integrations/ledger/ledger.py import-csv integrations/ledger/fixtures/events.csv integrations/ledger/fixtures/config.json _build/my-bill.json
python integrations/ledger/ledger.py report _build/my-bill.json
python integrations/ledger/ledger.py verify _build/my-bill.json
```

输出文件的父目录应已存在，文件名不能已存在。报告显示账户、周期、版本、计量模式、去重计数、基线、重置次数、每档未舍入分数及总金额（最小货币单位）。每次报告都先在 MoonBit 中重新计量和计价并核对完整档案，校验失败不展示成功报告。精确分数不能直接当成每档已舍入应收额。实际收费单位与货币小数位由调用方定义。

迟到补算应导入完整旧事件和新增事件并更换 `input_revision`，改价应更换 `plan_revision`；新建档案后用 `compare` 对比，不覆盖旧档案。仅更改输入或价格标签不会证明数据来源真实。

## 责任与范围

MoonBit 实现全部事件校验、去重、四种计量、两种阶梯价、整数精度、快照、全字段复算、版本关系和有符号差额。Python 只处理 CSV、文件、进程通信和报告排版。核心 API 可绕过客户端直接调用；`python integrations/ledger/test_ledger.py` 验证真实进程边界，四目标核心测试覆盖计量和定价。多账户出账可使用 `capture_batch`，运行 `moon run examples/batch` 得到两份独立账单及按币种汇总结果；任一请求失败则整体返回错误。

本期未实现在线事件接收、数据库、并发结算、支付退款、税务发票、签名或生产运维。CSV 最多 100,000 行数据，文件最多 16 MiB；完整 JSON 接口和快照另有文档化限制。空 CSV 被拒绝；允许空用量出账的调用方可以显式使用完整 JSON/API（基础费仍可能收取）。复算只能证明输入与结果一致，不能证明用量真实。
