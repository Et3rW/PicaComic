import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/tools/keep_screen_on.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:video_player/video_player.dart';

/// Something the player can play: one quality of a video on the site, or a
/// downloaded file.
class PlayableVideo {
  const PlayableVideo.network(this.label, String url)
      : _url = url,
        _file = null;

  const PlayableVideo.file(this.label, String path)
      : _file = path,
        _url = null;

  final String label;
  final String? _url;
  final String? _file;

  bool get isFile => _file != null;

  /// The address, to open in a browser where the player cannot play it.
  String? get url => _url;

  VideoPlayerController createController() => _file != null
      ? VideoPlayerController.file(File(_file))
      : VideoPlayerController.networkUrl(Uri.parse(_url!),
          httpHeaders: const {'User-Agent': webUA});
}

/// Plays a video: tap to show the controls, drag the bar to seek, double tap
/// either side to jump ten seconds.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.title,
    required this.videos,
    this.initialIndex,
    this.startAt = Duration.zero,
    this.timeline,
    this.onProgress,
  });

  final String title;

  /// Lowest quality first.
  final List<PlayableVideo> videos;

  /// The quality to start with; the last one remembered, or the best.
  final int? initialIndex;

  final Duration startAt;

  /// Pictures shown while seeking.
  final R34Timeline? timeline;

  /// Told where playback is now and then, and when the page closes.
  final void Function(Duration position, Duration duration)? onProgress;

  /// The label of the quality last chosen, for the next video.
  static String? preferredLabel;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? controller;
  late int index;
  String? error;
  bool showControls = true;
  Timer? hideTimer;
  Timer? progressTimer;

  /// Where the bar is being dragged to, while it is.
  Duration? seeking;

  double speed = 1.0;

  /// Shown for a moment after a double tap.
  String? jumpHint;
  Timer? jumpTimer;

  bool landscape = false;

  @override
  void initState() {
    super.initState();
    index = widget.initialIndex ?? _preferredIndex();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setKeepScreenOn();
    _open(widget.startAt);
    progressTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _report());
  }

  int _preferredIndex() {
    var label = VideoPlayerPage.preferredLabel;
    var found = widget.videos.indexWhere((v) => v.label == label);
    if (found >= 0) return found;
    // The best that is not 4k: a phone gains little from it and it is large.
    var best = widget.videos.lastIndexWhere((v) {
      var height = R34VideoSource(v.label, '').height;
      return height > 0 && height <= 1080;
    });
    return best >= 0 ? best : widget.videos.length - 1;
  }

  Future<void> _open(Duration position, {bool play = true}) async {
    var old = controller;
    setState(() {
      error = null;
      controller = null;
    });
    await old?.dispose();
    VideoPlayerController next;
    try {
      next = widget.videos[index].createController();
      await next.initialize();
    } catch (e) {
      if (!mounted) return;
      setState(() => error = _describe(e));
      return;
    }
    if (!mounted) {
      next.dispose();
      return;
    }
    next.addListener(_changed);
    if (position > Duration.zero && position < next.value.duration) {
      await next.seekTo(position);
    }
    await next.setPlaybackSpeed(speed);
    if (play) await next.play();
    setState(() => controller = next);
    _scheduleHide();
  }

  String _describe(Object e) {
    if (e is UnimplementedError || e is MissingPluginException) {
      return '这个平台不能在应用里播放视频'.tl;
    }
    if (e is PlatformException) return e.message ?? e.code;
    return '$e';
  }

  void _changed() {
    var value = controller?.value;
    if (value == null) return;
    if (value.hasError && error == null) {
      error = value.errorDescription ?? '播放失败'.tl;
    }
    if (mounted) setState(() {});
  }

  void _report() {
    var value = controller?.value;
    if (value == null || !value.isInitialized) return;
    widget.onProgress?.call(value.position, value.duration);
  }

  void _scheduleHide() {
    hideTimer?.cancel();
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          (controller?.value.isPlaying ?? false) &&
          seeking == null) {
        setState(() => showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => showControls = !showControls);
    if (showControls) _scheduleHide();
  }

  void _togglePlay() {
    var c = controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      if (c.value.position >= c.value.duration) c.seekTo(Duration.zero);
      c.play();
    }
    _scheduleHide();
  }

  void _jump(int seconds) {
    var c = controller;
    if (c == null) return;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    c.seekTo(target);
    jumpTimer?.cancel();
    setState(() => jumpHint = seconds > 0 ? '+${seconds}s' : '${seconds}s');
    jumpTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => jumpHint = null);
    });
  }

  void _chooseQuality() {
    if (widget.videos.length < 2) return;
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('清晰度'.tl),
        children: [
          for (var i = widget.videos.length - 1; i >= 0; i--)
            SimpleDialogOption(
              onPressed: () {
                Navigator.of(context).pop();
                if (i == index) return;
                var position = controller?.value.position ?? Duration.zero;
                var playing = controller?.value.isPlaying ?? true;
                index = i;
                VideoPlayerPage.preferredLabel = widget.videos[i].label;
                _open(position, play: playing);
              },
              child: Row(
                children: [
                  Expanded(child: Text(widget.videos[i].label)),
                  if (i == index) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _chooseSpeed() {
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('倍速'.tl),
        children: [
          for (var s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            SimpleDialogOption(
              onPressed: () {
                Navigator.of(context).pop();
                speed = s;
                controller?.setPlaybackSpeed(s);
                setState(() {});
              },
              child: Row(
                children: [
                  Expanded(child: Text('${s}x')),
                  if (s == speed) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _toggleLandscape() {
    landscape = !landscape;
    SystemChrome.setPreferredOrientations(landscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : DeviceOrientation.values);
    setState(() {});
  }

  @override
  void dispose() {
    _report();
    hideTimer?.cancel();
    jumpTimer?.cancel();
    progressTimer?.cancel();
    controller?.removeListener(_changed);
    controller?.dispose();
    cancelKeepScreenOn();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  static String _format(Duration d) {
    var h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildVideo()),
          if (showControls || controller == null || error != null)
            Positioned.fill(child: _buildControls()),
        ],
      ),
    );
  }

  Widget _buildVideo() {
    var c = controller;
    if (error != null) return const SizedBox();
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (context, constraints) {
      var width = constraints.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: (details) =>
            _jump(details.localPosition.dx < width / 2 ? -10 : 10),
        onDoubleTap: () {},
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
            if (c.value.isBuffering) const CircularProgressIndicator(),
            if (jumpHint != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(jumpHint!,
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildControls() {
    var c = controller;
    var value = c?.value;
    var ready = value != null && value.isInitialized;
    var duration = ready ? value.duration : Duration.zero;
    var position = seeking ?? (ready ? value.position : Duration.zero);
    var max = duration.inMilliseconds.toDouble();
    var current =
        position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble();
    const white = TextStyle(color: Colors.white);
    var preview = seeking == null ? null : widget.timeline?.at(seeking!);

    return Stack(
      children: [
        // Tapping the shaded space hides the controls again.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: ready ? _toggleControls : null,
            onDoubleTapDown: ready
                ? (details) => _jump(details.localPosition.dx <
                        MediaQuery.of(context).size.width / 2
                    ? -10
                    : 10)
                : null,
            onDoubleTap: ready ? () {} : null,
            child: Container(color: ready ? Colors.black26 : null),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 16)),
                ),
                if (widget.videos.length > 1)
                  TextButton(
                    onPressed: _chooseQuality,
                    child: Text(widget.videos[index].label, style: white),
                  ),
                TextButton(
                  onPressed: _chooseSpeed,
                  child: Text('${speed}x', style: white),
                ),
              ],
            ),
          ),
        ),
        if (error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white, size: 40),
                  const SizedBox(height: 12),
                  Text(error!, style: white, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton.tonal(
                        onPressed: () => _open(position),
                        child: Text('重试'.tl),
                      ),
                      if (widget.videos[index].url case var url?)
                        FilledButton.tonal(
                          onPressed: () => launchUrlString(url,
                              mode: LaunchMode.externalApplication),
                          child: Text('用其他应用打开'.tl),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          )
        else if (ready && !value.isBuffering)
          Center(
            child: IconButton(
              iconSize: 56,
              icon: Icon(
                value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                color: Colors.white,
              ),
              onPressed: _togglePlay,
            ),
          ),
        if (preview != null)
          Positioned(
            bottom: 96,
            left: 0,
            right: 0,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image(
                  image: CachedImageProvider(preview,
                      headers: const {'User-Agent': webUA}),
                  width: 196,
                  height: 109,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              ),
            ),
          ),
        if (ready)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Text(_format(position), style: white),
                    Expanded(
                      child: Slider(
                        value: current,
                        max: max <= 0 ? 1 : max,
                        onChangeStart: (v) {
                          hideTimer?.cancel();
                          setState(() =>
                              seeking = Duration(milliseconds: v.round()));
                        },
                        onChanged: (v) => setState(
                            () => seeking = Duration(milliseconds: v.round())),
                        onChangeEnd: (v) async {
                          await c!.seekTo(Duration(milliseconds: v.round()));
                          if (mounted) setState(() => seeking = null);
                          _scheduleHide();
                        },
                      ),
                    ),
                    Text(_format(duration), style: white),
                    IconButton(
                      icon: Icon(
                        landscape
                            ? Icons.screen_lock_portrait_outlined
                            : Icons.screen_rotation_outlined,
                        color: Colors.white,
                      ),
                      tooltip: landscape ? '恢复方向'.tl : '横屏'.tl,
                      onPressed: _toggleLandscape,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Opens the player, and records how far the video was watched in the
/// history.
void openVideoPlayer({
  required String title,
  required List<PlayableVideo> videos,
  Duration startAt = Duration.zero,
  R34Timeline? timeline,
  void Function(Duration position, Duration duration)? onProgress,
}) {
  if (videos.isEmpty) {
    showToast(message: '没有可以播放的视频'.tl);
    return;
  }
  App.globalTo(() => VideoPlayerPage(
        title: title,
        videos: videos,
        startAt: startAt,
        timeline: timeline,
        onProgress: onProgress,
      ));
}
