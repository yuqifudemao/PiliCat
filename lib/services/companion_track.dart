import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

enum CompanionKind { voice, image, text }

const maxTrackBytes = 12 * 1024 * 1024;
const maxAttachmentBytes = 1024 * 1024;
const maxRecordingMs = 30000;
final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$');

class CompanionCue {
  CompanionCue(this.kind, this.at, this.data, {this.length = 0, String? id})
      : id = id ?? const Uuid().v4();

  final String id;
  final CompanionKind kind;
  final int at;
  final String data;
  final int length;

  Uint8List get bytes => base64Decode(data);
  Map<String, dynamic> toJson() =>
      {'id': id, 'kind': kind.name, 'at': at, 'data': data, 'length': length};

  factory CompanionCue.fromJson(dynamic raw) {
    if (raw is! Map || raw['id'] is! String || !_uuid.hasMatch(raw['id']) ||
        raw['at'] is! int || raw['at'] < 0 || raw['at'] > 604800000 ||
        raw['data'] is! String || raw['length'] is! int) {
      throw const FormatException('伴看标记格式不正确');
    }
    final kind = CompanionKind.values.where((v) => v.name == raw['kind']).firstOrNull;
    final String data = raw['data'];
    final int length = raw['length'];
    if (kind == null || data.isEmpty ||
        (kind == CompanionKind.text && data.length > 500) ||
        (kind == CompanionKind.voice && (length < 1 || length > maxRecordingMs + 1000)) ||
        (kind != CompanionKind.voice && length != 0)) {
      throw const FormatException('伴看标记内容不正确');
    }
    if (kind != CompanionKind.text) {
      if (data.length > ((maxAttachmentBytes + 2) ~/ 3) * 4) {
        throw const FormatException('伴看附件超过 1 MB');
      }
      final bytes = base64Decode(data);
      final valid = switch (kind) {
        CompanionKind.voice => bytes.length > 12 &&
            String.fromCharCodes(bytes, 4, 8) == 'ftyp',
        CompanionKind.image => bytes.length > 8 &&
            ((bytes[0] == 0xff && bytes[1] == 0xd8) ||
                (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47)),
        _ => false,
      };
      if (!valid || bytes.length > maxAttachmentBytes) {
        throw const FormatException('附件需要是 M4A 录音或 JPG、PNG 图片');
      }
    }
    return CompanionCue(kind, raw['at'], data, length: length, id: raw['id']);
  }
}

class CompanionTrack {
  CompanionTrack(this.cid, {String? id, this.name = '我的伴看轨', List<CompanionCue>? cues})
      : id = id ?? const Uuid().v4(), cues = cues ?? [];

  final int cid;
  final String id;
  String name;
  final List<CompanionCue> cues;

  String encode() => jsonEncode({
    'format': 'PiliCat.companion', 'version': 1, 'cid': cid,
    'id': id, 'name': name, 'cues': cues.map((c) => c.toJson()).toList(),
  });

  static CompanionTrack decode(String contents, int cid) {
    if (contents.length > maxTrackBytes) throw const FormatException('伴看轨超过 12 MB');
    final raw = jsonDecode(contents);
    if (raw is! Map || raw['format'] != 'PiliCat.companion' || raw['version'] != 1 ||
        raw['cid'] is! int || raw['id'] is! String || !_uuid.hasMatch(raw['id']) ||
        raw['name'] is! String || (raw['name'] as String).trim().isEmpty ||
        raw['name'].length > 64 || raw['cues'] is! List || raw['cues'].length > 100) {
      throw const FormatException('请选择 PiliCat 导出的伴看轨文件');
    }
    if (raw['cid'] != cid) {
      throw FormatException('这条轨属于其他分集（CID ${raw['cid']}），请先打开对应分集');
    }
    final cues = (raw['cues'] as List).map(CompanionCue.fromJson).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (cues.map((c) => c.id).toSet().length != cues.length) {
      throw const FormatException('伴看轨内有重复标记');
    }
    return CompanionTrack(cid, id: raw['id'], name: raw['name'], cues: cues);
  }
}

// Store the author's editable track separately from imported, read-only tracks.
class CompanionStore {
  CompanionStore(Directory root, this.cid) : directory = Directory('${root.path}/$cid');
  final Directory directory;
  final int cid;
  static Future<void> _writes = Future.value();

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  File _file(String key) {
    if (key != 'mine' && !_uuid.hasMatch(key)) throw const FormatException('无效伴看轨');
    return File('${directory.path}/$key.json');
  }

  Future<List<String>> keys() async {
    final result = ['mine'];
    if (await directory.exists()) {
      await for (final item in directory.list(followLinks: false)) {
        final filename = item.uri.pathSegments.last;
        if (item is File && filename.endsWith('.json')) {
          final key = filename.substring(0, filename.length - 5);
          if (_uuid.hasMatch(key)) result.add(key);
        }
      }
    }
    return result;
  }

  Future<CompanionTrack> read(String key) async {
    final file = _file(key);
    if (!await file.exists() && key == 'mine') return CompanionTrack(cid);
    if (await file.length() > maxTrackBytes) throw const FormatException('伴看轨超过 12 MB');
    return CompanionTrack.decode(await file.readAsString(), cid);
  }

  Future<void> _save(String key, CompanionTrack track) async {
    if (track.cues.length > 100) throw const FormatException('每条伴看轨最多 100 个标记');
    final bytes = utf8.encode(track.encode());
    if (bytes.length > maxTrackBytes) throw const FormatException('伴看轨超过 12 MB');
    await directory.create(recursive: true);
    final file = _file(key);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<CompanionTrack> edit(void Function(CompanionTrack) change) =>
      _serialize(() async {
        final track = await read('mine');
        change(track);
        track.cues.sort((a, b) => a.at.compareTo(b.at));
        await _save('mine', track);
        return track;
      });

  Future<String> importTrack(CompanionTrack track) => _serialize(() async {
    if (track.cid != cid) throw const FormatException('分集不匹配');
    if ((await read('mine')).id == track.id) return 'mine';
    await _save(track.id, track);
    return track.id;
  });

  Future<void> removeImported(String key) => _serialize(() async {
    if (key == 'mine') throw const FormatException('请选择收到的伴看轨');
    await _file(key).delete();
  });
}

typedef Dialogue = ({int start, int end});
final _timing = RegExp(r'^(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{3})', multiLine: true);

List<Dialogue> dialogueFromVtt(String vtt) {
  int ms(RegExpMatch m, int i) => (int.tryParse(m[i] ?? '') ?? 0) * 3600000 +
      int.parse(m[i + 1]!) * 60000 + int.parse(m[i + 2]!) * 1000 + int.parse(m[i + 3]!);
  return [for (final m in _timing.allMatches(vtt)) (start: ms(m, 1), end: ms(m, 5))]
    ..sort((a, b) => a.start.compareTo(b.start));
}

// Never announce before the anchor. A crowded scene gets a tappable marker.
int? voiceStart(int anchor, int length, List<Dialogue> dialogue) {
  var start = anchor;
  for (final line in dialogue) {
    if (line.end <= start) continue;
    if (line.start >= start + length) break;
    start = line.end + 120;
    if (start - anchor > 4000) return null;
  }
  return start;
}
