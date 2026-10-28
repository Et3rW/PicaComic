# 5.1.5 正式发布说明

本版本汇总已在 5.1.1–5.1.4 测试版交付的修复：nhentai 登录/退出与收藏状态、详细列表标签、标签热门排序与中文分页，以及禁漫登录无限等待与失败状态处理。用户反馈禁漫更新 API 域名后恢复登录；本版本未额外变更禁漫域名、更新文件解析或请求签名算法。

正式版的更新检查、项目/反馈链接、下载与安装说明指向 Et3rW/PicaComic。版本号统一为 5.1.5（5015）。

## Android

经用户选择，新建独立正式版与长期发布签名，应用标识固定为 `com.github.et3rw.pica_comic`。密钥只保存在本机受限目录及 GitHub Actions Secrets，不提交仓库、不附在 Release 中。后续正式发布必须继续使用相同签名与应用标识。

发布证书 SHA-256：`D7:D2:AA:05:48:7A:C2:2F:2B:9E:C2:14:7D:56:29:53:5E:D7:6B:50:93:8A:41:27:07:AB:90:11:61:B8:90:3B`。

APK 为 release 模式，Android 7.0+，ARM64 和 x86_64。与旧正式版/测试版并存，无需卸载；首次使用本 fork 的正式版需重新登录。系统权限设置页面使用运行时包名，适配新的应用标识。

## iOS

沿用项目既有 unsigned IPA 分发方式，包名为 `PicaComic-5.1.5-unsigned.ipa`，应用标识仍为 `com.github.pacalini.picaComic`。这是 iPhoneOS ARM64 真机 release 包，需用户自行签名安装；未使用 Apple 开发者证书或描述文件，不是 TestFlight/App Store 包。

固定使用 Flutter 3.47.0 和 Xcode 26.3。Flutter 工具链的最低 iOS 部署版本为 15.0，Podfile、Runner 工程及框架配置统一调整为该版本。

## macOS

提供 `PicaComic-5.1.5-macos-universal.zip`，要求 macOS 12.4+，包含 Apple 芯片与 Intel 架构。沿用 macOS 应用标识 `com.github.pacalini.picaComic`，使用 Xcode 本地临时签名；未使用 Apple 开发者证书，也未公证。ZIP 保留应用目录及符号链接，解压后可放入“应用程序”。

## 发布校验

Android 工作流执行现有 57 项回归测试，检查 APK 包名、版本及发布证书指纹；iOS 工作流检查版本、包名、设备平台和 ARM64 架构；macOS 工作流检查版本、最低系统版本、所有原生二进制的双架构及应用签名完整性。各平台分别生成 SHA-256 校验文件。正式 Release 在构建完成、下载后完整性检查通过后创建，不复用临时签名测试 APK。iOS 真机安装及桌面端实际交互仍需用户验证。
