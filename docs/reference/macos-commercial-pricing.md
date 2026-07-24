# macOS 商业版计费方案

> 状态：首版商业模型决策，价格仍可在实际创建 App Store Connect 记录前调整。  
> 制定日期：2026-07-22。Apple 协议、费率、税务和价格点可能变化，上架前必须再次核对。  
> 适用范围：Mac App Store 首版；Developer ID 商店外收费另行决定支付渠道。

## 决策摘要

后续独立品牌版的 Mac App Store 首版采用“免费基础功能 + 一项非消耗型内购买断”：

```text
App 免费下载
  ├─ 免费：保留原版逐行/多段生成能力
  │    用户粘贴完整文本，应用自动拆分并逐段生成多个音频文件
  │    用户不需要预先自己分行
  └─ ¥68 一次买断“长文本与变速扩展包”
       自动组织长文本并最终交付一个完整 WAV
       解锁 0.01–2.50 保持音调变速
```

暂定商品：

| 项目 | 决策 |
| --- | --- |
| App 下载价格 | 免费 |
| 内购类型 | 非消耗型，一次购买、不随使用次数减少、不过期 |
| 暂定中文名 | 长文本与变速扩展包 |
| 暂定英文名 | Long-form & Speed Pack |
| 中国区建议价格 | `¥68` |

实际价格必须从 App Store Connect 当时提供的价格点中选择。建议以中国区作为基础地区，让 Apple 自动生成
其他销售地区的等值价格；除非有明确市场理由，不逐国手工维护汇率和税价。

## 免费版与付费版的准确边界

免费版不是需要用户手工拆分文本的残缺版本。用户可以把完整文本粘贴进原版逐行/多段生成路径，
应用会自动拆分并逐段生成多个音频文件。免费版保留：

- 自定义声音、声音设计和声音克隆；
- Speed 与 Quality 模型选择；
- 普通单段生成；
- 粘贴完整文本后由原版路径自动拆分、逐段生成多个音频文件；
- 原速 `1.00` 输出；
- 模型下载、历史记录、保存声音、输出目录和 10 种界面语言。

`¥68` 扩展包只解锁我们新增的两个产品能力：

1. **长文本完整 WAV：** 用户一次提交完整文稿，应用内部自动规划、分段、顺序生成、校验、合并，
   最终只交付一个完整 WAV，并及时清理过程文件；
2. **保持音调变速：** 解锁 `0.01–2.50` 手填语速，使用 FFmpeg `atempo` 对最终音频进行保持音调的变速。

因此付费价值不是“替用户拆分文本”。原版已经会自动拆分并输出多段；付费价值是把完整长稿自动整理成
一个最终 WAV，并提供复刻 Windows 行为的高质量变速。

## 为什么选择免费 App + 非消耗型买断

### 与产品成本结构一致

当前语音生成发生在用户自己的 Apple Silicon Mac 上，开发者不承担每次生成的 GPU、带宽或推理 API 成本。
模型由用户主动下载，本地文稿、参考声音和输出音频不需要上传到自建服务。因此没有足够理由按月持续收费。

### 不需要服务器

内购通过 StoreKit 和 Apple 签名交易完成，本机可以读取当前有效权益。首版仍不需要：

- 用户注册和登录；
- 授权码或许可证服务器；
- 自建支付页面；
- 订阅状态服务器；
- 按字数计量和点数余额数据库。

App 需要实现购买入口、Apple 签名交易验证、购买状态监听和“恢复购买”，但这些均可在本机通过 StoreKit 完成。
Apple 负责商店收款、全球货币展示、基础税价处理和退款渠道。

### 用户价值容易理解

用户先用免费路径确认模型、声音和本机性能确实可用，再决定是否为自动合成完整 WAV 和变速买断。
一次买断能清楚表达：

- 长文本不会因为字数增加而产生额外账单；
- 生成失败和重试不会扣点；
- 用户离线时仍能使用已经下载的模型；
- 助眠故事等高频长稿场景可以预测成本。

扩展包购买一次后不限文稿字数、生成次数或变速次数，也不把两个功能继续拆成多个商品。
已购买用户应获得这两个功能的修复、安全更新和兼容性更新。

## Apple 抽成与收入估算

符合条件并主动加入 App Store Small Business Program 后，App 内购买的佣金率为 15%。
资格通常要求开发者及关联账号上一年度和当前年度的 App Store proceeds 不超过 100 万美元；超过门槛后按
Apple 当时适用的标准费率处理。未加入或不符合条件时，不能按 15% 估算。

忽略税费、汇率、退款和其他调整，仅用于理解量级：

| 用户价格 | 按 15% 佣金粗算 | 按 30% 标准佣金粗算 |
| ---: | ---: | ---: |
| `¥68` | `¥57.80` | `¥47.60` |

实际 proceeds 的计算是“用户价格减去适用税费和 Apple 佣金”，不能把上表当成结算承诺。
退款、汇率、银行费用和开发者所在地税务也会影响最终到账。

## 上架前必须完成的财务配置

1. 保持有效的付费 Apple Developer Program 会员；
2. 由 Account Holder 在 App Store Connect 签署最新 Paid Apps Agreement；
3. 填写并通过银行账户验证；
4. 按账号所在地提交 Apple 要求的税务表格；
5. 确认是否符合并申请 App Store Small Business Program；
6. 在 App Store Connect 创建一个非消耗型内购商品；
7. 为内购选择基础地区、`¥68` 对应价格点和销售地区；
8. 以公司组织身份完成开发者账号和卖家主体核验，确保收款、税务和商店展示主体一致。

