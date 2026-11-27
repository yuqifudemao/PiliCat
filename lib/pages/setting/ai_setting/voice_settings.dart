import 'package:PiliPlus/pages/setting/ai_setting/voice_model_dialog.dart';
import 'package:PiliPlus/services/ai_chat/voice_options.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

export 'package:PiliPlus/services/ai_chat/voice_options.dart';

enum VoiceSettingsAction { saved, keyboard }

Future<VoiceSettingsAction?> showVoiceOptions(BuildContext context, {
  Map<String, String>? currentProfile,
  bool recognitionFailed = false,
}) {
  final options = VoiceOptions();
  final current = currentProfile ?? Pref.aiApiProfiles[Pref.activeAiApiProfile];
  if (recognitionFailed) options.transcription = true;
  return showDialog<VoiceSettingsAction>(context: context, builder: (context) => StatefulBuilder(
    builder: (context, update) {
      Widget modelTile(VoiceModelChoice choice, void Function(VoiceModelChoice) accept) {
        final selected = choice.profile(current, Pref.aiApiProfiles);
        final service = choice.profileId.isEmpty ? '当前视频接口' : selected?['name'] ?? '原接口已删除';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${choice.purpose.label}模型'),
          subtitle: Text('${choice.model} · $service', maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final next = await pickVoiceModel(context, choice: choice, current: current);
            if (context.mounted && next != null) update(() => accept(next));
          },
        );
      }
      return AlertDialog(
        title: Text(recognitionFailed ? '系统语音识别不可用' : 'AI 语音设置'),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(recognitionFailed
              ? '可用输入法的麦克风提问，也可选择录音转写。录音会发送到所选转写服务，费用由服务商决定。'
              : '录音会发送到转写服务，朗读文本会发送到朗读服务。两项可分别选择接口。'),
          if (!recognitionFailed) SwitchListTile(
            title: const Text('录音后用 AI 转写'), value: options.transcription,
            onChanged: (v) => update(() => options.transcription = v),
          ),
          if (options.transcription) modelTile(options.stt, (v) => options.stt = v),
          if (!recognitionFailed) SwitchListTile(
            title: const Text('使用 AI 朗读'), value: options.narration,
            onChanged: (v) => update(() => options.narration = v),
          ),
          if (!recognitionFailed && options.narration) ...[
            modelTile(options.tts, (v) => options.tts = v),
            TextFormField(key: const ValueKey('voice'), initialValue: options.voice,
              decoration: const InputDecoration(labelText: '音色'),
              onChanged: (v) => update(() => options.voice = v.trim())),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          if (recognitionFailed) TextButton(
            onPressed: () => Navigator.pop(context, VoiceSettingsAction.keyboard),
            child: const Text('用输入法提问'),
          ),
          FilledButton(onPressed: !recognitionFailed && options.narration && options.voice.isEmpty ? null : () async {
            await options.save();
            if (context.mounted) Navigator.pop(context, VoiceSettingsAction.saved);
          }, child: Text(recognitionFailed ? '开始录音转写' : '保存')),
        ],
      );
    },
  ));
}
