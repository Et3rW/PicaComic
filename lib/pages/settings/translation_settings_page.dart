import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/page_translation/model_store.dart';
import 'package:pica_comic/foundation/page_translation/page_translation_service.dart';
import 'package:pica_comic/foundation/page_translation/translation_settings.dart';
import 'package:pica_comic/foundation/page_translation/translator.dart';
import 'package:pica_comic/tools/translations.dart';

String translatorKindLabel(TranslatorKind kind) => switch (kind) {
      TranslatorKind.google => 'Google 翻译（免 Key）'.tl,
      TranslatorKind.openai => 'OpenAI 兼容'.tl,
      TranslatorKind.anthropic => 'Claude',
      TranslatorKind.gemini => 'Gemini',
    };

/// What the user has to do about [problem], in a sentence.
String translationProblemMessage(TranslationProblem problem) =>
    switch (problem) {
      TranslationProblem.unsupported => '图片翻译目前只支持 Android'.tl,
      TranslationProblem.modelsMissing => '请先在设置里下载文字识别模型'.tl,
      TranslationProblem.noProvider => '请先在设置里添加并填好一个翻译服务'.tl,
    };

String translationFailureMessage(TranslationException e) =>
    switch (e.failure) {
      TranslationFailure.refused => '翻译服务拒绝了这段内容'.tl,
      TranslationFailure.unauthorized => 'Key 无效, 或没有权限使用这个模型'.tl,
      TranslationFailure.notFound => '接口地址或模型名不对'.tl,
      TranslationFailure.rateLimited => '请求太频繁, 请稍后再试'.tl,
      TranslationFailure.badAnswer => '翻译服务的回答格式不对'.tl,
      TranslationFailure.other => '请求失败'.tl,
    };

String _megabytes(int bytes) => (bytes / 1000000).toStringAsFixed(1);

/// Settings > Reading > Page translation.
class TranslationSettingsPage extends StatefulWidget {
  const TranslationSettingsPage({super.key});

  @override
  State<TranslationSettingsPage> createState() =>
      _TranslationSettingsPageState();
}

class _TranslationSettingsPageState extends State<TranslationSettingsPage> {
  TranslationSettings get settings => TranslationSettings.instance;
  ModelStore get models => ModelStore.instance;
  PageTranslationService get service => PageTranslationService.instance;

  @override
  void initState() {
    super.initState();
    settings.addListener(_changed);
    models.addListener(_changed);
  }

