import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A small synchronous binding to the ONNX Runtime C API, enough to load a
/// model and run it on one float tensor.
///
/// Inference blocks the calling thread, so this is only used inside the OCR
/// isolate. The library itself comes with the Android build (see
/// android/app/build.gradle); other platforms have none bundled yet and
/// [OrtRuntime.open] throws [UnsupportedError] there.
///
/// `OrtApi` is a table of function pointers that only ever grows at the end.
/// The positions below were read from onnxruntime_c_api.h (1.23.0) and are the
/// same in every release since 1.12, the version requested from the library.
class OrtRuntime {
  OrtRuntime._(this._api, this._env);

  static OrtRuntime? _instance;

  /// Path of the library to load instead of the platform default. Tests point
  /// this at a desktop build of ONNX Runtime.
  static String? libraryPath;

  final Pointer<Pointer<Void>> _api;
  final Pointer<Void> _env;

  static const _apiVersion = 12;

  // Positions in OrtApi.
  static const _getErrorMessage = 2;
  static const _createEnv = 3;
  static const _createSessionFromArray = 8;
  static const _run = 9;
  static const _createSessionOptions = 10;
  static const _setGraphOptimizationLevel = 23;
  static const _setIntraOpNumThreads = 24;
  static const _sessionGetInputCount = 30;
  static const _sessionGetOutputCount = 31;
  static const _sessionGetInputName = 36;
  static const _sessionGetOutputName = 37;
  static const _createTensorWithData = 49;
  static const _getTensorMutableData = 51;
  static const _getDimensionsCount = 61;
  static const _getDimensions = 62;
  static const _getTensorShapeElementCount = 64;
  static const _getTensorTypeAndShape = 65;
  static const _createCpuMemoryInfo = 69;
  static const _allocatorFree = 76;
  static const _getAllocatorWithDefaultOptions = 78;
  static const _releaseStatus = 93;
  static const _releaseMemoryInfo = 94;
  static const _releaseSession = 95;
  static const _releaseValue = 96;
  static const _releaseTensorTypeAndShapeInfo = 99;
  static const _releaseSessionOptions = 100;

  /// Whether a runtime library can be loaded here.
  static bool get isAvailable {
    try {
      open();
      return true;
    } catch (_) {
      return false;
    }
  }

  static OrtRuntime open() {
    var existing = _instance;
    if (existing != null) return existing;
    var library = _openLibrary();
    var getApiBase = library.lookupFunction<Pointer<Pointer<Void>> Function(),
        Pointer<Pointer<Void>> Function()>('OrtGetApiBase');
    // OrtApiBase { GetApi, GetVersionString }
    var getApi = getApiBase()[0]
        .cast<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>>()
        .asFunction<Pointer<Pointer<Void>> Function(int)>();
    var api = getApi(_apiVersion);
    if (api == nullptr) {
      throw UnsupportedError('ONNX Runtime is older than 1.$_apiVersion');
    }
    var runtime = OrtRuntime._(api, nullptr);
    var env = runtime._createEnvironment();
    return _instance = OrtRuntime._(api, env);
  }

  static DynamicLibrary _openLibrary() {
    var path = libraryPath;
    if (path != null) return DynamicLibrary.open(path);
    if (Platform.isAndroid) return DynamicLibrary.open('libonnxruntime.so');
    throw UnsupportedError('ONNX Runtime is not bundled on this platform');
  }

  Pointer<NativeFunction<T>> _at<T extends Function>(int index) =>
      _api[index].cast<NativeFunction<T>>();

  /// Throws when [status] reports an error. ORT returns null on success.
  void _check(Pointer<Void> status) {
    if (status == nullptr) return;
    var message = _at<Pointer<Utf8> Function(Pointer<Void>)>(_getErrorMessage)
        .asFunction<Pointer<Utf8> Function(Pointer<Void>)>()(status)
        .toDartString();
    _release(_releaseStatus, status);
    throw OrtException(message);
  }

  void _release(int index, Pointer<Void> pointer) {
    if (pointer == nullptr) return;
    _at<Void Function(Pointer<Void>)>(index)
        .asFunction<void Function(Pointer<Void>)>()(pointer);
  }

