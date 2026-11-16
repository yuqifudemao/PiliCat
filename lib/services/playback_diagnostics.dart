import 'dart:async' show unawaited;

import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart';

abstract final class PlaybackDiagnostics {
  static const _key = 'playbackDiagnostics';
  static const _limit = 200;
  static final _entries = ValueNotifier<List<String>>(_read());

  static List<String> _read() {
    final saved = GStorage.localCache.get(_key);
    if (saved is! List) return const [];
    return List<String>.unmodifiable(saved.whereType<String>());
  }

  static ValueListenable<List<String>> get entries => _entries;

  // Only pass fixed labels, timings, or non-sensitive numeric results here.
  // Player messages and request URLs may include credentials.
  static void record(String message) {
    final previous = _entries.value;
    final skip = previous.length >= _limit ? previous.length - _limit + 1 : 0;
    final next = List<String>.unmodifiable([
      ...previous.skip(skip),
      '${DateTime.now().toIso8601String()}  $message',
    ]);
    _entries.value = next;
    unawaited(_save(next));
  }

  static Future<void> clear() {
    _entries.value = const [];
    return _save(const []);
  }

  static Future<void> _save(List<String> entries) async {
    try {
      await GStorage.localCache.put(_key, entries);
    } catch (_) {
      // A diagnostics write must never interrupt playback.
    }
  }
}
