# macOS 商业分发与 Mac App Store 可行性评估

> 状态：商业化预研记录，不是正式法律意见，也不授权启动 Mac App Store 改造。  
> 核对日期：2026-07-22。Apple 审核规则、模型许可和依赖许可可能变化，发布前必须重新核对。
> 当前开发范围：macOS 长文本、完整 WAV 和保持音调的语速控制。
> 暂缓事项：iOS、Mac App Store 沙盒化和收费系统。

实施拆分见[macOS 商业化与 Mac App Store 实施路线](macos-commercialization-roadmap.md)，首版收费决策见
[macOS 商业版计费方案](macos-commercial-pricing.md)。

## 结论

| 问题 | 当前结论 |
| --- | --- |
| 能否修改 Vocello/QwenVoice 后商业销售 | 可以。项目根许可证是 MIT，明确允许使用、修改、发布、分发、再许可和销售 |
| 修改后是否必须公开源代码 | MIT 不要求公开修改后的源代码；但必须保留原版权和许可文本 |
| 当前使用的 Qwen3-TTS 模型能否商业使用 | 当前六个生产模型页面均标注 Apache-2.0，原则上允许商业使用，但需履行模型许可和声明义务 |
| 当前 macOS 构建能否原样提交 Mac App Store | 不能。当前应用明确关闭 App Sandbox，而 Mac App Store 要求应用适当沙盒化 |
| 当前 macOS 构建能否在商店外收费分发 | 可以作为首选候选。现有 Developer ID 签名、公证和 DMG 流程就是商店外分发路线 |
| 汉化、更多语言和长文本是否妨碍商业化 | 不妨碍；长文本还是有实际价值的功能增强，但它们不会自动解决沙盒、品牌和审核合规问题 |
| FFmpeg 语速组件能否随商店外收费版分发 | 已建立独立 LGPL-only helper、对应源码、许可证、SBOM 和签名检查；仍应在实际收费发布前做最终法律审查 |
| 当前 App 是否已经包含全部第三方许可引用 | 没有。包含 helper 的签名测试包只完整携带 FFmpeg 声明；项目根 MIT、内化运行时、Swift 依赖和 Qwen3-TTS 模型声明仍需汇总进正式许可页面 |
| 上架前是否需要改应用名、Bundle ID 和图标 | Bundle ID 必须改为自己账号控制的唯一标识；应用名和图标从商标、独立品牌及 Apple 防换皮审核角度也应更换 |
| 首版如何收费 | App 免费；原版自动拆分并逐段生成多个音频文件的能力永久免费；长文本自动合并为一个完整 WAV 和保持音调变速以 `¥68` 非消耗型内购一次买断 |
| 个人 Apple 开发者账号能否销售 | 付费 Apple Developer Program 个人会员可以；免费 Personal Team 不具备商业分发资格 |

因此必须区分两个判断：

1. **许可证是否允许卖：允许。**
2. **当前技术形态是否能进 Mac App Store：不能原样进入，需要单独的沙盒化工程。**

## 当前产品范围

现阶段只实现以下用户合同：

```text
用户一次提交约 13,000–18,000 字
  -> 应用内部自动规划和分段
  -> 顺序生成并逐段校验
  -> 有界合并
  -> 对完整 WAV 执行一次可选的保音高变速
  -> 原子发布一个完整 WAV
  -> History 中接受一个最终成品
  -> 立即清理分段 WAV 和临时过程文件
```

“一次性生成”指一次用户任务和一个最终产物，不表示把整篇文稿塞进一次模型推理。语速为 `1.00` 时完全旁路；
其他速度对合并后的完整 WAV 执行一次 FFmpeg `atempo`。成功任务最终只保留完整 WAV、History 记录和必要的小型摘要元数据；
过程分段仅在任务活动或确实需要恢复时短暂存在，不作为长期缓存。

长文本技术边界见[长文本生成](long-form-generation.md)和
[macOS 长篇叙事与语速控制评估](long-form-narration-tempo-assessment.md)。正式 FFmpeg 组件边界见
[macOS FFmpeg LGPL-only 正式发布组件](ffmpeg-lgpl-release-component.md)。

