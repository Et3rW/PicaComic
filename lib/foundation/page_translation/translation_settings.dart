import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';

import 'translator.dart';

/// Page translation settings, kept in their own file
/// (`page_translation.json` in the app's data directory).
///
/// They are not part of the app settings: the file holds API keys. A data
/// export takes them along, a WebDAV sync only without the keys (see
/// TranslationBackup).
class TranslationSettings extends ChangeNotifier {
  TranslationSettings(this._file) {
    _load();
  }

  final File _file;

  static TranslationSettings? _instance;

  /// Created on first use, from the app's data directory.
  static TranslationSettings get instance => _instance ??=
      TranslationSettings(File('${App.dataPath}/page_translation.json'));

  /// Tests install their own.
  @visibleForTesting
  static set instance(TranslationSettings value) => _instance = value;

  var _targetCode = 'zh';
  var _providers = <TranslatorProvider>[];
  String? _activeId;
  var _prompt = '';

  TargetLanguage get target => TargetLanguage.of(_targetCode);

  List<TranslatorProvider> get providers => List.unmodifiable(_providers);

  /// The service in use: the chosen one, or the first if that was removed.
  TranslatorProvider? get activeProvider =>
      _providers.where((p) => p.id == _activeId).firstOrNull ??
      _providers.firstOrNull;

  /// The user's own system message, or '' when the built-in one is used.
  String get customPrompt => _prompt;

  /// The system message sent to models.
  String get prompt => _prompt.trim().isEmpty ? builtInTranslationPrompt : _prompt;

  void _load() {
    try {
      if (!_file.existsSync()) return;
      var json = jsonDecode(_file.readAsStringSync());
      if (json is! Map) return;
      _targetCode = TargetLanguage.of(json['target'] as String?).code;
      _providers = [
        if (json['providers'] is List)
          for (var item in json['providers'] as List)
            if (TranslatorProvider.fromJson(item) case var provider?) provider,
      ];
      _activeId = json['active'] as String?;
      _prompt = json['prompt'] is String ? json['prompt'] as String : '';
    } catch (_) {
      // A damaged file is treated as no settings.
    }
  }

  /// Everything as stored. Without [keys], the services' API keys are left
  /// out, for copies kept on a server.
  Map<String, dynamic> toJson({bool keys = true}) => {
        'target': _targetCode,
        'providers': [
          for (var provider in _providers)
            (keys ? provider : provider.copyWith(key: '')).toJson(),
        ],
        'active': _activeId,
        'prompt': _prompt,
      };

  /// Takes on settings from a backup written by [toJson]. Its services
  /// replace the ones with the same id and are added to the others; a
  /// service saved without its key keeps the key it has here.
  void importJson(Object? json) {
    if (json is! Map) return;
    if (json['target'] is String) {
      _targetCode = TargetLanguage.of(json['target'] as String).code;
    }
    if (json['prompt'] is String) _prompt = json['prompt'] as String;
    if (json['providers'] is List) {
      for (var item in json['providers'] as List) {
        var provider = TranslatorProvider.fromJson(item);
        if (provider == null) continue;
        var index = _providers.indexWhere((p) => p.id == provider!.id);
        if (index < 0) {
          _providers.add(provider);
          continue;
        }
        if (provider.key.isEmpty) {
          provider = provider.copyWith(key: _providers[index].key);
        }
        _providers[index] = provider;
      }
    }
    var active = json['active'];
    if (active is String && _providers.any((p) => p.id == active)) {
      _activeId = active;
    }
    _save();
  }

  void _save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode(toJson()));
    notifyListeners();
  }

  void setTarget(String code) {
    _targetCode = TargetLanguage.of(code).code;
    _save();
  }

  /// Stores [value] as the system message; blank or the built-in text goes
  /// back to following the built-in one.
  void setPrompt(String value) {
    _prompt = value.trim() == builtInTranslationPrompt.trim() ? '' : value.trim();
    _save();
  }

  /// Adds [provider], or replaces the entry with the same id. The first
  /// service added becomes the active one.
  void saveProvider(TranslatorProvider provider) {
    var index = _providers.indexWhere((p) => p.id == provider.id);
    if (index < 0) {
      _providers.add(provider);
    } else {
      _providers[index] = provider;
    }
    _activeId ??= provider.id;
    _save();
  }

  void removeProvider(String id) {
    _providers.removeWhere((p) => p.id == id);
    if (_activeId == id) _activeId = _providers.firstOrNull?.id;
    _save();
  }

  void setActive(String id) {
    if (_providers.any((p) => p.id == id)) {
      _activeId = id;
      _save();
    }
  }
}
