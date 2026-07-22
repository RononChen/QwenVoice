# macOS 商业化与 Mac App Store 实施路线

> 状态：实施规划，不代表已经授权启动上架、品牌替换或沙盒改造。  
> 制定日期：2026-07-22。  
> 当前范围：仅 macOS；iOS 继续暂缓。

本文把品牌、应用身份、许可合规、签名分发、Mac App Store 沙盒和计费拆成七个阶段。
每个阶段都有明确退出条件，避免同时修改产品身份、运行架构和付款逻辑。

计费决策详见[macOS 商业版计费方案](macos-commercial-pricing.md)，许可和上架依据详见
[macOS 商业分发与 Mac App Store 可行性评估](macos-commercial-distribution-assessment.md)。

## 总体结论

```text
第 1 阶段  冻结产品决策
    -> 第 2 阶段  品牌与应用身份改造
    -> 第 3 阶段  许可、隐私和素材合规
    -> 第 4 阶段  Developer ID 商业候选
    -> 第 5 阶段  Mac App Store 沙盒可行性
    -> 第 6 阶段  App Store 账户与计费配置
    -> 第 7 阶段  商店提交、审核和发布
```

其中第 5 阶段是唯一可能导致“Mac App Store 路线暂不可行”的技术决策点。即使该阶段不能通过，
前四个阶段仍然可以产出可收费分发的 Developer ID + 公证 DMG 版本，不会白做。

## 第 1 阶段：冻结产品决策

### 需要决定

- 新应用中文名、英文名及各商店语言的显示名；
- 自己控制的 Bundle ID 前缀；
- 新 Logo 的视觉方向和权利归属；
- 开发者账号继续使用个人身份，还是后续迁移为组织身份；
- 首版采用免费 App + `¥68` 非消耗型内购买断，不做订阅、点数或按字数收费；
- Developer ID 商店外版本和 Mac App Store 版本是否使用同一品牌。

### 暂定决策

- macOS App 免费下载；
- 原版逐行/多段路径永久免费：用户粘贴完整文本，应用自动拆分并逐段生成多个音频文件，用户无需预先自己分行；
- 只对“自动合并成一个完整 WAV”和“保持音调变速”收费；
- 两项功能合并为一个 `¥68` 非消耗型内购商品，一次购买、不过期、不限次数；
- 不建立用户账号、授权服务器或云端生成服务；
- 不以 `Vocello`、`QwenVoice` 或 `Qwen` 作为新商业品牌主体。

### 退出条件

- 一页产品身份表经人工确认；
- 名称完成基础商标、App Store 可用性和域名/社交账号冲突检索；
- 选定的 Bundle ID 尚未用于其他产品，并准备在自己的 Apple Developer 账号注册；
- Logo 设计委托或自产的著作权边界明确。

## 第 2 阶段：品牌与应用身份改造

### 实施内容

- 修改 `PRODUCT_NAME`、`CFBundleDisplayName`、`.app` 名称和用户可见品牌文案；
- 主应用 Bundle ID 从 `com.qwenvoice.app` 改为自己的唯一标识；
- XPC 服务 ID 同步改为主 ID 的子标识，例如 `<主ID>.engine-service`；
- 同步修改 XPC 信任策略、签名合同、权限脚本、测试合同和日志 subsystem；
- 替换 macOS AppIcon、关于页图形和商店使用的视觉素材；
- 将生产数据目录从 `QwenVoice` 改成新品牌目录；
- 为现有模型、声音、历史记录、偏好和输出目录设计一次性迁移；
- 保留 `QwenVoiceCore` 等纯内部模块名，避免无收益的大范围重构。

### 验证重点

- 主 App 与 XPC 使用同一签名团队并能互相信任；
- 新旧版本不会错误共用偏好、数据库或模型目录；
- 已有用户升级后不需要重新下载全部模型，也不会丢失保存声音和历史记录；
- 新图标包含 macOS 所需的完整尺寸；
- 所有 10 套界面语言中不再残留不应保留的旧品牌文案。

### 退出条件

- 确定性 macOS 测试和构建通过；
- 新身份签名测试包可以在干净账户上启动；
- XPC、麦克风、语音识别和文件权限均绑定到新 Bundle ID；
- 数据迁移有可回滚备份和自动化测试。

## 第 3 阶段：许可、隐私和素材合规

### 实施内容

- 建立统一的“开源软件与第三方许可”页面；
- 随 App 打包项目根 MIT、内化 `mlx-audio-swift` MIT 及全部实际随包依赖许可；
- 列出 Qwen3-TTS 精确模型名称、修订、来源和 Apache-2.0；
- 保留现有 FFmpeg LGPL、NOTICE、上游许可证和构建身份；
- 为 Mac App Store 版确定不依赖 DMG 旁挂文件的 FFmpeg 对应源码交付方式；
- 使用新品牌发布自己的隐私政策、支持网站、支持邮箱和服务条款；
- 在 macOS App 设置页增加隐私政策和支持入口；
- 保留声音克隆授权确认，并为演示声音、文稿、截图和图片保存权利证明；
- 对最终锁定依赖生成并审核 SPDX/CycloneDX SBOM。

### 退出条件

- 从最终 App 包可以访问完整许可集合；
- 隐私政策内容与实际“本地生成、模型下载、麦克风和文件处理”行为一致；
- 最终发行物不存在未确认许可证或来源的二进制、素材和模型；
- 专业法律审查列出的阻塞项清零或明确接受。

