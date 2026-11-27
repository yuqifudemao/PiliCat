import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Sends audio requests to the OpenAI-compatible service chosen for the operation.
class CloudVoice {
  static bool validBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty &&
        !uri.hasQuery && !uri.hasFragment;
  }

  static String _baseUrl(Map<String, String> profile) {
    final base = (profile['url'] ?? '').trim().replaceFirst(RegExp(r'/+$'), '');
    if (!validBaseUrl(base)) {
      throw const FormatException('请在「语音模型」中选择有效的 HTTPS 接口基础地址');
    }
    return base;
  }

  CloudVoice(Map<String, String> profile, {HttpClientAdapter? adapter})
      : _client = Dio(BaseOptions(
          baseUrl: _baseUrl(profile),
          headers: {if ((profile['key'] ?? '').isNotEmpty) 'Authorization': 'Bearer ${profile['key']}'},
          followRedirects: false,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        )) {
    if (adapter != null) _client.httpClientAdapter = adapter;
  }

  final Dio _client;
  final token = CancelToken();
  void close() {
    token.cancel();
    _client.close(force: true);
  }

  Future<String> transcribe(Uint8List bytes, String model) async {
    final res = await _client.post<dynamic>('/audio/transcriptions',
      cancelToken: token,
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: 'question.m4a'),
        'model': model, 'language': 'zh',
      }),
    );
    final data = res.data;
    final text = data is Map ? data['text'] : null;
    if (text is! String || text.trim().isEmpty) throw const FormatException('语音接口没有识别出文字');
    return text.trim();
  }

  Future<Uint8List> synthesize(String text, String model, String voice) async {
    final res = await _client.post<List<int>>('/audio/speech',
      cancelToken: token,
      options: Options(responseType: ResponseType.bytes),
      data: {
        'input': text, 'model': model, 'voice': voice, 'response_format': 'mp3',
        if (model.startsWith('gpt-4o-mini-tts'))
          'instructions': '请像朋友讲解视频一样，用自然的普通话朗读。疑问句略微上扬，重点适当强调，段落之间稍作停顿。',
      },
    );
    final bytes = res.data;
    if (bytes == null || bytes.isEmpty || res.headers.value('content-type')?.contains('json') == true) {
      throw const FormatException('朗读接口没有返回音频，请检查模型和音色名称');
    }
    return Uint8List.fromList(bytes);
  }

  static Iterable<String> passages(String text) sync* {
    final clean = text.replaceAll(RegExp(r'\[\d{1,2}:\d{2}(?::\d{2})?\]'), '')
        .replaceAll(RegExp(r'[*#`]+'), '').trim();
    final part = StringBuffer();
    var length = 0;
    for (final char in clean.runes) {
      part.writeCharCode(char);
      length++;
      if (length >= 650 || (length >= 160 && '。！？；\n'.runes.contains(char))) {
        yield part.toString();
        part.clear();
        length = 0;
      }
    }
    if (part.isNotEmpty) yield part.toString();
  }
}
