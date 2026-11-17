# 图片翻译

在阅读器里把页面上的对白翻译成目标语言。思路来自 [ccbkv/PicaComic](https://github.com/ccbkv/PicaComic) 的图片翻译功能：文字在本机识别，只把文字发给翻译服务，再把译文盖在原处。实现是本仓库自己写的。

## 怎么用

页面默认显示原图，打开漫画时不会自动翻译。点阅读器工具栏上的翻译按钮，整本都显示译文：从当前页开始，在后台把本章每一页依次翻译完，翻到后面的章节时也会继续翻译。按钮外圈显示本章的进度，完成后会提示。再点一下按钮就关闭翻译，换回原图，后台不再开始新的页面。

后台每次同时处理两页。连续三页失败（比如 key 填错或额度用完）就会停下并提示原因，不会把整章都请求一遍。长按按钮可以看本章进度、重新翻译当前页、查看失败原因、进入设置。

## 一页是怎么翻译的

1. **找字**：文字检测模型标出每一行字的位置（`text_detector.dart`）。
2. **读字**：文字识别模型读出每一行。竖排的列先转成横的再读（`text_recognizer.dart`）。
3. **合并**：相邻的行合成一个对话框，定出阅读顺序，取出气泡颜色和文字颜色（`text_blocks.dart`）。
4. **翻译**：已经是目标语言的对话框跳过，其余的文字一次发给翻译服务（`translator.dart`）。
5. **重画**：在每个对话框上盖一块气泡颜色的底，把译文排进去，字号不超过原来的字（`page_renderer.dart`）。

第 1 到 3 步在单独的 isolate 里运行（`ocr_engine.dart`），不卡界面。整个流程由 `page_translation_service.dart` 调度。

## 保存了什么

- **文字结果**（识别出的原文、译文、位置）存在 `page_translation.db`，不过期。同一页同一种目标语言只识别和翻译一次。
- **画好的图**放在图片缓存里，30 天后过期。被清掉后会用文字结果重新画，不用再请求翻译服务。
- **设置**在 `page_translation.json`。里面有 API key，所以不进应用的同步数据。

## 模型

不随安装包分发，在设置里下载，共约 21 MB，放在应用数据目录的 `translation_models/`。

| 文件 | 模型 | 来源 |
| --- | --- | --- |
| `det.onnx` | PP-OCRv4 mobile 文字检测 | RapidOCR 发布的 ONNX 版本，HuggingFace `SWHL/RapidOCR` 及其镜像 |
| `rec.onnx`、`dict.txt` | PP-OCRv5 mobile 文字识别，支持简繁中文、日文、英文，横排和竖排 | RapidOCR 发布的 ONNX 版本，ModelScope `RapidAI/RapidOCR` |

模型来自 PaddleOCR 项目，Apache-2.0 许可。

运行模型用 ONNX Runtime。`ort.dart` 通过 FFI 直接调用它的 C 接口，没有用 Flutter 插件。运行库只在 Android 的构建里引入（`android/app/build.gradle` 里的 `onnxruntime-android`），所以**目前只有 Android 能用**，iOS 和 macOS 的安装包不受影响，设置页会显示“暂不支持”。

## 翻译服务

| 接口格式 | 说明 |
| --- | --- |
| OpenAI 兼容 | `POST {地址}/chat/completions`。OpenAI、DeepSeek、通义千问、智谱、Kimi、豆包、硅基流动、OpenRouter、本机的 Ollama 等都是这个格式 |
| Claude | Anthropic 的 Messages 接口 |
| Gemini | Google 的 Gemini 接口 |
| Google 翻译 | 免 key 的公开接口，普通机器翻译，不使用提示词 |

- 设置里的“服务商预设”只是帮忙填好地址和一个模型名。模型名会过时，编辑页里可以点“获取模型列表”从服务商那里取当前的列表。
- 请求里带着 key，所以不走应用的网络日志。
- 各种格式的“拒绝翻译”都会被识别出来，不会当成译文显示；这一页会显示原图，长按翻译按钮能看到原因。
- 模型返回的条数和发出去的不一致时，整页算失败，不会错位显示。

## 测试

- `test/page_translation_*_test.dart`：检测和识别里的计算、对话框合并、各接口格式的请求和回答、整页流程（识别结果由测试提供，翻译服务是替身，解码和绘制是真的）。随 `flutter test` 运行。
- `test/page_translation_ocr_test.dart`：用真实模型读样例页面。需要桌面版的 ONNX Runtime 和模型文件，默认跳过：

  ```bash
  PICA_ORT_LIB=/path/to/libonnxruntime.dylib PICA_OCR_MODELS=/path/to/models flutter test test/page_translation_ocr_test.dart
  ```

  `models` 目录里放 `det.onnx`、`rec_zh.onnx`（即上表的 `rec.onnx`）和 `dict_zh.txt`。

## 已知限制

- 只有 Android，而且只有 arm64-v8a 设备。x86_64 的运行库（约 23 MB）没有打进安装包，模拟器和 x86 设备上会显示“暂不支持”。
- 原来的字是被一块底色盖住的，没有按画面补全。气泡是纯色时看不出来，压在画面上的字会留下一块色块。
- 手写体、艺术字和拟声词识别率低，识别把握不大的行会被丢掉。
- 没有跨页的译名表，同一个人名在不同页可能译法不同。
- 画好的页面是 PNG，比原图大，会多占一些图片缓存。
