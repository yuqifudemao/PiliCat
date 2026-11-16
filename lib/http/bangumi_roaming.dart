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
  static const _appPath = '/pgc/player/api/playurl';
  static const _intlPath = '/intl/gateway/v2/ogv/playurl';

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
    var prefix = uri.path.replaceFirst(RegExp(r'/+$'), '');
    for (final suffix in [_appPath, _intlPath]) {
      if (prefix.endsWith(suffix)) {
        prefix = prefix.substring(0, prefix.length - suffix.length);
        break;
      }
    }
    return uri.replace(path: '$prefix/$_webPath');
  }

  static Uri? appEndpoint(String address, {String area = 'tw'}) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      return null;
    }
    final path = area == 'th' ? _intlPath : _appPath;
    final prefix = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: prefix.endsWith(path) ? prefix : '$prefix$path');
  }

  static Iterable<MapEntry<String, String>> get regionalServers sync* {
    final servers = Pref.bangumiRegionServers;
    for (final area in {Pref.bangumiAppArea, 'tw', 'hk', 'th', 'cn'}) {
      if (servers[area] case final String address) {
        yield MapEntry(area, address);
      }
    }
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
      return const Error('请在设置 → 哔哩漫游中配置该地区的解析服务器');
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
    String? area,
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
        if (area != null) 'area': area,
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
    LoadingState<PlayUrlModel>? failure;
    for (final MapEntry(key: area, value: server) in regionalServers) {
      if (!Pref.bangumiRoamingEnabled) break;
      final authorized = Pref.bangumiAppAuth &&
          Pref.bangumiRegionServers[area] == server;
      final result = await _playUrl(
        address: server,
        area: area,
        useApp: authorized,
        episodeId: episodeId,
        cid: cid,
        qn: qn,
        avid: avid,
        bvid: bvid,
      );
      if (result.isSuccess) return result;
      failure ??= result;
    }
    if (address.isEmpty || !Pref.bangumiRoamingEnabled) {
      return failure ?? const Error('请配置番剧漫游解析服务器');
    }
    return _playUrl(
      address: address,
      episodeId: episodeId,
      cid: cid,
      qn: qn,
      avid: avid,
      bvid: bvid,
    );
  }

  static Future<LoadingState<PlayUrlModel>> _playUrl({
    required String address,
    required String episodeId,
    required int cid,
    required int qn,
    String? area,
    bool useApp = false,
    int? avid,
    String? bvid,
  }) async {
    final uri = useApp ? appEndpoint(address, area: area!) : endpoint(address);
    if (uri == null) return const Error('番剧漫游解析地址无效');
    final accessKey = useApp ? Accounts.video.accessKey : null;
    if (useApp && (accessKey == null || accessKey.isEmpty)) {
      return const Error('播放账号缺少访问令牌，请在 PiliCat 重新登录 B 站账号');
    }

    // Send the token only to the configured HTTPS endpoint, without redirects.
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
        if (area != null) 'area': area,
        if (useApp) ...{
          'access_key': accessKey!,
          'build': area == 'th' ? '1001310' : '2001100',
          'device': 'android',
          'mobi_app': area == 'th' ? 'bstar_a' : 'android_hd',
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
        final result = body['result'];
        final data = body['data'];
        for (final envelope in [body, result, data]) {
          if (envelope is! Map<String, dynamic>) continue;
          for (final info in [envelope, envelope['video_info']]) {
            if (info is! Map<String, dynamic>) continue;
            if (area == 'th') {
              final international = _internationalVideo(info);
              if (international != null) return Success(international);
            }
            final dash = info['dash'];
            final video = dash is Map<String, dynamic> ? dash['video'] : null;
            final durl = info['durl'];
            if ((video is List && video.isNotEmpty) ||
                (durl is List && durl.isNotEmpty)) {
              return Success(PlayUrlModel.fromJson(info));
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
  static PlayUrlModel? _internationalVideo(Map<String, dynamic> info) {
    final streams = info['stream_list'];
    if (streams is! List) return null;
    final videos = <Map<String, dynamic>>[];
    final formats = <Map<String, dynamic>>[];
    for (final stream in streams) {
      if (stream is! Map<String, dynamic>) continue;
      final video = stream['dash_video'];
      final format = stream['stream_info'];
      if (video is! Map<String, dynamic> || format is! Map<String, dynamic>) {
        continue;
      }
      final quality = format['quality'];
      final url = video['base_url'];
      if (quality is! int || url is! String || url.isEmpty) continue;
      videos.add({...video, 'id': quality});
      formats.add(format);
    }
    if (videos.isEmpty) return null;
    return PlayUrlModel.fromJson({
      ...info,
      'accept_quality': formats.map((format) => format['quality']).toSet().toList(),
      'support_formats': formats,
      'dash': {
        'video': videos,
        'audio': info['dash_audio'],
      },
    });
  }

}
