import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/pages/ai_chat/models.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/services/ai_chat/frame_captions.dart';
import 'package:PiliPlus/services/ai_chat/video_material.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class AiChatController extends GetxController {
  final messages = <ChatMessage>[].obs;
  final isRequesting = false.obs;
  final subtitleWarning = false.obs;
  final hasVideoContext = false.obs;
  final contextStatus = ''.obs;
  final selectedProfile = Rxn<Map<String, String>>();

  Map<String, String> get currentProfile =>
      selectedProfile.value ?? Pref.aiApiProfiles[Pref.activeAiApiProfile];

  final String heroTag;
  late final VideoDetailController _videoCtl;
  late final StreamSubscription<int> _partChanges;

  AiChatController({required this.heroTag});

  // --- Dynamic system prompts ---
  static const _systemPromptA =
      '你是一个智能问答助手。当前对话尚未关联任何视频内容。请使用你的通用知识库回答用户的问题。'
      '如果用户的提问明确指向某个特定视频的内容（如"视频里说了什么"），'
      '请委婉地提示用户：『抱歉，您还没有载入视频信息，请先点击【载入上下文】按钮补充上下文。』';

  static const _systemPromptB =
      '你是一个视频内容分析与互动学习助手。当前对话已成功关联视频上下文。请严格基于注入的视频内容解答用户的疑问。\n'
      '要求：\n'
      '1. 回复语言为中文，使用 Markdown 格式。\n'
      '2. 只要输出内容涉及到具体的视频时间点，必须统一使用 [mm:ss] 或 [hh:mm:ss] 格式。'
      '时间戳前后必须保留一个空格。时间段请使用 [开始] - [结束] 格式。'
      '严禁用代码块或反引号包裹时间戳（如 `[03:12]` 是错误的）。\n'
      '3. 如果用户询问的概念超出了视频本身的信息范围，请勿提示无法分析，'
      '而是主动调用通用知识补充解答，并在该段落前明确声明：'
      '『*视频中未提及此概念，为您补充相关背景知识：*』\n'
      '4. 根据标明的资料来源回答。画面字幕是抽样，仅涵盖识别到的文字。B 站摘要与提纲只涵盖所列要点。'
      '若资料仅有标题与简介，在开头说明这一点，只概括简介。不要补写台词、未提到的结论或时间点。';

  // --- Cached video context for system message injection ---
  String? _cachedVideoContext;
  int _contextLoadIndex = -1;
  CancelToken? _requestToken;
  ChatMessage? _responseMessage;

  // --- 思考耗时计时器（约 100ms 刷新，正文首字或流结束时冻结）---
  Timer? _reasoningTimer;
  ChatMessage? _reasoningTimerMsg;

  @override
  void onInit() {
    super.onInit();
    _videoCtl = Get.find<VideoDetailController>(tag: heroTag);
    _partChanges = _videoCtl.cid.listen((_) => clearMessages());
  }

  @override
  void onClose() {
    _partChanges.cancel();
    cancelRequest();
    _stopReasoningTimer();
    super.onClose();
  }

  bool get hasSubtitles => _videoCtl.subtitles.isNotEmpty;

  String _buildVideoInfo() {
    if (_videoCtl.isFileSource) return '';
    final String? title;
    final String? desc;
    if (_videoCtl.isUgc) {
      final video = _videoCtl.ugcIntroCtr.videoDetail.value;
      final part = video.hasParts
          ? video.pages?.where((p) => p.cid == _videoCtl.cid.value).firstOrNull?.part
          : null;
      title = [video.title, part].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · ');
      desc = video.desc;
    } else {
      final intro = _videoCtl.pgcIntroCtr;
      title = [intro.pgcItem.title, intro.videoDetail.value.title]
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join(' · ');
      desc = intro.pgcItem.evaluate;
    }
    return [
      if (title != null && title.isNotEmpty) '视频标题：$title\n',
      if (desc != null && desc.isNotEmpty) '视频简介：$desc\n',
    ].join();
  }

  Future<void> loadVideoContext({required ChooseCaptionSource chooseSource}) async {
    if (hasVideoContext.value) return;
    await _runRequest(chooseSource: chooseSource, errorPrefix: '载入失败');
  }

  Future<void> _loadVideoContext(
    CancelToken token,
    ChooseCaptionSource chooseSource,
  ) async {
    final video = _videoCtl;
    final bvid = video.bvid;
    final cid = video.cid.value;
    bool current() => _isCurrentRequest(token) && video.bvid == bvid && video.cid.value == cid;
    final tracks = video.subtitles.toList();
    final selected = video.vttSubtitlesIndex.value - 1;
    if (selected > 0 && selected < tracks.length) {
      final first = tracks.removeAt(selected);
      tracks.insert(0, first);
    }
    contextStatus.value = '正在查找本集字幕与转写…';
    var material = await VideoMaterial.resolve(
      available: tracks,
      refresh: () async {
        if (video.isFileSource || !current()) return <Subtitle>[];
        final info = await video.requestPlayInfo();
        if (!current()) return <Subtitle>[];
        return [...?info.dataOrNull?.subtitle?.subtitles, ...video.subtitles];
      },
      read: (url) => VideoHttp.fetchSubtitleBody(url, cancelToken: token),
      conclusion: video.isFileSource || !video.isUgc ? null : () async {
        if (!current()) return null;
        final intro = video.ugcIntroCtr;
        final cached = intro.aiConclusionResult;
        if (cached != null) return cached;
        final res = await VideoHttp.aiConclusion(
          bvid: bvid, cid: cid, upMid: intro.videoDetail.value.owner?.mid,
          cancelToken: token,
        );
        return res.dataOrNull?.modelResult;
      },
      token: token,
    );
    if (!current()) return;
    final info = _buildVideoInfo().trim();
    if (material == null) {
      final canRead = Platform.isAndroid && !video.isFileSource &&
          video.plPlayerController.isCurrentVideoSource(bvid: bvid, cid: cid);
      final clips = canRead
          ? FrameCaptions.clips(video.data, video.videoUrl ?? '')
          : const <CaptionClip>[];
      if (clips.isEmpty && info.isEmpty) {
        SmartDialog.showToast('本集暂无可读取的字幕、转写或简介');
        return;
      }
      contextStatus.value = '';
      final choice = await chooseSource(clips.isNotEmpty, info.isNotEmpty, token);
      if (!current() || choice == null) return;
      if (choice == MissingCaptionChoice.frames) {
        contextStatus.value = '正在打开视频画面…';
        final text = await FrameCaptions.read(
          clips: clips,
          headers: video.data.mediaHttpProfile.headers,
          token: token,
          progress: (done, total) {
            if (current()) contextStatus.value = '正在识别画面字幕 · $done/$total';
          },
        );
        if (!current()) return;
        if (text.isEmpty) {
          SmartDialog.showToast('未识别到足够的画面字幕。可再次点「分析」，选择仅根据简介。');
          return;
        }
        material = VideoMaterial(VideoMaterialSource.frames, text);
      } else {
        material = VideoMaterial(VideoMaterialSource.description, info);
      }
    }
    if (!current()) return;
    _cachedVideoContext = material.forModel(info);
    subtitleWarning.value = material.text.length > 15000;
    contextStatus.value = '';
    _contextLoadIndex = messages.length;
    messages.add(ChatMessage(role: 'system', content: material.source.label, isDivider: true));
    hasVideoContext.value = true;
  }

  Future<void> startAnalysis(
    String templatePrompt, {
    String? templateName,
    required ChooseCaptionSource chooseSource,
  }) => _runRequest(
    prompt: templatePrompt,
    templateName: templateName,
    chooseSource: chooseSource,
    errorPrefix: '分析失败',
  );

  /// Send a follow-up message.
  Future<void> sendFollowUp(String text) async {
    if (text.trim().isEmpty) return;
    await _runRequest(prompt: text.trim(), errorPrefix: '请求失败');
  }

  bool _isCurrentRequest(CancelToken token) =>
      identical(_requestToken, token) && !token.isCancelled && !isClosed;

  Future<void> _runRequest({
    String? prompt,
    String? templateName,
    ChooseCaptionSource? chooseSource,
    required String errorPrefix,
  }) async {
    if (_requestToken != null || isClosed) return;
    final profile = currentProfile;
    final token = CancelToken();
    _requestToken = token;
    isRequesting.value = true;
    var removeEmpty = false;

    try {
      if (chooseSource != null && !hasVideoContext.value) {
        await _loadVideoContext(token, chooseSource);
        if (!_isCurrentRequest(token) || !hasVideoContext.value) return;
      }
      if (prompt == null || !_isCurrentRequest(token)) return;

      final response = ChatMessage(role: 'assistant', content: '', isStreaming: true);
      _responseMessage = response;
      messages.addAll([
        ChatMessage(
          role: 'user',
          content: prompt,
          templateName: templateName,
        ),
        response,
      ]);

      await _streamResponse(token, response, profile);
    } catch (e) {
      if (_isCurrentRequest(token)) {
        removeEmpty = true;
        if (e is! DioException || !CancelToken.isCancel(e)) {
          final detail = e is FormatException ? e.message : e.toString();
          SmartDialog.showToast('$errorPrefix：$detail');
        }
      }
    } finally {
      _finishRequest(token, removeEmpty: removeEmpty);
    }
  }

  void cancelRequest() {
    final token = _requestToken;
    if (token == null) return;
    token.cancel('用户停止请求');
    _finishRequest(token, removeEmpty: true);
  }

  void _finishRequest(CancelToken token, {bool removeEmpty = false}) {
    // 停止后可以立即重发，旧请求的 finally 不能结束新请求。
    if (!identical(_requestToken, token)) return;
    final response = _responseMessage;
    _requestToken = null;
    _responseMessage = null;
    if (response != null) {
      response.isStreaming = false;
      _freezeReasoningDuration(response);
      if (removeEmpty && response.content.isEmpty && !response.hasReasoning) {
        messages.remove(response);
      } else {
        messages.refresh();
      }
    }
    contextStatus.value = '';
    isRequesting.value = false;
  }

  Future<void> _streamResponse(
    CancelToken token,
    ChatMessage response,
    Map<String, String> profile,
  ) async {
    subtitleWarning.value = false;

    final chatMessages = <Map<String, String>>[
      {
        'role': 'system',
        'content': hasVideoContext.value
            ? _systemPromptB
            : _systemPromptA,
      },
    ];

    // Inject cached video context as system message (for prefix caching)
    if (hasVideoContext.value && _cachedVideoContext != null) {
      chatMessages.add({
        'role': 'system',
        'content': _cachedVideoContext!,
      });
    }

    // Add conversation history, truncating at context load boundary.
    // 思考内容只保留在本地供 UI 展示，出站历史只用 role + 正文；
    // 正文为空的助手消息整条跳过（失败留下的思考卡片、流结束无正文的
    // 卡片、正在流式且尚无正文的占位都不发送空 content）
    final startIdx = _contextLoadIndex >= 0 ? _contextLoadIndex : 0;
    for (final m in messages.skip(startIdx)) {
      if (m.isDivider) continue;
      if (m.role == 'assistant' && m.content.isEmpty) continue;
      chatMessages.add({'role': m.role, 'content': m.content});
    }

    await for (final delta in AiChatService.streamChat(
      messages: chatMessages,
      profile: profile,
      model: profile['model'] ?? '',
      reasoningEffort: profile['effort'],
      cancelToken: token,
    )) {
      if (!_isCurrentRequest(token)) return;
      if (delta.reasoningDelta.isNotEmpty) {
        _appendReasoningDelta(response, delta.reasoningDelta);
      }
      if (delta.contentDelta.isNotEmpty) {
        _appendContentDelta(response, delta.contentDelta);
      }
    }
  }

  /// 追加思考增量。首次非空增量记录起始时刻，正文仍空时默认展开为限高卡片
  void _appendReasoningDelta(ChatMessage msg, String delta) {
    if (msg.reasoningStartedAt == null) {
      msg.reasoningStartedAt = DateTime.now();
      if (msg.content.isEmpty) {
        msg
          ..isReasoningExpanded = true
          ..isReasoningFullHeight = false;
      }
      _startReasoningTimer(msg);
    }
    msg.appendReasoningContent(delta);
    messages.refresh();
  }

  /// 追加正文增量。第一个正文字符到达时强制收成胶囊并冻结思考耗时
  void _appendContentDelta(ChatMessage msg, String delta) {
    if (msg.content.isEmpty) {
      _freezeReasoningDuration(msg);
      msg.isReasoningExpanded = false;
    }
    msg.appendContent(delta);
    messages.refresh();
  }

  /// 进行中的秒数由 [ChatMessage.reasoningSeconds] 实时计算，
  /// 这里只负责约每 100ms 触发一次刷新
  void _startReasoningTimer(ChatMessage msg) {
    _stopReasoningTimer();
    _reasoningTimerMsg = msg;
    _reasoningTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final target = _reasoningTimerMsg;
      if (target == null || target.reasoningDurationSeconds != null) {
        _stopReasoningTimer();
        return;
      }
      messages.refresh();
    });
  }

  void _stopReasoningTimer() {
    _reasoningTimer?.cancel();
    _reasoningTimer = null;
    _reasoningTimerMsg = null;
  }

  /// 按当前时刻冻结思考耗时：第一个正文字符到达或流结束时调用
  void _freezeReasoningDuration(ChatMessage msg) {
    if (msg.reasoningStartedAt != null) {
      msg.reasoningDurationSeconds = msg.reasoningSeconds;
    }
    if (identical(_reasoningTimerMsg, msg)) _stopReasoningTimer();
  }

  void clearMessages() {
    cancelRequest();
    _stopReasoningTimer();
    messages.clear();
    subtitleWarning.value = false;
    hasVideoContext.value = false;
    _cachedVideoContext = null;
    _contextLoadIndex = -1;
  }
}
