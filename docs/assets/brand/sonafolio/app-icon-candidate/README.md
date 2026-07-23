# Sonafolio macOS App 图标候选包

> 状态：平台图标候选 v0.1  
> 日期：2026-07-23  
> 当前用途：Icon Composer / Xcode 接入前的结构、配色与小尺寸验证  
> 工程状态：尚未替换 Vocello 的现有 App 图标

## 已确定的方向

本候选包使用已经锁定的 `Final Refinement 2` 矢量路径。macOS 图标只改变平台层级的
留白、颜色和图层组织，不重新绘制品牌主标志。

- 默认外观：`#17172A` 深靛蓝背景；
- 前景标志：`#F2E7D5` 暖纸白；
- 前景缩放：以 1024 × 1024 画布中心为基准，使用主母版的 `84%`；
- 背景层：完整覆盖 1024 × 1024，保持不透明；
- 前景层：透明 1024 × 1024 SVG；
- 平台圆角：不写入源图层，由 macOS / Icon Composer 处理；
- 图标内部不放 `Sonafolio`、`声卷`、`AI` 或 `TTS` 文字。

`84%` 是三种候选中的平衡值：

- `78% Compact`：安全但略显保守，在 Dock 中存在感不足；
- `84% Balanced`：轮廓清楚，四周仍有稳定呼吸空间；
- `90% Bold`：大尺寸有冲击力，但小尺寸和系统遮罩下稍显拥挤。

评审图见
[`sonafolio-app-icon-scale-comparison.png`](sonafolio-app-icon-scale-comparison.png)。

## Apple 平台图标规则

本包按 Apple 2026 年 6 月更新的图标流程准备：

1. 设计画布为 1024 × 1024；
2. 背景应完整覆盖且不透明；
3. 前景优先使用矢量图层；
4. 图层本身保持方形，不预先裁切平台圆角；
5. 主要内容保持居中、简洁，避免依靠细碎纹理；
6. Icon Composer 可以把背景与前景组合成一个多层图标文件，再交给系统生成平台外观；
7. 缺少的深色、透明或着色外观可由系统派生，但仍需在接入后逐项检查。

官方参考：

- [Apple Human Interface Guidelines — App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons/)
- [Apple Icon Composer](https://developer.apple.com/icon-composer/)
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer)
- [Configuring your app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon/)

## 目录说明

### `layers/`

供 Icon Composer 或其他矢量工具导入的无圆角源图层：

- `background-default.svg`：正式默认背景；
- `background-dark.svg`：更深的暗色候选；
- `background-depth-experiment.svg`：非常克制的径向层次实验，不是当前默认；
- `foreground-symbol.svg`：暖纸白、84% 的正式前景层；
- `foreground-symbol-monochrome.svg`：供单色/着色外观使用的黑色前景层。

### `sizes/`

同一 Balanced 候选直接光栅化的 1024、512、256、128、64、32、16 px PNG。
这些文件用于检查，不代表所有尺寸都必须手工交给 Asset Catalog。

### `previews/`

包含三种比例、四种外观及 16 px 微调方案。文件名中带
`masked-preview` 的圆角只用于展示，不得作为 Icon Composer 输入。

## 16 px 光学校正

直接缩小主母版时，最小的内侧声音弧只剩少量半透明像素，容易在不同显示缩放和背景下
变成噪点。本包比较了三种处理：

1. `Baseline`：主路径直接缩小；
2. `Simplified`：只在 16 px 专用资源中省略最小内侧声音弧；
3. `Reinforced`：省略小弧后再加粗。

最终保留 `Simplified`：

- 文件：`sonafolio-app-icon-16-optical.svg/.png`；
- 只允许用于 16 px 经典资源或同等极小显示；
- 32 px 及以上继续使用完整锁定路径；
- 不得把这条简化路径反向替换品牌母版；
- `Reinforced` 会堵塞负形，已经淘汰。

对比见
[`sonafolio-app-icon-16px-optical-comparison.png`](sonafolio-app-icon-16px-optical-comparison.png)。

## 当前推荐接入方式

1. 在 Icon Composer 中建立 1024 × 1024 图标；
2. 导入 `background-default.svg` 作为最底层；
3. 导入 `foreground-symbol.svg` 作为居中的独立前景层；
4. 使用系统默认材质强度开始，不额外添加厚重阴影、描边或玻璃纹理；
5. 检查 Default、Dark、Clear Light/Dark、Tinted Light/Dark；
6. 导出 `.icon` 后加入 Xcode 工程；
7. 同时保留 16 px 光学校正版，供经典 `AppIcon.appiconset` 或兼容性资源使用；
8. 完成 Dock、Finder、设置页、关于页和 App Store 上传前验证后，再替换现有应用图标。

Icon Composer 当前随本机 Xcode 安装，但本目录只交付可复现的开放 SVG/PNG 源资产，
不把专有编辑器文件当作唯一母版。

### 关于传统 `.icns`

本机 Xcode 26 工具链的 `iconutil` 拒绝了标准十尺寸 iconset；进一步把 Xcode 自带
`AppIcon.icns` 解包后，不作修改直接回封也同样被判定为 `Invalid Iconset`。因此本候选包
不伪造或保留一个未经验证的 `.icns`，只保留 1024–16 px 检查 PNG。正式接入优先使用
Icon Composer `.icon` 或 Xcode Asset Catalog，并以实际构建产物验证，不把当前
`iconutil` 的异常解释成品牌资产问题。

## 还没有完成的事项

- 未接入 `project.yml` 或 Xcode Asset Catalog；
- 未生成最终 `.icon` 文件；
- 未在真实 macOS Dock、Finder 与系统设置中做视觉验收；
- 未做公开图形近似检索或目标市场商标检索；
- 未形成商标可注册性或版权无冲突的法律结论；
- `background-depth-experiment.svg` 尚未被批准为正式背景。

## 锁定身份

完整品牌主路径 SHA-256：

`5183b7c7424a75d24246fbb533721e8b684b936b1e7cbdbdd60cece3ec9b3617`

各选定源文件的 SHA-256 记录在 `manifest.json`。任何更改主路径、前景比例或主色值的
版本都必须提高候选版本号，并重新生成全部尺寸验证图。
