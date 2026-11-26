import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/companion_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('timed notes keep their episode, identity and media position on sharing', () {
    final cue = CompanionCue(CompanionKind.text, 12500, '看左边的路牌');
    final mine = CompanionTrack(80, name: '一起看', cues: [cue]);
    final received = CompanionTrack.decode(mine.encode(), 80);
    expect(received.id, mine.id);
    expect(received.name, '一起看');
    expect(received.cues.single.toJson(), cue.toJson());
    expect(() => CompanionTrack.decode(mine.encode(), 81), throwsFormatException);
  });

  test('invalid attachments and duplicate markers cannot be imported', () {
    final cue = CompanionCue(CompanionKind.voice, 1000, base64Encode([1, 2, 3]), length: 300);
    expect(() => CompanionTrack.decode(CompanionTrack(1, cues: [cue]).encode(), 1),
        throwsFormatException);
    final text = CompanionCue(CompanionKind.text, 3000, '再看一次');
    expect(() => CompanionTrack.decode(CompanionTrack(1, cues: [text, text]).encode(), 1),
        throwsFormatException);
  });

  test('finds a short silence after the anchor, offers a marker for crowded dialogue', () {
    final vtt = dialogueFromVtt('WEBVTT\n\n00:00:05.000 --> 00:00:06.000\n一句\n'
        '\n00:00:09.500 --> 00:00:20.000\n另一句\n');
    expect(voiceStart(5100, 2000, vtt), 6120);
    expect(voiceStart(5100, 4000, vtt), isNull);
    expect(voiceStart(1000, 300, []), 1000);
  });

  test('concurrent authorship and repeated import preserve separate tracks on disk', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final store = CompanionStore(dir, 70);
    Future<void> add(int time) => store.edit((track) {
      track.cues.add(CompanionCue(CompanionKind.text, time, '标记'));
    }).then((_) {});
    await Future.wait([add(5000), add(1000)]);
    final mine = await store.read('mine');
    expect(mine.cues.map((c) => c.at), [1000, 5000]);
    final other = CompanionTrack(70, name: '朋友的轨道');
    await store.importTrack(other);
    await store.importTrack(other);
    expect((await store.keys()).toSet(), {'mine', other.id});
    expect(await store.importTrack(mine), 'mine');
    expect((await CompanionStore(dir, 70).read('mine')).id, mine.id);
    await store.removeImported(other.id);
    expect(await store.keys(), ['mine']);
  });
}
