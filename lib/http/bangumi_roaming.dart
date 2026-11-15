import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:dio/dio.dart';

abstract final class BangumiRoaming {
  static const _webPath = 'pgc/player/web/playurl';

  static Uri? endpoint(String address) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }
    if (uri.path.endsWith('/$_webPath') ||
        uri.path.endsWith('/pgc/player/web/v2/playurl')) {
      return uri;
    }
    final prefix = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: '$prefix/$_webPath');
  }

  static bool isRegionRestricted(int? code, String? message) {
    return code == 6002003 ||
        RegExp(r'(地区|地區|区域|區域).*(限制|不可|无法|無法|不能)|region.*restrict',
                caseSensitive: false)
            .hasMatch(message ?? '');
  }

  static Future<LoadingState<PlayUrlModel>> playUrl({
    required String address,
    required String episodeId,
    required int cid,
    required int qn,
    int? avid,
    String? bvid,
  }) async {
    final uri = endpoint(address);
    if (uri == null) return Error('番剧漫游解析地址无效');

    // Keep Bilibili account headers and cookies out of resolver requests.
    final client = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      followRedirects: false,
    ));
    try {
      final response = await client.getUri<dynamic>(uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'ep_id': episodeId,
          'cid': '$cid',
          'qn': '$qn',
          'fnval': '4048',
          'fnver': '0',
          'fourk': '1',
          'module': 'bangumi',
          if (avid != null) 'avid': '$avid',
          if (bvid != null) 'bvid': bvid,
        },
      ));
      final body = response.data;
      if (body is Map<String, dynamic> && body['code'] == 0) {
        final result = body['result'] ?? body['data'];
        if (result is Map<String, dynamic>) {
          final info = result['video_info'] ?? result;
          if (info is Map<String, dynamic>) {
            final playback = PlayUrlModel.fromJson(info);
            if (playback.dash?.video?.isNotEmpty == true ||
                playback.durl?.isNotEmpty == true) {
              return Success(playback);
            }
          }
        }
      }
      return Error('番剧漫游解析服务未返回可播放的视频');
    } on DioException {
      return Error('无法从番剧漫游解析服务获取视频，请检查地址或线路');
    } on Object {
      return Error('番剧漫游解析服务返回了不兼容的数据');
    } finally {
      client.close();
    }
  }
}
