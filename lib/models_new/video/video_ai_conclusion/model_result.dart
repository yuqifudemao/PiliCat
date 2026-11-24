import 'package:PiliPlus/models_new/video/video_ai_conclusion/outline.dart';
import 'package:PiliPlus/utils/ai_caption_text.dart';

class AiConclusionResult {
  String? summary;
  List<Outline>? outline;
  final String transcript;

  AiConclusionResult({
    this.summary,
    this.outline,
    this.transcript = '',
  });

  factory AiConclusionResult.fromJson(Map<String, dynamic> json) {
    final groups = json['subtitle'];
    final cues = groups is List
        ? groups.whereType<Map>().map((g) => g['part_subtitle']).whereType<List>().expand((rows) => rows)
        : const [];
    return AiConclusionResult(
      summary: json['summary'] as String?,
      outline: (json['outline'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(Outline.fromJson)
          .toList(),
      transcript: captionText(cues, timeKey: 'start_timestamp'),
    );
  }
}
