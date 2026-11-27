import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

class AssistantVoice {
  static final shared = AssistantVoice();
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  Object? _owner;
  Completer<String>? _turn;

  bool claim(Object owner) {
    if (_owner != null) return false;
    _owner = owner;
    return true;
  }

  Future<String> listen(Object owner) async {
    final ready = await _speech.initialize(onError: (error) {
      final turn = _turn;
      if (turn != null && !turn.isCompleted) {
        turn.completeError(StateError('语音识别结束（${error.errorMsg}）'));
      }
    });
    if (_owner != owner) return '';
    if (!ready) throw StateError('请启用系统语音识别服务，并允许使用麦克风');
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
    final stopping = Object();
    _owner = stopping;
    final turn = _turn;
    _turn = null;
    if (turn != null && !turn.isCompleted) turn.complete('');
    try {
      await Future.wait([_speech.cancel(), _tts.stop()]);
    } finally {
      if (_owner == stopping) _owner = null;
    }
  }
}
