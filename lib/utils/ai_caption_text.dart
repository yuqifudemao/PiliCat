import 'package:PiliPlus/utils/extension/string_ext.dart';

String? subtitleHttpUrl(String? value) {
  final url = value?.trim().http2https;
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? url
      : null;
}

String timedCaption(String content, num? start) {
  if (start == null || !start.isFinite || start < 0) return content;
  final seconds = start.toInt();
  String two(int v) => v.toString().padLeft(2, '0');
  final hours = seconds >= 3600 ? '${two(seconds ~/ 3600)}:' : '';
  return '[$hours${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}] $content';
}

String captionText(Iterable rows, {String timeKey = 'from'}) {
  final lines = <String>[];
  for (final row in rows.whereType<Map>()) {
    final content = row['content'];
    if (content is! String || content.trim().isEmpty) continue;
    final time = row[timeKey];
    lines.add(timedCaption(content.trim(), time is num ? time : null));
  }
  return lines.join('\n');
}
