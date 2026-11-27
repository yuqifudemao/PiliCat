import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io';

import 'package:PiliPlus/pages/ai_chat/controller.dart';
import 'package:PiliPlus/pages/ai_chat/models.dart';
import 'package:PiliPlus/pages/common/slide/common_slide_page.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/services/ai_chat/video_material.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/services/ai_chat/voice.dart';
import 'package:PiliPlus/pages/setting/ai_setting/voice_settings.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart';
import 'package:material_ui/material_ui.dart' hide TextField;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:markdown/markdown.dart' as md;

class AiChatPage extends CommonSlidePage {
  const AiChatPage({super.key, required this.heroTag, this.inPlayer = false})
      : super(enableSlide: !inPlayer);

  final String heroTag;
  final bool inPlayer;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage>
    with SingleTickerProviderStateMixin, CommonSlideMixin, WidgetsBindingObserver {
  late final AiChatController chatCtl;
  final _inputCtl = RichTextEditingController();
  final _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  final _scrollCtl = ScrollController();
  late List<AiPromptTemplate> _templates;
  int _selectedPromptIndex = 0;
  bool _isAtBottom = true;
  bool _scrollScheduled = false;

  /// 手指拖拽中，此时不自动滚动，避免和手指抢滚动位置
  bool _userDragging = false;

  /// 思考框限高档是否已消费本次滚轮事件
  bool _reasoningWheelConsumed = false;

  /// 顶部提示词栏的收起进度，从完全展开（0）到完全收起（1）。
  final _promptBarCollapse = ValueNotifier<double>(0);

  /// 顶部提示词栏的布局 key：取它布局后的自然高度，用于把滚动量换算成
  /// 收起进度，并保证滚动补偿与实际布局位移一致。
  final _promptBarKey = GlobalKey();

  /// 布局完成前的兜底高度，数值与提示词栏的默认高度接近。
  static const double _defaultPromptBarHeight = 64.0;

  /// 顶部提示词/分析栏的自然高度（含提示条、分割线）。
  double get _promptBarHeight =>
      _promptBarKey.currentContext?.size?.height ?? _defaultPromptBarHeight;

  /// 小屏设备（手表/小折叠屏）紧凑布局：仅压缩间距与控件密度，不缩放字号。
  bool get _isCompact => MediaQuery.sizeOf(context).height < 600;

  /// Desktop: Enter sends, Shift+Enter inserts newline.
  /// Mobile: consume Enter to prevent it from bubbling up to PlayerFocus
  /// (which would open the danmaku input panel).
  static KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      if (Platform.isAndroid || Platform.isIOS) {
        // On mobile, stop the KeyEvent from propagating to ancestor focus
        // handlers (e.g. PlayerFocus → send danmaku), but let the platform
        // IME process it as text input so the newline gets inserted.
        return KeyEventResult.skipRemainingHandlers;
      }
      if (!HardwareKeyboard.instance.isShiftPressed) {
        final state =
            node.context?.findAncestorStateOfType<_AiChatPageState>();
        if (state != null && !state.chatCtl.isRequesting.value) {
          state._sendCustomPrompt();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    chatCtl = Get.find<AiChatController>(tag: widget.heroTag);
    chatCtl.openPanel();
    _templates = AiChatService.getTemplates();
    _scrollCtl.addListener(_onScroll);
  }

  @override
  void dispose() {
    // 请求由视频页持有的 controller 管理，关闭面板后继续接收结果。
    WidgetsBinding.instance.removeObserver(this);
    _stopVoice(redraw: false);
    _inputCtl.dispose();
    _focusNode.dispose();
    _scrollCtl
      ..removeListener(_onScroll)
      ..dispose();
    _promptBarCollapse.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtl.hasClients) return;
    _syncFollowState(_scrollCtl.position.userScrollDirection);
  }

  /// 跟随开关：回看历史停跟随，滚向最新且贴底 100px 内恢复。
  ///
  /// 用 userScrollDirection 而非比较位移：程序滚动只会产生 idle，
  /// 不会把自动跟随或控制栏补偿误判成「用户回到最新」
  void _syncFollowState(ScrollDirection direction) {
    if (direction == ScrollDirection.forward) {
      if (_isAtBottom) setState(() => _isAtBottom = false);
    } else if (direction == ScrollDirection.reverse && !_isAtBottom) {
      final position = _scrollCtl.position;
      if (position.maxScrollExtent - position.pixels <= 100) {
        setState(() => _isAtBottom = true);
      }
    }
  }

  /// 只有用户手势滚动才收放控制栏。
  ///
  /// [ScrollUpdateNotification.dragDetails]、[OverscrollNotification.dragDetails]
  /// 为空时说明是惯性滑动或程序自动滚动（AI 流式回复时的自动滚到底部），
  /// 此时控制栏保持不动；鼠标滚轮、触控板没有 dragDetails，
  /// 由 [_onPointerSignal] 单独处理。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    // 思考框限高档的内层滚动不参与顶栏收放与列表贴底判定
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) _userDragging = true;
    } else if (notification is ScrollEndNotification) {
      // 程序滚动（correctBy 等）也会发 ScrollEnd，只有拖拽结束才复位
      if (notification.dragDetails != null) _userDragging = false;
    } else if (notification is UserScrollNotification) {
      // 拖拽接惯性时上面那次来自 ballistic，用 idle 兜底复位
      if (notification.direction == ScrollDirection.idle) {
        _userDragging = false;
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) return false;
      _handleUserScroll(notification.scrollDelta ?? 0);
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      // 列表到顶/到底后继续拖拽也能把控制栏平移回来
      _updateBarCollapse(notification.overscroll, _promptBarHeight);
    }
    return false;
  }

  /// 鼠标滚轮、触控板滚动只发指针信号，不产生带 dragDetails 的滚动通知。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_reasoningWheelConsumed) {
      _reasoningWheelConsumed = false;
      return;
    }
    final scrollDelta = event.scrollDelta.dy;
    if (scrollDelta == 0) return;
    if (_scrollCtl.hasClients) {
      final position = _scrollCtl.position;
      // 已在边界时滚轮不会真的滚动，只收放控制栏，不补偿滚动位置
      final canScroll = scrollDelta > 0
          ? position.pixels < position.maxScrollExtent
          : position.pixels > position.minScrollExtent;
      if (!canScroll) {
        _updateBarCollapse(scrollDelta, _promptBarHeight);
        return;
      }
    }
    _handleUserScroll(scrollDelta);
  }

  /// 按用户滚动的位移量收放控制栏，并补偿列表滚动位置。
  void _handleUserScroll(double scrollDelta) {
    final height = _promptBarHeight;
    final value = _promptBarCollapse.value;
    if (!_updateBarCollapse(scrollDelta, height)) return;
    // 顶栏收起会让列表上边缘上移同样高度，补偿滚动位置以保证内容跟手 1:1
    if (_scrollCtl.hasClients) {
      _scrollCtl.position.correctBy((value - _promptBarCollapse.value) * height);
    }
  }

  /// 按滚动量更新控制栏进度，返回进度是否发生变化。
  ///
  /// [height] 为顶栏的实际高度：累计滚动量与它相等时正好完全收起。
  bool _updateBarCollapse(double scrollDelta, double height) {
    if (scrollDelta == 0 || height <= 0) return false;
    final next = clampDouble(
      _promptBarCollapse.value + scrollDelta / height,
      0.0,
      1.0,
    );
    if (next == _promptBarCollapse.value) return false;
    _promptBarCollapse.value = next;
    return true;
  }

  void _jumpToLatest() {
    if (!_scrollCtl.hasClients) return;
    if (!_isAtBottom) {
      setState(() => _isAtBottom = true);
    }
    _scrollCtl.animateTo(
      _scrollCtl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// 思考框限高档内层滚到顶/底后，把剩余位移交给外层对话列表
  void _scrollOuterBy(double delta) {
    if (!_scrollCtl.hasClients || delta == 0) return;
    final position = _scrollCtl.position;
    final target = clampDouble(
      position.pixels + delta,
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    position.jumpTo(target);
    // jumpTo 不产生 forward/reverse，按交接方向补一次跟随判定
    _syncFollowState(
      delta > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
  }

  void _scrollToBottom() {
    // 手指还按在屏幕上时不抢滚动位置，松手后由下一次刷新接着跟随
    if (_userDragging) return;
    if (!_scrollCtl.hasClients || !_isAtBottom || _scrollScheduled) {
      return;
    }
    if (!Pref.aiAutoScroll) {
      _scrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollScheduled = false;
        if (mounted &&
            _scrollCtl.hasClients &&
            _isAtBottom &&
            _scrollCtl.position.maxScrollExtent -
                    _scrollCtl.position.pixels >
                100) {
          setState(() => _isAtBottom = false);
        }
      });
      return;
    }
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (_scrollCtl.hasClients && _isAtBottom) {
        _scrollCtl.animateTo(
          _scrollCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendSelectedPrompt() {
    if (_templates.isEmpty) return;
    if (_selectedPromptIndex >= 0 && _selectedPromptIndex < _templates.length) {
      final t = _templates[_selectedPromptIndex];
      chatCtl.startAnalysis(t.prompt, templateName: t.name, chooseSource: _chooseCaptionSource, confirmPlaying: _confirmPlayingCaptions);
    }
  }

  Future<MissingCaptionChoice?> _chooseCaptionSource(
    bool canReadFrames, bool hasDescription, CancelToken token,
  ) async {
    return _captionDialog(token, (context) => AlertDialog(
        scrollable: true,
        title: const Text('未找到本集字幕或转写'),
        content: Text(canReadFrames
            ? '可以在手机上抽取视频画面，识别画面下半部的字幕。读取视频会使用流量，只有识别出的文字会发给当前 AI 模型。'
            : '可以用视频标题与简介做简要概括。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          if (hasDescription)
            TextButton(
              onPressed: () => Navigator.pop(context, MissingCaptionChoice.description),
              child: const Text('仅根据简介'),
            ),
          if (canReadFrames)
            FilledButton(
              onPressed: () => Navigator.pop(context, MissingCaptionChoice.frames),
              child: const Text('识别画面字幕'),
            ),
        ],
      ),
    );
  }

  Future<bool> _confirmPlayingCaptions(CancelToken token) async =>
      await _captionDialog<bool>(token, (context) => AlertDialog(
        scrollable: true,
        title: const Text('改为识别当前播放片段？'),
        content: const Text('整集抽样没有取得可用字幕。可以继续播放约 30 秒，从实际播放的画面读取字幕，只总结这段内容。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('播放并识别')),
        ],
      )) ?? false;

  Future<T?> _captionDialog<T>(CancelToken token, WidgetBuilder builder) async {
    if (!mounted || token.isCancelled) return null;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(context: context, builder: builder);
    unawaited(token.whenCancel.then((_) {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    }));
    return navigator.push(route);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _stopVoice();
    }
  }

  Object? _voiceOwner;
  String _voiceStatus = '';
  bool _voiceRequest = false;
  ChatMessage? _reading;
  StreamSubscription<int>? _voiceParts;

  void _stopVoice({bool redraw = true}) {
    final owner = _voiceOwner;
    if (owner == null) return;
    _voiceOwner = null;
    _reading = null;
    _voiceStatus = '';
    _voiceParts?.cancel();
    _voiceParts = null;
    if (_voiceRequest) chatCtl.cancelRequest();
    _voiceRequest = false;
    unawaited(AssistantVoice.shared.release(owner).catchError((_) {}));
    if (redraw && mounted) setState(() {});
  }

  Future<void> _voice([ChatMessage? message]) async {
    if (_voiceOwner != null) {
      if (message == null && AssistantVoice.shared.recording) {
        AssistantVoice.shared.sendRecording();
      } else {
        _stopVoice();
      }
      return;
    }
    if (chatCtl.isRequesting.value) return;
    final owner = Object();
    final voice = AssistantVoice.shared;
    if (!voice.claim(owner)) return;
    _voiceOwner = owner;
    bool active() => mounted && identical(_voiceOwner, owner);
    try {
      final video = Get.find<VideoDetailController>(tag: widget.heroTag);
      _voiceParts = video.cid.listen((_) => _stopVoice());
      if (message == null) {
        final mic = await Permission.microphone.request();
        if (!active()) return;
        if (!mic.isGranted) {
          if (mic.isPermanentlyDenied) {
            final settings = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
              title: const Text('需要麦克风权限'),
              content: const Text('请在 PiliCat 的应用权限中允许使用麦克风，再回来点麦克风开始。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('打开应用设置')),
              ],
            ));
            if (settings == true && active()) await openAppSettings();
          } else {
            SmartDialog.showToast('请允许 PiliCat 在使用期间访问麦克风');
          }
          return;
        }
      }
      if (!active()) return;
      await video.plPlayerController.pause();
      if (!active()) return;
      var options = VoiceOptions();
      final profile = chatCtl.currentProfile;
      Future<void> read(String text) => options.narration
          ? voice.narrate(owner, profile, options.tts, options.voice, text)
          : voice.read(owner, text);
      if (message != null) {
        setState(() => _reading = message);
        await read(message.content);
        return;
      }
      while (active()) {
        setState(() => _voiceStatus = '正在听，点击结束');
        final String question;
        if (options.transcription) {
          question = await voice.recordQuestion(owner, profile, options.stt,
            onRecording: () { if (active()) setState(() => _voiceStatus = '录音中，点麦克风发送'); },
            onTranscribing: () { if (active()) setState(() => _voiceStatus = '正在转写，点击结束'); },
          );
        } else {
          try {
            question = await voice.listen(owner);
          } on SystemSpeechUnavailable {
            if (!active()) return;
            final saved = await showVoiceOptions(context, recognitionFailed: true);
            if (!active() || saved != true) return;
            options = VoiceOptions();
            if (options.transcription) continue;
            return;
          }
        }
        if (!active() || question.isEmpty) break;
        setState(() => _voiceStatus = '正在回答，点击结束');
        _voiceRequest = true;
        if (!chatCtl.hasVideoContext.value && chatCtl.messages.isEmpty) {
          await chatCtl.loadVideoContext(chooseSource: _chooseCaptionSource, confirmPlaying: _confirmPlayingCaptions);
        }
        if (!active()) return;
        final seconds = video.plPlayerController.progress;
        final before = chatCtl.messages.length;
        await chatCtl.sendFollowUp('当前播放位置 [${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}]。$question');
        if (!active()) return;
        _voiceRequest = false;
        final reply = chatCtl.messages.lastOrNull;
        if (chatCtl.messages.length <= before || reply == null || reply.role != 'assistant' || reply.content.trim().isEmpty) break;
        setState(() => _voiceStatus = '正在朗读，点击结束');
        await read(reply.content);
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (active()) SmartDialog.showToast(status == null ? '语音接口连接失败，请检查网络和 API 地址'
          : '语音接口返回 HTTP $status，请检查当前 API 的权限、语音模型和音色');
    } catch (error) {
      if (active()) SmartDialog.showToast('语音提示 · $error');
    } finally {
      if (active()) _stopVoice();
    }
  }

  void _sendCustomPrompt() {
    if (chatCtl.isRequesting.value) return;
    final text = _inputCtl.text.trim();
    if (text.isEmpty) return;
    _inputCtl.clear();
    chatCtl.sendFollowUp(text);
  }

  void _copyMessage(ChatMessage msg) {
    if (msg.content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: msg.content));
    SmartDialog.showToast('已复制到剪贴板');
  }

  @override
  Widget buildPage() {
    _templates = AiChatService.getTemplates();
    final colorScheme = theme.colorScheme;
    final typingInPlayer =
        widget.inPlayer && MediaQuery.viewInsetsOf(context).bottom > 0;
    return FocusScope(
      child: Material(
        color: colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: widget.inPlayer
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(28)),
        child: Column(
          children: [
            if (!widget.inPlayer) ...[
              GestureDetector(
                onTap: Get.back,
                child: SizedBox(
                  height: _isCompact ? 24 : 35,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 3,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: const BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      color: colorScheme.primary,
                      size: _isCompact ? 18 : 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'AI 视频助手',
                      style: (_isCompact ? theme.textTheme.titleSmall : theme.textTheme.titleMedium)?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Obx(() {
                      if (chatCtl.messages.isNotEmpty) {
                        return TextButton.icon(
                          onPressed: chatCtl.clearMessages,
                          style: _isCompact
                              ? TextButton.styleFrom(visualDensity: VisualDensity.compact)
                              : null,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('重置'),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],
                ),
              ),
              SizedBox(height: _isCompact ? 4 : 8),
            ],
            if (!typingInPlayer)
              ValueListenableBuilder<double>(
                valueListenable: _promptBarCollapse,
                builder: (context, progress, child) => SizeTransition(
                  sizeFactor: AlwaysStoppedAnimation(1.0 - progress),
                  alignment: Alignment.bottomLeft,
                  child: child,
                ),
                child: Column(
                  key: _promptBarKey,
                  children: [
                    _buildModelPicker(),
                    _buildPromptBar(theme),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    Obx(() {
                      final status = chatCtl.contextStatus.value;
                      if (status.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(status, style: theme.textTheme.bodySmall),
                      );
                    }),
                    Obx(() {
                      if (!chatCtl.subtitleWarning.value) {
                        return const SizedBox.shrink();
                      }
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        color: colorScheme.errorContainer,
                        child: Text(
                          '提示：当前视频文本较长，AI 首次阅读需要几秒钟，请耐心等待',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            Expanded(child: enableSlide ? slideList() : buildList()),
            _buildInputBar(theme),
          ],
        ),
      ),
    );
  }

  @override
  Widget buildList() {
    return Listener(
      // 鼠标滚轮/触控板滚动没有 dragDetails，由指针信号单独跟随
      onPointerSignal: _onPointerSignal,
      child: _buildContent(theme),
    );
  }

  Future<void> _selectModel() async {
    final profiles = Pref.aiApiProfiles
        .where((profile) => (profile['url'] ?? '').trim().isNotEmpty)
        .toList();
    if (profiles.isEmpty) {
      SmartDialog.showToast('请先在 AI 视频总结设置中添加 API 配置');
      return;
    }

    final selected = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _AiModelDialog(
        profiles: profiles,
        current: chatCtl.currentProfile,
      ),
    );
    if (mounted && selected != null && !chatCtl.isRequesting.value) {
      chatCtl.selectedProfile.value = selected;
    }
  }

  Widget _buildModelPicker() {
    return Obx(() {
      final profile = chatCtl.currentProfile;
      final model = profile['model'] ?? '';
      final label = model.isEmpty ? '选择模型' : model;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: chatCtl.isRequesting.value ? null : _selectModel,
                  icon: const Icon(Icons.smart_toy_outlined, size: 18),
                  label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
            if (widget.inPlayer && chatCtl.messages.isNotEmpty)
              IconButton(
                tooltip: '清除本集对话和已保存的总结',
                visualDensity: VisualDensity.compact,
                onPressed: chatCtl.clearMessages,
                icon: const Icon(Icons.refresh, size: 18),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildPromptBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: _isCompact ? 4 : 8),
      child: Row(
        children: [
          Expanded(
            child: _templates.isEmpty
                ? Text(
                    '暂无模板，请在设置中添加',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.outline,
                    ),
                  )
                : DropdownButtonFormField<int>(
                    isExpanded: true,
                    // ignore: deprecated_member_use
                    value: _selectedPromptIndex < _templates.length
                        ? _selectedPromptIndex
                        : 0,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: _isCompact ? 6 : 8,
                      ),
                      isDense: true,
                    ),
                    items: _templates.asMap().entries.map((entry) {
                      return DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedPromptIndex = value);
                      }
                    },
                  ),
          ),
          const SizedBox(width: 12),
          Obx(() {
            final requesting = chatCtl.isRequesting.value;
            final hasContext = chatCtl.hasVideoContext.value;
            final name = _templates.elementAtOrNull(_selectedPromptIndex)?.name;
            final hasSummary = name != null &&
                chatCtl.messages.any((message) => message.templateName == name);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!hasContext)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      onPressed: requesting ? null : () => chatCtl.loadVideoContext(chooseSource: _chooseCaptionSource, confirmPlaying: _confirmPlayingCaptions),
                      icon: Icon(Icons.post_add, size: _isCompact ? 18 : 22),
                      tooltip: '载入上下文',
                    ),
                  ),
                FilledButton.icon(
                  onPressed: requesting ? null : _sendSelectedPrompt,
                  style: _isCompact
                      ? FilledButton.styleFrom(visualDensity: VisualDensity.compact)
                      : null,
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: Text(hasSummary ? '重新分析' : '分析'),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Obx(() {
      final msgs = chatCtl.messages;

      // Empty state
      if (msgs.isEmpty) {
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(widget.inPlayer ? 12 : 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.inPlayer) ...[
                  Icon(Icons.auto_awesome, size: 48, color: colorScheme.outline),
                  const SizedBox(height: 16),
                ],
                Text(
                  chatCtl.hasVideoContext.value
                      ? '视频上下文已载入，请输入你的问题'
                      : '点「分析」查找本集字幕或转写，也可以直接提问',
                  style: TextStyle(color: colorScheme.outline),
                ),
              ],
            ),
          ),
        );
      }

      if (!chatCtl.showingSavedSummaries) _scrollToBottom();

       return NotificationListener<ScrollNotification>(
         onNotification: _onScrollNotification,
         child: Stack(
           children: [
             ListView.builder(
               controller: _scrollCtl,
               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
               itemCount: msgs.length,
               itemBuilder: (context, index) {
                 final msg = msgs[index];
                 if (msg.isDivider) return _buildDivider(theme, msg.content);
                 if (msg.role == 'user') {
                   final displayText = msg.templateName != null
                       ? '/${msg.templateName}'
                       : msg.content;
                   return _buildUserMessage(displayText, theme);
                 }
                 return _buildAssistantMessage(msg, theme);
               },
             ),
             if (!_isAtBottom)
               Positioned(
                 right: 16,
                 bottom: 16,
                 child: FloatingActionButton.small(
                   heroTag: null,
                   tooltip: '回到最新',
                   onPressed: _jumpToLatest,
                   child: const Icon(Icons.keyboard_arrow_down_rounded),
                 ),
               ),
           ],
         ),
       );
    });
  }

  Widget _buildDivider(ThemeData theme, String source) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: _isCompact ? 8 : 12),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(child: Divider(color: colorScheme.outlineVariant)),
          Flexible(
            flex: 8,
            child: Text(
              source,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.outline,
              ),
            ),
          ),
          Expanded(child: Divider(color: colorScheme.outlineVariant)),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildUserMessage(String content, ThemeData theme) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (_isCompact ? 0.92 : 0.8),
        ),
        margin: EdgeInsets.symmetric(vertical: _isCompact ? 2 : 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(
          content,
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantMessage(ChatMessage msg, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    // 既无思考（含只收到空白/标签）也无正文且已停流时不渲染空气泡
    if (!msg.hasReasoning && msg.content.isEmpty && !msg.isStreaming) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * (_isCompact ? 0.95 : 0.85),
            ),
            margin: EdgeInsets.symmetric(vertical: _isCompact ? 2 : 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 思考块是整条助手消息内部第一个子 Widget，不是独立消息
                if (msg.hasReasoning) ...[
                  _ReasoningBlock(
                    msg: msg,
                    onChanged: chatCtl.messages.refresh,
                    onOuterScrollBy: _scrollOuterBy,
                    isOuterAtBottom: () => _isAtBottom,
                    onInnerWheelConsumed: () => _reasoningWheelConsumed = true,
                  ),
                  if (msg.content.isNotEmpty) const SizedBox(height: 8),
                ],
                if (msg.content.isNotEmpty)
                  SelectionArea(
                    child: MarkdownBody(
                      data: msg.content,
                      blockSyntaxes: [LatexBlockSyntax()],
                      inlineSyntaxes: [LatexInlineSyntax(), TimestampSyntax()],
                      builders: {
                        'latex': LatexElementBuilder(),
                        'timestamp': TimestampBuilder(
                          onTap: _seekToTimestamp,
                        ),
                      },
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          height: 1.6,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        h1: TextStyle(
                          inherit: false,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.5,
                        ),
                        h2: TextStyle(
                          inherit: false,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.5,
                        ),
                        h3: TextStyle(
                          inherit: false,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        h4: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        h5: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        h6: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        a: TextStyle(
                          color: colorScheme.primary,
                          inherit: false,
                        ),
                        blockquote: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          height: 1.6,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: colorScheme.primary,
                              width: 3,
                            ),
                          ),
                        ),
                        blockquotePadding: const EdgeInsets.only(left: 12),
                        code: TextStyle(
                          inherit: false,
                          fontSize: 13,
                          color: colorScheme.primary,
                          backgroundColor: colorScheme.surfaceContainerHigh,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        codeblockPadding: const EdgeInsets.all(12),
                        listBullet: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          color: colorScheme.primary,
                        ),
                        listIndent: 24,
                        blockSpacing: 8,
                        tableHead: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                        tableBody: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          height: 1.5,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        tableHeadAlign: TextAlign.center,
                        tableBorder: TableBorder.all(
                          color: colorScheme.outlineVariant,
                        ),
                        tableCellsPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        tableHeadCellsPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        tableHeadCellsDecoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                        ),
                        tableCellsDecoration: const BoxDecoration(),
                        tablePadding: const EdgeInsets.only(bottom: 4),
                        checkbox: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          color: colorScheme.primary,
                        ),
                        horizontalRuleDecoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: colorScheme.outlineVariant,
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                // 流已开始但尚无思考、也无正文时保留原有等待占位
                else if (msg.isStreaming && !msg.hasReasoning)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'AI 正在思考...',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (Platform.isAndroid && !msg.isStreaming && msg.content.isNotEmpty)
            IconButton(
              tooltip: identical(_reading, msg) ? '停止朗读' : '朗读回答',
              onPressed: () => _voice(msg),
              icon: Icon(identical(_reading, msg) ? Icons.stop : Icons.volume_up_outlined),
            ),
          // Copy button at bottom-right of bubble, after streaming ends
          if (!msg.isStreaming && msg.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Material(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
                elevation: 2,
                child: InkWell(
                  onTap: () => _copyMessage(msg),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.copy,
                      size: 16,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _seekToTimestamp(int seconds) {
    try {
      final videoCtl = Get.find<VideoDetailController>(tag: widget.heroTag);
      final duration = videoCtl.plPlayerController.duration.value;
      if (duration > 0 && seconds > duration) {
        SmartDialog.showToast('时间戳超出视频时长');
        return;
      }
      videoCtl.plPlayerController.seekTo(
        Duration(seconds: seconds),
      );
    } catch (_) {
      SmartDialog.showToast('跳转失败');
    }
  }

  Widget _buildInputBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).viewPadding.bottom;
    final bottomPadding = bottomInset > 0 ? bottomInset + 4.0 : safeBottom + (_isCompact ? 8.0 : 16.0);
    return Container(
      padding: EdgeInsets.fromLTRB(16, _isCompact ? 4 : 8, 8, bottomPadding),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          if (Platform.isAndroid && _voiceOwner != null && AssistantVoice.shared.recording)
            IconButton(tooltip: '取消录音', onPressed: _stopVoice, icon: const Icon(Icons.close)),
          if (Platform.isAndroid)
            IconButton(
              tooltip: _voiceStatus.isEmpty ? '开始语音对话' : _voiceStatus,
              icon: Icon(_voiceOwner == null ? Icons.mic_none : AssistantVoice.shared.recording ? Icons.send : Icons.stop_circle_outlined),
              onPressed: () => _voice(),
            ),
          Expanded(
            child: RichTextField(
              controller: _inputCtl,
              focusNode: _focusNode,
              maxLines: widget.inPlayer && bottomInset > 0 ? 1 : 3,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: _voiceStatus.isEmpty ? '输入问题继续对话...' : _voiceStatus,
                hintStyle: TextStyle(color: colorScheme.outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: _isCompact ? 6 : 10,
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Obx(() {
            final requesting = chatCtl.isRequesting.value;
            return IconButton.filled(
              onPressed: requesting ? chatCtl.cancelRequest : _sendCustomPrompt,
              tooltip: requesting ? '停止生成' : '发送',
              icon: requesting
                  ? SizedBox.square(
                      dimension: 24,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onPrimary,
                            ),
                          ),
                          const Icon(Icons.stop_rounded, size: 16),
                        ],
                      ),
                    )
                  : const Icon(Icons.send),
            );
          }),
        ],
      ),
    );
  }
}

