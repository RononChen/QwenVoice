# macOS 界面多语言方案

本文记录 Sonafolio macOS 客户端的界面语言范围、运行规则和维护合同。该功能只控制应用界面，
不会改变文本转语音的目标语言、自动语言检测、说话人、模型或生成参数。iOS 暂不接入本方案。

## 支持范围

设置页提供“跟随系统”以及以下十种显式界面语言：

| 标识 | 设置中显示的名称 |
| --- | --- |
| `zh-Hans` | 简体中文 |
| `zh-Hant` | 繁體中文 |
| `en` | English |
| `ja` | 日本語 |
| `de` | Deutsch |
| `fr` | Français |
| `ru` | Русский |
| `pt` | Português |
| `es` | Español |
| `it` | Italiano |

葡萄牙语采用通用 `pt`，不固定为巴西或葡萄牙地区变体。语言名称始终使用各自的本地写法，
以便用户误选语言后仍能找到并恢复设置。

## 运行规则

- 首次启动默认“跟随系统”。系统首选语言不在支持列表时，按系统语言优先级继续匹配，最后回退英文。
- 显式选择写入应用自己的 `vocello.interfaceLanguage.v1` 偏好，不修改系统的 `AppleLanguages`。
- 进程启动时只解析一次有效语言；用户修改后重启 Vocello，主窗口、设置窗口和应用自有菜单统一切换。
- SwiftUI 文本通过场景的 `Locale` 环境解析；由 ViewModel 或可复用组件产生的普通 `String` 通过
  `AppLocalization` 从同一个 `.lproj` 资源包读取。
- 数字格式化也使用当前界面语言的 `Locale`，但生成请求继续使用原有语音语言配置。

## 资源与维护合同

每种语言均位于 `Sources/Resources/<locale>.lproj/Localizable.strings`。英文文件是键集合的基准，
英文值必须与源键相同。`scripts/check_localizations.py` 会阻止以下问题进入构建：

- 支持列表中任意语言缺少资源文件；
- 各语言键集合不一致、存在重复键或空翻译；
- `%@`、`%lld` 等格式占位符被翻译、丢失或改变数量；
- 英文回退值偏离源字符串。

新增界面文案时，应在同一改动中补齐十套资源并运行：

```sh
python3 scripts/check_localizations.py
python3 -m unittest scripts.tests.test_check_localizations
scripts/macos_test.sh test
./scripts/build.sh build
```

是否进行视觉验收由明确的前端 QA 请求决定；普通开发验证不自动启动 XCUITest。