Apple 通常在对应财务月结束后 45 天内向满足门槛且资料有效的银行账户付款，具体以当期协议和
App Store Connect 财务报告为准。

## 版本升级和未来收费

### 首版承诺

- `1.x` 的错误修复、兼容性和现有功能完善不重复收费；
- 以后调整扩展包价格，已经购买的用户不补差价；
- 不在宣传中写“终身包含所有未来版本”；
- 不因用户生成次数多而降低功能或改为扣点。

### 大版本选择

如果未来出现真正独立的大版本，例如新的模型体系、云同步或团队协作，应在当时重新选择：

- 继续为现有买断用户免费升级；
- 以非消耗型 App 内购买销售明确的新功能包；
- 发布新的独立 App，并为老用户提供合理迁移或优惠安排。

同一个非消耗型商品不会因为 App 版本号从 1 升到 2 而再次向已购买用户收费，因此不能把升级版本号本身
当成重复收费机制。

## 内购实现合同

- 商品类型必须是非消耗型，不得按生成次数消耗；
- 免费版始终保持可用，商品加载失败不能阻止原版生成；
- 只有用户主动选择长文本完整 WAV 或输入非 `1.00` 语速时才展示购买入口；
- 不锁整个“批量生成”入口，原版自动拆分并生成多段的路径永久免费；
- 购买成功后立即刷新权益，无需重启 App；
- 设置页和购买页均提供“恢复购买”；
- 使用 StoreKit 验证后的 `Transaction.currentEntitlements` 作为权限依据；
- 监听退款或撤销后的权益变化；
- 已验证权益需要支持合理的离线启动，不因短暂断网反复锁定；
- 首个非消耗型内购必须随对应 App 版本一起提交审核；
- 审核备注要提供免费路径、购买路径、恢复路径和两个付费功能的完整步骤。

## 暂不采用的方案

### 整款 App 付费下载

该方案会让用户在验证模型下载、本机速度和声音质量之前先付款，也无法突出我们真正新增的长文本完整 WAV 和变速价值。

结论：不采用。App 免费下载，原版自动拆分生成多段的能力永久免费。

### 自动续订订阅

订阅适合持续提供云服务、内容更新或运营服务的产品。当前本地 TTS 没有开发者侧的持续推理成本，强行订阅会增加
用户阻力、续订管理、退款支持和审核说明。

结论：当前不采用。以后增加有真实持续成本的云同步或团队服务时重新评估。

### 按字数、按分钟或点数收费

这种模式适合开发者支付云端推理成本的服务。当前计算发生在用户电脑上，按次收费既缺少成本依据，也需要账号、
计量、防篡改、余额和客服系统。

结论：不采用。

### 官网付款 + 许可证密钥

商店外 Developer ID 版本可以将来使用第三方支付和许可证系统，但通常需要授权服务、离线授权策略、设备迁移、
退款、税务和更新服务。用户目前没有服务器，本阶段不应为此扩张范围。

结论：Mac App Store 首版不采用；官网商业版以后单独立项。

## 退款、客服和隐私边界

- Mac App Store 订单由 Apple 收款，退款由 Apple 的流程处理；
- 应用需要提供真实可用的支持邮箱和支持网站；
- 不收集用户文稿、参考声音或生成音频来完成计费；
- 不需要为了验证购买建立用户画像或上传设备标识；
- 提供恢复购买和清晰的退款支持入口；
- 商店描述必须明确模型需要额外下载、所需磁盘空间、最低 macOS 要求，以及
  **Apple Silicon Mac + 至少 16 GB 统一内存**的产品支持下限。

## 上线后的价格复盘

首发后先观察以下指标，不急于加入复杂收费：

- 免费用户触发付费功能到购买的转化率；
- 退款率及主要退款原因；
- 模型下载完成率；
- 首次成功生成率；
- 真实长文本完成率；
- 支持工单中关于价格、试用和订阅的反馈；
- 各地区销量和实际 proceeds。

`¥68` 先作为稳定价格运行，不设置首发涨价日程。如果转化健康且退款原因主要不是价格，保持价格不变；
只有在功能范围或市场证据发生明显变化时才重新评估价格，不直接转成订阅。

## 官方依据

- [Apple：选择商业模式](https://developer.apple.com/app-store/business-models/)
- [Apple：设置 App 价格](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price)
- [Apple：App 定价与 proceeds](https://developer.apple.com/help/app-store-connect/reference/pricing-and-availability/app-pricing-and-availability/)
- [Apple：App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/)
- [Apple：签署 Paid Apps Agreement](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)
- [Apple：提交税务信息](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information)
- [Apple：收款概览](https://developer.apple.com/help/app-store-connect/getting-paid/overview-of-receiving-payments/)
- [Apple：App 内购买类型](https://developer.apple.com/in-app-purchase/)
- [Apple：购买验证方式](https://developer.apple.com/documentation/storekit/choosing-a-receipt-validation-technique)
- [Apple：配置 App 内购买](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)
- [Apple：恢复购买](https://developer.apple.com/documentation/storekit/offering-completing-and-restoring-in-app-purchases)