/// Matches timestamps like 00:12, 01:23:45 in any context.
/// Avoids matching IP addresses (192.168.x.x:80) and URLs.
class TimestampSyntax extends md.InlineSyntax {
  TimestampSyntax()
      : super(
        r'(?<![.\d])(?:\[| ［|【|[\(])?(\d{1,2})[：:](\d{2})(?:[：:](\d{2}))?(?:\]| ［|】|[\)])?(?![.\d])',
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final g1 = int.parse(match.group(1)!);
    final g2 = int.parse(match.group(2)!);
    final g3 = match.group(3) != null ? int.parse(match.group(3)!) : null;

    // Validate: minutes/seconds must be 0-59
    if (g2 > 59 || (g3 != null && g3 > 59)) return false;

    int seconds;
    if (g3 != null) {
      // HH:MM:SS
      seconds = g1 * 3600 + g2 * 60 + g3;
    } else {
      // MM:SS
      seconds = g1 * 60 + g2;
    }

    final element = md.Element.text('timestamp', match.group(0)!);
    element.attributes['seconds'] = '$seconds';
    parser.addNode(element);
    return true;
  }
}

/// Renders timestamps as tappable colored text.
class TimestampBuilder extends MarkdownElementBuilder {
  TimestampBuilder({required this.onTap});

