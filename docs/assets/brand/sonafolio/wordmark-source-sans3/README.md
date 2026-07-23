# Sonafolio 英文字标矢量候选

> 状态：字标候选 v0.1  
> 日期：2026-07-23  
> 基础字体：Source Sans 3  
> 字体许可：SIL Open Font License 1.1

## 结论

当前推荐：

- `sonafolio-wordmark-a-medium.svg`
- Source Sans 3 Medium；
- 使用字体自身的 OpenType kerning；
- 已转换为自包含 SVG 字形轮廓，运行时不依赖本机字体；
- 文字严格为 `Sonafolio`，仅首字母 `S` 大写。

对比方案：

- `sonafolio-wordmark-b-medium-tracked.svg`：在每个后续字形位置增加 4 个设计单位，
  整体呼吸更松，但 `f-o-l-i-o` 段略显分散；
- `sonafolio-wordmark-c-semibold.svg`：低尺寸更重，但与图形标组合时视觉重量偏高。

综合品牌气质、横向长度和与图形标的重量关系，暂时保留 A。

## 来源与许可

Source Sans 3 来自 Adobe 官方 `adobe-fonts/source-sans` 仓库的 release 分支。该字体
面向界面环境设计，并以 SIL Open Font License 1.1 发布。

本目录不分发字体二进制，只保留已经转换成轮廓的 `Sonafolio` 字标 SVG、预览 PNG
和原始许可证副本：

- 官方仓库：`https://github.com/adobe-fonts/source-sans`
- 字体版本：Source Sans 3 官方发布线
- Medium 字体文件 SHA-256：
  `3772689bdef0cd284428994189d89d1fd412591e8906fb5bd0c4692a3314cbe7`
- Semibold 字体文件 SHA-256：
  `26efb7fbad9540df2595fe867a37e454d22973b9e37816d263fdc5295cb084bb`
- 许可证文件 SHA-256：
  `56af9b9c6715597e458284a474dc118a50a4150e9d547c70f7b4a33c3e6a9328`

许可证声明包含 Reserved Font Name `Source`。项目不修改或重新发布字体软件，也不把
`Source` 用作品牌名称；字标文件只保存排版完成后的轮廓。正式商业发布前仍应把该
来源加入第三方字体/素材记录。

## 下一步

1. 使用 A 版制作图形标与英文字标横排组合；
2. 检查图形和字标在深底、浅底下的视觉重量；
3. 另行设计 `声卷`、`聲卷` 辅助名称排版；
4. 商标近似检索完成前，不把字标称为已注册或可独占标志。
