import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
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

  static bool hasAreaLimitPanel(Object? plugins) {
    return plugins is List &&
        plugins.any((plugin) =>
            plugin is Map &&
            plugin['name'] == 'AreaLimitPanel' &&
            plugin['config'] is Map &&
            plugin['config']['is_block'] == true);
  }

  static Dio _client() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      followRedirects: false,
    ),
  );

  static Future<LoadingState<SearchPgcData>> search({
    required String address,
    required String area,
    required String keyword,
    required String page,
  }) async {
    if (address.isEmpty) {
      return const Error('请在其它设置中配置外番搜索服务');
    }
    final playback = endpoint(address);
    if (playback == null) return const Error('外番搜索服务地址无效');

    final prefix = playback.path.replaceFirst(
      RegExp(r'/pgc/player/web/(?:v2/)?playurl$'),
      '',
    );
    final uri = playback.replace(
      path: '$prefix/x/web-interface/search/type',
      queryParameters: {
        ...playback.queryParameters,
        'search_type': 'media_bangumi',
        'keyword': keyword,
        'page': page,
        'area': area,
      },
    );
    final client = _client();
    try {
      final body = (await client.getUri<dynamic>(uri)).data;
      if (body is Map<String, dynamic> && body['code'] == 0) {
        final data = body['data'];
        if (data is Map<String, dynamic>) {
          final items = data['result'];
          return Success(SearchPgcData.fromJson({
            ...data,
            if (items is List)
              'result': items.where((item) =>
                  item is Map && item['season_id'] is int &&
                  (item['season_id'] as int) > 0).toList(),
          }));
        }
      }
      return const Error('外番搜索服务没有返回结果');
    } on DioException {
      return const Error('无法连接外番搜索服务');
    } on Object {
      return const Error('外番搜索服务返回了不兼容的数据');
    } finally {
      client.close();
    }
  }

  static Future<LoadingState<PgcInfoModel>> season({
    required String address,
    Object? seasonId,
    Object? epId,
  }) async {
    final playback = endpoint(address);
    if (playback == null) return const Error('番剧漫游解析地址无效');

    final prefix = playback.path.replaceFirst(
      RegExp(r'/pgc/player/web/(?:v2/)?playurl$'),
      '',
    );
    final uri = playback.replace(
      path: '$prefix/pgc/view/web/season',
      queryParameters: {
        ...playback.queryParameters,
        if (seasonId != null) 'season_id': '$seasonId',
        if (epId != null) 'ep_id': '$epId',
      },
    );
    final client = _client();
    try {
      final body = (await client.getUri<dynamic>(uri)).data;
      if (body is Map<String, dynamic> && body['code'] == 0) {
        final result = body['result'];
        if (result is Map<String, dynamic>) {
          final info = PgcInfoModel.fromJson(result);
          final (episode, _) = info.findEpisode();
          if (episode != null) return Success(info);
        }
      }
      return const Error('番剧漫游未返回详情，请检查线路是否支持番剧详情');
    } on DioException {
      return const Error('无法连接番剧漫游详情服务');
    } on Object {
      return const Error('番剧漫游返回了不兼容的详情数据');
    } finally {
      client.close();
    }
  }

  static Future<LoadingState<PlayUrlModel>> playUrl({
    required String address,
    required String episodeId,
    required int cid,
    required int qn,
    int? avid,
    String? bvid,
  }) async {
    final useApp = Pref.bangumiAppAuth;
    final uri = useApp
        ? Uri.parse('https://bili.nepnep.moe/pgc/player/api/playurl')
        : endpoint(address);
    if (uri == null) return const Error('番剧漫游解析地址无效');
    final accessKey = useApp ? Accounts.video.accessKey : null;
    if (useApp && (accessKey == null || accessKey.isEmpty)) {
      return const Error('播放账号缺少访问令牌，请在 PiliCat 重新登录 B 站账号');
    }

    // The opt-in token is sent only to this HTTPS endpoint, without redirects.
    final client = _client();
    try {
      final params = <String, dynamic>{
        ...uri.queryParameters,
        'ep_id': episodeId,
        'cid': '$cid',
        'qn': '$qn',
        'fnval': '4048',
        'fnver': '0',
        'fourk': '1',
        if (avid != null) 'avid': '$avid',
        if (bvid != null) 'bvid': bvid,
        if (useApp) ...{
          'area': Pref.bangumiAppArea == 'hk' ? 'hk' : 'tw',
          'access_key': accessKey!,
          'build': '2001100',
          'device': 'android',
          'mobi_app': 'android_hd',
          'platform': 'android',
          'force_host': '2',
        } else 'module': 'bangumi',
      };
      final Uri requestUri;
      if (useApp) {
        AppSign.appSign(params);
        final signature = params.remove('sign');
        // The resolver expects the signature after the signed query.
        requestUri = uri.replace(
          query: '${AppSign.makeQuery(params)}&sign=$signature',
        );
      } else {
        requestUri = uri.replace(queryParameters: params);
      }
      final response = await client.getUri<dynamic>(requestUri);
      final body = response.data;
      final mode = useApp ? '安卓解析' : '网页解析';
      if (body is! Map<String, dynamic>) {
        return Error('$mode返回了非 JSON 对象');
      }
      final code = int.tryParse(body['code']?.toString() ?? '');
      if (code == 0) {
        final result = body['result'] ?? body['data'] ?? body;
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
        return Error('$mode返回成功，但没有视频流（状态码 0）');
      }
      if (code == -101) {
        return const Error('漫游服务未接受账号令牌，请在 PiliCat 重新登录后重试');
      }
      if (code == -3) {
        return const Error('漫游服务拒绝了安卓接口签名');
      }
      final message = body['message'];
      if (code == -10403 ||
          isRegionRestricted(code, message is String ? message : null)) {
        return const Error('当前漫游线路也受地区限制，无法播放这一集');
      }
      // Display only the numeric status. Server text can contain request data.
      return Error(code == null
          ? '$mode响应缺少有效状态码'
          : '$mode服务拒绝了播放请求（状态码 $code）');
    } on DioException {
      return Error('无法从番剧漫游解析服务获取视频，请检查地址或线路');
    } on Object {
      return Error('番剧漫游解析服务返回了不兼容的数据');
    } finally {
      client.close();
    }
  }
}
