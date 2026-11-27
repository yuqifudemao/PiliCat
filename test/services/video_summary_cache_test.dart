import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart' as dio;
import 'package:PiliPlus/services/ai_chat/cloud_voice.dart';

import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/pages/ai_chat/controller.dart';
import 'package:PiliPlus/pages/ai_chat/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/ai_chat/video_summary_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

const episode = (account: 0, bvid: 'BVexample', cid: 11);
const profile = {'model': '测试模型', 'url': 'https://example.test', 'key': 'private-key'};

Future<void> save(VideoSummaryCache cache, String text, {
  SummaryEpisode part = episode,
  String template = '概貌总结',
}) => cache.saveAnalysis(
  part,
  analysis: (template: template, model: profile['model']!, source: '视频字幕', text: text),
  prompt: template,
  profile: profile,
);

class _Video extends GetxController implements VideoDetailController {
  @override
  String bvid = episode.bvid;
  @override
  final cid = episode.cid.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Assistant extends AiChatController {
  _Assistant(this.currentProfile) : super(heroTag: 'summary-test');
  @override
  final Map<String, String> currentProfile;
}

class _LoopbackHttp extends HttpOverrides {}

class _VoiceAdapter implements dio.HttpClientAdapter {
  @override
  Future<dio.ResponseBody> fetch(dio.RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    expect(options.headers['Authorization'], 'Bearer private-key');
    if (options.uri.path == '/v1/audio/transcriptions') {
      final form = options.data as dio.FormData;
      expect(Map.fromEntries(form.fields)['model'], 'whisper-1');
      expect(form.files.single.value.filename, 'question.m4a');
      return dio.ResponseBody.fromString('{"text":"刚才讲了什么"}', 200,
          headers: {'content-type': ['application/json']});
    }
    expect(options.uri.path, '/v1/audio/speech');
    expect(options.data['voice'], 'coral');
    expect(options.data['instructions'], isNotEmpty);
    return dio.ResponseBody.fromBytes([1, 2, 3], 200,
        headers: {'content-type': ['audio/mpeg']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('voice uses the selected provider for transcription and expressive speech', () async {
    final api = CloudVoice({...profile, 'url': 'https://example.test/v1/'}, adapter: _VoiceAdapter());
    addTearDown(api.close);
    expect(await api.transcribe(Uint8List.fromList([1]), 'whisper-1'), '刚才讲了什么');
    expect(await api.synthesize('你好', 'gpt-4o-mini-tts', 'coral'), [1, 2, 3]);
    expect(CloudVoice.passages('**你好** [01:02]').single, '你好');
  });
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pilicat-summary-');
    Hive.init(dir.path);
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.setting = await Hive.openBox('setting');
  });
  setUp(() => GStorage.localCache.clear());
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('reopening the database preserves summaries, expires each after seven days', () async {
    var now = DateTime.utc(2026, 11, 1);
    var box = await Hive.openBox('restart');
    var cache = VideoSummaryCache(box, now: () => now);
    await box.put('unrelated', true);
    await save(cache, '第一份');
    await box.close();
    box = await Hive.openBox('restart');
    cache = VideoSummaryCache(box, now: () => now);
    now = now.add(const Duration(days: 6));
    expect(cache.analyses(episode).single.text, '第一份');
    await save(cache, '第二份', template: '详细分析');
    await save(cache, ' ', template: '详细分析');
    now = now.add(const Duration(days: 1));
    expect(cache.analyses(episode).map((a) => a.text), ['第二份']);
    expect(cache.analyses((account: 1, bvid: episode.bvid, cid: episode.cid)), isEmpty);
    expect(cache.analyses((account: 0, bvid: 'BVother', cid: episode.cid)), isEmpty);
    expect(box.toMap().toString(), isNot(contains('private-key')));
    now = now.add(const Duration(days: 6));
    cache.pruneExpired();
    await box.flush();
    expect(box.toMap(), {'unrelated': true});
  });

  test('resetting assistant summaries preserves official chapters and transcription', () async {
    final cache = GStorage.videoSummaries;
    await save(cache, '自定义总结');
    await cache.saveOfficial(episode, {
      'summary': '平台摘要',
      'outline': [{'title': '章节', 'part_outline': [{'timestamp': 65, 'content': '段落'}]}],
      'subtitle': [{'part_subtitle': [{'start_timestamp': 65, 'content': '原文'}]}],
    });
    await cache.clearAnalyses(episode);
    final result = (await VideoHttp.aiConclusion(bvid: episode.bvid, cid: episode.cid))
        .data.modelResult!;
    expect(result.summary, '平台摘要');
    expect(result.outline!.single.partOutline!.single.timestamp, 65);
    expect(result.transcript, '[01:05] 原文');
    expect(cache.analyses(episode), isEmpty);
  });

  test('re-entering a video reads the completed answer without a second AI call', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      final streaming = Completer<void>();
      final release = Completer<void>();
      server.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(body['model'], profile['model']);
        final n = ++requests;
        req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.bufferOutput = false;
        final chunk = {'choices': [{'delta': {'content': '总结$n'}}]};
        req.response.write('data: ${jsonEncode(chunk)}\n\n');
        await req.response.flush();
        if (n == 3) {
          streaming.complete();
          await release.future;
        }
        if (n == 4) {
          req.response.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
        }
        if (n == 1) req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      final video = _Video();
      const tag = 'summary-test';
      Get.put<VideoDetailController>(video, tag: tag);
      addTearDown(() => Get.delete<VideoDetailController>(tag: tag));
      AiChatController open() {
        final chat = Get.put<AiChatController>(
          _Assistant({...profile, 'url': 'http://127.0.0.1:${server.port}'}), tag: tag,
        );
        chat.openPanel();
        return chat;
      }
      var chat = open();
      addTearDown(() => Get.delete<AiChatController>(tag: tag));
      Future<void> analyze() {
        // A loaded transcript is already available in this session.
        chat.hasVideoContext.value = true;
        return chat.startAnalysis(
          '总结一下', templateName: '概貌总结',
          chooseSource: (_, _, _) async => fail('unexpected subtitle lookup'),
          confirmPlaying: (_) async => fail('unexpected frame capture'),
        );
      }

      await analyze();
      expect(GStorage.videoSummaries.analyses(episode).single.text, '总结1');
      await Get.delete<AiChatController>(tag: tag);
      chat = open();
      expect(chat.messages.last.content, '总结1');
      expect(requests, 1);
      await analyze(); // A socket closed without a terminal event.
      expect(GStorage.videoSummaries.analyses(episode).single.text, '总结1');
      final cancelled = analyze();
      await streaming.future;
      chat.cancelRequest();
      release.complete();
      await cancelled;
      expect(GStorage.videoSummaries.analyses(episode).single.text, '总结1');
      await analyze(); // Some compatible providers send finish_reason without [DONE].
      expect(GStorage.videoSummaries.analyses(episode).single.text, '总结4');
      video.cid.value = 12;
      await Future<void>.delayed(Duration.zero);
      expect(chat.messages, isEmpty);
      video.cid.value = episode.cid;
      await Future<void>.delayed(Duration.zero);
      expect(chat.messages.last.content, '总结4');
      expect(requests, 4);
      chat.clearMessages();
      expect(GStorage.videoSummaries.analyses(episode), isEmpty);
    }, _LoopbackHttp());
  });

  for (final landscape in [false, true]) {
    testWidgets('restores the saved summary when opening the ${landscape ? 'player' : 'detail'} panel',
        (tester) async {
      await tester.runAsync(() => save(GStorage.videoSummaries, '这个分集之前的总结'));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = landscape ? const Size(800, 400) : const Size(400, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const tag = 'summary-test';
      Get.put<VideoDetailController>(_Video(), tag: tag);
      Get.put<AiChatController>(_Assistant(profile), tag: tag);
      addTearDown(() => Get.delete<VideoDetailController>(tag: tag));
      addTearDown(() => Get.delete<AiChatController>(tag: tag));
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 400, child: AiChatPage(heroTag: tag, inPlayer: landscape)),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('本机保存 7 天'), findsOneWidget);
      expect(find.textContaining('这个分集之前的总结', findRichText: true), findsAtLeastNWidgets(1));
      expect(find.text('重新分析'), findsOneWidget);
    });
  }
}
