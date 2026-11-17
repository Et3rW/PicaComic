# 发版流程

## 改版本号

只改两处，其余都从 `pubspec.yaml` 读取：

1. `pubspec.yaml` 的 `version`，格式 `主.次.修订+构建号`，例如 `5.1.8+5018`。构建号必须比上一版大，否则 Android 不能覆盖安装。
2. `lib/foundation/def.dart` 的 `appVersion`，应用内显示和检查更新用。

两处不一致时 `test/version_test.dart` 会失败，工作流会在打包前停下。

工作流里的文件名、校验用的版本号，以及 Android 测试版的包名后缀（`.test518`）和应用名（“Pica Comic 测试版 5.1.8”），都由 `pubspec.yaml` 的版本号生成，不用再手动改。

## 测试版

在功能分支上手动运行 **Build Android Test APK**，填入这是该版本的第几个测试版（`gh workflow run android_test.yml --ref <分支> -f test_number=3`）。测试版的版本号是四位：5.1.9 的第 3 个测试版是 5.1.9.3，安装包叫 `PicaComic-5.1.9.3-test.apk`，应用名“Pica Comic 测试版 5.1.9.3”，版本代码是 `pubspec.yaml` 里的构建号乘 100 再加序号（501903），所以后一个测试版总能作为更新装在前一个上面。正式版仍是三位版本号。预发布的标签用 `v5.1.9.3`。测试版包名带版本后缀，和正式版并存，不会覆盖正式版的数据。测试版用一把固定的测试签名（证书 SHA-256 `b0c88322130e114c4ed2cce5533c2eb9e87c7ecaddd0b43025bcae3cfdcf22c5`），同一版本的新测试版可以直接覆盖安装旧的；工作流会核对证书。没有配置测试签名的 fork 会退回每次临时生成的调试签名，这时新测试版要先卸载旧的才能安装。产物在该次运行的 Artifacts 里，核对 `SHA256SUMS.txt` 后发布为 GitHub 预发布版本。

## 正式版

合并到 `master` 后，在 `master` 上分别运行 **Build Android Release APK**、**Build iOS Release IPA**、**Build macOS Release App**。

- Android 工作流会跑 `test/` 下的全部测试，并校验包名、版本号和发布证书指纹。新增测试文件不需要在工作流里登记。
- 下载三个产物，核对各自的 SHA256SUMS，再创建 `v主.次.修订` 的 Release。应用内的更新检查读取最新的正式 Release。

## 依赖

`pubspec.yaml` 里的 git 依赖都指向 Et3rW 名下的 fork，并锁定到完整的提交号；每个 fork 在该提交上有一个 `pica-pin` 标签。要升级某个依赖时，先把改动同步到 fork，再改这里的提交号并运行 `flutter pub get`。工作流用 `--enforce-lockfile` 安装依赖，`pubspec.lock` 没同步更新会直接失败。

## 发布签名

Android 发布签名保存在仓库的 Actions Secrets 里（`ANDROID_RELEASE_KEYSTORE_BASE64`、`ANDROID_RELEASE_KEYSTORE_PASSWORD`），测试签名也是（`ANDROID_TEST_KEYSTORE_BASE64`、`ANDROID_TEST_KEYSTORE_PASSWORD`，别名 `pica-test`）。Secrets 写入后无法再读出，所以必须另外保留一份密钥库和密码。丢失后只能换签名，用户需要卸载重装。
