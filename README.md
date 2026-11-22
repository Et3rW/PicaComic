# Pica Comic

[![flutter](https://img.shields.io/badge/flutter-3.47.0-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/Et3rW/PicaComic)](https://github.com/Et3rW/PicaComic/blob/master/LICENSE)
[![Download](https://img.shields.io/github/v/release/Et3rW/PicaComic)](https://github.com/Et3rW/PicaComic/releases)
[![stars](https://img.shields.io/github/stars/Et3rW/PicaComic)](https://github.com/Et3rW/PicaComic/stargazers)

A comic app with multiple sources built with flutter.

**Forked from [nyne](https://github.com/wgh136), provide extended support & fix, no guaranteed roadmap.**

[中文介绍](#中文介绍) | English

## Download

<a href="https://github.com/Et3rW/PicaComic/releases">
<img src="https://user-images.githubusercontent.com/69304392/148696068-0cfea65d-b18f-4685-82b5-329a330b1c0d.png"
alt="Get it on GitHub" align="center" height="80" /></a>

<a href="https://github.com/Et3rW/PicaComic/blob/master/INSTALL.md#obtainium">
<img src="https://github.com/ImranR98/Obtainium/blob/main/assets/graphics/badge_obtainium.png"
alt="Get it on Obtainium" align="center" height="54" />
</a>

An [AUR package](https://aur.archlinux.org/packages/pica-comic-bin) is packed by [Lilinzta](https://github.com/Lilinzta):
```shell
paru -S pica-comic-bin
```

## Build

1. Clone the repository
```shell
git clone https://github.com/Et3rW/PicaComic
```
2. Install Flutter 3.47.0 (matches the checked-in dependency lockfile): https://docs.flutter.dev/get-started/install
3. Build Application: https://docs.flutter.dev/deployment

## Introduction

### Built-in Comic Source

Pica Comic has 7 built-in sources:
- picacg
- e-hentai/exhentai
- jmcomic
- hitomi
- htcomic
- nhentai
- rule34video (videos, played in the app)

### Features

- Browse manga
- Online reading
- Download manga
- Manage local favorites and network favorites
- Data sync(using webdav)
- Reading history
- In-app updates: on Android the update is downloaded, checked and installed from the app; test builds follow test builds
- Videos from rule34video: played in the app (quality switch, seek previews, resume where you left off) and downloadable for offline viewing. See [doc/rule34video.md](doc/rule34video.md).
- Page translation (Android): text on a page is recognized on the device and sent to a translation service of your choice (OpenAI-compatible APIs, Claude, Gemini or Google Translate), then drawn back over the page. Nothing is translated until you tap the translate button; then the whole comic is shown translated, with each chapter translated in the background from the page you are on. See [doc/page-translation.md](doc/page-translation.md).

### History

This project initially started as an unofficial app for picacg
and later evolved into an app that supports multiple comic sources.

## 中文介绍

Pica Comic 是一个用 Flutter 编写的多漫画源阅读器。本仓库 fork 自 [nyne](https://github.com/wgh136) 的原项目，在其基础上继续维护和修复问题，没有固定的开发计划。

### 下载

在 [Releases](https://github.com/Et3rW/PicaComic/releases) 页面下载：

- **Android**：`PicaComic-<版本>.apk`，要求 Android 7.0 及以上，支持 ARM64 和 x86_64。
- **iOS**：`PicaComic-<版本>-unsigned.ipa`，未签名，需要用自己的方式签名安装。
- **macOS**：`PicaComic-<版本>-macos-universal.zip`，支持 Apple 芯片和 Intel。没有经过 Apple 公证，第一次打开时可能被系统拦截。

标着 Pre-release 的是测试版。正式版的版本号末位是 0（5.2.0、5.3.0），测试版的末位表示这是上次正式版之后的第几个测试版，按 1 到 9、a 到 f 数，例如 5.2.3 是 5.2.0 之后的第 3 个测试版。测试版的包名和正式版不同，可以同时安装；新的测试版可以直接覆盖旧的测试版。也可以用 [Obtainium](INSTALL.md#obtainium) 从 GitHub 自动获取更新。

### 内置漫画源

- 哔咔漫画（picacg）
- e-hentai / exhentai
- 禁漫天堂（jmcomic）
- hitomi
- 绅士漫画（htcomic）
- nhentai
- rule34video（视频，在应用里播放）

### 功能

- 浏览、搜索漫画，在线阅读
- 下载漫画，离线阅读
- 本地收藏和网络收藏
- 阅读历史
- 应用内检查更新；Android 上可以直接在应用里下载并安装，测试版只更新到测试版
- 通过 WebDAV 同步数据
- e-hentai、nhentai 点击标签时可以叠加多个标签一起搜索
- nhentai 分类里的“全部”：不选任何标签和语言，按最新或热门浏览所有作品
- **rule34video 视频**：在应用里播放，可以切换清晰度、拖动时预览画面、从上次的位置继续；可以下载后离线观看。详见 [doc/rule34video.md](doc/rule34video.md)。
- **图片翻译（仅 Android）**：在本机识别页面上的文字，只把文字发给你选择的翻译服务，再把译文画回原处。支持 OpenAI 兼容接口（DeepSeek、通义千问、智谱 GLM、Kimi、豆包、硅基流动、OpenRouter、Ollama 等）、Claude、Gemini，以及不需要 key 的 Google 翻译。页面默认显示原图，点工具栏的翻译按钮后整本显示译文，从当前页开始在后台把每一章依次翻译完，退出漫画也会继续翻。翻译设置和译文可以随用户数据导出、导入。详见 [doc/page-translation.md](doc/page-translation.md)。

### 自己构建

1. 克隆仓库：`git clone https://github.com/Et3rW/PicaComic`
2. 安装 Flutter 3.47.0（与仓库里锁定的依赖版本一致）：https://docs.flutter.dev/get-started/install
3. 按 Flutter 官方文档构建对应平台：https://docs.flutter.dev/deployment

发布流程见 [doc/releasing.md](doc/releasing.md)，漫画源的测试见 [doc/source-tests.md](doc/source-tests.md)。

### 致谢

- 禁漫图片的重排算法来自 [tonquer/JMComic-qt](https://github.com/tonquer/JMComic-qt)。
- 漫画标签的中文翻译来自 [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database)。
- 图片翻译的思路参考了 [ccbkv/PicaComic](https://github.com/ccbkv/PicaComic)。

## Thanks

### Projects
[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=tonquer&repo=JMComic-qt)](https://github.com/tonquer/JMComic-qt)

The image restructuring algorithm used to display jm images is from this project.

### Tags Translation
[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=EhTagTranslation&repo=Database)](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.
