import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/pages/ai_chat/controller.dart';
import 'package:PiliPlus/pages/ai_chat/models.dart';
import 'package:PiliPlus/pages/ai_chat/view.dart';
import 'package:PiliPlus/pages/video/widgets/player_ai_summary.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

class _ExistingChat extends AiChatController {
  _ExistingChat() : super(heroTag: 'video');

  @override
  void onInit() {}
  @override
  void onClose() {}
  @override
  bool get hasSubtitles => true;
  @override
  Map<String, String> get currentProfile => const {'model': '我的模型'};
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pilicat-player-chat-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('the landscape assistant reopens the current model and conversation',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final chat = _ExistingChat();
    Get.put<AiChatController>(chat, tag: chat.heroTag);
    addTearDown(() => Get.delete<AiChatController>(tag: chat.heroTag));
    chat.messages.add(ChatMessage(role: 'user', content: '之前问过的问题'));
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => TextButton(
          onPressed: () => PageUtils.showVideoBottomSheet(
            context,
            child: PlayerAiSummary(
              assistant: AiChatPage(heroTag: chat.heroTag, inPlayer: true),
              onSeek: (_) {},
            ),
          ),
          child: const Text('打开助手'),
        )),
      ),
    ));
    for (int i = 0; i < 2; i++) {
      await tester.tap(find.text('打开助手'));
      await tester.pumpAndSettle();
      expect(find.text('我的模型'), findsOneWidget);
      expect(find.text('之前问过的问题'), findsOneWidget);
      expect(chat.isRequesting.value, isFalse);
      tester.view.viewInsets = const FakeViewPadding(bottom: 215);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '关闭总结',
      ));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('opens on the right, switches summaries, and returns to the player',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    int requests = 0;
    int? seek;
    final result = AiConclusionResult.fromJson({
      'summary': '本集简介',
      'outline': [
        {
          'title': '章节',
          'part_outline': [{'timestamp': 65, 'content': '第二节'}],
        },
      ],
    });
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => PageUtils.showVideoBottomSheet(
              context,
              child: PlayerAiSummary(
                assistant: const Text('已有的模型总结'),
                loadConclusion: () async {
                  requests++;
                  return result;
                },
                onSeek: (seconds) => seek = seconds,
              ),
            ),
            child: const Text('AI'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(PlayerAiSummary)), const Rect.fromLTWH(400, 0, 400, 400));
    expect(find.text('已有的模型总结'), findsOneWidget);
    expect(requests, 0);
    Future<void> select(String name) async {
      await tester.tap(find.byType(DropdownButton<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }
    await select('B 站 AI 总结');
    expect(find.text('本集简介'), findsOneWidget);
    final chapter = find.byWidgetPredicate(
      (w) => w is Text && w.textSpan?.toPlainText().contains('第二节') == true,
    );
    await tester.tapAt(tester.getTopLeft(chapter) + const Offset(5, 9));
    expect(seek, 65);
    await select('AI 视频助手');
    await select('B 站 AI 总结');
    expect(requests, 1);
    await tester.tap(find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '关闭总结',
    ));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerAiSummary), findsNothing);
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('official-only mode offers a retry for an unavailable summary', (tester) async {
    int requests = 0;
    await tester.pumpWidget(MaterialApp(
      home: PlayerAiSummary(
        loadConclusion: () async =>
            ++requests == 1 ? null : AiConclusionResult(summary: '已获取总结'),
        onSeek: (_) {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('当前视频暂无可用的 B 站总结'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('已获取总结'), findsOneWidget);
    expect(requests, 2);
  });

  testWidgets('a previous episode response cannot replace the new summary', (tester) async {
    final episode = ValueNotifier(1);
    final first = Completer<AiConclusionResult?>();
    addTearDown(episode.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: episode,
        builder: (context, id, child) => PlayerAiSummary(
          key: ValueKey(id),
          loadConclusion: () async =>
              id == 1 ? await first.future : AiConclusionResult(summary: '第二集'),
          onSeek: (_) {},
        ),
      ),
    ));
    episode.value = 2;
    await tester.pumpAndSettle();
    first.complete(AiConclusionResult(summary: '第一集'));
    await tester.pumpAndSettle();
    expect(find.text('第一集'), findsNothing);
    expect(find.text('第二集'), findsOneWidget);
  });
}