  @override
  void dispose() {
    settings.removeListener(_changed);
    models.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var supported = PageTranslationService.isSupported;
    return Scaffold(
      appBar: Appbar(title: Text('图片翻译'.tl)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '在本机识别页面上的文字, 只把文字发给翻译服务, 再把译文盖在原处。'
                      '在阅读器工具栏里点翻译按钮开启。'
                  .tl,
              style: TextStyle(color: context.colorScheme.outline),
            ),
          ),
          if (!supported)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('图片翻译目前只支持 Android'.tl),
            ),
          _buildModels(supported),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text('翻译成'.tl),
            trailing: DropdownButton<String>(
              value: settings.target.code,
              underline: const SizedBox(),
              items: [
                for (var language in TargetLanguage.all)
                  DropdownMenuItem(
                      value: language.code, child: Text(language.label)),
              ],
              onChanged: (code) {
                if (code != null) settings.setTarget(code);
              },
            ),
          ),
          const Divider(),
          ListTile(title: Text('翻译服务'.tl)),
          for (var provider in settings.providers) _buildProvider(provider),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text('添加翻译服务'.tl),
            onTap: _addProvider,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: Text('翻译提示词'.tl),
            subtitle: Text(settings.customPrompt.isEmpty
                ? '使用内置提示词'.tl
                : '已自定义'.tl),
            trailing: const Icon(Icons.arrow_right),
            onTap: _editPrompt,
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text('清除已保存的译文'.tl),
            subtitle: Text('已保存 @n 页'.tlParams({'n': '${service.store.count}'})),
            onTap: () => showConfirmDialog(
              context,
              '清除已保存的译文'.tl,
              '清除后, 再次阅读时会重新识别和翻译'.tl,
              () {
                service.clearAll();
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModels(bool supported) {
    String subtitle;
    Widget? trailing;
    if (models.isDownloading) {
      subtitle = '${'下载中'.tl} ${_megabytes(models.received)} / '
          '${_megabytes(ModelStore.totalBytes)} MB';
      trailing = TextButton(
          onPressed: models.cancelDownload, child: Text('取消'.tl));
    } else if (models.isInstalled) {
      subtitle = '已安装, 占用 @n MB'
          .tlParams({'n': _megabytes(models.installedBytes)});
      trailing = TextButton(
        onPressed: () => showConfirmDialog(
            context, '删除文字识别模型'.tl, '删除后需要重新下载才能翻译'.tl, models.remove),
        child: Text('删除'.tl),
      );
    } else {
      subtitle = models.error != null
          ? '${'下载失败'.tl}: ${models.error}'
          : '未安装, 约 @n MB'
              .tlParams({'n': _megabytes(ModelStore.totalBytes)});
      trailing = FilledButton.tonal(
        onPressed: supported ? models.download : null,
        child: Text('下载'.tl),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.document_scanner_outlined),
          title: Text('文字识别模型'.tl),
          subtitle: Text(subtitle),
          trailing: trailing,
        ),
        if (models.isDownloading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: (models.received / ModelStore.totalBytes).clamp(0.0, 1.0),
            ),
          ),
      ],
    );
  }

  Widget _buildProvider(TranslatorProvider provider) {
    var active = settings.activeProvider?.id == provider.id;
    var detail = [
      translatorKindLabel(provider.kind),
      if (provider.kind.usesModel && provider.model.isNotEmpty) provider.model,
      if (!provider.isUsable) '未填完整'.tl,
    ].join(' · ');
    return ListTile(
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? context.colorScheme.primary : null,
      ),
      title: Text(provider.name.isEmpty
          ? translatorKindLabel(provider.kind)
          : provider.name),
      subtitle: Text(detail),
      trailing: IconButton(
        icon: const Icon(Icons.edit_outlined),
        tooltip: '编辑'.tl,
        onPressed: () => _editProvider(provider, isNew: false),
      ),
      onTap: () => settings.setActive(provider.id),
    );
  }

  Future<void> _addProvider() async {
    var preset = await showDialog<TranslatorPreset>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('添加翻译服务'.tl),
        children: [
          for (var preset in translatorPresets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(preset),
              child: Text(preset.name.tl),
            ),
        ],
      ),
    );
    if (preset == null || !mounted) return;
    var provider = TranslatorProvider(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: preset.kind == TranslatorKind.google || preset.url.isEmpty
          ? (preset.kind == TranslatorKind.openai ? '' : preset.name.tl)
          : preset.name.tl,
      kind: preset.kind,
      url: preset.url,
      model: preset.model,
    );
    if (preset.kind == TranslatorKind.google) {
      settings.saveProvider(provider);
      return;
    }
    await _editProvider(provider, isNew: true);
  }

  Future<void> _editProvider(TranslatorProvider provider,
      {required bool isNew}) async {
    await context.to(
        () => _ProviderEditPage(provider: provider, isNew: isNew));
  }

  Future<void> _editPrompt() async {
    var controller = TextEditingController(text: settings.prompt);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('翻译提示词'.tl),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                r'发给模型的说明。$target 会换成目标语言的名字。Google 翻译不使用它。'
                    .tl,
                style: TextStyle(
                    fontSize: 13, color: context.colorScheme.outline),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: TextField(
                  controller: controller,
                  maxLines: 12,
                  minLines: 6,
                  style: const TextStyle(fontSize: 13),
                  decoration:
                      const InputDecoration(border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => controller.text = builtInTranslationPrompt,
            child: Text('恢复默认'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () {
              settings.setPrompt(controller.text);
              Navigator.of(context).pop();
            },
            child: Text('保存'.tl),
          ),
        ],
      ),
    );
    controller.dispose();
  }
}