## 1. MIT 对商业销售的含义

项目根目录的 [`LICENSE`](../../LICENSE) 是 MIT License，版权声明为：

```text
Copyright (c) 2026 PowerBeef
```

MIT 明确允许取得软件副本的人：

- 使用和复制；
- 修改和合并；
- 发布和分发；
- 再许可；
- 销售软件副本。

商业版应至少做到：

- 在应用包或“开源许可”页面中保留原版权声明和完整 MIT 文本；
- 不删除或替换 `Copyright (c) 2026 PowerBeef`；
- 将自己的修改版权声明作为新增内容，而不是覆盖原声明；
- 保留 MIT 的免责声明；
- 不宣称原作者、贡献者或上游项目为商业版背书。

MIT 不要求商业版公开修改后的源代码，也不要求免费分发。

## 2. 根许可证不是全部许可

最终发行物还受到内化运行时、Swift 依赖、模型权重、图标、名称和其他素材权利的约束。

### 内化运行时

`Packages/VocelloQwen3Core` 包含源自 `mlx-audio-swift` 的代码，其历史来源许可证也是 MIT。
项目已经保留：

- [`Packages/VocelloQwen3Core/LICENSE`](../../Packages/VocelloQwen3Core/LICENSE)
- [`Packages/VocelloQwen3Core/NOTICES.md`](../../Packages/VocelloQwen3Core/NOTICES.md)
- [`Packages/VocelloQwen3Core/LINEAGE.json`](../../Packages/VocelloQwen3Core/LINEAGE.json)

商业包不得丢失这些来源身份和声明。

### Qwen3-TTS 模型

当前生产目录使用 `mlx-community` 的 Qwen3-TTS 1.7B 4-bit/8-bit 模型。核对时，以下六个页面均标注
Apache-2.0：

- Custom Voice：[4-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit) / [8-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit)
- Voice Design：[4-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit) / [8-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit)
- Voice Clone Base：[4-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit) / [8-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit)

Apache-2.0 原则上允许商业使用。当前应用让用户从 Hugging Face 下载模型，没有把权重打进安装包，
这比自行再分发权重简单，但仍建议在“开源许可”中列出模型名称、来源和许可证。

如果以后把模型放进安装包或迁移到自己的服务器，必须在行动前重新核对每个精确模型修订的许可证、NOTICE、
来源声明和再分发条件，不得仅凭今天的模型卡结论长期假设授权不变。

### 其他依赖

MLX/MLX Swift 当前为 MIT，但完整应用还包含 GRDB、Swift Hugging Face、Swift Transformers、Swift NIO 等
传递依赖。仓库发布流程会生成 SPDX 和 CycloneDX 清单，但 SBOM 不是法律结论；正式收费发布前仍需对每个锁定版本
完成许可证和 NOTICE 审计，并生成随应用交付的第三方许可集合。

### FFmpeg 语速组件

正式 macOS 包不复制 Homebrew 或 Windows 的完整 FFmpeg，而是从固定 FFmpeg 8.0.3 官方源码构建独立
`Contents/Helpers/ffmpeg-vocello`。它只开放本地 WAV、PCM16 与 `atempo` 所需能力，明确禁用 GPL、nonfree、
version3、网络和外部库自动发现。App 内包含完整 LGPL 2.1、上游许可证、NOTICE 和构建身份；同一 GitHub
Release 提供精确对应源码、上游分离签名及构建清单，并纳入 SBOM、发布证据和 SHA-256 校验和。

这让闭源 Swift 主程序与 LGPL helper 保持独立进程和独立签名边界，但不是自动法律豁免。收费发布前仍需核对最终
用户协议不得限制 FFmpeg 许可证允许的权利，并由专业人士复核目标市场和实际销售方式。

### 当前发行物的许可引用实况

截至本次核对，不能把“仓库里存在许可证”理解成“最终 App 已经完整交付许可证”。实际状态如下：

