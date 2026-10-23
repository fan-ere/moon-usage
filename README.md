# moon-usage

[![MoonBit core](https://github.com/fan-ere/moon-usage/actions/workflows/ci.yml/badge.svg)](https://github.com/fan-ere/moon-usage/actions/workflows/ci.yml)

纯 MoonBit 离线用量聚合与阶梯计费库。输入带 ID 的用量事件、计费周期和价目表，输出用量、费用、参与事件与精确计价明细。仅依赖 MoonBit 标准库。

**直接体验 MVP：** 安装 MoonBit、Node.js、Python 3.10+ 后，在仓库根目录执行 `python scripts/verify_mvp.py _build/mvp-demo`（输出目录须不存在）。这会实际导入 CSV、出账、存档、读取复算、生成可读报告，并验证迟到补算、改价和错误拒绝。结果保存在指定目录，可直接打开账单、报告与 `evidence.json` 检查。完整操作和自有数据格式见 [MVP 使用说明](docs/MVP.md)。

## 已实现的工作流

| 使用者及输入 | 计算过程 | 输出 |
| --- | --- | --- |
| API 服务开发者提交请求计数事件，含重复投递 | 去重、按账户/计量项/周期隔离、求和、免费档与分段阶梯价 | 12,500 次调用，3,300 分，附每档数量与费用分子 |
| 存储服务开发者提交容量快照 | 取周期峰值、按整量所在档定价 | 峰值 120 单位，360 分；较晚的低读数不会覆盖峰值 |
| 设备平台开发者提交累计表读数、周期前基线与重置策略 | 排序、差分、明确处理读数回退，再计算费用 | 42 单位，336 分，记录基线与 1 次重置；严格策略拒绝同一输入 |

这些示例使用虚构数据和演示价格，不代表任何运营商或实际产品费率。

## 本地运行

前提：MoonBit 工具链，验证版本为 `moon 0.1.20261016` / `moonc v0.10.16+b1a0e846e`。JS 目标需要 Node.js，Native 需要 C 编译器。该项目尚未发布，不能从 Mooncakes 安装本包。

首次获取源码（公开仓库，无需登录）：

```sh
git clone https://github.com/fan-ere/moon-usage.git
cd moon-usage
moon run examples/demo --target wasm-gc
```

本机 PowerShell（复用已验证的工具链）：

```powershell
Set-Location D:\moonbit\moon-usage
$env:MOON_HOME = 'D:\moonbit\moon-usage\_build\toolchain-current'
$env:PATH = $env:MOON_HOME + '\bin;' + $env:PATH
moon run examples/demo
```

已把工具链加入 PATH 时，项目根目录执行：

```sh
moon check --deny-warn --target all
moon build --target all
moon test --deny-warn --target all
moon run examples/demo --target wasm-gc
moon fmt --check
moon info
```

演示的主要输出：

```text
API graduated: units=12500 total_minor=3300 currency=CNY
Storage peak: units=120 total_minor=360 currency=CNY
Device counter: units=42 total_minor=336 currency=CNY
Counter strict ERROR CounterDecreased("reset")
Conflicting retry ERROR DuplicateConflict("same")
```

## 调用 API

独立包的 `moon.pkg` 导入配置如下；在本地多模块工程中需先将模块解析到本目录，不要执行 `moon add` 下载一个尚未发布的包。项目内的 `examples/demo` 已演示真实的包边界调用。

```moonbit
import {
  "fan-ere/moon-usage" @usage,
}
```

```moonbit
let events : Array[@usage.Event] = [
  { id: "batch-1", account: "customer-a", meter: "requests", time: 11, value: 12500 },
]
let plan : @usage.Plan = {
  currency: "CNY", pricing: Graduated, rounding: HalfEven,
  per_units: 1000, base_minor: 100,
  tiers: [
    { up_to: Some(1000), rate: 0 },
    { up_to: Some(10000), rate: 300 },
    { up_to: None, rate: 200 },
  ],
}
let result = @usage.bill(events, "customer-a", "requests", 10, 20, Sum, plan)
// Ok(Bill): quantity=12500, total_minor=3300 (CNY 33.00).
```

| API | 职责 |
| --- | --- |
| `aggregate(events, account, meter, start, end, mode)` | 校验、去重、隔离、排序、聚合，返回 `Result[Usage, UsageError]` |
| `validate_plan(plan)` | 校验全部档位，包括本次不会用到的档位 |
| `rate(plan, quantity)` | 独立对已知用量计价，返回 `Result[Quote, UsageError]` |
| `bill(events, account, meter, start, end, mode, plan)` | 组合前两层，返回 `Result[Bill, UsageError]` |
| `Bill::to_json()` | 导出带模式、逐笔累计差分、事件来源和费用明细的 JSON 账单 |
| `capture(BillInput)` | 冻结完整原始输入、价目表、版本标签和计算结果，返回可复算快照 |
| `BillInput::from_string(text)` | 严格读取原始输入 JSON，拒绝重复键、数字精度丢失与过深嵌套；随后调用 `capture` 执行计量计价校验 |
| `Snapshot::from_string(text)` / `Snapshot::from_json(value)` | 校验快照版本与字段，重新计算并核对完整账单 |
| `Snapshot::replay()` | 使用已保存输入重新计算；返回 `Result[Bill, ReplayError]` |
| `compare_snapshots(before, after)` | 复算两份快照，校验上下文、币种和版本标签，返回精确有符号差额与事件增删改 |

完整公开接口见 [pkg.generated.mbti](pkg.generated.mbti)，算法与不变量见 [docs/DESIGN.md](docs/DESIGN.md)。

## 计量语义

- 周期为 `[start, end)`：包含 start，排除 end。时间是同一刻度的非负 `Int`，不解析日期、时区或账期。推荐使用调用方定义的相对时间刻度；`Int` 最大为 2,147,483,647，不可直接放 Unix 毫秒时间戳。
- 事件 ID 在整批输入内全局唯一；同 ID、全部字段相同视为重投，不重复计量；任何字段不同均拒绝。整个批次先校验，因此其他账户、其他周期的坏事件或 ID 冲突也会使本次计算失败。
- `Sum` 汇总增量；`Peak` 取峰值；`Last` 取周期内最后读数。空周期均为 0，不继承周期前的快照。Peak 和 Sum 允许同刻度多事件；Last 拒绝同刻度不同 ID 的多个读数。
- `Counter(policy)` 要求周期前严格早于 start 的最新读数作基线，按读数时间归属增量。start 处的读数算本周期第一笔差分，end 处的读数留到下一周期。即使周期无读数也必须提供基线。选中计量项在 end 前的任意同刻度多读数均拒绝，包括历史基线候选。
- Counter 不插值、不推断两个读数之间实际发生的用量；只有基线且周期内无读数时输出 0。跨周期差分可能包含 start 前发生的用量，这是一种“增量归属到读数时刻”的约定，不是连续时间积分。调用方必须确认适合其业务。
- `RejectDecrease` 拒绝回退；`RestartAtZero` 将回退后的值作为重置以来增量并计数。该策略假设归零重置，不适用于自然溢出或未知换表偏移；无法恢复最后读数到重置之间未观测的消耗。
- 输出事件按 `(time, id)` 排序；不修改输入。`accepted_events` 和 `duplicate_events` 仅统计本周期匹配项；基线单独列在 `baseline_id`，不计入上述两项。
- `Usage.aggregation` 保留聚合模式及累计表策略。`counter_deltas` 为每笔累计表读数记录 ID、时间、前值、当前值、差分和是否重置；重复投递不重复产生明细，零差分及归零重置仍保留。普通聚合返回空差分数组。

## 定价与精度

- `rate` 是每 `per_units` 个用量单位对应的最小货币单位数。例：CNY 下 `rate=300, per_units=1000` 表示每千单位 300 分。
- `Graduated` 将各档覆盖的数量分别计价；`Volume` 用总量所在档的单价计算全部数量。上界包含在当前档：上界 10 时数量 10 属于第一档，11 才进入下一档。整量价可能在跨档时总费用下降，这是该模式的定义。
- 档位上界严格递增且为正，只有最后一档可为 `None`，且必须如此。0 费率表示免费档。零用量仍收基础费；Graduated 返回空用量明细，Volume 返回首档的零用量明细。
- 用量和费率范围均为 `0..1,000,000,000`，`per_units` 为 `1..1,000,000,000`，基础费同样限制为 `0..1,000,000,000`。超出范围返回错误。较细单位由调用方按比例编码，量纲必须一致。
- 使用 `Int64` 累加全部用量费用分子，再除以共同分母、只舍入一次，最后加整数基础费。支持向下、向上、银行家舍入。每条明细保留未舍入分子，没有可能与总额不一致的“逐条舍入金额”。
- `currency` 是非空标签，货币小数位与单位解释由调用方负责；本库不校验 ISO 4217，也不执行换汇、税、折扣、支付、退款或发票开具。

## JSON 账单导出

```sh
moon run examples/export
```

成功账单可调用 `bill.to_json().stringify(indent=2)` 导出，顶层 schema 为 `moon-usage.bill.v1`。导出包含账户、计量项、周期、聚合和重置策略、事件 ID、基线、逐笔累计差分，以及定价方式、舍入模式和费用明细。演示的 30 单位增量加 4 单位重置读数，共 34 单位，费用 272 分。

`usage_numerator`、`usage_minor`、`total_minor` 和每条费用 `numerator` 都用十进制**字符串**，以保留超过 JavaScript 安全整数范围的 Int64 精度；有界的数量、费率、分母、基础费和时间仍为 JSON 数字。无基线或无重置策略时字段为 null，明细为空时为 []。JSON 对象键的顺序不属于接口约定。

这是给上层存储和展示使用的结构化导出，不提供 JSON 导入或账单真实性校验。公开结构可以由调用方自行构造，序列化不代表重新校验该结构。导出保留输入中的账户与事件标识，实际分享时由调用方决定这些标识是否适合公开。

导出包含计算明细，但不包含全部原始事件与完整价目表快照，不能仅凭此 JSON 独立重放整个计算。需要复算的应用应另行保存原始输入、价目表及其版本。

## 完整输入快照与离线复算

需要独立复算时使用新增的 `Snapshot`，其 schema 是 `moon-usage.replay.v1`，计算规则版本为 `moon-usage.rules.v1`；原有 `Bill::to_json` 的账单格式保持不变。

```moonbit
let input : @usage.BillInput = {
  input_revision: "events-1", plan_revision: "price-1",
  events, account: "customer-a", meter: "requests",
  start: 10, end: 20, aggregation: Sum, plan,
}
let snapshot = @usage.capture(input).unwrap()
let saved_text = snapshot.to_string() // 交给上层文件或数据库保存
let restored = @usage.Snapshot::from_string(saved_text).unwrap()
let recalculated = restored.replay().unwrap()
```

快照保留**整批原始事件**（含重复投递及其他账户的事件）、全部价目表档位、周期、聚合/回退政策、输入与价格版本标签，以及完整账单。保存原始顺序是为了保留整批校验语义；修改调用方的事件或价目表数组、修改导出的 JSON，不会改变已有快照。载入时重新调用计量和定价逻辑，比较全部账单字段，拒绝旧金额、被改动的明细、未知 schema/规则版本、缺失或多余字段、非法枚举及非法计价输入。

文本载入显式拒绝重复 JSON 键；数量、时间、费率等数字必须为普通非负整数字面量，不接受小数或指数写法，避免浮点解析把极小小数差异吞掉。`from_json` 接受已解析对象，调用方若自行解析应保留数字原文并拒绝重复键；推荐直接用 `from_string`。快照限制为 100,000 条事件、4,096 档、16 Mi 个字符串代码单元，文本解析深度最多 64；这些是快照层的资源边界，不改变原聚合 API 的能力范围。

快照验证证明“这组输入按本版本规则能产生此结果”，不证明输入真实或文件未被恶意改写。版本是调用方标签；同时改写输入与对应结果仍可通过一致性核对。本期不提供签名、可信时间或账单授权。

独立的 [本地账单存档应用](integrations/ledger/README.md) 通过标准输入调用 MoonBit 桥接程序，实际完成文件存档、读取复算、迟到事件补算和价目表变更比较。Python 只处理文件、版本关系和已验证金额之间的整数差额，费用仍由 MoonBit 核心计算。示例中首次费用 35 分，迟到事件补齐后 45 分，换价后 30 分；比较分别得到 +10、-15 分。它是可运行的接入示例，数据为虚构，不声称已有外部客户或上游采用。

## 重放、边界与交付状态

这是无持久状态的批量计算库。去重只对本次完整输入生效；迟到事件应加入完整事件集后重算。调用方负责事件存储、跨批幂等、账单版本、已结算账单调整及费用授权。禁止把多个分批账单直接相加冒充完整账单，阶梯价和单次舍入通常不具可加性。

纯函数不读取系统时钟、不访问网络、不发送收费请求。成功输出代表输入在本模型内可计算，不证明上游用量真实或账单合法。采用哈希索引时，批量校验预期 O(n)、周期内 k 个事件排序 O(k log k)、定价 O(t)，空间 O(n+k+t)。所有模式只排序本周期匹配事件；累计表在扫描历史时选择最新基线，以时间索引检测全部历史歧义，无需对历史排序。仍会校验整批输入。分段计费达到总用量后停止拆档，完整价目表仍预先验证。CSV 和文件 IO 由本地客户端负责，不属于纯函数核心；客户端有输入规模限制，但不提供进程级恶意输入资源隔离。此处为算法分析，未测量具体提速倍数。

来源与查重见 [SOURCES.md](SOURCES.md)。源码采用 MIT。GitHub 源码仓库 [fan-ere/moon-usage](https://github.com/fan-ere/moon-usage) 已公开，可匿名克隆。CI 提供 check/build/test、接口检查和四目标示例结果核对，实际结果以对应提交的 GitHub Actions 为准；尚未发布 Mooncakes，本地测试与源码上传不代表初审或官方验收通过。

申报书与内部验证记录仅保留在本地，已列入 `.gitignore`，不属于仓库源码交付内容。

使用 Python 3 可在本地执行与 CI 相同的演示结果核对：`python scripts/verify_examples.py`。脚本在四个目标上运行两个示例，将文本与已记录输出比较，将 JSON 与完整参考对象比较（不依赖对象键顺序），避免示例虽然成功退出、实际结果却发生漂移。

独立应用的集成检查：`python integrations/ledger/test_ledger.py`，需要 Python 3、Node.js 与 MoonBit。测试在临时目录通过真实进程执行文件存档、复算、改价、拒绝旧版本标签、拒绝改坏的文件和拒绝覆盖旧账单；不写入生产数据。
