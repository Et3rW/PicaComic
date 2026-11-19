# 发版流程

## 改版本号

只改两处，其余都从 `pubspec.yaml` 读取：

1. `pubspec.yaml` 的 `version`，格式 `主.次.修订+构建号`，例如 `5.1.8+5018`。构建号必须比上一版大，否则 Android 不能覆盖安装。
2. `lib/foundation/def.dart` 的 `appVersion`，应用内显示和检查更新用。

两处不一致时 `test/version_test.dart` 会失败，工作流会在打包前停下。

工作流里的文件名、校验用的版本号和 Android 测试版的应用名（“Pica Comic 测试版 5.2.3”）都由 `pubspec.yaml` 的版本号生成，不用再手动改。测试版的包名固定为 `com.github.pacalini.pica_comic.test519`，不随版本变。

## 版本号规则

版本号是三位。前两位是正式版，按十进制进位，正式版的末位总是 0：5.2.0 之后的正式版是 5.3.0，5.9.0 之后是 6.0.0。末位留给测试版，按十六进制数：5.2.0 发布后的测试版依次是 5.2.1 … 5.2.9、5.2.a … 5.2.f，所以两个正式版之间最多 15 个测试版，之后发下一个正式版 5.3.0。版本号从小到大就是发布顺序。

`pubspec.yaml` 里写的是**最近一次发布的正式版**，`+` 后面的构建号是主版本 × 1000 + 次版本 × 10 + 修订号（5.2.0 是 5020）。发布新正式版时才改它：比如发 5.3.0 时改成 `5.3.0+5030`，同时改 `lib/foundation/def.dart` 的 `appVersion`。`test/version_test.dart` 会检查每一位都在 0 到 9、构建号和版本号对得上。

过渡：5.2.0 之前的测试版用四位版本号（5.1.9.1 到 5.1.9.4，`pubspec.yaml` 当时写的是 5.1.9）。5.1.9 不会作为正式版发布，图片翻译这一批改动合并后作为正式版 5.2.0 发布。

## 测试版

在功能分支上手动运行 **Build Android Test APK**，填入这是上次正式版之后的第几个测试版（`gh workflow run android_test.yml --ref <分支> -f test_number=3`，1 到 15）。工作流据此算出版本号：`pubspec.yaml` 是 5.2.0 时，3 是 5.2.3，10 是 5.2.a。安装包叫 `PicaComic-5.2.3-test.apk`，应用名“Pica Comic 测试版 5.2.3”，预发布的标签用 `v5.2.3`。版本代码是 `pubspec.yaml` 里的构建号乘 100 再加序号（502003），所以后一个测试版总能作为更新装在前一个上面。所有测试版共用一个包名（`.test519`，从 5.1.9 的测试版沿用下来），和正式版并存，不会覆盖正式版的数据；新的测试版都能直接覆盖安装旧的测试版。测试版用一把固定的测试签名（证书 SHA-256 `b0c88322130e114c4ed2cce5533c2eb9e87c7ecaddd0b43025bcae3cfdcf22c5`），工作流会核对证书。没有配置测试签名的 fork 会退回每次临时生成的调试签名，这时新测试版要先卸载旧的才能安装。产物在该次运行的 Artifacts 里，核对 `SHA256SUMS.txt` 后发布为 GitHub 预发布版本。

## 应用内更新

应用检查更新时，正式版只看最新的正式 Release（`releases/latest`），测试版只看测试版的预发布（`v5.2.3`、`v5.2.a` 这种标签，以及 5.2.0 之前的 `v5.1.9.3`；更早的 `v5.1.9-test.N` 不算），两边互不干扰。在 Android 上点“下载”，应用会下载对应的 APK（正式版找 `PicaComic-<版本>.apk`，测试版找 `PicaComic-<版本>-test.apk`），用同一个 Release 里的 SHA256SUMS 文件核对，再交给系统安装；其他平台打开发布页。所以发布时文件名和校验文件都要按上面的规则来。

## 正式版

合并到 `master` 后，在 `master` 上分别运行 **Build Android Release APK**、**Build iOS Release IPA**、**Build macOS Release App**。

- Android 工作流会跑 `test/` 下的全部测试，并校验包名、版本号和发布证书指纹。新增测试文件不需要在工作流里登记。
- 下载三个产物，核对各自的 SHA256SUMS，再创建 `v主.次.修订` 的 Release。应用内的更新检查读取最新的正式 Release。

## 依赖

`pubspec.yaml` 里的 git 依赖都指向 Et3rW 名下的 fork，并锁定到完整的提交号；每个 fork 在该提交上有一个 `pica-pin` 标签。要升级某个依赖时，先把改动同步到 fork，再改这里的提交号并运行 `flutter pub get`。工作流用 `--enforce-lockfile` 安装依赖，`pubspec.lock` 没同步更新会直接失败。

## 发布签名

Android 发布签名保存在仓库的 Actions Secrets 里（`ANDROID_RELEASE_KEYSTORE_BASE64`、`ANDROID_RELEASE_KEYSTORE_PASSWORD`），测试签名也是（`ANDROID_TEST_KEYSTORE_BASE64`、`ANDROID_TEST_KEYSTORE_PASSWORD`，别名 `pica-test`）。Secrets 写入后无法再读出，所以必须另外保留一份密钥库和密码。丢失后只能换签名，用户需要卸载重装。
