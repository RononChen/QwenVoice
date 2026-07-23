# Sonafolio 品牌与 Mac App Store 元数据方案

> 版本：v0.1，2026-07-23。
> 状态：品牌工作名与首版 ASO 方向已选定；尚未完成正式商标、域名、社交账号和 App Store Connect 注册。
> 范围：macOS 商业版；iOS 暂缓。

本文深化[macOS 产品身份表](macos-product-identity-sheet.md)中的产品工作名。当前决定使用 `Sonafolio`
作为十种语言统一的核心品牌，以“声卷”作为简体中文辅助名、“聲卷”作为繁体中文辅助名。在正式检索完成前，
文档中的名称、Bundle ID 和元数据都是发行候选，不代表已经获得注册权利。

## 1. 品牌定义

| 项目 | 决策 |
| --- | --- |
| 全球核心品牌 | `Sonafolio` |
| 标准拼写 | 仅首字母大写，不写成 `SonaFolio`、`Sona Folio` 或全大写 |
| 小写标识 | `sonafolio`，用于 Bundle ID、文件名和技术标识候选 |
| 简体中文辅助名 | `声卷` |
| 繁体中文辅助名 | `聲卷` |
| 中文标准读音 | `shēng juàn`；“卷”取书卷、篇章之意，不读 `juǎn` |
| 英文读音参考 | `so-na-FOH-lee-oh`；不要求在用户界面显示音标 |
| 中文品牌口号 | **让每一页，自然成声。** |
| 英文品牌口号 | **Every page, naturally voiced.** |
| 产品证明句 | **一篇长稿，一个完整 WAV。** |

名称由表示声音联想的 `Sona` 和表示书页、文稿、篇册联想的 `folio` 组合而成，重点表达“把完整文稿整理为
连续声音”。它不绑定 Qwen、某个模型版本、助眠单一场景或云服务，未来仍可覆盖旁白、有声内容、视频配音、
播客草稿和本地声音创作。

“声卷”存在多音字识别成本，因此首发阶段不单独把“声卷”作为唯一产品名：应用图标旁、关于页、商店名称和
宣传材料都优先使用 `Sonafolio 声卷` 的组合。Logo 的书页语义也应帮助用户把“卷”理解为 `juàn`。

## 2. 初步冲突检索

2026-07-23 的低成本公开检索包括：

- 精确搜索 `Sonafolio`、`SonaFolio` 和 `SONAFOLIO`；
- App Store 与 Google Play 的精确名称搜索；
- 中文“声卷 + App/软件/商标”的组合搜索。

本轮未发现明显的同名 App 或同领域产品。这只能排除容易发现的冲突，不能证明名称可注册、域名可购买或不存在
未被搜索引擎收录的在先权利。进入正式发行身份改造前仍需：

1. 在中国对第 9 类软件、第 42 类软件技术服务进行正式近似检索；如果未来提供音频制作、出版或内容服务，
   同时评估第 41 类；
2. 对计划销售的主要海外市场进行文字商标近似检索；
3. 检查 App Store Connect 名称可用性；
4. 检查并决定域名与主要社交账号，不因没有营销官网而提前购买高价域名；
5. 检索通过后再决定是否申请 `Sonafolio`、`Sonafolio 声卷` 及图形标志。

## 3. 产品定位

### 一句话定位

`Sonafolio` 是面向创作者的 Apple Silicon 本地语音工作室，把完整长稿转成自然、可控、可直接交付的 WAV。

### 核心价值顺序

1. **完整长稿：** 一次提交，内部规划、分段、校验、合并并清理过程文件；
2. **自然节奏：** `0.01–2.50` 保持音调变速，适合旁白和长篇叙事；
3. **本地隐私：** 模型下载完成后在 Mac 本地生成，文稿和声音不依赖自建云服务；
4. **声音创作：** 自定义声音、声音设计和经过授权确认的声音克隆；
5. **先用后买：** 免费路径自动拆分并输出多个音频，`¥68` 只解锁完整 WAV 和变速。

产品名称和首屏文案不把“声音克隆”放在第一位。长文本完整 WAV 是区别于普通 TTS 和原版免费路径的首要价值，
保持音调变速是第二价值，克隆属于完整声音能力的一部分。

## 4. App Store 名称与副标题

安装后的 `.app`、菜单栏和关于页统一显示 `Sonafolio`。App Store 名称使用“核心品牌 + 本地化最高价值搜索词”；
副标题承担长文本、克隆和本地处理等差异化信息。以下候选均不超过 Apple 当前的 30 字符上限：

