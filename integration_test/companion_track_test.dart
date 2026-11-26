import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/companion_session.dart';
import 'package:PiliPlus/services/companion_track.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('record, share, import and play a timed AAC note on Android', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('companion-test-');
      appSupportDirPath = dir.path;
      final author = CompanionSession(71);
      final receiver = CompanionSession(71);
      try {
        expect(await Permission.microphone.isGranted, isTrue);
        await author.startRecording();
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        final voice = await author.finishRecording();
        expect(voice.length, greaterThan(300));
        final cue = CompanionCue(CompanionKind.voice, 1500, base64Encode(voice.bytes),
            length: voice.length);
        final track = CompanionTrack(71, cues: [cue]);
        final received = CompanionTrack.decode(track.encode(), 71);
        final key = await receiver.store.importTrack(received);
        final saved = await receiver.store.read(key);
        final started = Stopwatch()..start();
        await CompanionSession.audio.invokeMethod<void>('play',
            {'owner': receiver.owner, 'audio': saved.cues.single.bytes})
            .timeout(const Duration(seconds: 8));
        expect(started.elapsedMilliseconds, greaterThan(200));
        receiver.select(key, saved, 1000);
        receiver.setEnabled(true, 1000);
        receiver.setDialogue([(start: 0, end: 15000)]);
        receiver.tick(1499, 0, 1);
        expect(receiver.notice.value, isNull);
        receiver.tick(1500, 0, 1);
        expect(receiver.notice.value?.id, cue.id);
        receiver.tick(12000, 1, 1);
        expect(receiver.notice.value, isNull);
        receiver.tick(1000, 2, 1);
        receiver.tick(1600, 2, 1);
        expect(receiver.notice.value?.id, cue.id);
      } finally {
        author.dispose();
        receiver.dispose();
        await dir.delete(recursive: true);
      }
    });
  });
}
