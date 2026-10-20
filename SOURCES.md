# 来源、选题与有限查重

检索日期：2026-10-20（Asia/Shanghai）。本记录支持本地选题，不保证全网唯一、报名获批或最终验收通过。

## 需求、独立性与边界

API 增量事件、存储容量快照、设备累计读数具有不同聚合语义，却都需要将指定账户的周期用量转为可复查费用。本期交付包含批量事件一致性、去重、四种聚合、累计读数重置政策、两种阶梯价、统一舍入和原始事件/费用明细的完整计算链路。

该模块与本机 postal 地址规则、CoAP、GTFS、电子发票及维护窗口项目无源代码或业务模型依赖。未将一个旧项目拆成多个模块。它解决用量归集与定价语义，不承担币种运算、支付、发票及物流业务规则。

## 检索范围

- 实时读取 [Mooncakes modules API](https://mooncakes.io/api/v0/modules)，当次响应 3,143 条模块记录。扫描 name/description/keywords，覆盖 `usage, meter, metering, billing, tariff, pricing, subscription`，并额外核查约束求解方向。相关摘要保存于 `docs/registry-neighbors.json`，其中 meter 等词会命中参数、传感器等无关记录，不能把命中数当同类数。
- GitHub 仓库搜索 API：`moonbit billing` 返回 2 项；`moonbit tariff`、`moonbit metering`、`moonbit usage pricing` 各返回 0 项。
- 扩展查询 `language:MoonBit (metering OR tariff OR "tiered pricing" OR "usage billing")` 返回 0；`moonbit graduated volume pricing` 返回 0；这两次响应 `incomplete_results=false`。
- `moonbit usage billing in:readme` 返回 39 项，本次只检查返回的首 30 条元数据，多数是综合清单或含泛化词汇的项目；额外核读 `daqing/moon-pay-sdk` 的 `README.mbt.md`、根接口和 `wechat/client.mbt`，其已给定金额的支付订单流程与本库的用量定价责任不同。不能据此排除所有支付项目中含有计费能力。
- 这是名称、描述、关键词及有限 README 检索，不是 GitHub 全量代码检索。未覆盖未索引、私有、未发布、非英文描述的全部项目，也未穷举社区讨论。

GitHub 查询可通过 `https://api.github.com/search/repositories?q=<URL编码关键词>` 重现，结果会随时间变化。

## 相邻项目比较

| 项目与观察日期的维护状态 | 真实覆盖及核读材料 | 本期区别与关系 |
| --- | --- | --- |
| [haol-05/moonmoney](https://github.com/haol-05/moonmoney)，Apache-2.0，未归档，pushed_at=2026-10-16T08:31:41Z | README 及调用示例、根 `pkg.generated.mbti`、`money.mbt`。`Money::of_minor`、币种模型、舍入、税务、分配及换汇 | 金额舍入存在基础能力交集，不宣称原创；未在所读 API/源码发现事件去重、周期聚合及用量阶梯模型。本库输出最小货币单位，未复制或依赖上游；金额格式化等应交给金额库，本期未宣称上游扩展或完成互操作测试 |
| [xvkong834/moonbit-freight-calculator](https://github.com/xvkong834/moonbit-freight-calculator)，MIT，未归档，pushed_at=2026-08-24T13:29:14Z | README、示例、根 `pkg.generated.mbti`、`engine.mbt`。输入包裹、重量、分区、保价，输出运费与附加费用；另有结算等功能 | 都有档位/整数费用/明细，不能说完全无重叠。该项目核心为单包裹物流报价；本库新增完整的用量事件生命周期计算语义。未复用其代码或价目表，也未把已有运费算法换名宣称独创 |
| [vectie/moongate](https://github.com/vectie/moongate) | 核读 `README.mbt.md`、根接口、`usage_preview/pkg.generated.mbti`、`cost.mbt` 的成本计算与 `usage_preview/price.mbt`。含请求合并、过滤、LLM token 成本及用户指定 USD 单价情景重估 | 与用量导入、统计、按费率估算存在实质部分重叠，不能称为没有同类。所读 `price_usage_file_json` 明确只支持输入/输出 token 平价，注明不支持请求、阶梯、税等规则。本库的可验证增量是通用快照/累计表语义、重置策略及完整的分段/整量阶梯模型；没有依赖、移植或上游协作关系，也不宣称对整个仓库进行了审计 |
| [daqing/moon-pay-sdk](https://github.com/daqing/moon-pay-sdk) | README 与示例、根接口、`wechat/client.mbt`。微信/支付宝下单、查询和回调，传入已算好的整数金额 | 支付集成可作为应用的下游责任；本库不发送支付请求，未与其集成，输入事件到应计金额的责任不同 |

初始候选“有限域约束求解器”发现 [cn-xjr/MoonPlan](https://github.com/cn-xjr/MoonPlan) 与 [mjfmjf879/moonbit-constraint](https://github.com/mjfmjf879/moonbit-constraint) 已覆盖有限域建模、约束、搜索和排班。核读前者 README/示例/公开接口，后者元数据/公开接口后放弃该候选，未创建另一个同类求解项目。

**结论：** 存在部分重叠，独立申报价值仍须评审核定；不能以本库拼成完整链路为唯一独立性理由。新增责任由累计表及峰值计量、显式重置政策、分段与整量阶梯 API 和对应测试举证。有限范围未发现相同的通用模型实现，但未证明整个生态不存在；正式申报应继续比较相邻库的最新能力、评估上游扩展或协作。独立代码和更方便的 API 本身不构成过审依据。本次可以完成本地工程交付，不将技术测试替代选题初审。

## 概念参考与许可

- [Stripe：Usage-based billing](https://docs.stripe.com/billing/subscriptions/usage-based) 与 [tiered pricing](https://docs.stripe.com/billing/subscriptions/usage-based/pricing-models#tiered-pricing) 为进一步核对业务术语的公开参考链接；本次未抓取或逐项验证其当前页面。项目采用 README 明文定义的 Graduated、Volume 语义，不宣称 Stripe API/账单兼容，不使用其 SDK 或数据。
- 半偶舍入、累计表差分及阶梯分段属于通用数学/业务方法，不主张算法发明。实际规则由本项目文档与测试定义。
- 当前 `.mbt` 为本次独立编写；未移植第三方源文件、测试套件、币种表或商业价格数据。全部样例为手工构造的虚构 ID、读数和价格。源码 MIT，标准库使用 MoonBit 工具链自带版本。
- `registry-neighbors.json` 是公开注册表 name/description/repository 的检索摘要，用于调查记录，不是本库运行时数据库，不应视为权威完整目录。

## 赛事材料来源的待确认项

本地流程依据 `D:\moonskill\moonbit-contest-projects\SKILL.md` 及其 2026-10-16 口径摘要。摘要包含历史材料，不能当本次实时核验的最新章程。

本次访问摘要所列微信链接 `https://mp.weixin.qq.com/s/dzzs7ElnW5WhwVW-8qwa5g`，实际返回标题“7.5 万元奖金！MoonBit 黑客松奖励升级，9月报名延期，秋招机会同步来袭！”，正文含九月报名延长至 9 月 30 日、十月起支持最多 3 人组队及每人单独提交申请的旧说明。它与本地摘要给出的十月标题、材料提交口径不完全一致，不能用这个链接验证摘要内全部十月规则。本次不修改技能或记忆，不据此推断新的统一截止日期。

后续增加累计读数差分证据、JSON 导出并减少普通聚合不必要的历史排序；这些改进不改变上文生态重叠判断。源码上传与申报材料分开，申报书仅保留本地供参赛者人工核对、改写，不进入源码仓库。尚未执行报名或 Mooncakes 发布。正式参赛前应向官方确认当期章程、报名额度和组队提交口径。