| 语言 | App Store 名称 | 字符数 | 副标题 | 字符数 |
| --- | --- | ---: | --- | ---: |
| 简体中文 | `Sonafolio 声卷 - AI文字转语音` | 22 | `本地语音合成・长文本・声音克隆` | 15 |
| 繁体中文 | `Sonafolio 聲卷 - AI文字轉語音` | 22 | `本機語音合成・長文・聲音複製` | 14 |
| 英文 | `Sonafolio: AI Text to Speech` | 28 | `Long-form TTS & Voice Cloning` | 29 |
| 日文 | `Sonafolio：AI音声合成` | 16 | `長文TTS・音声クローン・ローカル処理` | 19 |
| 德文 | `Sonafolio: Text zu Sprache` | 26 | `Lange Texte & Stimmklonen` | 25 |
| 法文 | `Sonafolio : Synthèse vocale` | 27 | `Textes longs et clonage vocal` | 29 |
| 俄文 | `Sonafolio: синтез речи` | 22 | `Длинные тексты и клон голоса` | 28 |
| 葡萄牙文 | `Sonafolio: Texto para voz` | 25 | `Texto longo e clonagem de voz` | 29 |
| 西班牙文 | `Sonafolio: Texto a voz` | 22 | `Texto largo y clonación de voz` | 30 |
| 意大利文 | `Sonafolio: Sintesi vocale` | 25 | `Testi lunghi e voci clonate` | 27 |

这是首轮语义草案，不是最终母语审校结果。App Store 的葡萄牙文、西班牙文、英文和法文存在地区本地化；界面内部
使用通用 `pt` 不代表商店只能建立一个葡萄牙文版本。上架时可先复用同一标题，再根据巴西/葡萄牙、西班牙/墨西哥、
美国/英国等地区的实际搜索词分别调整关键词和截图。

## 5. 首版关键词

名称和公司名本身可以被搜索，因此关键词字段不重复 `Sonafolio`、公司名或标题中的“文字转语音 / Text to Speech”。
首轮重点覆盖创作者使用场景：

```text
简体中文（92 字节）
配音,旁白,有声书,朗读,音频,故事,离线,创作者,播客,助眠,声音设计,WAV

英文（84 字节）
voiceover,narration,audiobook,reader,offline,story,wav,creator,dubbing,podcast,sleep
```

其余语言的关键词应由母语审校与实际搜索建议共同确定，不直接机械翻译英文列表。发布后按展示量、产品页浏览量、
下载转化和退款原因调整，不通过反复改品牌名追逐短期关键词。

## 6. 类别建议

当前工程的 `LSApplicationCategoryType` 是 `public.app-category.music`。同领域 App 的选择并不一致：有的归入工具，
有的归入效率、娱乐或音乐。`Sonafolio` 的核心任务是把文稿加工成可交付音频，而不是音乐播放或创作，因此商业版建议：

| 项目 | 建议 |
| --- | --- |
| Mac App Store 主要类别 | **效率（Productivity）** |
| 次要类别 | **音乐（Music）** |
| Xcode 类别 | 第 2 阶段将 `LSApplicationCategoryType` 改为 `public.app-category.productivity` |

Apple 要求 macOS 工程中的类别与 App Store Connect 主要类别一致。类别修改属于第 2 阶段，当前只记录决策，
不提前修改仍以 `Vocello` 身份运行的工程。

## 7. 搜索结果与商店截图叙事

首发截图不从“模型名称”或“参数很多”开始，而按用户痛点排序：

1. **`16,000 字长稿 → 一个完整 WAV`** — `一次提交，自动分段、校验、合并并清理过程文件。`
2. **`语速可控，音调自然`** — `0.01–2.50 自由输入，适合旁白、故事和有声内容。`
3. **`三种声音创作方式`** — `自定义声音・声音设计・授权声音克隆。`
4. **`模型下载后，本地生成`** — `文稿和参考声音不依赖 Sonafolio 云端服务。`
5. **`先免费生成，再决定是否升级`** — `免费自动拆分多段；¥68 解锁完整 WAV 与保持音调变速。`

描述开头建议固定为：

> 把完整长稿变成一个自然、连续、可直接使用的 WAV。Sonafolio 在 Apple Silicon Mac 本地运行，支持自定义声音、
> 声音设计和声音克隆；模型下载完成后，文稿与参考声音无需上传到 Sonafolio 云端。

