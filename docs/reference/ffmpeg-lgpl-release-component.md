# macOS FFmpeg LGPL-only 正式发布组件

> 状态：实现完成并通过本机确定性构建、功能、能力面和依赖验证。Developer ID 公证版仍需在下一次正式候选发布中按既有发布流程验证。
> 范围：仅 macOS。iOS 不打包、不调用此组件。
> 性质：工程与合规记录，不是法律意见。

## 结论

Vocello 不随包携带 Homebrew 或 Windows 的完整 FFmpeg。正式 macOS 包改为从固定的 FFmpeg 8.0.3
官方源码构建一个独立可执行文件：

```text
Sonafolio.app/
  Contents/
    MacOS/Vocello
    Helpers/ffmpeg-vocello
    Resources/ThirdPartyNotices/FFmpeg/
      NOTICE.txt
      COPYING.LGPLv2.1
      LICENSE.md
      BUILD-INFO.json
```

`ffmpeg-vocello` 通过 `Process` 启动，不与 Vocello 的 Swift 主程序链接。它是 arm64 静态内部 FFmpeg
库组成的独立 LGPL 程序，只处理本地 WAV/PCM16 和 `atempo`。发布脚本先单独签名该 helper，再签名 XPC
和外层 App。

## 固定来源与身份

权威合同是 [`config/ffmpeg-lgpl-component.json`](../../config/ffmpeg-lgpl-component.json)：

- 上游版本：FFmpeg 8.0.3。
- 源码：`https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz`。
- 源码 SHA-256：`6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818`。
- 上游分离签名 SHA-256：`975f9512458fc39cacf35a9496f51c9d82e3a3b684a9db111bedcfa523f2b2b8`。
- FFmpeg 发布签名公钥指纹：`FCF986EA15E6E293A5644F10B4322F04D67658D8`。
- 许可证：`LGPL-2.1-or-later`。

构建只接受摘要完全匹配的源码和签名缓存。正式 GitHub Release 会把同一份源码归档、上游分离签名和
`BUILD-INFO.json` 与 DMG 一起发布；它们也进入 `release-evidence.json` 和 `SHA256SUMS`。

## 最小功能面

构建从 `--disable-everything` 开始，并明确禁用 GPL、version3、nonfree、网络、ffplay、ffprobe、
avdevice、外部库自动发现及不需要的 Apple 媒体后端。对产品有意义的能力只有：

- 协议：本地 `file`。
- 解复用/封装：WAV。
- 解码/编码：`pcm_s16le`。
- 音频处理：`atempo`、`aformat`、`aresample` 及 FFmpeg CLI 强制带入的基础空操作/缓冲过滤器。
- 架构：仅 arm64；最低 macOS 26.0。

FFmpeg CLI 会强制编入若干基础视频过滤器，但组件没有任何可用的视频解复用器、封装器、视频解码器或视频
编码器，因此不存在可执行的视频处理路径。自动验证按完整白名单比较能力面，新增协议、格式、编解码器或过滤器
都会失败，而不是静默进入发布包。

## 构建与验证

联网构建：

```sh
./scripts/build_ffmpeg_lgpl_component.sh
```

缓存已经准备好时的离线复现：

```sh
./scripts/build_ffmpeg_lgpl_component.sh --offline
```

构建结果位于 `build/artifacts/macos/ffmpeg-lgpl/8.0.3/`。源码和分离签名使用
`build/cache/third-party/ffmpeg-lgpl/`，中间目标只存在于 `build/scratch/transient/ffmpeg-lgpl/`，服从统一
构建输出和清理合同。

验证器会检查：

1. 源码与分离签名的固定 SHA-256。
2. `ffmpeg -version` 中的版本和完整 configure 参数逐项相等。
3. `ffmpeg -L` 自报 LGPL 2.1-or-later，且不存在 `--enable-gpl`、`--enable-version3`、`--enable-nonfree`。
4. arm64-only、能力白名单，以及动态依赖只能来自 `/usr/lib` 或系统 Framework。
5. 用 24 kHz 单声道 PCM16 正弦 WAV 执行一次 `atempo=0.85`，检查输出格式和时长。
6. App 中 helper、完整 LGPL 文本、上游 LICENSE、NOTICE 和构建身份齐全。

在同一源码、配置和 Xcode 工具链下，两次独立构建得到相同的 helper SHA-256，当前本机结果为
`4b1c96fbb10d4590e5a9edc68ac1efa4743d99789f3b5c70dad2dbd7dbb111eb`。这是签名前构建产物摘要；Apple 签名会改变
Mach-O 文件字节，签名后的包内文件改由 codesign、Hardened Runtime、Team ID 和外层 DMG/发布证据摘要验证。
这个构建摘要也不是跨工具链永久常量；
每次候选发布以当次 `BUILD-INFO.json` 和发布证据为准。

## 发布链路

`scripts/release.sh` 在复制 Xcode 产物后构建并注入组件，随后：

1. 运行组件功能和合规验证。
2. 对 `Contents/Helpers/ffmpeg-vocello` 单独启用 Hardened Runtime 并签名。
3. 签名 XPC，再签名外层 App。
4. `verify_release_bundle.sh` 复核 helper 内容、能力、许可证、签名和 Team ID。
5. DMG 验证从挂载包复制 App 后再执行同一检查。
6. CI 发布源码、分离签名、构建身份、SBOM、证据和校验和；远端资产集合必须精确匹配后才能公开。

SBOM 将 FFmpeg 作为 `LGPL-2.1-or-later` 的源码组件列出，并绑定官方源码 URL 与 SHA-256。设置页只在正式
包确实包含 NOTICE 时显示“开源许可”按钮。

## LGPL 履行边界

当前工程选择“独立进程”而不是把 FFmpeg 库链接进闭源 Swift 主程序，目的是让许可证边界、签名边界和可替换
文件边界更清楚。发布包保留完整 LGPL 文本和上游许可证，Release 同站提供精确对应源码、构建配置与摘要，并且
Vocello 的用户条款不得禁止法律已经授予的 FFmpeg 逆向工程或修改权利。

这些措施是按照 FFmpeg 官方合规清单建立的工程控制，但不能代替针对最终销售地区、商店条款和用户协议的专业
法律审查。任何版本升级都必须重新核对上游许可证、源码签名、能力白名单、二进制依赖、SBOM 和实际发布资产。

## 仍需在正式候选版完成

- 使用实际 Developer ID 和公证凭据跑完整 `release.sh` 与 `verify_packaged_dmg.sh`。
- 在最终用户协议和官网第三方软件页面中保留 FFmpeg/LGPL 提示及对应源码入口。
- 若以后提交 Mac App Store，单独验证沙盒内启动 helper 和审核政策；本组件完成不等于当前非沙盒 App 已满足商店要求。
- iOS 继续不接入此 helper，除非用户以后另开范围。
