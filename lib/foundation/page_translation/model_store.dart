import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/http_client.dart';

import 'ocr_engine.dart';

/// One file of the OCR models, with the public places it can be fetched from.
/// They are tried in order, so one blocked host does not prevent the install.
class ModelFile {
  const ModelFile(this.name, this.minBytes, this.urls);

  final String name;

  /// A download smaller than this is an error page, not the model.
  final int minBytes;

  final List<String> urls;
}

/// Downloads and keeps the OCR models. Nothing is shipped with the app: the
/// two models are about 21 MB together and only needed by people who use
/// page translation.
///
/// - Text detection: PP-OCRv4 mobile detection (PaddleOCR, Apache-2.0).
/// - Text recognition: PP-OCRv5 mobile recognition, which reads Simplified
///   and Traditional Chinese, Japanese and English, horizontal and vertical.
///
/// Both are the ONNX conversions published by the RapidOCR project.
class ModelStore extends ChangeNotifier {
  ModelStore(this.directory);

  static ModelStore? _instance;

  /// Created on first use, in the app's data directory.
  static ModelStore get instance =>
      _instance ??= ModelStore('${App.dataPath}/translation_models');

  /// Tests install their own.
  @visibleForTesting
  static set instance(ModelStore value) => _instance = value;

  final String directory;

  static const files = [
    ModelFile('det.onnx', 3 * 1000 * 1000, [
      'https://hf-mirror.com/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_det_infer.onnx',
      'https://huggingface.co/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_det_infer.onnx',
    ]),
    ModelFile('rec.onnx', 10 * 1000 * 1000, [
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx',
    ]),
    ModelFile('dict.txt', 30 * 1000, [
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt',
    ]),
  ];

  /// Rough size of everything, shown before downloading.
  static const totalBytes = 21500000;

  var _downloading = false;
  var _received = 0;
  String? _error;
  CancelToken? _cancel;

  bool get isDownloading => _downloading;

  /// Bytes received in the running download.
  int get received => _received;

  /// Why the last download failed, if it did.
  String? get error => _error;

  File _file(String name) => File('$directory/$name');

  bool get isInstalled => files.every((file) {
        var local = _file(file.name);
        return local.existsSync() && local.lengthSync() >= file.minBytes;
      });

  OcrModelPaths get paths => OcrModelPaths(
        detector: _file('det.onnx').path,
        recognizer: _file('rec.onnx').path,
        dictionary: _file('dict.txt').path,
      );

  /// Space the installed files take.
  int get installedBytes {
    var total = 0;
    for (var file in files) {
      var local = _file(file.name);
      if (local.existsSync()) total += local.lengthSync();
    }
    return total;
  }

  /// Fetches every file that is missing. Returns whether the models are
  /// installed afterwards; [error] says why not.
  Future<bool> download() async {
    if (_downloading) return false;
    _downloading = true;
    _received = 0;
    _error = null;
    _cancel = CancelToken();
    notifyListeners();
    try {
      await setNetworkProxy();
      Directory(directory).createSync(recursive: true);
      var done = 0;
      for (var file in files) {
        var local = _file(file.name);
        if (local.existsSync() && local.lengthSync() >= file.minBytes) {
          done += local.lengthSync();
          _received = done;
          continue;
        }
        await _fetch(file, local, done);
        done += local.lengthSync();
      }
    } on DioException catch (e) {
      _error = CancelToken.isCancel(e) ? null : (e.message ?? '${e.error}');
    } catch (e) {
      _error = '$e';
    } finally {
      _downloading = false;
      _cancel = null;
      notifyListeners();
    }
    return isInstalled;
  }

  Future<void> _fetch(ModelFile file, File local, int alreadyDone) async {
    var partial = File('${local.path}.part');
    Object? lastError;
    for (var url in file.urls) {
      try {
        // Large one-off transfer: no logging and no overall time limit.
        var dio = plainDio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ));
        await dio.download(
          url,
          partial.path,
          cancelToken: _cancel,
          onReceiveProgress: (received, _) {
            _received = alreadyDone + received;
            notifyListeners();
          },
        );
        if (partial.lengthSync() < file.minBytes) {
          throw Exception('${file.name}: the download is too small');
        }
        if (local.existsSync()) local.deleteSync();
        partial.renameSync(local.path);
        return;
      } catch (e) {
        if (partial.existsSync()) partial.deleteSync();
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        lastError = e;
      }
    }
    throw lastError ?? Exception('${file.name}: no download address');
  }

  void cancelDownload() => _cancel?.cancel();

  /// Removes the installed files.
  void remove() {
    OcrWorker.instance.release();
    for (var file in files) {
      var local = _file(file.name);
      if (local.existsSync()) local.deleteSync();
    }
    notifyListeners();
  }
}