| 项目 | 仓库中是否存在 | 当前 App/发布包状态 |
| --- | --- | --- |
| 项目根 MIT（PowerBeef） | 有：[`LICENSE`](../../LICENSE) | 尚未随 App 打包 |
| 内化 `mlx-audio-swift` MIT（Prince Canuma） | 有：[`Packages/VocelloQwen3Core/LICENSE`](../../Packages/VocelloQwen3Core/LICENSE) | 尚未随 App 打包 |
| 内化运行时来源说明 | 有：[`Packages/VocelloQwen3Core/NOTICES.md`](../../Packages/VocelloQwen3Core/NOTICES.md) | 尚未进入面向用户的许可集合 |
| SwiftPM 直接与传递依赖 | 构建锁定版本可追溯 | 尚未完成逐项许可审计和随包许可集合 |
| Qwen3-TTS 代码及模型来源 | 模型目录和不可变修订可追溯 | 尚未在 App 内列出 Apache-2.0、精确模型身份和来源 |
| FFmpeg LGPL helper | 有完整配置、构建脚本和声明 | 包含 helper 的签名测试包已完整携带；普通开发构建不携带 |
| SPDX/CycloneDX SBOM | 发布流程可生成 | SBOM 是组件清单，不能代替许可证正文、版权声明或 NOTICE |

包含 helper 的签名测试包当前实际携带：

```text
Vocello.app/Contents/Resources/ThirdPartyNotices/FFmpeg/
  NOTICE.txt
  COPYING.LGPLv2.1
  LICENSE.md
  BUILD-INFO.json
```

设置页“开源许可证”按钮目前只在上述 FFmpeg `NOTICE.txt` 存在时显示，并且只打开 FFmpeg 声明。
正式商业版需要把入口升级为统一的“开源软件与第三方许可”页面，至少覆盖项目根 MIT、内化运行时、
全部实际随包 Swift 依赖、Qwen3-TTS 模型身份以及 FFmpeg。

当前 FFmpeg 对应源码归档采用“与 Developer ID DMG 同一 GitHub Release 发布”的交付方式。Mac App Store
不会替开发者分发 DMG 的旁挂资产，因此商店版必须另外确定持续可访问、与二进制精确对应的 LGPL 源码交付方式，
并在实际上架前由专业人士复核 App Store 分发条款与 LGPL 用户权利是否兼容。

## 3. 品牌、名称和素材必须独立处理

MIT 主要授权软件代码，不能自动推定它已经授予以下所有权利：

- `Vocello` 或 `QwenVoice` 产品名称与潜在商标；
- 原项目图标、截图和宣传图片；
- 原作者或团队身份；
- 第三方音频、人物声音和示例素材。

商业版建议：

- 使用自己的产品名称、图标和商店宣传素材；
- 使用自己控制的唯一 Bundle ID；
- 使用自己的开发者账号、支持邮箱、网站和隐私政策；
- 在法律/许可页面中诚实说明基于 Vocello/QwenVoice、Qwen3-TTS 和 MLX；
- 不在商店名称、截图或描述中造成“原作者官方版本”的误解。

Apple 审核规则 4.1 和 5.2.1 会关注换皮、误导性名称、商标和第三方素材权利。汉化和长文本属于有意义的增强，
但不能代替独立品牌与完整素材授权。

### 当前身份与建议改造边界

当前 macOS 目标的外部产品身份是：

| 项目 | 当前值 | 上架前建议 |
| --- | --- | --- |
| 应用显示名/产品名 | `Vocello` | 更换为自己的独立品牌 |
| 主 Bundle ID | `com.qwenvoice.app` | 更换为自己开发者账号控制的反向域名标识 |
| XPC 引擎 Bundle ID | `com.qwenvoice.app.engine-service` | 使用新主 ID 的子标识并同步信任策略和签名合同 |
| App 图标 | `Sources/Assets.xcassets/AppIcon.appiconset` | 使用有完整权利证明的原创图标 |
| 应用数据目录 | `~/Library/Application Support/QwenVoice` | 改为新品牌目录，并为现有用户设计一次性迁移 |
| 调试偏好与日志 subsystem | 多处使用 `com.qwenvoice.*` | 产品身份相关项同步迁移；纯内部诊断名称可按风险分阶段处理 |

