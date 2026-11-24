import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';

/// A media transport or decode failure. OCR failures have a separate path.
class CaptionFrameUnavailable implements Exception {
  const CaptionFrameUnavailable(this.message);
  final String message;
}

typedef CaptionFrame = ({int ms, Uint8List png});

/// The foreground player stays on its own timeline. This decoder has no audio
/// output, widget, Surface, or attachment to the playback controller.
class CaptionFrameReader {
  CaptionFrameReader._(this._player, this.token);

  final Player _player;
  final CancelToken token;

  static Future<CaptionFrameReader> create(
    Map<String, String> headers, CancelToken token,
  ) async {
    token.throwIfCancelled();
    final player = await Player.create(configuration: const PlayerConfiguration(
      vo: 'null',
      options: {
        'vid': 'auto', 'aid': 'no', 'ao': 'null', 'sid': 'no', 'hwdec': 'no',
        'vd-lavc-threads': '2', 'demuxer-max-bytes': '8MiB',
        'demuxer-max-back-bytes': '1MiB', 'cache-secs': '2',
      },
    ));
    player.setMediaHeader(userAgent: headers['user-agent'], referer: headers['referer'] ?? '');
    return CaptionFrameReader._(player, token);
  }

  Future<void> _waitFor(bool Function() ready, String error) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      token.throwIfCancelled();
      if (ready()) return;
      if (elapsed.elapsed >= const Duration(seconds: 7)) {
        throw CaptionFrameUnavailable(error);
      }
      await Future<void>.delayed(const Duration(milliseconds: 65));
    }
  }

  Future<int> open(String url, int fallbackDuration) async {
    token.throwIfCancelled();
    await _player.open(Media(url), play: false);
    await _waitFor(() =>
        _player.getProperty('path') == url &&
        (_player.state.videoParams.w ?? 0) > 0 &&
        _player.getProperty('seeking') == 'no' &&
        _player.getProperty('idle-active') == 'no',
        '读流或视频解码未就绪');
    final actual = _player.state.duration.inMilliseconds;
    return actual > 0 ? actual : fallbackDuration;
  }

  Future<CaptionFrame> at(int ms) async {
    token.throwIfCancelled();
    await _player.command(['seek', (ms / 1000).toStringAsFixed(3), 'absolute+exact']);
    await _waitFor(() {
      final seconds = double.tryParse(_player.getProperty('time-pos'));
      return seconds != null && (seconds * 1000 - ms).abs() <= 300 &&
          _player.getProperty('seeking') == 'no';
    }, '跳转到抽样时间点失败');
    final frame = await captureCaptionFrame(_player);
    if (frame == null) throw const CaptionFrameUnavailable('播放器没有输出视频帧');
    return frame;
  }

  Future<void> dispose() => _player.dispose();
}

extension CaptionCancellation on CancelToken {
  void throwIfCancelled() {
    if (isCancelled) throw cancelError!;
  }
}

/// mpv's video-only screenshot excludes landscape panels, danmaku and app UI.
Future<CaptionFrame?> captureCaptionFrame(Player player) async {
  final ms = player.state.position.inMilliseconds;
  final frame = await player.screenshot();
  if (frame == null) return null;
  try {
    final width = math.min(frame.width, 1280);
    final top = frame.height ~/ 2;
    final height = math.max(1, ((frame.height - top) * width / frame.width).round());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      frame,
      ui.Rect.fromLTRB(0, top.toDouble(), frame.width.toDouble(), frame.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    try {
      final band = await picture.toImage(width, height);
      try {
        final data = await band.toByteData(format: ui.ImageByteFormat.png);
        return data == null ? null :
            (ms: ms, png: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      } finally {
        band.dispose();
      }
    } finally {
      picture.dispose();
    }
  } finally {
    frame.dispose();
  }
}
