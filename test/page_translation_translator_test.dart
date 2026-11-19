import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/translator.dart';

import 'support/fake_http.dart';

// What is sent to each kind of translation service and how its answers,
// refusals and errors are read. No request leaves the machine.
void main() {
  final http = useFakeHttp();
  final zh = TargetLanguage.of('zh');
  const lines = ['WHAT ARE YOU DOING HERE?', 'LATER THAT DAY'];
  final answer = jsonEncode({
    'translations': ['你在这里做什么？', '当天晚些时候'],
  });

  TranslatorProvider provider(TranslatorKind kind,
          {String url = '', String key = 'secret', String model = 'm1'}) =>
      TranslatorProvider(
          id: 'p', name: 'test', kind: kind, url: url, key: key, model: model);

  Map<String, dynamic> body() =>
      Map<String, dynamic>.from(http.requests.last.data as Map);

  group('OpenAI-compatible', () {
    test('request and answer', () async {
      http.text('api.example/v1/chat/completions', jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'role': 'assistant', 'content': answer},
          },
        ],
      }));
      final result = await Translator(
              provider(TranslatorKind.openai, url: 'https://api.example/v1/'))
          .translate(lines, zh);
      expect(result, ['你在这里做什么？', '当天晚些时候']);

      final request = http.requests.last;
      expect(request.uri.toString(),
          'https://api.example/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(body()['model'], 'm1');
      final messages = body()['messages'] as List;
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], contains('译成简体中文'));
      expect(messages[0]['content'], isNot(contains(r'$target')));
      expect(jsonDecode(messages[1]['content'] as String), {'lines': lines});
    });

    test('no key, no Authorization header (a local server)', () async {
      http.text('127.0.0.1:11434/v1/chat/completions', jsonEncode({
        'choices': [
          {
            'message': {'content': answer},
          },
        ],
      }));
      await Translator(provider(TranslatorKind.openai,
              url: 'http://127.0.0.1:11434/v1', key: ''))
          .translate(lines, zh);
      expect(http.requests.last.headers.containsKey('Authorization'), isFalse);
    });

    test('addresses are completed whichever form the user typed', () {
      expect(Translator.openAiBase('https://api.deepseek.com'),
          'https://api.deepseek.com/v1');
      expect(Translator.openAiBase('https://api.deepseek.com/'),
          'https://api.deepseek.com/v1');
      expect(Translator.openAiBase('https://api.openai.com/v1'),
          'https://api.openai.com/v1');
      expect(
          Translator.openAiBase(
              'https://open.bigmodel.cn/api/paas/v4/chat/completions'),
          'https://open.bigmodel.cn/api/paas/v4');
      expect(Translator.openAiBase(' http://127.0.0.1:11434/v1/models '),
          'http://127.0.0.1:11434/v1');
    });

    test('content filter and explicit refusal', () async {
      final translator = Translator(
          provider(TranslatorKind.openai, url: 'https://filter.example/v1'));
      http.text('filter.example/v1/chat/completions', jsonEncode({
        'choices': [
          {
            'finish_reason': 'content_filter',
            'message': {'content': ''},
          },
        ],
      }));
      await expectLater(
          translator.translate(lines, zh),
          throwsA(isA<TranslationException>()
              .having((e) => e.failure, 'failure', TranslationFailure.refused)));

      http.text('filter.example/v1/chat/completions', jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': null, 'refusal': 'I cannot help with that'},
          },
        ],
      }));
      await expectLater(
          translator.translate(lines, zh),
          throwsA(isA<TranslationException>()
              .having((e) => e.failure, 'failure', TranslationFailure.refused)));
    });

    test('model list', () async {
      http.text('api.example/v1/models', jsonEncode({
        'data': [
          {'id': 'm1'},
          {'id': 'm2'},
        ],
      }));
      expect(
          await Translator(
                  provider(TranslatorKind.openai, url: 'https://api.example/v1'))
              .listModels(),
          ['m1', 'm2']);
    });
  });

  group('Claude', () {
    final translator = Translator(
        provider(TranslatorKind.anthropic, model: 'claude-opus-5-5'));

    test('request and answer, reasoning blocks skipped', () async {
      http.text('api.anthropic.com/v1/messages', jsonEncode({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {'type': 'text', 'text': answer},
        ],
      }));
      expect(await translator.translate(lines, zh),
          ['你在这里做什么？', '当天晚些时候']);

      final request = http.requests.last;
      expect(request.uri.toString(), 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'secret');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(body()['model'], 'claude-opus-5-5');
      expect(body()['max_tokens'], greaterThanOrEqualTo(4096));
      expect(body()['system'], contains('简体中文'));
      expect(body()['messages'], [
        {'role': 'user', 'content': jsonEncode({'lines': lines})},
      ]);
    });

    test('a refusal is not read as a translation', () async {
      http.text('api.anthropic.com/v1/messages', jsonEncode({
        'stop_reason': 'refusal',
        'stop_details': {'type': 'refusal', 'category': 'general_harms'},
        'content': [
          {'type': 'text', 'text': '{"translations": ["x", "y"]}'},
        ],
      }));
      await expectLater(
          translator.translate(lines, zh),
          throwsA(isA<TranslationException>()
              .having((e) => e.failure, 'failure', TranslationFailure.refused)
              .having((e) => e.message, 'message', 'general_harms')));
    });

    test('a custom address replaces the default', () async {
      http.text('gateway.example/v1/messages', jsonEncode({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': answer},
        ],
      }));
      await Translator(provider(TranslatorKind.anthropic,
              url: 'https://gateway.example/'))
          .translate(lines, zh);
      expect(http.urls.last, 'https://gateway.example/v1/messages');
    });

    test('model list', () async {
      http.text('api.anthropic.com/v1/models', jsonEncode({
        'data': [
          {'id': 'claude-opus-5-5', 'display_name': 'Claude Opus 5.5'},
        ],
      }));
      expect(await translator.listModels(), ['claude-opus-5-5']);
    });
  });

  group('Gemini', () {
    final translator =
        Translator(provider(TranslatorKind.gemini, model: 'gemini-x'));
    const endpoint =
        'generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent';

    test('request and answer', () async {
      http.text(endpoint, jsonEncode({
        'candidates': [
          {
            'finishReason': 'STOP',
            'content': {
              'parts': [
                {'text': 'thinking…', 'thought': true},
                {'text': answer},
              ],
            },
          },
        ],
      }));
      expect(await translator.translate(lines, zh),
          ['你在这里做什么？', '当天晚些时候']);
      final request = http.requests.last;
      expect(request.headers['x-goog-api-key'], 'secret');
      // The key is not put in the address.
      expect(request.uri.query, isEmpty);
      expect(body()['system_instruction']['parts'][0]['text'],
          contains('简体中文'));
      expect(jsonDecode(body()['contents'][0]['parts'][0]['text'] as String),
          {'lines': lines});
    });

    test('blocked prompts and blocked answers are refusals', () async {
      http.text(endpoint, jsonEncode({
        'promptFeedback': {'blockReason': 'PROHIBITED_CONTENT'},
      }));
      await expectLater(
          translator.translate(lines, zh),
          throwsA(isA<TranslationException>()
              .having((e) => e.failure, 'failure', TranslationFailure.refused)));
      http.text(endpoint, jsonEncode({
        'candidates': [
          {'finishReason': 'SAFETY'},
        ],
      }));
      await expectLater(
          translator.translate(lines, zh),
          throwsA(isA<TranslationException>()
              .having((e) => e.failure, 'failure', TranslationFailure.refused)));
    });

    test('model list drops the "models/" prefix', () async {
      http.text('generativelanguage.googleapis.com/v1beta/models?', jsonEncode({
        'models': [
          {'name': 'models/gemini-x'},
        ],
      }));
      expect(await translator.listModels(), ['gemini-x']);
    });
  });

  group('Google Translate', () {
    test('one request per line, results in order', () async {
      http.on('translate.googleapis.com/translate_a/single', (request) {
        final q = request.uri.queryParameters;
        expect(q['client'], 'gtx');
        expect(q['sl'], 'auto');
        expect(q['tl'], 'zh-CN');
        return FakeResponse(jsonEncode([
          [
            ['译:${q['q']}', q['q'], null, null, 10],
          ],
          null,
          'en',
        ]));
      });
      final before = http.requests.length;
      final result = await Translator(provider(TranslatorKind.google))
          .translate([...lines, 'third', 'fourth', 'fifth'], zh);
      expect(result, [
        '译:WHAT ARE YOU DOING HERE?',
        '译:LATER THAT DAY',
        '译:third',
        '译:fourth',
        '译:fifth',
      ]);
      expect(http.requests.length - before, 5);
    });

    test('a text of several sentences is joined', () {
      expect(
          Translator.parseGoogle([
            [
              ['你好。', 'Hello. ', null],
              ['再见。', 'Bye.', null],
            ],
            null,
            'en',
          ]),
          '你好。再见。');
      expect(() => Translator.parseGoogle({'error': 1}),
          throwsA(isA<TranslationException>()));
    });
  });

  group('reading a model answer', () {
    test('plain, fenced, wrapped in prose, bare array', () {
      const expected = ['甲', '乙'];
      expect(Translator.parseTranslations('{"translations":["甲","乙"]}', 2),
          expected);
      expect(
          Translator.parseTranslations(
              '```json\n{"translations": ["甲", "乙"]}\n```', 2),
          expected);
      expect(
          Translator.parseTranslations(
              '好的，译文如下：{"translations": [" 甲 ", "乙"]} 希望有帮助', 2),
          expected);
      expect(Translator.parseTranslations('["甲","乙"]', 2), expected);
      expect(Translator.parseTranslations('{"result":["甲","乙"]}', 2), expected);
    });

    test('a wrong number of lines is rejected, never shifted', () {
      expect(
          () => Translator.parseTranslations('{"translations":["甲"]}', 2),
          throwsA(isA<TranslationException>()
              .having((e) => e.failure, 'failure', TranslationFailure.badAnswer)
              .having((e) => e.message, 'message', contains('sent 2'))));
      expect(() => Translator.parseTranslations('抱歉，我无法翻译。', 2),
          throwsA(isA<TranslationException>()));
    });
  });

  group('errors', () {
    Future<TranslationException> failWith(int status, String body) async {
      http.on('errors.example/v1/chat/completions',
          (_) => FakeResponse(body, status: status));
      try {
        await Translator(
                provider(TranslatorKind.openai, url: 'https://errors.example/v1'))
            .translate(lines, zh);
      } on TranslationException catch (e) {
        return e;
      }
      fail('no error');
    }

    test('status codes are told apart and the service message is kept',
        () async {
      var e = await failWith(401, '{"error":{"message":"Incorrect API key"}}');
      expect(e.failure, TranslationFailure.unauthorized);
      expect(e.message, 'HTTP 401: Incorrect API key');
      e = await failWith(404, '{"error":{"message":"model not found"}}');
      expect(e.failure, TranslationFailure.notFound);
      e = await failWith(429, '{"message":"slow down"}');
      expect(e.failure, TranslationFailure.rateLimited);
      expect(e.message, 'HTTP 429: slow down');
      e = await failWith(500, 'upstream exploded');
      expect(e.failure, TranslationFailure.other);
      expect(e.message, contains('upstream exploded'));
    });
  });

  test('providers survive a round trip through settings', () {
    final original = provider(TranslatorKind.gemini, url: 'https://x.example');
    final restored = TranslatorProvider.fromJson(
        jsonDecode(jsonEncode(original.toJson())))!;
    expect(restored.toJson(), original.toJson());
    expect(restored.kind, TranslatorKind.gemini);
    expect(TranslatorProvider.fromJson({'name': 'no id'}), isNull);
    // An unknown kind from a newer version falls back to the common format.
    expect(TranslatorProvider.fromJson({'id': 'a', 'kind': 'future'})!.kind,
        TranslatorKind.openai);
  });

  test('what each kind needs before it can be used', () {
    expect(provider(TranslatorKind.google, key: '', model: '').isUsable, isTrue);
    expect(provider(TranslatorKind.openai, url: '', model: 'm').isUsable,
        isFalse);
    expect(
        provider(TranslatorKind.openai, url: 'http://h/v1', key: '').isUsable,
        isTrue);
    expect(provider(TranslatorKind.anthropic, key: '').isUsable, isFalse);
    expect(provider(TranslatorKind.gemini, model: '').isUsable, isFalse);
    for (final preset in translatorPresets) {
      expect(preset.name, isNotEmpty);
    }
  });
}
