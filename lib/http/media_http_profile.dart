import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';

/// Media headers belong to the API that issued the signed stream URL.
/// Android UA matches BiliRoaming's SpeedTestDialog at v1.7.0.
enum MediaHttpProfile {
  web,
  android;

  String get userAgent => this == android
      ? 'Bilibili Freedoooooom/MarkII'
      : BrowserUa.pc;

  // An empty value explicitly clears mpv's previous referrer on source changes.
  String get referer => this == android ? '' : HttpString.baseUrl;

  Map<String, String> get headers => {
    'user-agent': userAgent,
    if (referer.isNotEmpty) 'referer': referer,
  };

  String get label => this == android ? '安卓原生' : '网页';
}
