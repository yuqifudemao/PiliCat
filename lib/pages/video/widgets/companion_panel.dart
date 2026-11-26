import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/companion_session.dart';
import 'package:PiliPlus/services/companion_track.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:share_plus/share_plus.dart';

String _clock(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _label(CompanionCue cue) => switch (cue.kind) {
  CompanionKind.voice => '伴看语音 · ${(cue.length / 1000).ceil()} 秒',
  CompanionKind.image => '伴看截图',
  CompanionKind.text => cue.data,
};

Future<void> _preview(BuildContext context, CompanionSession session, CompanionCue cue) async {
  if (cue.kind == CompanionKind.voice) {
    await session.playVoice(cue);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('伴看 · ${_clock(cue.at)}'),
      content: cue.kind == CompanionKind.image
          ? InteractiveViewer(child: Image.memory(cue.bytes, cacheWidth: 1024,
              fit: BoxFit.contain, errorBuilder: (_, _, _) => const Text('图片无法显示')))
          : SingleChildScrollView(child: SelectableText(cue.data)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    ),
  );
}

class CompanionMarker extends StatelessWidget {
  const CompanionMarker(this.session, {super.key});
  final CompanionSession session;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<CompanionCue?>(
    valueListenable: session.notice,
    builder: (context, cue, _) => cue == null ? const SizedBox.shrink() : ActionChip(
      avatar: const Icon(Icons.headphones, size: 16),
      label: Text(cue.kind == CompanionKind.voice ? '听伴看语音' :
          cue.kind == CompanionKind.image ? '查看伴看截图' : '查看伴看留言'),
      onPressed: () => _preview(context, session, cue),
    ),
  );
}

class CompanionPanel extends StatefulWidget {
  const CompanionPanel({super.key, required this.session, required this.player,
    required this.anchor, required this.source});
  final CompanionSession session;
  final PlPlayerController player;
  final int anchor;
  final String source;

  @override
  State<CompanionPanel> createState() => _CompanionPanelState();
}

class _CompanionPanelState extends State<CompanionPanel> with WidgetsBindingObserver {
  CompanionSession get session => widget.session;
  bool get active => mounted && !session.closed;
  int get position => widget.player.positionInMilliseconds;
  late int anchor = widget.anchor;
  List<String> keys = ['mine'];
  final names = <String, String>{};
  bool busy = true;
  bool recording = false;
  bool resumeAfterRecord = false;
  String? error;
  Timer? timer;
  int captureEpoch = 0;
  CompanionSession? micSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _run(_load);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _abandonRecording();
  }

  void _abandonRecording() {
    ++captureEpoch;
    timer?.cancel();
    final owner = micSession;
    micSession = null;
    resumeAfterRecord = false;
    if (owner != null) unawaited(owner.cancelRecording().catchError((Object _) {}));
    if (recording && mounted) setState(() => recording = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    recording = false;
    _abandonRecording();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (!active) return;
    setState(() { busy = true; error = null; });
    try {
      await fn();
    } catch (e) {
      if (active) {
        setState(() => error = switch (e) {
          FormatException() => e.message,
          PlatformException() => e.message ?? '伴看操作失败',
          _ => '伴看操作失败，请检查文件后重试',
        });
      }
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  Future<void> _load() async {
    keys = await session.store.keys();
    await _select(keys.contains(session.key) ? session.key : 'mine');
  }

  Future<void> _select(String key) async {
    final track = await session.store.read(key);
    if (!active) return;
    session.select(key, track, position);
    names[key] = track.name;
  }

  Future<void> _edit(void Function(CompanionTrack) change) async {
    if (!active || session.key != 'mine') return;
    final mine = await session.store.edit(change);
    if (active) session.select('mine', mine, position);
  }

  Future<String?> _input(String title, int limit, {String value = ''}) async {
    String draft = value;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextFormField(initialValue: value, autofocus: true, maxLength: limit,
          maxLines: 3, minLines: 1, onChanged: (text) => draft = text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, draft.trim()), child: const Text('保存')),
        ],
      ),
    );
  }

  Future<void> _text() async {
    final text = await _input('在 ${_clock(anchor)} 留言', 500);
    if (text != null && text.isNotEmpty) {
      await _edit((t) => t.cues.add(CompanionCue(CompanionKind.text, anchor, text)));
    }
  }

  Future<void> _image() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery,
      maxWidth: 1280, maxHeight: 1280, imageQuality: 80, requestFullMetadata: false);
    if (file == null || !active) return;
    if (await file.length() > maxAttachmentBytes) throw const FormatException('请选择 1 MB 以内的截图');
    final cue = CompanionCue(CompanionKind.image, anchor, base64Encode(await file.readAsBytes()));
    CompanionCue.fromJson(cue.toJson());
    await _edit((t) => t.cues.add(cue));
  }

  Future<void> _record() async {
    final epoch = ++captureEpoch;
    if (!(await Permission.microphone.request()).isGranted) {
      throw const FormatException('录音需要麦克风权限，可在系统应用权限中开启');
    }
    if (!active || epoch != captureEpoch) return;
    resumeAfterRecord = widget.player.playerStatus.isPlaying;
    final owner = session;
    micSession = owner;
    try {
      await widget.player.pause();
      if (!active || epoch != captureEpoch) return;
      await owner.startRecording();
      if (!active || epoch != captureEpoch) {
        await owner.cancelRecording();
        return;
      }
      setState(() => recording = true);
      timer = Timer(const Duration(milliseconds: maxRecordingMs), () {
        if (active && recording) _run(_finish);
      });
    } catch (_) {
      micSession = null;
      await _resume();
      rethrow;
    }
  }

  Future<void> _resume() async {
    if (!resumeAfterRecord) return;
    resumeAfterRecord = false;
    if (active && widget.player.cid == session.cid &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await widget.player.play(hideControls: false);
    }
  }

  Future<void> _finish() async {
    timer?.cancel();
    setState(() => recording = false);
    final epoch = captureEpoch;
    try {
      final voice = await session.finishRecording();
      if (!active || epoch != captureEpoch) return;
      await _edit((t) => t.cues.add(CompanionCue(CompanionKind.voice, anchor,
          base64Encode(voice.bytes), length: voice.length)));
    } finally {
      micSession = null;
      await _resume();
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null || !active) return;
    final file = picked.xFile;
    if (await file.length() > maxTrackBytes) throw const FormatException('伴看轨超过 12 MB');
    final track = CompanionTrack.decode(await file.readAsString(), session.cid);
    if (!active) return;
    final key = await session.store.importTrack(track);
    if (!active) return;
    keys = await session.store.keys();
    await _select(key);
    if (active) session.setEnabled(true, position);
  }

  Future<void> _share() async {
    final track = session.track!;
    final bytes = Uint8List.fromList(utf8.encode(track.encode()));
    final name = 'PiliCat-伴看轨-${track.cid}.json';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'application/json', name: name)],
      fileNameOverrides: [name],
      text: '${track.name}\n${widget.source}\n在同一分集打开「更多设置 → 伴看轨 → 导入」。',
    ));
  }

  Future<void> _confirmRemove(CompanionCue? cue) async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(cue == null ? '移除收到的伴看轨？' : '删除这条标记？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
      ],
    ));
    if (yes != true || !active) return;
    if (cue != null) {
      await _edit((t) => t.cues.removeWhere((e) => e.id == cue.id));
    } else {
      await session.store.removeImported(session.key);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = session.track;
    final mine = session.key == 'mine';
    final locked = busy || recording;
    return Material(
      child: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(12), children: [
        Row(children: [
          const Expanded(child: Text('伴看轨', style: TextStyle(fontSize: 20))),
          IconButton(tooltip: '关闭', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('随本集播放'),
          value: session.enabled, onChanged: locked || track == null ? null :
              (v) => setState(() => session.setEnabled(v, position))),
        Row(children: [
          Expanded(child: DropdownButton<String>(isExpanded: true, value: session.key,
            items: [for (final key in keys) DropdownMenuItem(value: key,
              child: Text(key == 'mine' ? '我的伴看轨' : (names[key] ?? '收到的伴看轨 ${keys.indexOf(key)}'),
                overflow: TextOverflow.ellipsis))],
            onChanged: locked ? null : (key) { if (key != null) _run(() => _select(key)); })),
          if (!mine) IconButton(tooltip: '移除这条轨道', onPressed: locked ? null :
              () => _run(() => _confirmRemove(null)), icon: const Icon(Icons.delete_outline)),
        ]),
        Wrap(spacing: 4, children: [
          TextButton.icon(icon: const Icon(Icons.file_open), label: const Text('导入'),
            onPressed: locked ? null : () => _run(_import)),
          TextButton.icon(icon: const Icon(Icons.share), label: const Text('分享'),
            onPressed: locked || track == null || track.cues.isEmpty ? null : () => _run(_share)),
          if (mine) TextButton(onPressed: locked || track == null ? null : () => _run(() async {
            final name = await _input('分享时显示的轨道名称', 64, value: track.name);
            if (name != null && name.isNotEmpty) await _edit((t) => t.name = name);
          }), child: const Text('命名')),
        ]),
        if (mine && track != null) ...[
          Row(children: [
            Expanded(child: Text('在 ${_clock(anchor)} 添加标记')),
            TextButton(onPressed: locked ? null : () => setState(() => anchor = position),
              child: const Text('用当前进度')),
          ]),
          Wrap(spacing: 4, children: [
            FilledButton.icon(onPressed: busy ? null : () => _run(recording ? _finish : _record),
              icon: Icon(recording ? Icons.stop : Icons.mic),
              label: Text(recording ? '结束并保存' : '录语音')),
            TextButton(onPressed: locked ? null : () => _run(_text), child: const Text('写留言')),
            TextButton(onPressed: locked ? null : () => _run(_image), child: const Text('选截图')),
          ]),
          if (recording) const Text('录音中，最多 30 秒。关闭面板会取消本条录音。'),
        ],
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (busy) const LinearProgressIndicator(),
        if (track != null && track.cues.isEmpty && !busy)
          const Padding(padding: EdgeInsets.all(12), child: Text('在这个时间点留一条语音，或导入朋友分享的伴看轨。')),
        for (final cue in track?.cues ?? <CompanionCue>[])
          ListTile(contentPadding: EdgeInsets.zero,
            leading: TextButton(onPressed: locked ? null :
                () => widget.player.seekTo(Duration(milliseconds: cue.at)), child: Text(_clock(cue.at))),
            title: Text(_label(cue), maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: locked ? null : () => _preview(context, session, cue),
            trailing: mine ? IconButton(tooltip: '删除标记', icon: const Icon(Icons.delete_outline),
              onPressed: locked ? null : () => _run(() => _confirmRemove(cue))) : null),
      ])),
    );
  }
}