  Pointer<Void> _createEnvironment() {
    return using((arena) {
      var out = arena<Pointer<Void>>();
      var name = 'pica'.toNativeUtf8(allocator: arena);
      // Logging level 3: errors only.
      _check(_at<
                  Pointer<Void> Function(
                      Int32, Pointer<Utf8>, Pointer<Pointer<Void>>)>(_createEnv)
          .asFunction<
              Pointer<Void> Function(
                  int, Pointer<Utf8>, Pointer<Pointer<Void>>)>()(3, name, out));
      return out.value;
    });
  }

  /// Loads the model at [path]. [threads] bounds the CPU threads one run may
  /// use.
  OrtSession openSession(String path, {int threads = 2}) {
    var bytes = File(path).readAsBytesSync();
    var model = malloc<Uint8>(bytes.length);
    var options = nullptr.cast<Void>();
    try {
      model.asTypedList(bytes.length).setAll(0, bytes);
      return using((arena) {
        var out = arena<Pointer<Void>>();
        _check(_at<Pointer<Void> Function(Pointer<Pointer<Void>>)>(
                _createSessionOptions)
            .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>()(out));
        options = out.value;
        _check(_at<Pointer<Void> Function(Pointer<Void>, Int32)>(
                _setIntraOpNumThreads)
            .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(
                options, threads));
        // 99: every graph optimization.
        _check(_at<Pointer<Void> Function(Pointer<Void>, Int32)>(
                _setGraphOptimizationLevel)
            .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(
                options, 99));
        _check(_at<
                    Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, Size,
                        Pointer<Void>, Pointer<Pointer<Void>>)>(
                _createSessionFromArray)
            .asFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int,
                    Pointer<Void>, Pointer<Pointer<Void>>)>()(
            _env, model, bytes.length, options, out));
        var session = out.value;
        return OrtSession._(
          this,
          session,
          _names(session, _sessionGetInputCount, _sessionGetInputName),
          _names(session, _sessionGetOutputCount, _sessionGetOutputName),
        );
      });
    } finally {
      _release(_releaseSessionOptions, options);
      malloc.free(model);
    }
  }

  List<String> _names(Pointer<Void> session, int countIndex, int nameIndex) {
    return using((arena) {
      var count = arena<Size>();
      _check(_at<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>(
              countIndex)
          .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>()(
              session, count));
      var allocatorOut = arena<Pointer<Void>>();
      _check(_at<Pointer<Void> Function(Pointer<Pointer<Void>>)>(
              _getAllocatorWithDefaultOptions)
          .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>()(
              allocatorOut));
      var allocator = allocatorOut.value;
      var names = <String>[];
      for (var i = 0; i < count.value; i++) {
        var out = arena<Pointer<Utf8>>();
        _check(_at<
                    Pointer<Void> Function(Pointer<Void>, Size, Pointer<Void>,
                        Pointer<Pointer<Utf8>>)>(nameIndex)
            .asFunction<
                Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>,
                    Pointer<Pointer<Utf8>>)>()(session, i, allocator, out));
        names.add(out.value.toDartString());
        _check(_at<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>(
                _allocatorFree)
            .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>()(
                allocator, out.value.cast()));
      }
      return names;
    });
  }
}

class OrtException implements Exception {
  OrtException(this.message);

  final String message;

  @override
  String toString() => 'OrtException: $message';
}

/// A float tensor: [data] in row-major order with dimensions [shape].
class OrtTensor {
  OrtTensor(this.data, this.shape);

  final Float32List data;
  final List<int> shape;
}

/// A loaded model.
class OrtSession {
  OrtSession._(this._runtime, this._session, this.inputNames, this.outputNames);

  final OrtRuntime _runtime;
  Pointer<Void> _session;

  final List<String> inputNames;
  final List<String> outputNames;