class _ProviderEditPage extends StatefulWidget {
  const _ProviderEditPage({required this.provider, required this.isNew});

  final TranslatorProvider provider;
  final bool isNew;

  @override
  State<_ProviderEditPage> createState() => _ProviderEditPageState();
}

class _ProviderEditPageState extends State<_ProviderEditPage> {
  late var kind = widget.provider.kind;
  late final name = TextEditingController(text: widget.provider.name);
  late final url = TextEditingController(text: widget.provider.url);
  late final key = TextEditingController(text: widget.provider.key);
  late final model = TextEditingController(text: widget.provider.model);
  var showKey = false;
  var busy = false;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    key.dispose();
    model.dispose();
    super.dispose();
  }

  TranslatorProvider get current => widget.provider.copyWith(
        name: name.text.trim(),
        kind: kind,
        url: url.text.trim(),
        key: key.text.trim(),
        model: model.text.trim(),
      );

  String get urlHint => switch (kind) {
        TranslatorKind.openai => 'https://api.example.com/v1',
        TranslatorKind.anthropic => 'https://api.anthropic.com',
        TranslatorKind.gemini => 'https://generativelanguage.googleapis.com',
        TranslatorKind.google => '',
      };

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } on TranslationException catch (e) {
      showToast(message: '${translationFailureMessage(e)}\n${e.message}');
    } catch (e) {
      showToast(message: '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _test() => _run(() async {
        var result = await Translator(current,
                systemPrompt: TranslationSettings.instance.prompt)
            .translate(const ['Hello, how are you?'],
                TranslationSettings.instance.target);
        showToast(message: '${'测试成功'.tl}: ${result.first}');
      });

  Future<void> _pickModel() => _run(() async {
        var names = await Translator(current).listModels();
        if (!mounted) return;
        if (names.isEmpty) {
          showToast(message: '这个服务没有返回模型列表'.tl);
          return;
        }
        var picked = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text('选择模型'.tl),
            children: [
              for (var name in names)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(name),
                  child: Text(name),
                ),
            ],
          ),
        );
        if (picked != null) model.text = picked;
      });

  void _save() {
    TranslationSettings.instance.saveProvider(current);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    var isGoogle = kind == TranslatorKind.google;
    return Scaffold(
      appBar: Appbar(
        title: Text(widget.isNew ? '添加翻译服务'.tl : '编辑翻译服务'.tl),
        actions: [
          if (!widget.isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除'.tl,
              onPressed: () => showConfirmDialog(
                  context, '删除'.tl, '删除这个翻译服务?'.tl, () {
                TranslationSettings.instance.removeProvider(widget.provider.id);
                Navigator.of(context).pop();
              }),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: name,
            decoration: InputDecoration(
                labelText: '名称'.tl, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: InputDecoration(
                labelText: '接口格式'.tl, border: const OutlineInputBorder()),
            child: DropdownButton<TranslatorKind>(
              value: kind,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox(),
              items: [
                for (var value in TranslatorKind.values)
                  DropdownMenuItem(
                      value: value, child: Text(translatorKindLabel(value))),
              ],
              onChanged: (value) {
                if (value != null) setState(() => kind = value);
              },
            ),
          ),
          if (!isGoogle) ...[
            const SizedBox(height: 12),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: kind == TranslatorKind.openai
                    ? '接口地址'.tl
                    : '接口地址（留空用官方地址）'.tl,
                hintText: urlHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: key,
              obscureText: !showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => showKey = !showKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: model,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '模型'.tl,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.list),
                  tooltip: '获取模型列表'.tl,
                  onPressed: busy ? null : _pickModel,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Key 只保存在这台设备上, 不会随数据同步。'.tl,
            style:
                TextStyle(fontSize: 13, color: context.colorScheme.outline),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton(
                onPressed: busy ? null : _test,
                child: Text(busy ? '请稍候'.tl : '测试'.tl),
              ),
              const Spacer(),
              FilledButton(onPressed: _save, child: Text('保存'.tl)),
            ],
          ),
        ],
      ),
    );
  }
}