必须区分“商店身份”和“内部代码命名”：`CFBundleDisplayName`、`PRODUCT_NAME`、主/XPC Bundle ID、图标、
应用数据目录和面向用户的 `Vocello` 文案属于改造范围；`QwenVoiceCore`、Swift 模块名、源码目录和测试目标等
纯内部名称不需要为了上架一次性重命名。这样可以降低大范围重构风险。

Bundle ID 应在首次上传 App Store Connect 构建之前确定。Apple 明确说明首次上传后不能为同一个应用记录更换
Bundle ID；届时只能建立新的应用记录。应用名可以本地化且最长 30 个字符，但仍需要可用并不得造成商标或官方身份混淆。

## 4. 当前 Mac App Store 的明确阻塞项

当前 [`Sources/QwenVoice.entitlements`](../../Sources/QwenVoice.entitlements) 包含：

```text
com.apple.security.app-sandbox = false
com.apple.security.cs.allow-unsigned-executable-memory = true
com.apple.security.cs.disable-library-validation = true
```

[运行时安全与信任边界决策](../decisions/runtime-hardening-and-trust-boundary.md)明确说明，当前 MLX/Metal 与本地模型
工作流运行在 App Sandbox 之外。当前发布方式是 Hardened Runtime + Developer ID 签名 + Apple 公证。

Apple App Review Guidelines 2.4.5(i) 要求 Mac App Store 应用适当启用沙盒。因此当前构建不是一个可直接上传的
Mac App Store 候选。汉化、增加语言或完成长文本都不会改变这一事实。

未来如决定进入 Mac App Store，应建立独立发行目标并逐项验证：

- 主应用和 XPC 引擎的沙盒边界；
- MLX JIT/Metal 在商店沙盒和允许权限下的实际运行；
- 是否能够移除 `disable-library-validation` 和其他高风险权限；
- 模型、历史、音频和临时项目迁移到沙盒容器；
- 文件导入导出改用用户选择权限和安全作用域书签；
- 模型下载、取消、恢复、校验和删除全部只发生在允许的容器内；
- Mac App Store 更新、收据和付费逻辑与 Developer ID 版本隔离；
- 长文本 1、10、100 段以及真实 13,000–18,000 字任务的内存和稳定性证据。

在这些验证完成前，只能说“值得评估”，不能承诺一定通过 Apple 审核。

## 5. 模型下载的审核解释

Apple 规则禁止应用下载可执行代码来新增或改变功能，也要求初次运行需要下载额外资源时披露大小并征得用户确认。
当前项目对审核较有利的事实是：

- 下载的是 `.safetensors` 等模型数据，不是脚本、插件或独立可执行程序；
- 下载源、不可变修订、文件路径、大小和 SHA-256 由产品目录固定；
- 模型只有通过完整性校验后才能安装；
- 所有能力在提交审核的应用界面中已经存在，模型只为用户选定的本地推理能力提供数据；
- 应用会显示模型大小并由用户主动开始下载。

Mac App Store 候选需要在审核备注中清楚说明上述事实，并提供完整可复现的审核路径。Apple 仍可能根据
2.4.5(iv)、2.5.2 和实际行为作出独立判断，因此模型下载不能被写成“必然获批”。

## 6. 两条商业分发路线

### 路线 A：商店外收费分发

这是与当前技术架构最接近的路线：

1. 使用自己的付费 Apple Developer Program 账号和 Developer ID Application 证书。
2. 运行现有确定性发布检查。
3. 使用 Hardened Runtime 签名应用和 XPC 服务。
4. 提交 Apple 公证并装订公证票据。
5. 生成并验证 DMG、校验和、SBOM 和发布证据。
6. 通过自己负责的渠道销售和提供下载、更新、付款与售后。

