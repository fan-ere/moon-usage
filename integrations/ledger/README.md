# 本地账单存档应用

这是一个可以独立启动的 Python 命令行客户端，用来展示业务程序如何消费 moon-usage。Python 只负责文件读写、版本关系和两份已验证金额的精确差额；MoonBit 桥接包通过公共 API 完成全部计量、定价、快照创建和复算校验。桥接程序在 Node.js 下通过标准输入输出传输 JSON，核心库仍支持 Wasm、WasmGC、JS、Native。

示例数据、价格和账户均为虚构，不是第三方客户采用或生产账单证据。没有复制外部项目代码，不依赖收费服务或第三方 Python 包。

新增 `import-csv` 和 `report` 命令：可以导入自己的 CSV 和独立价目表，直接生成并阅读已复算的账单。完整数据格式、错误行为和一条命令复现见 [MVP 使用说明](../../docs/MVP.md)。`python scripts/verify_mvp.py _build/mvp-demo` 会保留可检查的账单、报告、差额及拒绝证据，输出目录必须不存在。

## 运行

前提：Python 3.10+、Node.js 与项目 README 对应 MoonBit 工具链均在 PATH 中。在仓库根目录执行以下 PowerShell 命令：

```powershell
New-Item -ItemType Directory -Force _build/ledger-demo
python integrations/ledger/ledger.py record integrations/ledger/fixtures/initial.json _build/ledger-demo/first.json
python integrations/ledger/ledger.py verify _build/ledger-demo/first.json
python integrations/ledger/ledger.py record integrations/ledger/fixtures/late.json _build/ledger-demo/late.json
python integrations/ledger/ledger.py compare _build/ledger-demo/first.json _build/ledger-demo/late.json
python integrations/ledger/ledger.py record integrations/ledger/fixtures/repriced.json _build/ledger-demo/repriced.json
python integrations/ledger/ledger.py compare _build/ledger-demo/late.json _build/ledger-demo/repriced.json
```

每次存档都会先计算并校验，然后以新文件创建，已有文件会报错，不会覆盖。重跑可换一个新目录；自动集成测试每次使用独立临时目录，无需清理上述文件。

## 输入与结果

| 文件 | 完整输入的变化 | 结果 |
| --- | --- | --- |
| fixtures/initial.json | 10 单位事件含一次重投；前 10 单位每单位 3 分，之后 2 分，基础费 5 分 | 去重后用量 10，费用 35 分；存档仍保留两次原始投递和未用到的第二档 |
| fixtures/late.json | 保留完整旧批次，加入迟到的 5 单位事件，输入版本改为 events-2 | 用量 15，费用 45 分；较前版增加 5 单位、10 分，列出新增事件 late |
| fixtures/repriced.json | 输入事件不变，价格版本改为 price-2，两档单价改为 2、1 分 | 用量 15，费用 30 分；较前版减少 15 分，标明价目表已改变 |

`record` 接受完整 BillInput JSON，结构见 fixtures；`verify` 读取档案原文并交给 MoonBit，保留对重复键的拒绝。归档同时保存输入、版本标签和账单；载入时从输入重新计算，任何账单字段与重算结果不一致即失败。

`compare` 首先验证两份归档，要求账户、计量项、周期、聚合方式和重置策略相同，并拒绝跨币种相减。原始事件变化必须更换 input_revision，完整价格变化必须更换 plan_revision；这些标签由调用方维护，不是数字签名。输出新增、删除和内容变化的原始事件 ID，以及用量和费用的有符号差额；重复投递本身的次数变化保存在各自账单计数中。

归档包含整批数据，事件差异也是整批差异，可能包含本计费周期外或其他账户的变化；不应把 ID 列表当作本周期收费归因。负差额仅供业务核对，不会发送退款或修改已结算账单。

## 验证与边界

```powershell
python integrations/ledger/test_ledger.py
```

12 项进程级测试覆盖首次存档、独立读取复算、迟到补算、改价重算、版本标签要求、事件删除与更正、改坏账单拒绝、不同上下文/币种拒绝、禁止覆盖和错误输入不落盘；另验证 CSV 导入和报告、冲突重投、CSV 格式与身份错误、未知配置及数字精度、累计表基线与重置策略。测试会实际运行 MoonBit，不用 Python 重写计价逻辑代替验证。

此客户端单个输入或归档文件最多 16 MiB；核心快照另有事件数、档位数和字符串长度限制。程序是本地单机命令行应用，未实现数据库事务、多进程结算协调、签名或访问控制；文件创建失败时不保留本次未完成归档。快照可以复算，不代表上游用量真实或文件不可伪造。业务应用需自行管理存储权限和已结算账单政策。
