import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/ai_caption_text.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

typedef CaptionClip = ({int durationMs, List<String> urls});

abstract final class FrameCaptions {
  static const _channel = MethodChannel('PiliCat/frameCaptions');
  static int _nextId = 0;

  static List<CaptionClip> clips(PlayUrlModel data, String currentUrl) {
    List<String> candidates(Iterable<String?> urls) =>
        urls.map(subtitleHttpUrl).whereType<String>().toSet().take(5).toList();
    final parts = data.durl;
    if (parts != null && parts.length > 1) {
      final clips = <CaptionClip>[];
      for (final part in parts) {
        final urls = candidates(part.playUrls);
        final duration = part.length ?? 0;
        if (duration <= 0 || urls.isEmpty) return const [];
        clips.add((durationMs: duration, urls: urls));
      }
      return clips;
    }
    final videos = data.dash?.video ?? const <VideoItem>[];
    // A lower-bandwidth AVC track is easier to seek on Android and keeps the
    // playing decoder independent. Keep the original signed URLs on all tracks.
    final scanTracks = videos.where((v) => v.codecid == 7 &&
        (v.height ?? 0) >= 360 && (v.height ?? 0) <= 720).toList()
      ..sort((a, b) => b.height!.compareTo(a.height!));
    final urls = candidates([
      if (scanTracks.isNotEmpty) scanTracks.first.baseUrl,
      currentUrl,
      ...data.cdnTestUrls(),
      if (scanTracks.isNotEmpty) ...?scanTracks.first.backupUrl,
    ]);
    return urls.isEmpty ? const [] : [(durationMs: data.timeLength ?? 0, urls: urls)];
  }

  // Short videos use one frame per two seconds. Long videos are sampled
  // across their full timeline, including the final part.
  static List<int> sampleTimes(int durationMs) {
    if (durationMs <= 0) return const [];
    final count = math.min(120, (durationMs / 2000).ceil());
    return List.generate(count, (i) => (2 * i + 1) * durationMs ~/ (2 * count));
  }

  static Future<String> read({
    required List<CaptionClip> clips,
    required Map<String, String> headers,
    required CancelToken token,
    required void Function(int done, int total) progress,
  }) async {
    if (clips.isEmpty || token.isCancelled) return '';
    final id = ++_nextId;
    bool finished = false;
    Future<void> close() async {
      try {
        await _channel.invokeMethod<void>('close', {'id': id});
      } on PlatformException {
        // The Android activity may already have disposed the reader.
      } on MissingPluginException {
        // An engine that was detached has no remaining reader.
      }
    }
    void check() {
      if (token.isCancelled) throw token.cancelError!;
    }
    unawaited(token.whenCancel.then((_) async {
      if (!finished) await close();
    }));
    final lines = <String>[];
    final distinct = <String>{};
    String previous = '';
    int done = 0;
    int offset = 0;
    int total = clips.fold(0, (ms, clip) => ms + clip.durationMs);
    var times = sampleTimes(total);
    try {
      for (final clip in clips) {
        check();
        if (clips.length > 1 && !times.any((ms) => ms >= offset && ms < offset + clip.durationMs)) {
          offset += clip.durationMs;
          continue;
        }
        final duration = await _channel.invokeMethod<int>('open', {
          'id': id, 'urls': clip.urls, 'headers': headers,
        }).timeout(const Duration(seconds: 35));
        check();
        if (clips.length == 1) {
          total = (duration ?? 0) > 0 ? duration! : clip.durationMs;
          times = sampleTimes(total);
        }
        if (times.isEmpty) throw const FormatException('无法读取视频时长');
        final end = clips.length == 1 ? total : offset + clip.durationMs;
        progress(done, times.length);
        for (final ms in times.where((ms) => ms >= offset && ms < end)) {
          check();
          final text = await _channel.invokeMethod<String>('frame', {
            'id': id, 'ms': ms - offset,
          }).timeout(const Duration(seconds: 20));
          check();
          final line = text?.trim() ?? '';
          final key = line.replaceAll(RegExp(r'\s+'), '');
          if (key.isNotEmpty && key != previous) {
            lines.add(timedCaption(line, ms / 1000));
            distinct.add(key);
            previous = key;
          }
          progress(++done, times.length);
        }
        offset = end;
      }
    } on TimeoutException {
      throw const FormatException('读取视频画面超时，请稍后重试');
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '手机无法读取这条视频的画面');
    } finally {
      finished = true;
      await close();
    }
    // A single static watermark is not evidence of the spoken content.
    if (total >= 15000 && distinct.length < 2) return '';
    return lines.join('\n');
  }
}
