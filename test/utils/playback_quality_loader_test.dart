import 'dart:async';

import 'package:PiliPlus/http/media_http_profile.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/playback_quality_loader.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

PlayUrlModel _source(List<int> qualities) => PlayUrlModel.fromJson({
  'dash': {
    'duration': 60,
    'video': [
      for (final quality in qualities)
        {
          'id': quality,
          'base_url': 'https://cdn.example.com/$quality.m4s',
          'codecs': VideoDecodeFormatType.AVC.codes.first,
          'codecid': 7,
        },
    ],
  },
  'accept_quality': [120, 116, 80, 64],
  'support_formats': [
    for (final quality in [120, 116, 80, 64])
      {'quality': quality, 'codecs': VideoDecodeFormatType.AVC.codes},
  ],
});

void main() {
  test('available selected quality opens without waiting for other formats', () async {
    final source = _source([120, 80]);
    final requests = <int>[];
    final pending = Completer<PlayUrlModel?>();
    final loader = PlaybackQualityLoader(
      source: source,
      isCurrent: () => true,
      request: (quality) {
        requests.add(quality);
        return pending.future;
      },
    );

    await loader.prepare(80).timeout(const Duration(seconds: 1));
    expect(requests, isEmpty);
    final background = loader.complete();
    expect(requests, [116]);
    pending.complete(_source([116, 80, 64]));
    await background;
    expect(source.dash!.video!.availableVideoQualities, {120, 116, 80, 64});
  });

  test('only the selected missing quality blocks initial playback', () async {
    final source = _source([120, 64]);
    final requests = <int>[];
    final loader = PlaybackQualityLoader(
      source: source,
      isCurrent: () => true,
      request: (quality) async {
        requests.add(quality);
        return _source([80, 64]);
      },
    );
    await loader.prepare(80);
    expect(requests, [80]);
    expect(source.dash!.video!.availableVideoQualities, {120, 80, 64});
  });

  test('failed quality lookup selects a real lower stream without throwing', () async {
    final source = _source([120, 64]);
    final loader = PlaybackQualityLoader(
      source: source,
      isCurrent: () => true,
      request: (_) async => throw Exception('unavailable'),
    );
    await loader.prepare(80);
    final selected = VideoUtils.findTargetVideo(
      source.dash!.video!,
      80,
      source.acceptQuality,
      source.supportFormats!,
      [VideoDecodeFormatType.AVC],
    );
    expect(selected.$1, 64);
    expect(selected.$4.baseUrl, 'https://cdn.example.com/64.m4s');
  });

  test('response arriving after an episode change is discarded', () async {
    final source = _source([120, 80]);
    var current = true;
    final pending = Completer<PlayUrlModel?>();
    final loader = PlaybackQualityLoader(
      source: source,
      isCurrent: () => current,
      request: (_) => pending.future,
    );
    final background = loader.complete();
    current = false;
    pending.complete(_source([116, 64]));
    await background;
    expect(source.dash!.video!.availableVideoQualities, {120, 80});
  });

  test('manual quality selection reuses an in-flight background request', () async {
    final source = _source([120, 80]);
    final requests = <int>[];
    final pending = Completer<PlayUrlModel?>();
    final loader = PlaybackQualityLoader(
      source: source,
      isCurrent: () => true,
      request: (quality) {
        requests.add(quality);
        return pending.future;
      },
    );
    final background = loader.complete();
    final selected = loader.prepare(116);
    expect(requests, [116]);
    pending.complete(_source([116, 80]));
    await Future.wait([background, selected]);
    expect(source.dash!.video!.availableVideoQualities, {120, 116, 80});
  });

  test('roaming URLs cannot be mixed with a different media header profile', () async {
    final source = _source([120, 80])
      ..preserveStreamUrls = true
      ..mediaHttpProfile = MediaHttpProfile.android;
    final loader = PlaybackQualityLoader(
      source: source,
      isCurrent: () => true,
      request: (_) async => _source([116, 64]),
    );
    await loader.complete();
    expect(source.dash!.video!.availableVideoQualities, {120, 80});
  });
}