## 第 4 阶段：Developer ID 商业候选

这是与当前架构最接近、风险最低的商业发布基线，也是进入 App Store 沙盒改造前的稳定参照。

### 实施内容

- 使用自己的 Developer ID Application 身份签名主 App、XPC 和 FFmpeg helper；
- 启用 Hardened Runtime，完成 Apple 公证并装订公证票据；
- 生成 DMG、校验和、SBOM、发布证据和 FFmpeg 对应源码资产；
- 在一台没有开发环境的 Mac 和朋友的 Mac 上验证安装、权限、模型下载、长文本和调速；
- 明确商店外付款、交付、更新、退款和客户支持流程，但本阶段不强制建设销售服务器。

### 退出条件

- 发布验证脚本全部通过；
- 干净 Mac 可以直接安装和完成核心任务；
- 13,000–18,000 字真实长文本生成、完整 WAV、0.85/0.90 调速和过程文件清理通过；
- 公证、签名、许可入口和隐私入口均可复查。

## 第 5 阶段：Mac App Store 沙盒可行性

当前 App 明确关闭 App Sandbox，因此这一阶段必须作为独立工程，不允许仅修改签名后直接上传。

### 原型范围

- 建立独立 Mac App Store 发行目标或配置，不破坏 Developer ID 版本；
- 主 App 和 XPC 适当启用 App Sandbox；
- 验证 MLX/Metal、内存映射和本地模型推理；
- 验证嵌入式 FFmpeg helper 在允许的沙盒边界内运行；
- 模型、历史、声音和临时文件迁移到容器；
- 文件导入导出使用用户选择权限和安全作用域书签；
- 模型下载、恢复、校验、取消和删除只发生在允许位置；
- 尝试移除 `disable-library-validation` 等商店不友好的权限；
- 验证 XPC 退出、重启、长文本内存压力和完整清理。

### 决策门

- **通过：** 继续第 6、7 阶段，建立正式 Mac App Store 候选；
- **有限通过：** 明确需要裁剪的功能，再决定商店版与官网版是否形成差异；
- **不通过：** 暂停 Mac App Store，继续 Developer ID 商店外收费路线。

不能为了上架静默降低长文本、语速控制或声音克隆的可靠性；任何功能差异都必须在产品页面明确披露。

## 第 6 阶段：App Store 账户与计费配置

### 账户工作

- 保持有效的付费 Apple Developer Program 会员；
- 由 Account Holder 签署 Paid Apps Agreement；
- 提交 Apple 要求的银行和税务信息；
- 符合条件时主动申请 App Store Small Business Program；
- 在 App Store Connect 创建新应用记录并绑定最终 Bundle ID；
- App 本体设为免费；
- 创建“长文本与变速扩展包”非消耗型内购；
- 以中国区或选定地区为基础市场配置 `¥68` 对应价格点和全球自动换算。

### 应用工作

首版需要接入 StoreKit 非消耗型内购，但不需要登录、订阅、点数、许可证激活或自建服务器。免费路径必须在
商品不可用、购买取消或断网时继续正常工作。付费入口只在用户主动选择长文本完整 WAV 或非 `1.00` 语速时出现。
购买成功后使用 Apple 签名的当前权益解锁，并提供“恢复购买”、退款/撤销同步和离线权益处理。

### 退出条件

- Paid Apps Agreement、税务和银行状态有效；
- Small Business Program 资格状态确认；
- 价格、销售地区、隐私信息和版权信息填写完毕；
- App Store Connect 沙盒购买、取消、失败、恢复、退款/撤销和离线权益有书面测试方案。

## 第 7 阶段：商店提交、审核和发布

### 提交材料

- Mac App Store 签名的 Archive 和上传构建；
- 新品牌名称、图标、描述、关键词、分类、版权和支持信息；
- 所需尺寸的 Mac 截图，并按重点市场本地化；
- 隐私政策 URL、App Privacy 问卷和年龄分级；
- 审核备注：本地离线推理、模型数据下载、模型大小、长文本路径、声音克隆授权和测试步骤；
- 审核备注同时说明免费自动拆分多段路径、`¥68` 内购入口、恢复购买和两个解锁功能；
- 可复现的测试文本、参考声音和预期输出路径，不包含私人素材。

### 发布方式

- 首次建议手动发布，不使用审核通过后自动立即发布；
- 先确认商店页、价格、许可、隐私和下载体验，再开放销售；
- 首发阶段观察崩溃、内购转化、退款、模型下载失败和真实长文本完成率；
- 只有证据稳定后才扩大营销或调整 `¥68` 价格。

## 当前不要提前做的事情

- 不要在产品名未确定前注册最终 Bundle ID；
- 不要先把所有 `QwenVoice` 内部模块机械重命名；
- 不要为一次性付费方案建设账号或授权服务器；
- 不要在沙盒原型通过前承诺一定会上 Mac App Store；
- 不要把 SBOM 当成完整许可证页面；
- 不要承诺“终身包含所有未来大版本”。

## 官方依据

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [修改 Bundle ID](https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier)
- [配置 App 图标](https://developer.apple.com/documentation/xcode/configuring-your-app-icon/)
- [选择 App Store 商业模式](https://developer.apple.com/app-store/business-models/)
- [设置 App 价格](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price)
- [签署 Paid Apps Agreement](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)
- [App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/)
