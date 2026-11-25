import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/services/ai_chat/caption_frame_reader.dart';
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
      currentUrl,
      if (scanTracks.isNotEmpty) scanTracks.first.baseUrl,
      if (scanTracks.isNotEmpty) ...?scanTracks.first.backupUrl,
      ...data.cdnTestUrls(),
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
    void Function(String message)? diagnostic,
  }) async {
    if (clips.isEmpty) throw const CaptionFrameUnavailable('缺少本集可读取的视频地址');
    token.throwIfCancelled();
    final id = ++_nextId;
    CaptionFrameReader? reader;
    final lines = _CaptionLines();
    var total = clips.fold<int>(0, (ms, clip) => ms + clip.durationMs);
    var times = sampleTimes(total);
    var offset = 0;
    var done = 0;
    await _channel.invokeMethod<void>('start', {'id': id});
    try {
      reader = await CaptionFrameReader.create(headers, token);
      for (final clip in clips) {
        final start = offset;
        offset += clip.durationMs;
        if (clips.length > 1 && !times.any((t) => t >= start && t < offset)) continue;
        final sampled = <int>{};
        CaptionFrameUnavailable? failure;
        for (final url in clip.urls.take(3)) {
          token.throwIfCancelled();
          try {
            final duration = await reader.open(url, clip.durationMs);
            if (clips.length == 1) {
              if (duration <= 0) throw const CaptionFrameUnavailable('视频未返回时长');
              if (sampled.isEmpty) {
                total = duration;
                offset = duration;
                times = sampleTimes(total);
              }
            }
            progress(done, times.length);
            for (final t in times.where((t) => t >= start && t < offset && !sampled.contains(t))) {
              final frame = await reader.at(t - start);
              token.throwIfCancelled();
              final line = await _recognize(id, frame, token);
              lines.add(t, line);
              sampled.add(t);
              progress(++done, times.length);
            }
            failure = null;
            break;
          } on CaptionFrameUnavailable catch (e) {
            failure = e;
            diagnostic?.call('字幕抽帧 · ${e.message}');
          } on TimeoutException {
            failure = const CaptionFrameUnavailable('解码器等待视频超时');
          }
        }
        if (failure != null) throw failure;
        if (sampled.isEmpty) throw const CaptionFrameUnavailable('没有可用的视频帧');
      }
      diagnostic?.call('字幕抽帧 · 已读取 $done 帧 · ${lines.distinct.length} 条不同文字');
      return lines.text(total);
    } finally {
      try {
        await reader?.dispose();
      } finally {
        await _channel.invokeMethod<void>('close', {'id': id});
      }
    }
  }

  /// Read a short excerpt using frames the foreground player actually displayed.
  /// The caller owns playback; this method never seeks or starts it.
  static Future<String> readPlaying({
    required Future<CaptionFrame?> Function() capture,
    required int? Function() position,
    required CancelToken token,
    required void Function(int seconds) progress,
    Duration interval = const Duration(milliseconds: 500),
    Duration limit = const Duration(seconds: 30),
  }) async {
    token.throwIfCancelled();
    final id = ++_nextId;
    final lines = _CaptionLines();
    final elapsed = Stopwatch()..start();
    int? last;
    var frameCount = 0;
    await _channel.invokeMethod<void>('start', {'id': id});
    try {
      while (elapsed.elapsed < limit) {
        token.throwIfCancelled();
        final now = position();
        if (now == null) break;
        if (last == null || (now - last).abs() >= 1000) {
          final frame = await capture();
          token.throwIfCancelled();
          if (frame != null) {
            final line = await _recognize(id, frame, token);
            lines.add(frame.ms, line);
            last = frame.ms;
            frameCount++;
          }
        }
        progress(elapsed.elapsed.inSeconds);
        await Future<void>.delayed(interval);
      }
      if (frameCount == 0) throw const CaptionFrameUnavailable('当前播放器未能提供画面');
      return lines.distinct.length >= 2 ? lines.text(0) : '';
    } finally {
      await _channel.invokeMethod<void>('close', {'id': id});
    }
  }

  static Future<String> _recognize(int id, CaptionFrame frame, CancelToken token) async {
    token.throwIfCancelled();
    try {
      final text = await _channel.invokeMethod<String>('recognize', {
        'id': id, 'png': frame.png,
      }).timeout(const Duration(seconds: 20));
      token.throwIfCancelled();
      return text ?? '';
    } on PlatformException catch (e) {
      if (e.code == 'ocr' || e.code == 'image') return '';
      throw FormatException(e.message ?? '手机文字识别失败');
    } on TimeoutException {
      throw const FormatException('手机文字识别超时');
    }
  }
}

class _CaptionLines {
  final distinct = <String>{};
  final lines = <String>[];
  String previous = '';

  void add(int ms, String text) {
    final line = text.trim();
    final key = line.replaceAll(RegExp(r'\s+'), '');
    if (key.isEmpty || previous == key) return;
    previous = key;
    distinct.add(key);
    lines.add(timedCaption(line, ms / 1000));
  }

  String text(int duration) => duration >= 15000 && distinct.length < 2
      ? '' : lines.join('\n');
}
