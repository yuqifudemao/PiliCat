import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/utils/ai_caption_text.dart';
import 'package:dio/dio.dart';

enum VideoMaterialSource {
  captions('视频字幕'),
  transcript('B 站语音转写'),
  outline('B 站摘要与提纲'),
  frames('画面字幕（抽样识别）'),
  playingFrames('当前片段画面字幕（约 30 秒）'),
  description('仅标题与简介');

  const VideoMaterialSource(this.label);
  final String label;
}

enum MissingCaptionChoice { frames, description }

typedef ChooseCaptionSource = Future<MissingCaptionChoice?> Function(
  bool canReadFrames,
  bool hasDescription,
  CancelToken token,
);

class VideoMaterial {
  const VideoMaterial(this.source, this.text);
  final VideoMaterialSource source;
  final String text;

  static Future<VideoMaterial?> resolve({
    required List<Subtitle> available,
    required Future<List<Subtitle>> Function() refresh,
    required Future<List?> Function(String url) read,
    required CancelToken token,
    Future<AiConclusionResult?> Function()? conclusion,
  }) async {
    final tried = <String>{};
    Future<VideoMaterial?> tryTracks(List<Subtitle> tracks) async {
      for (final track in tracks) {
        if (token.isCancelled) return null;
        final url = subtitleHttpUrl(track.subtitleUrl);
        if (url == null || !tried.add(url)) continue;
        try {
          final body = await read(url);
          if (token.isCancelled) return null;
          final text = captionText(body ?? const []);
          if (text.isNotEmpty) return VideoMaterial(VideoMaterialSource.captions, text);
        } on Exception {
          if (token.isCancelled) return null;
        }
      }
      return null;
    }

    var result = await tryTracks(available);
    if (result != null || token.isCancelled) return result;
    try {
      result = await tryTracks(await refresh());
    } on Exception {
      if (token.isCancelled) return null;
    }
    if (result != null || token.isCancelled || conclusion == null) return result;
    try {
      final official = await conclusion();
      if (token.isCancelled || official == null) return null;
      if (official.transcript.isNotEmpty) {
        return VideoMaterial(VideoMaterialSource.transcript, official.transcript);
      }
      final parts = <String>[];
      void add(String? text, [num? time]) {
        if (text != null && text.trim().isNotEmpty) {
          parts.add(timedCaption(text.trim(), time));
        }
      }
      add(official.summary);
      for (final section in official.outline ?? const []) {
        add(section.title);
        for (final cue in section.partOutline ?? const []) {
          add(cue.content, cue.timestamp);
        }
      }
      return parts.isEmpty ? null : VideoMaterial(VideoMaterialSource.outline, parts.join('\n'));
    } on Exception {
      return null;
    }
  }

  String forModel(String info) => [
    if (info.isNotEmpty && source != VideoMaterialSource.description) info.trim(),
    '本集资料来源：${source.label}',
    text,
  ].join('\n');
}
