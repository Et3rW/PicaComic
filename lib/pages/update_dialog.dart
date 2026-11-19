import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/update.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Shows the notes of an available update. The notes scroll when they are
/// longer than the dialog. On Android "下载" downloads the update and hands
/// it to the system installer; elsewhere it opens the release page.
///
/// [onDisableCheck] adds a button that turns off the check at start-up.
Future<void> showUpdateDialog(BuildContext context, String notes,
    {VoidCallback? onDisableCheck}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      var maxHeight = MediaQuery.of(dialogContext).size.height * 0.5;
      var controller = ScrollController();
      return AlertDialog(
        title: Text("有可用更新".tl),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight, minWidth: 280),
          child: Scrollbar(
            controller: controller,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: controller,
              padding: const EdgeInsets.only(right: 12),
              child: SelectableText(notes),
            ),
          ),
        ),
        actions: [
          if (onDisableCheck != null)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onDisableCheck();
              },
              child: Text("关闭更新检查".tl),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              startUpdate();
            },
            child: Text("下载".tl),
          ),
        ],
      );
    },
  );
}

/// Downloads and installs the update on Android when the release has an APK;
/// otherwise opens the release page.
void startUpdate() {
  var update = latestAndroidUpdate;
  if (App.isAndroid && update != null) {
    showDialog<void>(
      context: App.globalContext!,
      barrierDismissible: false,
      builder: (_) => _UpdateDownloadDialog(update),
    );
  } else {
    openReleasePage();
  }
}

void openReleasePage() {
  getDownloadUrl().then(
      (url) => launchUrlString(url, mode: LaunchMode.externalApplication));
}

enum _Stage { downloading, checking, ready, failed }

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog(this.update);

  final AndroidUpdate update;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  static const _channel = MethodChannel("pica_comic/update");

  var _stage = _Stage.downloading;
  var _received = 0;
  var _total = 0;
  String? _message;
  File? _apk;
  final _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    _total = widget.update.apk.size;
    _download();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  void _set(_Stage stage, [String? message]) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      _message = message;
    });
  }

  Future<void> _download() async {
    var apk = widget.update.apk;
    try {
      await setNetworkProxy();
      // Only the app's own downloads live here: older ones are removed.
      var dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      var partial = File('${dir.path}/${apk.name}.part');
      var dio = plainDio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      await dio.download(apk.url, partial.path, cancelToken: _cancel,
          onReceiveProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _received = received;
          if (total > 0) _total = total;
        });
      });
      _set(_Stage.checking);
      var checksums = widget.update.checksums;
      if (checksums != null) {
        var listing = await dio.get<String>(checksums.url,
            options: Options(responseType: ResponseType.plain),
            cancelToken: _cancel);
        var expected = checksumFor(listing.data ?? '', apk.name);
        var actual = (await sha256.bind(partial.openRead()).first).toString();
        if (expected == null || expected != actual) {
          partial.deleteSync();
          _set(_Stage.failed, "下载的文件校验失败".tl);
          return;
        }
      }
      var file = partial.renameSync('${dir.path}/${apk.name}');
      _apk = file;
      _set(_Stage.ready);
      await _install();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      _set(_Stage.failed, e.message ?? '${e.error}');
    } catch (e, s) {
      Log.error("Update", "$e\n$s");
      _set(_Stage.failed, '$e');
    }
  }

  Future<void> _install() async {
    try {
      var result = await _channel
          .invokeMethod<String>("install", {"path": _apk!.path});
      if (result == "permission") {
        _set(_Stage.ready, "请允许安装未知应用, 然后返回点击安装".tl);
      } else if (mounted) {
        Navigator.of(context).pop();
      }
    } on PlatformException catch (e) {
      _set(_Stage.failed, e.message ?? e.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    var name = widget.update.apk.name;
    Widget content;
    switch (_stage) {
      case _Stage.downloading:
        var progress = _total > 0 ? _received / _total : null;
        content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(_total > 0
                ? "${_mb(_received)} / ${_mb(_total)}"
                : _mb(_received)),
          ],
        );
      case _Stage.checking:
        content = Text("正在校验".tl);
      case _Stage.ready:
        content = Text(_message ?? "下载完成".tl);
      case _Stage.failed:
        content = Text("${"更新失败".tl}: ${_message ?? ""}");
    }
    return AlertDialog(
      title: Text("下载更新".tl),
      content: content,
      actions: [
        if (_stage == _Stage.failed)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openReleasePage();
            },
            child: Text("在浏览器中下载".tl),
          ),
        if (_stage == _Stage.ready)
          TextButton(onPressed: _install, child: Text("安装".tl)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_stage == _Stage.downloading || _stage == _Stage.checking
              ? "取消".tl
              : "关闭".tl),
        ),
      ],
    );
  }

  static String _mb(int bytes) => "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
}