不能写“完全不需要网络”：首次模型下载、App Store 购买与恢复购买仍可能需要网络。也不写“无限长度”“绝不失败”
或“任何声音均可克隆”等无法无条件证明的承诺。

## 8. Logo 与视觉方向

主方向定为 **Folio Wave（书页声波）**：

- 两张连续书页或一条纸带形成简洁的 `S` 形轮廓；
- 纸带末端自然过渡为三段声波，表达“页面连续成声”；
- 不使用麦克风、机器人头像、播放按钮，也不延续现有 `Vocello` 的 V 形图形；
- 图标内不放 `AI`、`TTS`、`Sonafolio` 或“声卷”文字；
- 16 px 黑白剪影仍可辨认，完整尺寸再表现纸张层次；
- 暂定“深靛夜色 + 暖纸白 + 少量琥珀金”，兼顾长篇阅读、专业创作和沉静感，但不把产品做成助眠专用。

建议的概念色只用于下一轮视觉草图，不视为最终品牌色：

| 用途 | 概念色 |
| --- | --- |
| 深色背景 | `#17172A` |
| 纸页主体 | `#F2E7D5` |
| 强调色 | `#D7A65A` |

下一轮先制作 3 个不同轮廓的黑白图标，只比较辨识度和独创性；选定轮廓后再处理颜色、材质和 macOS 图标尺寸。
正式 Logo 必须保留可编辑矢量源文件，并由公司自行创作或通过书面合同取得完整商业使用、修改和注册权利。

第一轮三个黑白方向及 `64/32/16 px` 缩小判断已经记录在
[Sonafolio “书页声波”黑白轮廓探索](sonafolio-logo-silhouette-exploration.md)。当前建议淘汰方案 1 的具体造型，
把方案 2 作为安全备选，并以方案 3“页边声纹”进入第二轮结构变体；在结构确认前暂不进入配色。

由于第一轮内部草图不足以作为专业委托依据，后续外部设计和生成工具输入改以
[Sonafolio Logo 专业设计需求书](sonafolio-logo-design-brief.md)为唯一设计简报。该需求书不要求沿用第一轮造型，
并将概念数量、禁用元素、缩小测试、评审权重、交付格式和知识产权记录列为明确验收条件。

## 9. 技术身份候选

名称通过正式检索后，建议注册：

```text
公司命名空间：  com.yiwenmeida
macOS 主应用：  com.yiwenmeida.sonafolio
macOS XPC 服务：com.yiwenmeida.sonafolio.engine-service
```

首次上传 App Store Connect 构建后 Bundle ID 不能更改，因此现在只记录候选，不修改 `project.yml`，也不在个人开发者
账号中抢先注册。公司组织账号建立后，需要同时确认主 App、XPC、权限、签名信任合同和数据迁移方案。

## 10. 当前冻结状态

- [x] 选定全球核心品牌工作名 `Sonafolio`；
- [x] 选定中文辅助名“声卷 / 聲卷”及标准读音 `shēng juàn`；
- [x] 选定品牌口号、首版 ASO 结构和 Logo 主方向；
- [x] 完成公开网页与应用商店的第一轮明显冲突筛查；
- [ ] 完成正式商标近似检索；
- [ ] 确认域名、社交账号和 App Store Connect 名称；
- [ ] 在公司组织账号注册最终 Bundle ID；
- [ ] 产出并确认原创 Logo 矢量源文件与权利归属；
- [ ] 完成十种语言元数据的母语审校。

## 官方依据与市场参照

- [Apple：App 名称与副标题最多 30 个字符，Bundle ID 上传后不可修改](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Apple：关键词最多 100 字节，描述进入网页搜索，支持 URL 为必填](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Apple：本地化关键词可以用于对应商店地区的搜索](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information)
- [Apple：搜索排序参考名称、关键词、主要类别和用户行为](https://developer.apple.com/app-store/discoverability/)
- [Chinny：同领域产品归入 Utilities](https://apps.apple.com/us/app/chinny-offline-voice-cloner/id6753816417)
- [VoClone：同领域产品归入 Productivity](https://apps.apple.com/us/app/voclone/id6743171000?mt=12)
- [Sonar：同领域产品归入 Entertainment](https://apps.apple.com/us/app/sonar-voice-clone-tts/id6758903660?mt=12)
- [Cast：同领域产品归入 Music](https://apps.apple.com/us/app/cast-ai-voice-studio/id6757167728?mt=12)
