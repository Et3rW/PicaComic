import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/pages/rule34video/video_player_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Plays nothing: every player reports a one-minute 720p video and records
/// what it was asked to do.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final created = <DataSource>[];
  final seeks = <(int, Duration)>[];
  final disposed = <int>[];
  final playing = <int, bool>{};
  final positions = <int, Duration>{};
  final _events = <int, StreamController<VideoEvent>>{};

  /// Addresses that fail to open.
  final failing = <String>{};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    var id = created.length + 1;
    created.add(options.dataSource);
    var events = StreamController<VideoEvent>();
    _events[id] = events;
    var uri = options.dataSource.uri ?? '';
    scheduleMicrotask(() {
      if (failing.any(uri.contains)) {
        events.addError(
            PlatformException(code: 'VideoError', message: 'Source error'));
      } else {
        events.add(VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 1),
          size: const Size(1280, 720),
        ));
      }
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events[playerId]?.close();
  }

  @override
  Future<void> play(int playerId) async {
    playing[playerId] = true;
    _events[playerId]?.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate, isPlaying: true));
  }

  @override
  Future<void> pause(int playerId) async {
    playing[playerId] = false;
    _events[playerId]?.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate, isPlaying: false));
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add((playerId, position));
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.black);
}

void main() {
  late FakeVideoPlatform platform;

  setUpAll(() => AppTranslation.translations = {});

  setUp(() {
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    VideoPlayerPage.preferredLabel = null;
  });

  const videos = [
    PlayableVideo.network('360p', 'https://example.com/v_360.mp4'),
    PlayableVideo.network('1080p', 'https://example.com/v_1080.mp4'),
    PlayableVideo.network('4k', 'https://example.com/v_2160.mp4'),
  ];

  Future<List<(Duration, Duration)>> open(WidgetTester tester,
      {List<PlayableVideo> list = videos,
      Duration startAt = Duration.zero}) async {
    var reports = <(Duration, Duration)>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => VideoPlayerPage(
                  title: 'A video',
                  videos: list,
                  startAt: startAt,
                  onProgress: (p, d) => reports.add((p, d)),
                ),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    return reports;
  }

  /// Players are created and let go of asynchronously, partly outside the
  /// test's clock.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await settle(tester);
  }

  testWidgets('opens the best quality up to 1080p where it was left',
      (tester) async {
    var reports = await open(tester, startAt: const Duration(seconds: 42));
    expect(platform.created.single.uri, 'https://example.com/v_1080.mp4');
    expect(platform.created.single.httpHeaders['User-Agent'], isNotEmpty);
    expect(platform.seeks, [(1, const Duration(seconds: 42))]);
    expect(platform.playing[1], isTrue);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('A video'), findsOneWidget);

    await close(tester);
    // Closing tells where playback was, and frees the player.
    expect(reports.last,
        (const Duration(seconds: 42), const Duration(minutes: 1)));
    expect(platform.disposed, [1]);
  });

  testWidgets('another quality goes on from the same place', (tester) async {
    await open(tester, startAt: const Duration(seconds: 10));
    await tester.tap(find.text('1080p'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('360p'));
    await tester.pump();
    await settle(tester);
    expect(platform.created.map((d) => d.uri),
        ['https://example.com/v_1080.mp4', 'https://example.com/v_360.mp4']);
    expect(platform.disposed, contains(1));
    expect(platform.seeks.last, (2, const Duration(seconds: 10)));
    expect(VideoPlayerPage.preferredLabel, '360p');
    await close(tester);
  });

  testWidgets('the quality chosen last is used for the next video',
      (tester) async {
    VideoPlayerPage.preferredLabel = '4k';
    await open(tester);
    expect(platform.created.single.uri, 'https://example.com/v_2160.mp4');
    await close(tester);
  });

  testWidgets('a video that fails to open says so and offers another app',
      (tester) async {
    platform.failing.add('v_1080');
    await open(tester);
    expect(find.text('Source error'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a downloaded file plays from the disk', (tester) async {
    await open(tester,
        list: const [PlayableVideo.file('已下载', '/data/video.mp4')]);
    expect(platform.created.single.sourceType, DataSourceType.file);
    expect(platform.created.single.uri, 'file:///data/video.mp4');
    // One quality: nothing to choose.
    expect(find.text('已下载'), findsNothing);
    expect(find.text('用其他应用打开'), findsNothing);
    await close(tester);
  });

  testWidgets('double tapping a side jumps ten seconds', (tester) async {
    await open(tester, startAt: const Duration(seconds: 30));
    var size = tester.getSize(find.byType(VideoPlayerPage));
    var right = Offset(size.width * 0.8, size.height / 2);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 400));
    expect(platform.seeks.last, (1, const Duration(seconds: 40)));
    expect(find.text('+10s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await close(tester);
  });
}
