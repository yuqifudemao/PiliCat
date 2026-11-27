import 'dart:convert';
import 'dart:io';
import 'dart:async' show Timer;

import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart' show RichTextField;
import 'package:PiliPlus/pages/ai_chat/controller.dart';
import 'package:PiliPlus/pages/ai_chat/models.dart';
import 'package:PiliPlus/pages/ai_chat/view.dart';
import 'package:PiliPlus/pages/setting/ai_setting/voice_settings.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/ai_chat/voice.dart';
import 'package:PiliPlus/services/ai_chat/cloud_voice.dart';
import 'package:PiliPlus/services/companion_session.dart';
import 'package:PiliPlus/services/companion_track.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

class _PausedVideo extends GetxController implements VideoDetailController {
  @override
  final cid = 11.obs;
  @override
  Null get player => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VoiceChat extends AiChatController {
  _VoiceChat() : super(heroTag: 'voice-test');
  @override
  void onInit() {}
  @override
  void openPanel() {}
  @override
  void onClose() {}
  @override
  bool get hasSubtitles => true;
  @override
  Map<String, String> get currentProfile => const {'model': '测试模型', 'url': 'https://example.invalid/v1'};
}

class _VoiceApi implements dio.HttpClientAdapter {
  _VoiceApi(this.calls, this.mp3);
  final List<List<String>> calls;
  final Uint8List mp3;
  @override
  Future<dio.ResponseBody> fetch(dio.RequestOptions request, Stream<Uint8List>? stream, Future<void>? cancel) async {
    final body = request.data;
    if (body is dio.FormData) {
      expect(body.files.single.value.length, greaterThan(0));
      calls.add([request.uri.toString(), request.headers['Authorization'] as String,
        Map.fromEntries(body.fields)['model']!]);
      return dio.ResponseBody.fromString('{"text":"你好"}', 200, headers: {'content-type': ['application/json']});
    }
    calls.add([request.uri.toString(), request.headers['Authorization'] as String,
      body['model'] as String, body['voice'] as String]);
    return dio.ResponseBody.fromBytes(mp3, 200, headers: {'content-type': ['audio/mpeg']});
  }
  @override
  void close({bool force = false}) {}
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final watch = Stopwatch()..start();
  while (finder.evaluate().isEmpty && watch.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}

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
        final mp3 = base64Decode(const String.fromEnvironment('VOICE_TEST_MP3'));
        expect(mp3, isNotEmpty);
        final speechTime = Stopwatch()..start();
        await CompanionSession.audio.invokeMethod<void>('playSpeech',
            {'owner': receiver.owner, 'audio': mp3}).timeout(const Duration(seconds: 8));
        expect(speechTime.elapsedMilliseconds, greaterThan(200));
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

