# Sonafolio 锁定路径母版

> 状态：候选母版 v0.1  
> 日期：2026-07-23  
> 来源方向：Google Stitch `Sonafolio Final Refinement 2`  
> 当前用途：轮廓、缩小表现和配色评审；尚未替换应用图标

## 这一步解决了什么

Stitch 在后续结构微调和配色生成中会重新绘制图形，无法保证不同版本使用同一条路径。
本目录把 `Final Refinement 2` 重建成了真正可编辑的 SVG：

- 所有标准版和配色版使用同一条矢量路径；
- 配色只改变背景与填充颜色，不改变轮廓、负形、粗细、比例或朝向；
- 黑白版提供 256、128、64、32、16 px 的直接光栅化结果；
- `currentColor` 母版可以在矢量工具或前端中直接换色；
- 路径追踪结果与清理后的黑白来源图二值轮廓 IoU 为约 `0.9933`。

这仍是从概念图重建的候选母版，不等于已经完成商标注册、图形近似检索或正式版权结论。

## 推荐文件

- `sonafolio-symbol-master.svg`：透明背景、`currentColor` 填充的主母版；
- `sonafolio-symbol-black-on-white.svg`：黑图白底标准评审版；
- `sonafolio-symbol-white-on-black.svg`：白图黑底反转版；
- `sonafolio-symbol-midnight-paper.svg`：深靛蓝背景、暖纸白图形；
- `sonafolio-symbol-warm-editorial.svg`：暖纸白背景、深靛蓝图形；
- `sonafolio-symbol-ember-voice.svg`：实验性金琥珀声音弧版本；
- `sonafolio-symbol-size-validation.png`：真实 64、32、16 px 及像素放大检查；
- `sonafolio-symbol-color-comparison.png`：同路径黑白和双色对比。

PNG 是评审和预览文件；后续修改以 SVG 为准。

## 当前判断

### 轮廓

主轮廓保留了连续书页、中心折页和声音弧三个特征。与 Stitch 后续产生的块状 `S`、
回形针和绳结方案相比，本母版的独立性更好，因此继续保留 `Final Refinement 2`。

### 小尺寸

- 64 px：结构完整，中心折页与两级声音弧均可辨认；
- 32 px：可用，细节开始合并，但整体轮廓稳定；
- 16 px：仍能辨认为同一符号，但书页语义明显弱化，更接近抽象 `S`。

现阶段建议把 `32 px` 作为独立品牌标志的常规最小尺寸。macOS 的 16 px 资源可以在
正式图标阶段另做一个光学校正版，但不能反向替换或污染主母版。

### 配色

当前优先级：

1. `Midnight Paper`：`#17172A` 背景 + `#F2E7D5` 图形，最适合作为深色主方向；
2. `Warm Editorial`：`#F2E7D5` 背景 + `#17172A` 图形，适合文档、商店页面和浅色界面；
3. `Ember Voice`：额外使用 `#D7A65A` 标记内侧声音弧，仅作为实验方向。

`Ember Voice` 没有改变路径，但强调色面积较大。在品牌调性正式确认前，不建议把它
设为默认 App 图标。

## 后续顺序

1. 项目方在 `Midnight Paper` 与 `Warm Editorial` 中确认主次关系；
2. 基于保留的 `Editorial Humanist` 方向重建英文 `Sonafolio` 字标；
3. 制作图形标、英文横排、简体中文和繁体中文组合规范；
4. 另外制作 macOS App 图标容器版，不把平台圆角写进品牌母版；
5. 完成公开图形近似检索和目标市场商标检索后，才能称为商业终稿。
