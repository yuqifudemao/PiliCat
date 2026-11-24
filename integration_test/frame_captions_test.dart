import 'package:PiliPlus/http/media_http_profile.dart';
import 'package:PiliPlus/services/ai_chat/caption_frame_reader.dart';
import 'package:PiliPlus/services/ai_chat/frame_captions.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('recognizes Chinese burned into fragmented video, without seeking the viewer', (tester) async {
    const host = 'http://10.0.2.2:8765';
    const video = '$host/captions.m4s';
    final profile = MediaHttpProfile.web;
    final viewer = await Player.create(configuration: const PlayerConfiguration(
      options: {'vid': 'auto', 'ao': 'null', 'aid': 'no', 'hwdec': 'no'},
    ));
    addTearDown(viewer.dispose);
    viewer.setMediaHeader(userAgent: profile.userAgent, referer: profile.referer);
    await viewer.open(const Media(video), play: false);
    final start = Stopwatch()..start();
    while ((viewer.state.videoParams.w ?? 0) == 0 && start.elapsed.inSeconds < 12) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    expect(viewer.state.videoParams.w, greaterThan(0));
    final initialPosition = viewer.state.position;
    final stages = <String>[];
    final scanned = await FrameCaptions.read(
      clips: const [(durationMs: 4000, urls: ['$host/unavailable', video])],
      headers: profile.headers,
      token: CancelToken(),
      progress: (_, _) {},
      diagnostic: stages.add,
    );
    final transcript = scanned.replaceAll(RegExp(r'\s+'), '');
    expect(stages, contains(contains('抽帧')));
    expect(transcript, contains('[00:01]'));
    expect(transcript, contains('[00:03]'));
    expect(transcript.indexOf('晴天'), greaterThanOrEqualTo(0));
    expect(transcript.indexOf('下雨'), greaterThan(transcript.indexOf('晴天')));
    expect(viewer.state.playing, isFalse);
    expect((viewer.state.position - initialPosition).inMilliseconds.abs(), lessThan(250));

    await viewer.play();
    final excerpt = await FrameCaptions.readPlaying(
      capture: () => captureCaptionFrame(viewer),
      position: () => viewer.state.completed ? null : viewer.state.position.inMilliseconds,
      token: CancelToken(),
      progress: (_) {},
      interval: const Duration(milliseconds: 80),
      limit: const Duration(seconds: 8),
    );
    expect(excerpt.replaceAll(RegExp(r'\s+'), ''), contains('下雨'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
