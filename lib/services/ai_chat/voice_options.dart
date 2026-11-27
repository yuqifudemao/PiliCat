import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

enum VoicePurpose {
  transcription('转写', 'whisper-1', '/audio/transcriptions'),
  narration('朗读', 'gpt-4o-mini-tts', '/audio/speech');

  const VoicePurpose(this.label, this.defaultModel, this.path);
  final String label;
  final String defaultModel;
  final String path;
}

class VoiceModelChoice {
  VoiceModelChoice(this.purpose, this.profileId, this._models);

  factory VoiceModelChoice.restore(VoicePurpose purpose, dynamic saved, dynamic legacy) {
    final models = <String, String>{};
    if (legacy is String && legacy.trim().isNotEmpty) models[''] = legacy.trim();
    if (saved is Map && saved['models'] is Map) {
      for (final entry in (saved['models'] as Map).entries) {
        if (entry.key is String && entry.value is String && entry.value.trim().isNotEmpty) {
          models[entry.key as String] = (entry.value as String).trim();
        }
      }
    }
    final id = saved is Map ? saved['profileId'] : null;
    return VoiceModelChoice(purpose, id is String ? id : '', models);
  }

  final VoicePurpose purpose;
  String profileId; // The empty ID follows the API selected for this video.
  final Map<String, String> _models;
  String get model => _models[profileId] ?? purpose.defaultModel;
  set model(String value) => _models[profileId] = value.trim();
  String get followModel => _models[''] ?? purpose.defaultModel;
  VoiceModelChoice copy() => VoiceModelChoice(purpose, profileId, Map.of(_models));
  Map<String, dynamic> toMap() => {'profileId': profileId, 'models': Map.of(_models)};

  Map<String, String>? profile(Map<String, String> current, List<Map<String, String>> saved) {
    if (profileId.isEmpty) return current;
    for (final item in saved) {
      if (item['id'] == profileId) return item;
    }
    return null;
  }

  Map<String, String> resolve(Map<String, String> current) {
    final selected = profile(current, Pref.aiApiProfiles);
    if (selected == null) {
      throw StateError('原来的${purpose.label}接口已删除，请在「语音模型」中重新选择。');
    }
    return selected;
  }
}

class VoiceOptions {
  VoiceOptions() {
    final stored = GStorage.setting.get('aiVoiceOptions');
    final raw = stored is Map ? stored : const {};
    transcription = raw['transcription'] == true;
    narration = raw['narration'] == true;
    final savedVoice = raw['voice'];
    voice = savedVoice is String && savedVoice.trim().isNotEmpty ? savedVoice : 'coral';
    stt = VoiceModelChoice.restore(VoicePurpose.transcription, raw['sttChoice'], raw['stt']);
    tts = VoiceModelChoice.restore(VoicePurpose.narration, raw['ttsChoice'], raw['tts']);
  }

  late bool transcription;
  late bool narration;
  late String voice;
  late VoiceModelChoice stt;
  late VoiceModelChoice tts;
  Future<void> save() => GStorage.setting.put('aiVoiceOptions', {
    'transcription': transcription, 'narration': narration, 'voice': voice,
    'stt': stt.followModel, 'tts': tts.followModel,
    'sttChoice': stt.toMap(), 'ttsChoice': tts.toMap(),
  });
}
