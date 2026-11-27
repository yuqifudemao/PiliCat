import 'package:PiliPlus/utils/storage.dart';
import 'package:material_ui/material_ui.dart';

class VoiceOptions {
  VoiceOptions() {
    final raw = GStorage.setting.get('aiVoiceOptions');
    if (raw is Map) {
      transcription = raw['transcription'] == true;
      narration = raw['narration'] == true;
      stt = raw['stt'] as String? ?? stt;
      tts = raw['tts'] as String? ?? tts;
      voice = raw['voice'] as String? ?? voice;
    }
  }
  bool transcription = false;
  bool narration = false;
  String stt = 'whisper-1';
  String tts = 'gpt-4o-mini-tts';
  String voice = 'coral';
  Future<void> save() => GStorage.setting.put('aiVoiceOptions', {
    'transcription': transcription, 'narration': narration,
    'stt': stt, 'tts': tts, 'voice': voice,
  });
}

enum VoiceSettingsAction { saved, keyboard }

Future<VoiceSettingsAction?> showVoiceOptions(BuildContext context, {bool recognitionFailed = false}) {
  final options = VoiceOptions();
  if (recognitionFailed) options.transcription = true;
  return showDialog<VoiceSettingsAction>(context: context, builder: (context) => StatefulBuilder(
    builder: (context, update) => AlertDialog(
      title: Text(recognitionFailed ? '系统语音识别不可用' : 'AI 语音设置'),
      scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(recognitionFailed
            ? '可以用输入法的麦克风提问。也可以选择录音转写，把录音发送到当前 AI 接口。转写需要服务商支持，可能产生费用。'
            : '启用后，录音或朗读文本会发送到当前对话所选的 API 服务。请确认服务支持相应语音模型，费用由服务商决定。'),
        if (!recognitionFailed) SwitchListTile(title: const Text('录音后用 AI 转写'), value: options.transcription,
          onChanged: (v) => update(() => options.transcription = v)),
        if (options.transcription) TextFormField(key: const ValueKey('stt'), initialValue: options.stt,
          decoration: const InputDecoration(labelText: '转写模型'), onChanged: (v) => update(() => options.stt = v.trim())),
        if (!recognitionFailed) SwitchListTile(title: const Text('使用 AI 朗读'), value: options.narration,
          onChanged: (v) => update(() => options.narration = v)),
        if (!recognitionFailed && options.narration) ...[
          TextFormField(key: const ValueKey('tts'), initialValue: options.tts,
            decoration: const InputDecoration(labelText: '朗读模型'), onChanged: (v) => update(() => options.tts = v.trim())),
          TextFormField(key: const ValueKey('voice'), initialValue: options.voice,
            decoration: const InputDecoration(labelText: '音色'), onChanged: (v) => update(() => options.voice = v.trim())),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (recognitionFailed) TextButton(
          onPressed: () => Navigator.pop(context, VoiceSettingsAction.keyboard),
          child: const Text('用输入法提问'),
        ),
        FilledButton(onPressed: (options.transcription && options.stt.isEmpty) ||
            (!recognitionFailed && options.narration && (options.tts.isEmpty || options.voice.isEmpty)) ? null : () async {
          await options.save();
          if (context.mounted) Navigator.pop(context, VoiceSettingsAction.saved);
        }, child: Text(recognitionFailed ? '开始录音转写' : '保存')),
      ],
    ),
  ));
}
