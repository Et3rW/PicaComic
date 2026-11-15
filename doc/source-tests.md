# 漫画源测试

每个内置源有两层检查。

## 1. 解析测试（`test/source_*_test.dart`）

随 `flutter test` 一起运行，不联网。`test/support/fake_http.dart` 把网络层换成替身（`AppHttpAdapter.testAdapter`），各源的请求和解析代码原样运行，响应来自 `test/fixtures/` 里保存的页面。没有登记的地址一律返回 404，测试不会意外访问真实网站。

| 源 | 素材来源 |
| --- | --- |
| e-hentai、绅士漫画、hitomi | 从网站保存的真实页面 |
| 禁漫 | 真实接口响应，保存的是解密后的 JSON，测试时按请求里的时间戳重新加密 |
| 哔咔 | 手写（所有接口都要登录，没法匿名抓取），只能防止我们自己的解析代码改坏 |
| nhentai | 原有的 `test/nhentai_*_test.dart` |

素材由 `tool/make_fixtures.py` 从抓到的页面生成：保留网站原样的标记，只裁掉多余的条目，并把标题、用户名、评论、标签换成占位文字，不把别人的内容抄进仓库。

### 网站改版后更新素材

1. 把页面保存到一个临时目录（不要放进仓库），文件名如下：

   | 文件 | 地址 |
   | --- | --- |
   | `eh/nonh_l.html`、`nonh_m.html`、`nonh_e.html`、`nonh_t.html` | `https://e-hentai.org/?f_cats=767&inline_set=dm_l`（`dm_m`、`dm_e`、`dm_t`） |
   | `eh/gallery.html`、`eh/reader.html` | 列表里任意一个画廊页，以及它的第一张图的阅读页 |
   | `ht/home.html`、`ht/list.html`、`ht/search.html` | 绅士漫画首页、`/albums-index-page-1.html`、`/search/?q=touhou&f=_all&s=create_time_DESC&syn=yes` |
   | `ht/info.html`、`ht/gallery.js` | `/photos-index-page-1-aid-<id>.html`、`/photos-gallery-aid-<id>.html` |
   | `hitomi/block.html`、`hitomi/gallery.js`、`hitomi/gg.js` | `https://ltn.<域名>/galleryblock/<id>.html`、`/galleries/<id>.js`、`/gg.js` |
   | `jm/*.json` | `tool/capture_jm.py https://<接口域名> <目录>/jm` |

2. 运行 `python3 tool/make_fixtures.py <临时目录> test/fixtures`（需要 `beautifulsoup4`）。
3. 运行测试。画廊编号、页数这类写在断言里的值会变，按新素材改掉；如果是解析结果不对，那就是要修的地方。

图片加载（`test/image_manager_test.dart`）用同一个替身测试：下载并写入缓存、命中缓存不再请求、失败和取消后不留半成品文件、e-hentai 的换线路重试、禁漫和自定义源的处理。

## 2. 线上检查（`test_live/`）

```bash
flutter test test_live
```

直接访问真实网站，对每个源走一遍“列表 → 详情 → 图片地址 → 用应用自己的图片加载通道下载一张图”，并核对缓存里的文件。不在普通测试里，也不在打包流程里。

- 网站有响应但解析不出内容：**失败**。
- 网站连不上（被屏蔽、超时、验证页）：**跳过**，并给出提示，不算失败。
- 哔咔没有账号，只检查服务器是否还接受请求签名。

工作流 **Check comic sources** 每周一自动运行一次，也可以手动触发；失败时 GitHub 会发邮件。GitHub 的服务器可能被部分网站屏蔽，这些源会显示为跳过，需要在本机运行上面的命令来检查。
