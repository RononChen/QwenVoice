# macOS 产品身份表

> 版本：v0.3，2026-07-23。
> 状态：第 1 阶段进行中；macOS 外部显示名已切换为 Sonafolio，不代表商标、Logo 或 Bundle ID 已注册。
> 范围：macOS 商业发行；iOS 暂缓。

本文是[macOS 商业化实施路线图](macos-commercialization-roadmap.md)第 1 阶段的一页式决策记录；前两张表为
身份表主体，后续内容是命名、商店搜索、Bundle ID 和 Logo 的工作附录。
营业执照编号、法定代表人、银行和税务资料不进入项目仓库。

## 已冻结的产品决策

| 项目 | 当前决策 |
| --- | --- |
| 商业发行主体 | 北京艺文美达文化传播有限公司 / Beijing Yiwen Meida Cultural Communication Co., Ltd. |
| Apple 开发者身份 | 使用公司组织身份，不以个人身份进行正式商业发行 |
| 平台范围 | 首先处理 macOS；iOS 继续暂缓 |
| 品牌数量 | Developer ID 商店外版、Mac App Store 版及未来可能建立的官网统一使用一个品牌 |
| 现有品牌处理 | 新商业品牌不使用 `Vocello`、`QwenVoice` 或 `Qwen` 作为品牌主体 |
| 下载价格 | App 免费下载 |
| 免费能力 | 粘贴完整文本后自动拆分，并逐段生成多个音频文件；用户不需要预先分行 |
| 付费能力 | `¥68` 非消耗型内购买断：完整长稿合并为一个 WAV，以及 `0.01–2.50` 保持音调变速 |
| 服务形态 | 本地生成；不建立用户账号、授权服务器或云端生成服务 |

## 尚待冻结的身份项目

| 项目 | 当前状态 | 冻结前必须完成 |
| --- | --- | --- |
| 产品品牌名 | 工作名采用 `Sonafolio`，中文辅助名“声卷 / 聲卷” | 完成正式商标、App Store、域名和社交账号近似检索 |
| Bundle ID | 候选为 `com.yiwenmeida.sonafolio` | 公司 Apple Developer 组织账号建立后检查并注册唯一标识 |
| Logo | 已锁定 `Final Refinement 2` 候选路径，并完成字标、组合与 macOS App 图标候选包 | 完成真实系统验收、近似检索，并把最终权利归入公司 |
| 商店支持信息 | 尚未建立 | 支持页面、隐私政策 URL、支持邮箱；没有营销官网也必须提供可访问的支持 URL |
| 中国大陆发行材料 | 延后 | 与其他待软著 App 的整体节奏协调，不作为当前开发阻塞项 |

品牌、十种语言商店名称、关键词、截图顺序和视觉方案详见
[Sonafolio 品牌与 Mac App Store 元数据方案](sonafolio-brand-and-store-metadata.md)。

## 附录 A：命名简报

名称采用“统一核心品牌 + 中文辅助名 + 本地化描述词”的结构：

```text
应用安装后的品牌名：Sonafolio
App Store 中文名：    Sonafolio 声卷 - AI文字转语音
App Store 英文名：    Sonafolio: AI Text to Speech
副标题和关键词：       承担长文本、配音、声音克隆、本地生成等搜索意图
```

`Sonafolio` 是全球统一工作名，“声卷 / 聲卷”是中文辅助名，标准读音为 `shēng juàn`。中文品牌口号为
“让每一页，自然成声。”，英文为 “Every page, naturally voiced.”。

最终名称应满足：

- 中文、英文都容易读写，核心品牌在十种语言中保持一致，不为每种语言另造一个品牌；
- 不包含 `Qwen`、`Vocello`、模型版本或其他第三方品牌；
- 不把产品限定成“助眠专用”，因为实际能力还覆盖旁白、有声内容、配音和本地 TTS；
- 避免只有“AI Voice”“文字转语音”等通用词，便于商标保护和口碑搜索；
- 避免近似知名语音、配音、有声书或生成式 AI 产品；
- 先形成 10–20 个候选，再做网络、App Store、中国商标和目标海外市场的逐级筛查；
- 没有完成正式检索前，任何候选都只能标为工作名。

## 附录 B：App Store 搜索优化框架

Apple 当前允许应用名称最多 30 个字符、副标题最多 30 个字符、关键词最多 100 字节。搜索相关性会参考名称、
副标题、关键词、主要类别和公司名称，同时也会受到下载量及评分评论数量和质量影响。描述最多 4,000 个字符，
还会用于应用发布后的网页搜索结果。

因此首版不追求“品牌名本身包含所有关键词”，而采用以下分工：

