# macOS 商业分发与 Mac App Store 可行性评估

> 状态：商业化预研记录，不是正式法律意见，也不授权启动 Mac App Store 改造。  
> 核对日期：2026-07-21。Apple 审核规则、模型许可和依赖许可可能变化，发布前必须重新核对。  
> 当前开发优先级：只完成 macOS 长文本“一次提交、内部自动分段、最终得到一个完整 WAV”。  
> 暂缓事项：语速控制、iOS、Mac App Store 沙盒化和收费系统。

## 结论

| 问题 | 当前结论 |
| --- | --- |
| 能否修改 Vocello/QwenVoice 后商业销售 | 可以。项目根许可证是 MIT，明确允许使用、修改、发布、分发、再许可和销售 |
| 修改后是否必须公开源代码 | MIT 不要求公开修改后的源代码；但必须保留原版权和许可文本 |
| 当前使用的 Qwen3-TTS 模型能否商业使用 | 当前六个生产模型页面均标注 Apache-2.0，原则上允许商业使用，但需履行模型许可和声明义务 |
| 当前 macOS 构建能否原样提交 Mac App Store | 不能。当前应用明确关闭 App Sandbox，而 Mac App Store 要求应用适当沙盒化 |
| 当前 macOS 构建能否在商店外收费分发 | 可以作为首选候选。现有 Developer ID 签名、公证和 DMG 流程就是商店外分发路线 |
| 汉化、更多语言和长文本是否妨碍商业化 | 不妨碍；长文本还是有实际价值的功能增强，但它们不会自动解决沙盒、品牌和审核合规问题 |
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
  -> 失败可恢复
  -> 有界合并
  -> 原子发布一个完整 WAV
  -> History 中接受一个最终成品
  -> 立即清理分段 WAV 和临时过程文件
```

“一次性生成”指一次用户任务和一个最终产物，不表示把整篇文稿塞进一次模型推理。语速、音高、TimePitch 和
其他后处理不进入本阶段的实现或验收标准。成功任务最终只保留完整 WAV、History 记录和必要的小型摘要元数据；
过程分段仅在任务活动或确实需要恢复时短暂存在，不作为长期缓存。

长文本技术边界见[长文本生成](long-form-generation.md)和
[macOS 长篇叙事与语速控制评估](long-form-narration-tempo-assessment.md)。后者的语速部分现阶段只保留为历史预研，
不进入当前开发范围。

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

Mac App Store 初始商业模型建议优先考虑“一次性付费下载”，因为它不需要在应用内部实现额外解锁系统。
如果以后用免费应用内付费解锁长文本、模型或其他数字功能，原则上必须使用 Apple In-App Purchase，不能用自己的
许可证密钥或外部付款来解锁商店版数字功能。Mac App Store 应用也不能在启动时展示自己的许可证激活页面。

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

## 9. 发布前合规清单

### 代码与许可证

- [ ] 保留项目根 MIT 版权和完整许可文本。
- [ ] 保留内化 `mlx-audio-swift` 的 MIT 来源与声明。
- [ ] 核对全部锁定 Swift 依赖的许可证和 NOTICE。
- [ ] 核对六个精确模型修订的许可证和来源。
- [ ] 生成最终发行物实际包含内容的 SPDX/CycloneDX 清单。
- [ ] 在应用内提供“开源软件与许可证”入口，不在启动时强制展示。

### 品牌与商店资料

- [ ] 使用自己的名称、图标、Bundle ID、截图和说明。
- [ ] 不暗示原作者、Qwen、MLX 或 Apple 为产品背书。
- [ ] 对所有演示声音、文本和图片拥有明确权利。
- [ ] 准备自己的支持网站、邮箱、隐私政策和服务条款。

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
- [ ] 按收费模式实现一次性付费或合规的 In-App Purchase。
- [ ] 在提交备注中提供模型下载、离线推理和长文本完整审核步骤。

## 10. 建议决策顺序

```text
现在：只做长文本完整 WAV
  -> 长文本可靠性和恢复证据通过
  -> 独立品牌与许可证清单
  -> Developer ID 商业候选
  -> Mac App Store 沙盒可行性原型
  -> 再决定是否投入正式商店版
```

这能避免在长文本尚未完成时，同时引入沙盒、模型存储迁移、支付和审核四类独立风险。

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
- [Developer ID 商店外分发](https://developer.apple.com/developer-id/)
- [Apple Developer Program 个人与组织会员](https://developer.apple.com/help/account/membership/program-enrollment)
- [Paid Apps Agreement](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)
- [App Store 税务资料](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information)

模型与运行时：

- [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [MLX Swift](https://github.com/ml-explore/mlx-swift)
- 本文第 2 节列出的六个 `mlx-community` 模型页面。
