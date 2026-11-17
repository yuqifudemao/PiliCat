import 'dart:typed_data';

import 'package:PiliPlus/http/media_http_profile.dart';
import 'package:PiliPlus/pages/setting/widgets/cdn_select_dialog.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simulate a media endpoint that accepts only native media requests.
/// Exercise the actual Dio request, including signed query and Range.
class _NativeOnlyAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    final native = options.headers['user-agent'] ==
            'Bilibili Freedoooooom/MarkII' &&
        !options.headers.containsKey('referer');
    return ResponseBody.fromBytes(
      native ? List<int>.filled(4096, 42) : <int>[0],
      native ? 206 : 403,
      headers: {
        Headers.contentTypeHeader: ['video/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const url = 'https://upos-sz-mirrorcosov.bilivideo.com/video.m4s'
      '?deadline=2000000000&upsig=PRIVATE_SIGNATURE&value=a%2Bb%2Fc';

  test('Android stream and speed test use native headers and signed URL', () async {
    final source = NetworkSource(
      videoSource: url,
      audioSource: null,
      mediaHttpProfile: MediaHttpProfile.android,
    );
    final diagnostics = <String>[];
    final tester = CdnSpeedTester(
      mediaHttpProfile: source.mediaHttpProfile,
      onDiagnostic: diagnostics.add,
    );
    final adapter = _NativeOnlyAdapter();
    tester.dio.httpClientAdapter = adapter;
    addTearDown(tester.dispose);

    final result = await tester.measure(source.videoSource);
    expect(result, endsWith('MB/s'));
    expect(adapter.request!.method, 'GET');
    expect(adapter.request!.uri.toString(), url);
    expect(adapter.request!.headers['range'], 'bytes=0-2097151');
    expect(adapter.request!.headers.containsKey('cookie'), isFalse);
    expect(adapter.request!.headers.containsKey('authorization'), isFalse);
    expect(source.mediaHttpProfile.referer, '');
    expect(diagnostics.single, contains('安卓原生'));
    expect(diagnostics.single, isNot(contains('PRIVATE_SIGNATURE')));
    expect(diagnostics.single, isNot(contains('video.m4s')));
  });

  test('web playback after Android retains web headers and reports HTTP 403', () async {
    final android = NetworkSource(
      videoSource: url,
      audioSource: null,
      mediaHttpProfile: MediaHttpProfile.android,
    );
    final web = NetworkSource(videoSource: url, audioSource: null);
    expect(android.mediaHttpProfile.referer, isEmpty);
    expect(web.mediaHttpProfile.referer, 'https://www.bilibili.com');

    final tester = CdnSpeedTester(mediaHttpProfile: web.mediaHttpProfile);
    final adapter = _NativeOnlyAdapter();
    tester.dio.httpClientAdapter = adapter;
    addTearDown(tester.dispose);
    expect(await tester.measure(url), '节点拒绝请求（HTTP 403）');
    expect(adapter.request!.headers['referer'], 'https://www.bilibili.com');
  });
}
