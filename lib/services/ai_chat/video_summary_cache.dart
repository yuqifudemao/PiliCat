import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/models_new/video/video_ai_conclusion/data.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';

typedef SummaryEpisode = ({int account, String bvid, int cid});
typedef SavedAnalysis = ({
  String template,
  String model,
  String source,
  String text,
});

class VideoSummaryCache {
  VideoSummaryCache(this._box, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const retention = Duration(days: 7);
  static const _prefix = 'video-summary-v1/';
  static const _official = 'official';
  final Box<dynamic> _box;
  final DateTime Function() _now;

  String? _key(SummaryEpisode episode) => episode.cid > 0
      ? '$_prefix${episode.account}/${episode.bvid}/${episode.cid}'
      : null;

  // Hive updates its in-memory view synchronously. Keep the read/modify/write
  // together so completing one template never drops a concurrent result.
  Map<dynamic, dynamic> _liveEntries(String? key) {
    final raw = key == null ? null : _box.get(key);
    if (raw is! Map) return {};
    final cutoff = _now().millisecondsSinceEpoch - retention.inMilliseconds;
    final entries = Map.of(raw)..removeWhere(
      (_, item) => item is! Map || item['at'] is! int || (item['at'] as int) <= cutoff,
    );
    if (entries.length != raw.length) unawaited(_write(key!, entries));
    return entries;
  }

  Future<void> _write(String key, Map<dynamic, dynamic> entries) async {
    try {
      if (entries.isEmpty) {
        await _box.delete(key);
      } else {
        await _box.put(key, Map.of(entries));
      }
    } catch (e) {
      debugPrint('本地视频总结缓存写入失败（${e.runtimeType}）');
    }
  }

  Future<void> _save(SummaryEpisode episode, String variant, Object value) async {
    final key = _key(episode);
    if (key == null) return;
    final entries = _liveEntries(key);
    entries[variant] = {'at': _now().millisecondsSinceEpoch, 'value': value};
    await _write(key, entries);
  }

  void pruneExpired() {
    for (final key in _box.keys.whereType<String>().toList()) {
      if (key.startsWith(_prefix)) _liveEntries(key);
    }
  }

  List<SavedAnalysis> analyses(SummaryEpisode episode) {
    final entries = _liveEntries(_key(episode))..remove(_official);
    final sorted = entries.values.whereType<Map>().toList()
      ..sort((a, b) => (a['at'] as int).compareTo(b['at'] as int));
    return [
      for (final item in sorted)
        if (item['value'] case [String template, String model, String source, String text])
          (template: template, model: model, source: source, text: text),
    ];
  }

  Future<void> saveAnalysis(
    SummaryEpisode episode, {
    required SavedAnalysis analysis,
    required String prompt,
    required Map<String, String> profile,
  }) async {
    if (analysis.text.trim().isEmpty) return;
    final identity = jsonEncode([
      analysis.template, prompt, profile['url'], analysis.model, profile['effort'],
    ]);
    final variant = sha256.convert(utf8.encode(identity)).toString();
    await _save(episode, variant, [
      analysis.template, analysis.model, analysis.source, analysis.text,
    ]);
  }

  Future<void> clearAnalyses(SummaryEpisode episode) async {
    final key = _key(episode);
    if (key == null) return;
    final entries = _liveEntries(key)..removeWhere((variant, _) => variant != _official);
    await _write(key, entries);
  }

  AiConclusionData? official(SummaryEpisode episode) {
    final value = _liveEntries(_key(episode))[_official]?['value'];
    if (value is! String) return null;
    try {
      return AiConclusionData.fromJson({'model_result': jsonDecode(value)});
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> saveOfficial(SummaryEpisode episode, Map<String, dynamic> result) async {
    // Only persist a result that the official summary panel can actually show.
    if ((result['summary'] as String?)?.trim().isNotEmpty != true &&
        (result['outline'] as List?)?.isNotEmpty != true) return;
    await _save(episode, _official, jsonEncode(result));
  }
}
