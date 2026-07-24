# macOS 本地 SRT 字幕生成方案

> 状态：首版实现记录。仅适用于 macOS；iOS 暂不接入。  
> 最低商业发行配置：Apple Silicon Mac、16 GB 统一内存。  
> 目标：根据最终变速后的 WAV 与原文，在本机生成同名 SRT。

## 1. 用户流程

“生成 SRT”位于语速输入框旁边，默认关闭。首次打开时下载一次约 574 MB 的
`Whisper large-v3 turbo Q5` 本地模型；下载完成后才允许提交带字幕的任务。

设置页“模型下载”区域提供独立的 Whisper 模型卡片，可执行下载、失败重试、重新检测、打开 Hugging Face、
显示模型目录、复制路径及导入已下载文件。网络不稳定时建议使用浏览器或支持断点续传的下载工具获取模型，再通过
“导入文件…”交给应用校验并安装。

应用内下载同样复用 Qwen 模型使用的原生下载器：暂存未完成数据，遇到短暂网络错误自动重试，并在再次点击下载时
尽量从已保留的部分继续，而不是每次都从零开始。

手动下载页：

```text
https://huggingface.co/ggerganov/whisper.cpp/blob/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin
```

正式版默认存放位置：

```text
~/Library/Application Support/QwenVoice/models/whisper/ggml-large-v3-turbo-q5_0.bin
```

文件名必须保持为 `ggml-large-v3-turbo-q5_0.bin`。设置页会显示当前运行环境的实际绝对路径；调试模式使用隔离的
`QwenVoice-Debug` 数据目录，因此应以设置页显示的路径为准。直接导入时，应用先复制到隐藏暂存文件，校验
`574,041,195` 字节及固定 SHA-256，全部通过后才原子替换正式模型。

处理顺序固定为：

```text
文稿提交
  → TTS 自动分段与生成
  → 合并最终 WAV
  → FFmpeg atempo 保持音调变速
  → 释放 TTS 模型
  → whisper.cpp 识别最终 WAV
  → 将识别时间轴对齐回原文
  → 原 WAV 同目录写入同名 .srt
```

长文本只为最终完整 WAV 生成一个 SRT，不为内部过程段生成字幕。逐条批量模式先完成全部 WAV，再集中生成各自的
SRT，避免在 TTS 与 Whisper 模型之间反复切换。

## 2. 技术选择

- 推理运行时：官方 `whisper.cpp 1.9.1` XCFramework；
- 上游 macOS XCFramework 同时包含 `arm64` 与 `x86_64`；应用构建阶段只抽取 `arm64`，
  随后的统一架构检查与代码签名仍必须通过，正式包不携带 Intel 切片；
- 模型：`ggml-large-v3-turbo-q5_0.bin`；
- 模型来源固定到 Hugging Face 仓库提交
  `98aa99a0a9db05ae2342309f5096248665f7cba3`；
- 模型大小：`574,041,195` 字节；
- 模型 SHA-256：
  `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`；
- 音频使用 `AVFoundation` 转换成 16 kHz 单声道 Float32；
- 长音频按 10 分钟窗口识别，相邻窗口保留 2 秒重叠，并按时间中点去重；
- 不捆绑 Python、faster-whisper、CTranslate2、PyAV 或额外 FFmpeg 发行版。

选择 whisper.cpp 的主要原因不是否定 faster-whisper 的效果，而是正式 macOS 应用需要更小、更容易签名、更适合
Apple Silicon、并且许可边界清晰的原生组件。现有 Python 工具仍可保留为独立制作流程和结果对照工具。

## 3. 对齐与字幕格式

Whisper 提供识别片段的起止时间。应用先把原文按句末标点、软标点和最多 32 个字符拆成字幕块，再将识别文本和
原文统一规范化。对齐器使用单调的六字符锚点建立原文位置到识别时间轴的位置映射，锚点之间线性插值。

最终 SRT 保留用户原文，不直接把 Whisper 识别结果当字幕正文。每条字幕默认最多 18 个字符一行；时间轴在识别
片段前后分别留出少量边界，并保证相邻字幕不倒序。

## 4. 文件与失败语义

- 输出路径：`成品名.wav` 对应 `成品名.srt`；
- SRT 先写隐藏临时文件，完成后再原子替换；
- 临时下载与临时字幕文件无论成功或失败都会清理；
- 字幕失败不删除、不回滚已经通过检查的 WAV；
- 批量任务中的字幕失败显示为“WAV 已保存”的警告，不把音频伪装成生成失败；
- 模型文件放在应用数据目录的 `models/whisper/`，并排除 Time Machine 备份；
- 未完成的应用内下载保存在模型根目录的隐藏 `.qwenvoice-downloads/` 暂存区，成功后进行原子目录替换；
- 每次使用前检查模型大小和 SHA-256，损坏或被替换时拒绝加载。

## 5. 内存与最低配置

商业版不考虑低于 16 GB 的 Mac。字幕阶段开始前主动释放 TTS 模型；识别按窗口读取音频，避免把数小时 WAV
一次性全部装入内存。正式 App Store 页面、支持文档和审核备注应统一写明：

> 需要 Apple Silicon Mac 和至少 16 GB 统一内存；首次使用语音与字幕功能需要额外下载本地模型。

现有上游 Vocello 的 8 GB 运行能力与未来 Sonafolio 商业版的产品支持下限是两件事。历史 8 GB 性能证据可以继续
保留，但不得用于把商业版最低要求重新写回 8 GB。

## 6. 许可与商店边界

- whisper.cpp：MIT；
- OpenAI Whisper 模型：MIT；
- 转换后的 ggml 模型仓库声明 MIT；
- 完整版权声明写入应用内“开源许可”入口和
  `Sources/Resources/ThirdPartyNotices/NOTICE.txt`；
- 模型是数据，不是下载后执行的新代码；whisper.cpp 运行库必须随 App 一起签名和封装；
- Mac App Store 版仍需独立验证 App Sandbox、模型下载目录、网络权限和动态库装载；
- 本方案没有解决当前非沙盒主应用直接上架的问题，也不代替最终商店审核和法律复核。

## 7. 后续验收

- 小段中文、英文及日文原文对齐；
- 0.80、0.85、1.00、1.25 倍最终 WAV 的字幕时间轴；
- 13,000–18,000 字真实长稿只产生一个 WAV 与一个 SRT；
- 人为中断模型下载、篡改模型、磁盘空间不足和已有同名 SRT；
- 字幕失败后 WAV 仍可在历史记录播放和导出；
- 16 GB Apple Silicon Mac 的峰值内存、耗时和温度记录；
- 签名测试包在没有 Python、Homebrew 和系统 FFmpeg 的干净 Mac 上直接使用。