  testWidgets('microphone tap recovers from an unavailable recognizer and starts native recording',
      (tester) async {
    final dir = await Directory.systemTemp.createTemp('assistant-voice-');
    Hive.init(dir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    final chat = _VoiceChat();
    chat.messages.add(ChatMessage(role: 'user', content: '上一条问题'));
    Get.put<VideoDetailController>(_PausedVideo(), tag: chat.heroTag);
    Get.put<AiChatController>(chat, tag: chat.heroTag);
    const speech = MethodChannel('plugin.csdcorp.com/speech_to_text');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var starts = 0;
    messenger.setMockMethodCallHandler(speech, (call) async {
      if (call.method == 'initialize') {
        starts++;
        if (starts == 1) throw PlatformException(code: 'recognizerNotAvailable');
        return null;
      }
      return null;
    });
    try {
      await tester.pumpWidget(GetMaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        home: Scaffold(body: AiChatPage(heroTag: chat.heroTag)),
      ));
      await tester.pumpAndSettle();
      final mic = find.byTooltip('开始语音对话');
      await tester.tap(mic);
      await _waitFor(tester, find.text('系统语音识别不可用'));
      await tester.tap(find.text('用输入法提问'));
      await tester.pumpAndSettle();
      expect(VoiceOptions().transcription, isFalse);
      final input = tester.widget<RichTextField>(find.byType(RichTextField));
      expect(input.focusNode?.hasFocus, isTrue);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(mic);
      await _waitFor(tester, find.text('开始录音转写'));
      await tester.tap(find.text('开始录音转写'));
      await _waitFor(tester, find.byTooltip('录音中，点麦克风发送'));
      expect(VoiceOptions().transcription, isTrue);
      await tester.tap(find.byTooltip('取消录音'));
      await _waitFor(tester, mic);
      expect(starts, 2);
      await tester.tap(find.text('语音模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转写模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增接口'));
      await tester.pumpAndSettle();
      final fields = find.descendant(of: find.widgetWithText(AlertDialog, '新增 API 接口'), matching: find.byType(TextField));
      await tester.enterText(fields.at(0), '独立语音');
      await tester.enterText(fields.at(1), 'https://voice.example.test/v1');
      await tester.enterText(fields.at(2), 'test-key');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存接口'));
      await tester.pumpAndSettle();
      final idField = find.widgetWithText(TextField, '模型 ID');
      await tester.enterText(idField, 'my-transcriber');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用此模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = VoiceOptions();
      expect(saved.stt.model, 'my-transcriber');
      expect(saved.stt.resolve(chat.currentProfile)['key'], 'test-key');
      expect(saved.tts.resolve(chat.currentProfile), chat.currentProfile);
      expect(Pref.aiApiProfiles[Pref.activeAiApiProfile]['name'], '默认配置');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      messenger.setMockMethodCallHandler(speech, null);
      Get.delete<AiChatController>(tag: chat.heroTag);
      Get.delete<VideoDetailController>(tag: chat.heroTag);
      await Hive.close();
      await dir.delete(recursive: true);
    }
  });

  testWidgets('one voice conversation sends recorded audio and narration to their own API and model', (tester) async {
    await tester.runAsync(() async {
      final calls = <List<String>>[];
      final mp3 = base64Decode(const String.fromEnvironment('VOICE_TEST_MP3'));
      final voice = AssistantVoice(createCloud: (profile) => CloudVoice(profile, adapter: _VoiceApi(calls, mp3)));
      final owner = Object();
      expect(voice.claim(owner), isTrue);
      try {
        final text = await voice.recordQuestion(owner, {'url': 'https://in.test/v2', 'key': 'mic-key'}, 'stt-zh',
          onRecording: () => Timer(const Duration(milliseconds: 1200), voice.sendRecording),
          onTranscribing: () {});
        expect(text, '你好');
        await voice.narrate(owner, {'url': 'https://out.test/v1', 'key': 'tts-key'}, 'my-tts', 'voice-zh', text);
        expect(calls, [
          ['https://in.test/v2/audio/transcriptions', 'Bearer mic-key', 'stt-zh'],
          ['https://out.test/v1/audio/speech', 'Bearer tts-key', 'my-tts', 'voice-zh'],
        ]);
      } finally {
        await voice.release(owner);
      }
    });
  });

  testWidgets('an empty native recording is recoverable without a transcription request', (tester) async {
    final voice = AssistantVoice();
    final owner = Object();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const audio = MethodChannel('pilicat/companion_audio');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(audio, (call) async {
      calls.add(call.method);
      return null;
    });
    try {
      expect(voice.claim(owner), isTrue);
      await expectLater(
        voice.recordQuestion(owner, {'url': 'https://example.invalid/v1'}, 'whisper-1',
            onRecording: voice.sendRecording, onTranscribing: () {}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('没有取得录音'))),
      );
      expect(calls, ['record', 'finish', 'cancel']);
      await voice.release(owner);
      expect(voice.claim(owner), isTrue);
      await voice.release(owner);
    } finally {
      messenger.setMockMethodCallHandler(audio, null);
    }
  });
}