Apple 的 macOS 分发说明明确区分两条路线：Mac App Store 强制沙盒；Developer ID 商店外分发只建议沙盒。
项目当前 [macOS Release QA](macos-release-qa.md) 和 `scripts/release.sh` 已经服务于 Developer ID + 公证 DMG。

这条路线仍需要新增商业层工作，例如独立品牌、最终许可页面、付款交付、更新策略、退款/支持政策和目标地区合规；
这些不属于当前长文本开发阶段。

### 路线 B：Mac App Store

这是一项后续专项工程，不应与当前长文本实现同时展开。建议顺序是：

1. 先完成并验证长文本完整 WAV。
2. 完成品牌和许可证清单。
3. 先验证 Developer ID 商业候选。
4. 单独进行 Mac App Store 沙盒可行性原型。
5. 只有沙盒模型下载、MLX 推理、XPC、文件访问和长文本全部通过后，才建立正式商店发布流程。

## 7. 收费方式和个人账号

如果账号是付费 Apple Developer Program 个人会员，可以在 App Store 销售应用；免费的 Personal Team 不可以。

个人会员需要注意：

- App Store 卖家名称显示个人法定真实姓名；
- 若希望显示公司法律实体名称，需要以组织身份加入，并按 Apple 要求提供 D-U-N-S 编号；
- 销售付费应用或提供内购前，Account Holder 必须签署 Paid Apps Agreement；
- 必须提交所需税务和收款银行信息。

Mac App Store 首版采用免费 App + 一项非消耗型内购：用户把完整文本粘贴到原版逐行/多段路径后，应用已经会
自动拆分并逐段生成多个音频文件，用户不需要预先自己分行，这条路径永久免费。`¥68`“长文本与变速扩展包”只解锁：

- 把完整长稿自动组织、校验并最终合并成一个完整 WAV；
- `0.01–2.50` 保持音调变速。

这是数字功能解锁，必须使用 Apple In-App Purchase，不能使用自己的许可证密钥。商品类型为非消耗型：一次购买、
不过期、不按字数或生成次数扣减。StoreKit 可以在本机验证 Apple 签名权益，因此不需要自建账号或授权服务器，
但 App 必须提供购买状态处理和“恢复购买”。

## 8. 隐私、声音和用户责任

商业版至少需要：

- 在 App Store Connect 和应用内提供可访问的隐私政策；
- 准确说明麦克风、参考音频、转写文本、文稿、生成音频和模型下载的处理方式；
- 保持当前“本地生成、不上传私密内容”的承诺与真实实现一致；
- 保留清晰的声音克隆授权确认，只允许用户克隆自己拥有或已获授权的声音；
- 不在诊断、公开基准、截图或客服附件中泄露文稿、私人音色、绝对路径或设备身份；
- 为导入内容、人物声音、商店截图和演示音频保留权利证明。

项目已有 [`Sources/PrivacyInfo.xcprivacy`](../../Sources/PrivacyInfo.xcprivacy) 和本地隐私边界，但商业发布人仍需使用
自己的隐私政策网址、支持信息和实际数据披露，不能只复制原项目说明。

当前 macOS 设置页还没有隐私政策入口。`PrivacyInfo.xcprivacy` 是隐私清单，不等于面向用户的隐私政策；
Mac App Store 候选仍需在 App Store Connect 提供隐私政策 URL、填写实际数据处理问卷，并在 App 内提供容易访问的入口。

## 9. 发布前合规清单

### 代码与许可证

- [ ] 保留项目根 MIT 版权和完整许可文本。
- [ ] 保留内化 `mlx-audio-swift` 的 MIT 来源与声明。
- [ ] 核对全部锁定 Swift 依赖的许可证和 NOTICE。
- [ ] 核对六个精确模型修订的许可证和来源。
- [x] 包含 helper 的签名测试包已携带 FFmpeg LGPL 正文、NOTICE、上游许可证和构建身份。
- [ ] 将现有 FFmpeg 单项入口升级为完整的“开源软件与第三方许可”页面。
- [ ] 为 Mac App Store 版确定不依赖 DMG 旁挂资产的 LGPL 对应源码交付方案。
- [ ] 生成最终发行物实际包含内容的 SPDX/CycloneDX 清单。
- [ ] 在应用内提供“开源软件与许可证”入口，不在启动时强制展示。