  final void Function(int seconds) onTap;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final seconds = int.tryParse(element.attributes['seconds'] ?? '') ?? 0;
    final text = element.textContent;
    final style = (parentStyle ?? const TextStyle()).copyWith(
      color: Theme.of(context).colorScheme.primary,
    );

    return GestureDetector(
      onTap: () => onTap(seconds),
      child: Text(text, style: style),
    );
  }
}

/// 助手消息内的思考块（不拆成独立消息）。
///
/// 两套独立状态：
/// - 形态 [ChatMessage.isReasoningExpanded]：true=卡片，false=胶囊
/// - 高度档 [ChatMessage.isReasoningFullHeight]：false=限高 120（内容框内局部
///   滚动），true=放开（无内层滚动，整段跟着对话列表走）
class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({
    required this.msg,
    required this.onChanged,
    required this.onOuterScrollBy,
    required this.isOuterAtBottom,
    required this.onInnerWheelConsumed,
  });

  final ChatMessage msg;
  final VoidCallback onChanged;

  /// 内层滚到顶/底后，把剩余位移交给外层对话列表
  final void Function(double delta) onOuterScrollBy;

  /// 外层对话列表是否贴着底部
  final bool Function() isOuterAtBottom;

  /// 限高档滚轮由内层消费时通知页面，避免外层同时滚动
  final VoidCallback onInnerWheelConsumed;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  /// 限高档高度（逻辑像素），紧凑布局同样使用 120
  static const double _limitedHeight = 120;

  /// 贴底判定，复用 P0 的 100 像素阈值
  static const double _bottomThreshold = 100;

  final _innerCtl = ScrollController();

  /// 内层是否贴着底部：贴着时新字到达后内层自动滚到最新
  bool _innerFollowing = true;

  /// 待执行的内层定位：落到最新 / 回到顶部
  bool _jumpInnerToLatest = false;
  bool _resetInnerToTop = false;

  @override
  void initState() {
    super.initState();
    _innerCtl.addListener(_onInnerScroll);
  }

  @override
  void dispose() {
    _innerCtl
      ..removeListener(_onInnerScroll)
      ..dispose();
    super.dispose();
  }

  void _onInnerScroll() {
    if (!_innerCtl.hasClients) return;
    final position = _innerCtl.position;
    _innerFollowing =
        position.maxScrollExtent - position.pixels <= _bottomThreshold;
  }

  @override
  void didUpdateWidget(covariant _ReasoningBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.msg.isReasoningExpanded) {
      _jumpInnerToLatest = false;
      _resetInnerToTop = false;
      return;
    }
    if (widget.msg.isReasoningFullHeight &&
        !_jumpInnerToLatest &&
        !_resetInnerToTop) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInnerScroll());
  }

  /// 限高档流式跟随与点击切换后的内层定位，只在限高档生效
  void _syncInnerScroll() {
    if (!mounted || !_innerCtl.hasClients) return;
    if (!widget.msg.isReasoningExpanded || widget.msg.isReasoningFullHeight) {
      return;
    }
    if (_jumpInnerToLatest || _resetInnerToTop) {
      final toLatest = _jumpInnerToLatest;
      _jumpInnerToLatest = false;
      _resetInnerToTop = false;
      final position = _innerCtl.position;
      final target = toLatest
          ? position.maxScrollExtent
          : position.minScrollExtent;
      if (target != position.pixels) _innerCtl.jumpTo(target);
      return;
    }
    // 贴着内层底部才跟随新字，用户上滑后暂停，回到底部附近后恢复
    if (!_innerFollowing) return;
    final position = _innerCtl.position;
    if (position.pixels < position.maxScrollExtent) {
      _innerCtl.jumpTo(position.maxScrollExtent);
    }
  }

  /// Header 点击：
  /// - 思考中且正文仍空：只切换高度档，不收成胶囊
  /// - 正文已出现：收成胶囊，回看结束后再点即收起
  /// - 流已结束且始终没有正文：放开高度档时收成胶囊，限高时先放开
  void _onHeaderTap() {
    final msg = widget.msg;
    if (msg.content.isNotEmpty) {
      _collapseToCapsule();
    } else if (msg.isStreaming) {
      _toggleHeight();
    } else if (msg.isReasoningFullHeight) {
      _collapseToCapsule();
    } else {
      _toggleHeight();
    }
  }

  /// 限高 ↔ 放开，形态保持卡片
  void _toggleHeight() {
    final msg = widget.msg;
    if (msg.isReasoningFullHeight) {
      // 外层贴底才让内层落到最新
      msg.isReasoningFullHeight = false;
      if (widget.isOuterAtBottom()) {
        _jumpInnerToLatest = true;
      } else {
        _jumpInnerToLatest = false;
        _resetInnerToTop = false;
      }
    } else {
      // 切换前内层贴底才补偿一次滚动，把最新思考滚进可见区
      final wasAtBottom = _innerCtl.hasClients && _innerFollowing;
      final growth =
          _innerCtl.hasClients ? _innerCtl.position.maxScrollExtent : 0.0;
      msg.isReasoningFullHeight = true;
      if (wasAtBottom && growth > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onOuterScrollBy(growth);
        });
      }
    }
    widget.onChanged();
  }

  /// 收成胶囊：只改形态，不改高度档
  void _collapseToCapsule() {
    widget.msg.isReasoningExpanded = false;
    _jumpInnerToLatest = false;
    _resetInnerToTop = false;
    widget.onChanged();
  }

  /// 整条胶囊点击：形态改回卡片、高度档放开，从思考内容顶部开始回看
  void _onCapsuleTap() {
    widget.msg
      ..isReasoningExpanded = true
      ..isReasoningFullHeight = true;
    _resetInnerToTop = true;
    _jumpInnerToLatest = false;
    widget.onChanged();
  }

  /// 限高档滚轮先滚内层，只有内层还能滚时才消费本次事件
  void _onInnerPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_innerCtl.hasClients) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0) return;
    final position = _innerCtl.position;
    final canScroll = delta > 0
        ? position.pixels < position.maxScrollExtent
        : position.pixels > position.minScrollExtent;
    if (canScroll) widget.onInnerWheelConsumed();
  }

  /// 限高档内层滚到顶/底后继续同方向滚动，把剩余位移交给外层对话列表
  bool _onInnerScrollNotification(ScrollNotification notification) {
    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      widget.onOuterScrollBy(notification.overscroll);
    }
    return false;
  }

  String get _title =>
      '思考了 ${widget.msg.reasoningSeconds.toStringAsFixed(1)} 秒';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
      child: widget.msg.isReasoningExpanded
          ? _buildCard(theme, colorScheme)
          : _buildCapsule(colorScheme),
    );
  }

  Widget _buildCapsule(ColorScheme colorScheme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: _onCapsuleTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 30,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 18,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _title,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 卡片形态：Header 只切换高度档，内容区只负责滚动和划词
  Widget _buildCard(ThemeData theme, ColorScheme colorScheme) {
    final fullHeight = widget.msg.isReasoningFullHeight;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: _onHeaderTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 18,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _title,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.outline,
                      ),
                    ),
                  ),
                  Icon(
                    fullHeight
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Divider(
            height: 1,
            thickness: 1,
            color: colorScheme.outline.withValues(alpha: 0.1),
          ),
          const SizedBox(height: 6),
          _buildContent(theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme colorScheme) {
    final text = Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
      child: SelectionArea(
        child: Text(
          widget.msg.reasoningContent,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: theme.hintColor,
          ),
        ),
      ),
    );
    // 放开高度档没有内层滚动，整段跟着对话列表走
    if (widget.msg.isReasoningFullHeight) return text;
    return NotificationListener<ScrollNotification>(
      onNotification: _onInnerScrollNotification,
      child: Listener(
        onPointerSignal: _onInnerPointerSignal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _limitedHeight),
          child: SingleChildScrollView(
            controller: _innerCtl,
            physics: const ClampingScrollPhysics(),
            child: text,
          ),
        ),
      ),
    );
  }
}