  /// Runs the model on one float input and returns its first output.
  OrtTensor run(Float32List input, List<int> shape) {
    if (_session == nullptr) throw StateError('session is closed');
    var rt = _runtime;
    var data = malloc<Float>(input.length);
    var memoryInfo = nullptr.cast<Void>();
    var inputValue = nullptr.cast<Void>();
    var outputValue = nullptr.cast<Void>();
    var info = nullptr.cast<Void>();
    try {
      data.asTypedList(input.length).setAll(0, input);
      return using((arena) {
        var out = arena<Pointer<Void>>();
        // Arena allocator (1), default memory type (0).
        rt._check(rt
            ._at<Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>)>(
                OrtRuntime._createCpuMemoryInfo)
            .asFunction<
                Pointer<Void> Function(
                    int, int, Pointer<Pointer<Void>>)>()(1, 0, out));
        memoryInfo = out.value;

        var dims = arena<Int64>(shape.length);
        for (var i = 0; i < shape.length; i++) {
          dims[i] = shape[i];
        }
        // Element type 1: float.
        rt._check(rt
            ._at<
                Pointer<Void> Function(
                    Pointer<Void>,
                    Pointer<Float>,
                    Size,
                    Pointer<Int64>,
                    Size,
                    Int32,
                    Pointer<Pointer<Void>>)>(OrtRuntime._createTensorWithData)
            .asFunction<
                Pointer<Void> Function(
                    Pointer<Void>,
                    Pointer<Float>,
                    int,
                    Pointer<Int64>,
                    int,
                    int,
                    Pointer<Pointer<Void>>)>()(
            memoryInfo, data, input.length * 4, dims, shape.length, 1, out));
        inputValue = out.value;

        var inputName = arena<Pointer<Utf8>>()
          ..value = inputNames.first.toNativeUtf8(allocator: arena);
        var outputName = arena<Pointer<Utf8>>()
          ..value = outputNames.first.toNativeUtf8(allocator: arena);
        var inputs = arena<Pointer<Void>>()..value = inputValue;
        var outputs = arena<Pointer<Void>>()..value = nullptr;
        rt._check(rt
            ._at<
                Pointer<Void> Function(
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Pointer<Utf8>>,
                    Pointer<Pointer<Void>>,
                    Size,
                    Pointer<Pointer<Utf8>>,
                    Size,
                    Pointer<Pointer<Void>>)>(OrtRuntime._run)
            .asFunction<
                Pointer<Void> Function(
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Pointer<Utf8>>,
                    Pointer<Pointer<Void>>,
                    int,
                    Pointer<Pointer<Utf8>>,
                    int,
                    Pointer<Pointer<Void>>)>()(
            _session, nullptr, inputName, inputs, 1, outputName, 1, outputs));
        outputValue = outputs.value;

        rt._check(rt
            ._at<Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
                OrtRuntime._getTensorTypeAndShape)
            .asFunction<
                Pointer<Void> Function(
                    Pointer<Void>, Pointer<Pointer<Void>>)>()(outputValue, out));
        info = out.value;
        var size = arena<Size>();
        rt._check(rt
            ._at<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>(
                OrtRuntime._getDimensionsCount)
            .asFunction<
                Pointer<Void> Function(
                    Pointer<Void>, Pointer<Size>)>()(info, size));
        var rank = size.value;
        var outDims = arena<Int64>(rank);
        rt._check(rt
            ._at<Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, Size)>(
                OrtRuntime._getDimensions)
            .asFunction<
                Pointer<Void> Function(
                    Pointer<Void>, Pointer<Int64>, int)>()(info, outDims, rank));
        rt._check(rt
            ._at<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>(
                OrtRuntime._getTensorShapeElementCount)
            .asFunction<
                Pointer<Void> Function(
                    Pointer<Void>, Pointer<Size>)>()(info, size));
        var count = size.value;

        var dataOut = arena<Pointer<Float>>();
        rt._check(rt
            ._at<
                Pointer<Void> Function(Pointer<Void>,
                    Pointer<Pointer<Float>>)>(OrtRuntime._getTensorMutableData)
            .asFunction<
                Pointer<Void> Function(Pointer<Void>,
                    Pointer<Pointer<Float>>)>()(outputValue, dataOut));
        // Copy: the buffer belongs to the output value released below.
        var result = Float32List.fromList(dataOut.value.asTypedList(count));
        return OrtTensor(result, [for (var i = 0; i < rank; i++) outDims[i]]);
      });
    } finally {
      rt._release(OrtRuntime._releaseTensorTypeAndShapeInfo, info);
      rt._release(OrtRuntime._releaseValue, outputValue);
      rt._release(OrtRuntime._releaseValue, inputValue);
      rt._release(OrtRuntime._releaseMemoryInfo, memoryInfo);
      malloc.free(data);
    }
  }

  void close() {
    _runtime._release(OrtRuntime._releaseSession, _session);
    _session = nullptr;
  }
}