### 品牌与商店资料

- [ ] 确定自己的应用名称，并同步 `PRODUCT_NAME`、`CFBundleDisplayName` 和面向用户的品牌文案。
- [ ] 在首次上传前注册并切换主应用及 XPC 服务的唯一 Bundle ID。
- [ ] 使用原创图标、截图、预览和商店说明，并保留设计源文件与权利证明。
- [ ] 改用新品牌的数据目录并设计原 `QwenVoice` 数据迁移。
- [ ] 不暗示原作者、Qwen、MLX 或 Apple 为产品背书。
- [ ] 对所有演示声音、文本和图片拥有明确权利。
- [ ] 准备自己的支持网站、邮箱、隐私政策和服务条款。
- [ ] 在 macOS App 内增加容易访问的隐私政策入口。

### Developer ID 商店外版本

- [ ] 使用自己的 Developer ID 身份完成签名和公证。
- [ ] 验证嵌套 XPC 签名、Team ID、Hardened Runtime 和公证票据。
- [ ] 明确付款、交付、更新、退款和客户支持责任。
- [ ] 在目标国家或地区重新核对税务、消费者保护和 AI/声音克隆规则。

### Mac App Store 版本

- [ ] 单独证明 App Sandbox 可行，不能复用当前无沙盒结论。
- [ ] 证明模型下载属于受控数据资源而非下载代码。
- [ ] 使用 Mac App Distribution/App Store Connect 发布流程，而不是 Developer ID DMG 流程。
- [ ] 完成 Paid Apps Agreement、税务、银行和商店元数据。
- [ ] App 本体设为免费，并完成一项合规的非消耗型 In-App Purchase。
- [ ] 保持原版自动拆分并逐段生成多个音频文件的路径永久免费。
- [ ] 使用 StoreKit 非消耗型内购，以 `¥68` 一次解锁完整 WAV 和变速。
- [ ] 覆盖购买、取消、失败、恢复、退款/撤销和离线权益测试。
- [ ] 在提交备注中提供模型下载、离线推理和长文本完整审核步骤。

## 10. 建议决策顺序

```text
现在：长文本完整 WAV 和语速控制已形成可用基础
  -> 确定新产品名称与品牌边界
  -> 更换图标、主/XPC Bundle ID 和数据目录
  -> 完成统一许可页面与隐私政策入口
  -> Developer ID 商业候选
  -> Mac App Store 沙盒可行性原型
  -> 再决定是否投入正式商店版
```

这能先把品牌和许可证这类确定性工作收口，再单独验证沙盒、模型存储迁移、FFmpeg helper、支付和审核风险。

## 官方依据

Apple：

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
  - 2.4.5：Mac App Store 沙盒、打包、资源下载、更新和许可证密钥要求。
  - 2.5.2：不得下载执行会新增或改变功能的代码。
  - 3.1.1：数字功能解锁与 In-App Purchase。
  - 4.1：Copycats。
  - 4.2.3(ii)：额外资源下载大小披露和用户确认。
  - 5.1.1：隐私政策与数据说明。
  - 5.2.1：知识产权、商标、名称与素材权利。
- [macOS 分发方式比较](https://developer.apple.com/macos/distribution/)
- [App Store Connect 应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [首次上传前修改 Bundle ID](https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier)
- [配置和提交 App 图标](https://developer.apple.com/documentation/xcode/configuring-your-app-icon/)
- [App Store 隐私信息](https://developer.apple.com/app-store/app-privacy-details/)
- [Developer ID 商店外分发](https://developer.apple.com/developer-id/)
- [Apple Developer Program 个人与组织会员](https://developer.apple.com/help/account/membership/program-enrollment)
- [Paid Apps Agreement](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)
- [App Store 税务资料](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information)

模型与运行时：

- [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [MLX Swift](https://github.com/ml-explore/mlx-swift)
- 本文第 2 节列出的六个 `mlx-community` 模型页面。
