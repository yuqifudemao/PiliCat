import 'dart:async';

import 'package:flutter/services.dart';
import 'package:PiliPlus/services/ai_chat/cloud_voice.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SystemSpeechUnavailable implements Exception {
  const SystemSpeechUnavailable([this.reason = 'unavailable']);
  final String reason;
}

class AssistantVoice {
  static final shared = AssistantVoice();
  final _speech = SpeechToText();
  FlutterTts? _tts;
  static const _audio = MethodChannel('pilicat/companion_audio');
  String _audioId = '';
  CloudVoice? _cloud;
  Completer<void>? _sendRecording;
  Object? _owner;
  Completer<String>? _turn;

  bool claim(Object owner) {
    if (_owner != null) return false;
    _audioId = const Uuid().v4();
    _owner = owner;
    return true;
  }

  Future<String> listen(Object owner) async {
    if (_owner != owner) return '';
    final turn = _turn = Completer<String>();
    Future<void> start() async {
      try {
        final ready = await _speech.initialize(
          options: [SpeechToText.androidNoBluetooth],
          // The plugin retains this callback across successful initializations.
          onError: (error) {
            final current = _turn;
            if (current == null || current.isCompleted) return;
            if (error.errorMsg == 'error_speech_timeout' || error.errorMsg == 'error_no_match') {
              current.complete('');
            } else {
              final code = error.errorMsg;
              current.completeError(SystemSpeechUnavailable(
                  RegExp(r'^error_[a-z_]+$').hasMatch(code) ? code : 'recognizer_error'));
            }
          },
        ).timeout(const Duration(seconds: 10));
        if (!identical(_turn, turn) || turn.isCompleted) return;
        if (!ready) throw const SystemSpeechUnavailable();
        await _speech.listen(
          listenOptions: SpeechListenOptions(localeId: 'zh-CN', listenMode: ListenMode.dictation),
          onResult: (result) {
            if (result.finalResult && !turn.isCompleted) {
              turn.complete(result.recognizedWords.trim());
            }
          },
        );
      } catch (error, stack) {
        // Some Android services throw at startup instead of returning false.
        if (!turn.isCompleted) {
          turn.completeError(error is SystemSpeechUnavailable ? error
              : SystemSpeechUnavailable(error.runtimeType.toString()), stack);
        }
      }
    }

    unawaited(start());
    try {
      return await turn.future.timeout(const Duration(seconds: 60),
          onTimeout: () => throw const SystemSpeechUnavailable('timeout'));
    } on SystemSpeechUnavailable {
      if (identical(_turn, turn)) {
        _turn = null;
        // Release the microphone before the user switches to the recorder.
        try {
          await _speech.cancel().timeout(const Duration(seconds: 2));
        } catch (_) {
          // The service may already have disconnected.
        }
      }
      rethrow;
    } finally {
      if (identical(_turn, turn)) _turn = null;
    }
  }

  bool get recording => _sendRecording != null;
  void sendRecording() {
    final send = _sendRecording;
    if (send != null && !send.isCompleted) send.complete();
  }

  Future<String> recordQuestion(Object owner, Map<String, String> profile, String model,
      {required void Function() onRecording, required void Function() onTranscribing}) async {
    final cloud = _cloud ??= CloudVoice(profile);
    final args = {'owner': _audioId};
    await _audio.invokeMethod<void>('record', args);
    if (_owner != owner) return '';
    final send = _sendRecording = Completer<void>();
    try {
      onRecording();
      await send.future.timeout(const Duration(seconds: 29), onTimeout: () {});
      if (_owner != owner) return '';
      _sendRecording = null;
      onTranscribing();
      final result = await _audio.invokeMapMethod<String, dynamic>('finish', args);
      if (_owner != owner) return '';
      final audio = result?['audio'];
      if (audio is! Uint8List || audio.isEmpty) {
        throw StateError('没有取得录音。请重新点麦克风，说完后再点发送。');
      }
      return await cloud.transcribe(audio, model);
    } finally {
      if (identical(_sendRecording, send)) _sendRecording = null;
      await _audio.invokeMethod<void>('cancel', args);
    }
  }

  Future<void> narrate(Object owner, Map<String, String> profile, String model,
      String voice, String text) async {
    final cloud = _cloud ??= CloudVoice(profile);
    final id = _audioId;
    for (final part in CloudVoice.passages(text)) {
      if (_owner != owner) return;
      final bytes = await cloud.synthesize(part, model, voice);
      if (_owner != owner) return;
      await _audio.invokeMethod<void>('playSpeech', {'owner': id, 'audio': bytes});
    }
  }

  Future<void> read(Object owner, String text) async {
    final tts = _tts ??= FlutterTts();
    await tts.awaitSpeakCompletion(true);
    if (_owner != owner) return;
    if (await tts.setLanguage('zh-CN') != 1) {
      throw StateError('系统朗读引擎没有可用的中文语音，可在「AI 语音设置」启用 AI 朗读。');
    }
    for (final paragraph in text.split('\n')) {
      final chars = paragraph.trim().runes.toList();
      for (var i = 0; i < chars.length; i += 1500) {
        if (_owner != owner) return;
        final part = String.fromCharCodes(chars.skip(i).take(1500));
        if (await tts.speak(part) != 1 && _owner == owner) {
          throw StateError('朗读失败，请检查系统中文语音引擎');
        }
      }
    }
  }

  Future<void> release(Object owner) async {
    if (_owner != owner) return;
    final id = _audioId;
    _cloud?.close();
    _cloud = null;
    sendRecording();
    _sendRecording = null;
    final stopping = Object();
    _owner = stopping;
    final turn = _turn;
    _turn = null;
    if (turn != null && !turn.isCompleted) turn.complete('');
    try {
      final tts = _tts;
      await Future.wait([_speech.cancel(), if (tts != null) tts.stop(),
        _audio.invokeMethod<void>('cancel', {'owner': id}),
        _audio.invokeMethod<void>('stop', {'owner': id}),
      ]).timeout(const Duration(seconds: 3));
    } finally {
      if (_owner == stopping) _owner = null;
    }
  }
}
