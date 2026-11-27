import 'dart:async';

import 'package:flutter/services.dart';
import 'package:PiliPlus/services/ai_chat/cloud_voice.dart';
import 'package:uuid/uuid.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SystemSpeechUnavailable implements Exception {
  const SystemSpeechUnavailable();
}

class AssistantVoice {
  static final shared = AssistantVoice();
  final _speech = SpeechToText();
  final _tts = FlutterTts();
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
    final bluetooth = await Permission.bluetoothConnect.status;
    if (_owner != owner) return '';
    final ready = await _speech.initialize(
      options: [if (!bluetooth.isGranted) SpeechToText.androidNoBluetooth],
      onError: (error) {
      final turn = _turn;
      if (turn != null && !turn.isCompleted) {
        turn.completeError(error.errorMsg == 'error_permission'
            ? const SystemSpeechUnavailable() : StateError('语音识别结束（${error.errorMsg}）'));
      }
    });
    if (_owner != owner) return '';
    if (!ready) throw const SystemSpeechUnavailable();
    final turn = _turn = Completer<String>();
    try {
      unawaited(_speech.listen(localeId: 'zh_CN', onResult: (result) {
        if (result.finalResult && !turn.isCompleted) turn.complete(result.recognizedWords.trim());
      }).then<void>((_) {}, onError: (Object error) {
        if (!turn.isCompleted) turn.completeError(error);
      }));
      return await turn.future.timeout(const Duration(seconds: 60));
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
      return await cloud.transcribe(result!['audio'] as Uint8List, model);
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
    await _tts.awaitSpeakCompletion(true);
    if (_owner != owner) return;
    await _tts.setLanguage('zh-CN');
    for (final paragraph in text.split('\n')) {
      final chars = paragraph.trim().runes.toList();
      for (var i = 0; i < chars.length; i += 1500) {
        if (_owner != owner) return;
        final part = String.fromCharCodes(chars.skip(i).take(1500));
        if (await _tts.speak(part) != 1 && _owner == owner) {
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
    final stopping = Object();
    _owner = stopping;
    final turn = _turn;
    _turn = null;
    if (turn != null && !turn.isCompleted) turn.complete('');
    try {
      await Future.wait([_speech.cancel(), _tts.stop(),
        _audio.invokeMethod<void>('cancel', {'owner': id}),
        _audio.invokeMethod<void>('stop', {'owner': id}),
      ]);
    } finally {
      if (_owner == stopping) _owner = null;
    }
  }
}
