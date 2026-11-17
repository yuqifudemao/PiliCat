/// Safe stream diagnostics: never return a signed URL, path, query or token.
abstract final class MediaUrlDiagnostics {
  static String describe(String? url, {DateTime? now}) {
    if (url == null || url.isEmpty) return '无';
    try {
      final uri = Uri.parse(url);
      if ((uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        return '未知';
      }
      final expiry = expiresAt(url);
      if (expiry == null) return uri.host;
      final seconds = expiry.difference(now ?? DateTime.now()).inSeconds;
      return '${uri.host} · 有效期 $seconds s（本机时间）';
    } on FormatException {
      return '未知';
    }
  }

  static DateTime? expiresAt(String url) {
    try {
      final query = Uri.parse(url).queryParameters;
      final deadlines = <int>[];
      void add(String? value) {
        final seconds = int.tryParse(value ?? '');
        if (seconds != null && seconds > 0 && seconds <= 253402300799) {
          deadlines.add(seconds);
        }
      }

      add(query['deadline']);
      final token = query['hdnts'];
      if (token != null) {
        add(RegExp(r'(?:^|~)exp=(\d+)(?:~|$)').firstMatch(token)?.group(1));
      }
      if (deadlines.isEmpty) return null;
      deadlines.sort();
      return DateTime.fromMillisecondsSinceEpoch(
        deadlines.first * 1000,
        isUtc: true,
      );
    } on FormatException {
      return null;
    }
  }

  static int? httpStatus(String message) {
    final match = RegExp(
      r'(?:^|:\s+)(?:HTTP\s+(?:error\s+)?|Server returned\s+)([45]\d{2})\b',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(message);
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}
