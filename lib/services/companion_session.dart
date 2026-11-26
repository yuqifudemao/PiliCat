import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/companion_track.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:uuid/uuid.dart';

class CompanionSession extends ChangeNotifier {
  CompanionSession(this.cid)
      : store = CompanionStore(Directory('$appSupportDirPath/companion'), cid);

  static const audio = MethodChannel('pilicat/companion_audio');
  final owner = const Uuid().v4();
  final int cid;
  final CompanionStore store;
  final notice = ValueNotifier<CompanionCue?>(null);
  CompanionTrack? track;
  String key = 'mine';
  bool enabled = false;
  bool closed = false;
  List<Dialogue> dialogue = [];
  int? _previous;
  int? _seek;
  int _audioGeneration = 0;
  bool _speaking = false;
  double _rate = 1;
  List<({CompanionCue cue, int at, bool automatic})> _events = [];
  Timer? _clear;

  void select(String newKey, CompanionTrack value, int position) {
    if (closed) return;
    interrupt();
    key = newKey;
    track = value;
    _schedule();
    _previous = position - 1;
    notifyListeners();
  }

  void setEnabled(bool value, int position) {
    interrupt();
    enabled = value;
    _previous = position - 1;
    notifyListeners();
  }

  void setDialogue(List<Dialogue> value) {
    if (closed) return;
    dialogue = value;
    _schedule();
  }

  void _schedule() {
    _events = (track?.cues ?? <CompanionCue>[]).map((cue) {
      final start = cue.kind == CompanionKind.voice
          ? voiceStart(cue.at, (cue.length * _rate).ceil(), dialogue)
          : null;
      return (cue: cue, at: start ?? cue.at, automatic: start != null);
    }).toList()..sort((a, b) => a.at.compareTo(b.at));
  }

  void tick(int ms, int seek, double rate) {
    if (closed || !enabled || _events.isEmpty) return;
    if (_rate != rate) {
      _rate = rate;
      _schedule();
    }
    var previous = _previous ?? (ms < 1000 ? -1 : ms - 1);
    if ((_seek != null && _seek != seek) || ms < previous || ms - previous > 2000) {
      interrupt();
      previous = ms - 250;
    }
    _seek = seek;
    _previous = ms;
    for (final event in _events) {
      if (event.at > ms) break;
      if (event.at <= previous) continue;
      if (event.automatic && !_speaking) {
        unawaited(playVoice(event.cue));
      } else {
        showMarker(event.cue);
      }
    }
  }

  void showMarker(CompanionCue cue) {
    if (closed) return;
    notice.value = cue;
    _clear?.cancel();
    _clear = Timer(const Duration(seconds: 7), () => notice.value = null);
  }

  Future<void> playVoice(CompanionCue cue) async {
    if (closed) return;
    final generation = ++_audioGeneration;
    _speaking = true;
    try {
      await audio.invokeMethod<void>('play', {'owner': owner, 'audio': cue.bytes});
    } catch (_) {
      if (!closed && generation == _audioGeneration) {
        showMarker(cue);
        SmartDialog.showToast('伴看语音播放失败，可在伴看轨中重试');
      }
    } finally {
      if (generation == _audioGeneration) _speaking = false;
    }
  }

  Future<void> startRecording() => audio.invokeMethod<void>('record', {'owner': owner});
  Future<({Uint8List bytes, int length})> finishRecording() async {
    final result = await audio.invokeMapMethod<String, dynamic>('finish', {'owner': owner});
    return (bytes: result!['audio'] as Uint8List, length: result['duration'] as int);
  }
  Future<void> cancelRecording() => audio.invokeMethod<void>('cancel', {'owner': owner});

  void interrupt() {
    _clear?.cancel();
    notice.value = null;
    _previous = null;
    if (_speaking) {
      _speaking = false;
      ++_audioGeneration;
      unawaited(audio.invokeMethod<void>('stop', {'owner': owner}).catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    if (closed) return;
    closed = true;
    interrupt();
    unawaited(cancelRecording().catchError((Object _) {}));
    notice.dispose();
    super.dispose();
  }
}