| 元数据 | 任务 | 初步模板/方向 |
| --- | --- | --- |
| 应用名称 | 品牌记忆 + 最高价值关键词 | 中文：`Sonafolio 声卷 - AI文字转语音`；英文：`Sonafolio: AI Text to Speech` |
| 副标题 | 补充差异化能力 | 中文：`本地语音合成・长文本・声音克隆`；英文：`Long-form TTS & Voice Cloning` |
| 关键词 | 覆盖未在名称中重复的搜索意图 | 配音、旁白、有声书、长文本、声音克隆、本地生成等；最终按每种语言单独组合 |
| 主要类别 | 建立正确搜索语境 | 建议“效率（Productivity）”，次要类别“音乐（Music）” |
| 截图 | 提高搜索结果点击后的转化 | 第一屏突出“完整长稿 → 一个 WAV”，第二屏突出保持音调变速，后续展示本地生成和声音能力 |
| 描述 | 解释价值并承接网页搜索 | 准确写明 Apple Silicon、本地运行、模型另行下载、免费多段输出和 `¥68` 两项解锁能力 |

关键词不重复应用名或公司名，不填写竞品名称，不堆砌不相关热门词。十种界面语言可以逐步建设商店元数据；首发
优先保证简体中文和英文准确，再按目标市场增加繁体中文、日文、德文、法文、俄文、葡萄牙文、西班牙文和意大利文。

## 附录 C：Bundle ID 预留结构

Bundle ID 不使用中文公司全称，而使用稳定的反向域名式 ASCII 命名空间。正式检索完成前只记录候选，不注册：

```text
公司命名空间候选：com.yiwenmeida
macOS 主应用：    com.yiwenmeida.sonafolio
macOS XPC 服务：  com.yiwenmeida.sonafolio.engine-service
```

正式值必须由公司组织账号在 Apple Developer 后台确认唯一并注册；在首次 App Store Connect 构建上传前冻结。
CLI、测试目标和纯内部 Swift 模块是否同步更名属于第 2 阶段的技术评估，不应为了外部品牌做无收益的全仓库机械重命名。

2026-07-24 已先完成低风险的 macOS 外部品牌迁移：安装产物和可执行文件为 `Sonafolio.app` /
`Sonafolio`，用户可见品牌文案同步更新；现有 Bundle ID、XPC ID、内部模块、`vocello` CLI、偏好键与
`QwenVoice` 数据目录保持不变。正式公司标识注册后再执行独立的身份与数据迁移。

## 附录 D：Logo 设计简报

Logo 主方向采用“Folio Wave（书页声波）”，围绕“长文字被整理成连续、自然的声音”设计。
当前已经从概念探索进入候选终稿阶段：

- 选定 `Final Refinement 2`，重建为一个完整、可编辑的锁定 SVG 路径；
- 完整主路径 SHA-256 为 `5183b7c7424a75d24246fbb533721e8b684b936b1e7cbdbdd60cece3ec9b3617`；
- 主色为深靛蓝 `#17172A` 与暖纸白 `#F2E7D5`；
- macOS 图标选用 1024 × 1024 分层结构，前景为主母版的 84%，不在源图层内预画平台圆角；
- 32 px 及以上保留完整主路径；16 px 另用省略最小内侧声音弧的光学校正版；
- 避免通用麦克风、机器人头像、播放三角形，以及与现有 `Vocello` 的 V 形标志近似；
- 图标不直接写 `AI`、`TTS` 或产品全名，搜索含义由商店文案承担；
- 生成工具负责概念探索，仓库保留人工重建的开放 SVG/PNG、生成记录和字体许可证；
- 正式接入前仍需完成 Dock、Finder、设置页、关于页和 App Store 上传前的真实系统验收；
- 商标近似检索和最终权利归入公司尚未完成，因此当前仍标记为商业候选。

资产入口：

- [Sonafolio 锁定路径母版](../assets/brand/sonafolio/final-refinement-2/README.md)
- [Sonafolio 字标与组合](../assets/brand/sonafolio/lockups/README.md)
- [Sonafolio macOS App 图标候选包](../assets/brand/sonafolio/app-icon-candidate/README.md)

## 第 1 阶段冻结检查表

- [x] 公司主体、组织账号方向、统一品牌原则和收费方式已经人工确认；
- [x] 选出产品工作名并完成公开网络与应用商店的第一轮明显冲突筛查；
- [ ] 完成正式商标、App Store、域名和社交账号近似检索；
- [ ] 确认公司命名空间及最终主应用/XPC Bundle ID；
- [ ] 确认 Logo 方向、设计责任和权利归属；
- [ ] 将本表从 v0.1 更新为“已冻结”，再进入品牌与应用身份改造。

## Apple 官方依据

- [App information：名称最多 30 个字符，副标题最多 30 个字符](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Platform version information：关键词最多 100 字节，描述最多 4,000 个字符](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Discovery：搜索相关性和主要类别](https://developer.apple.com/app-store/discoverability/)
- [Localize app information：不同商店语言的元数据与搜索](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information)