class _AiModelDialog extends StatefulWidget {
  const _AiModelDialog({required this.profiles, required this.current});

  final List<Map<String, String>> profiles;
  final Map<String, String> current;

  @override
  State<_AiModelDialog> createState() => _AiModelDialogState();
}

class _AiModelDialogState extends State<_AiModelDialog> {
  int _profileIndex = 0;
  late final TextEditingController _modelController;
  String _model = '';

  @override
  void initState() {
    super.initState();
    final index = widget.profiles.indexWhere(
      (profile) =>
          profile['name'] == widget.current['name'] &&
          profile['url'] == widget.current['url'] &&
          profile['key'] == widget.current['key'],
    );
    _profileIndex = index < 0 ? 0 : index;
    _model = (index < 0 ? _profile['model'] : widget.current['model']) ?? '';
    _modelController = TextEditingController(text: _model);
  }

  @override
  void dispose() {
    _modelController.dispose();
    super.dispose();
  }
  List<String> _models = [];
  bool _loading = false;

  Map<String, String> get _profile => widget.profiles[_profileIndex];

  Future<void> _fetchModels() async {
    setState(() => _loading = true);
    try {
      final models = await AiChatService.fetchModels(profile: _profile);
      if (!mounted) return;
      setState(() => _models = models.toSet().toList());
      if (models.isEmpty) SmartDialog.showToast('未获取到模型，可手动填写');
    } catch (_) {
      if (mounted) SmartDialog.showToast('获取模型失败，可手动填写');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('切换 AI 模型'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButton<int>(
            value: _profileIndex,
            isExpanded: true,
            items: [
              for (final (index, profile) in widget.profiles.indexed)
                DropdownMenuItem(
                  value: index,
                  child: Text(
                    profile['name'] ?? 'API 配置',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _loading
                ? null
                : (index) {
                    if (index == null) return;
                    setState(() {
                      _profileIndex = index;
                      _modelController.text = _model = _profile['model'] ?? '';
                      _models = [];
                    });
                  },
          ),
          TextFormField(
            controller: _modelController,
            decoration: const InputDecoration(labelText: '模型名称'),
            onChanged: (value) => setState(() => _model = value),
          ),
          TextButton(
            onPressed: _loading ? null : _fetchModels,
            child: Text(_loading ? '正在获取模型…' : '获取模型列表'),
          ),
          if (_models.isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: _models.contains(_model) ? _model : null,
              hint: const Text('从列表选择模型'),
              items: [
                for (final model in _models)
                  DropdownMenuItem(
                    value: model,
                    child: Text(model, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (model) {
                if (model == null) return;
                setState(() {
                  _modelController.text = _model = model;
                });
              },
            ),
          const Text('仅用于当前视频的后续分析和追问。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _model.trim().isEmpty || _loading
              ? null
              : () => Navigator.pop(context, {
                  ..._profile,
                  'model': _model.trim(),
                }),
          child: const Text('切换'),
        ),
      ],
    );
  }
}
