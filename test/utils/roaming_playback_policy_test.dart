import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  const local = 'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video.m4s?sign=local';
  const overseas = 'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/video.m4s?hdnts=original';
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pilicat-playback-test-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  setUp(() async {
    await GStorage.setting.clear();
    await GStorage.setting.putAll({
      SettingBoxKey.bangumiRoamingEnabled: true,
      SettingBoxKey.bangumiUpos: CDNService.akamai.name,
      SettingBoxKey.bangumiUposForAll: false,
    });
    VideoUtils.cdnService = CDNService.baseUrl;
    VideoUtils.customCDNUrl = null;
    VideoUtils.disableAudioCDN = false;
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('ordinary videos and unrestricted bangumi keep the regular CDN', () {
    for (final isBangumi in [false, true]) {
      expect(
        VideoUtils.getCdnUrl([local, overseas], isBangumi: isBangumi),
        local,
      );
    }
  });

  test('roaming streams use the selected signed original CDN URL', () {
    expect(
      VideoUtils.getCdnUrl(
        [local, overseas],
        isBangumi: true,
        preserveStreamUrls: true,
      ),
      overseas,
    );
  });

  test('explicit UPOS-for-all option still applies to ordinary videos', () async {
    await GStorage.setting.put(SettingBoxKey.bangumiUposForAll, true);
    expect(VideoUtils.getCdnUrl([local, overseas], isBangumi: false), overseas);
  });

  test('larger default cache is restricted to roaming playback', () {
    expect(Pref.initBuffer()['demuxer-max-bytes'], '${4 * 1024 * 1024}');
    expect(Pref.initBuffer()['cache-secs'], '16.000');
    expect(Pref.initRoamingBuffer()['demuxer-max-bytes'], '${32 * 1024 * 1024}');
    expect(Pref.initRoamingBuffer()['cache-secs'], '30.000');
    expect(Pref.initRoamingBuffer().containsKey('cache-pause-wait'), isFalse);
    expect(Pref.initRoamingBuffer().containsKey('demuxer-cache-wait'), isFalse);
  });

  test('custom cache values remain authoritative for every source', () async {
    await GStorage.setting.putAll({
      SettingBoxKey.bufferSize: 8.0,
      SettingBoxKey.bufferSec: 20.0,
    });
    expect(Pref.initRoamingBuffer(), Pref.initBuffer());
    expect(Pref.initRoamingBuffer(2)['cache-secs'], '40.000');
  });

  test('setting one cache limit leaves the other roaming default intact', () async {
    await GStorage.setting.put(SettingBoxKey.bufferSize, 8.0);
    expect(Pref.initRoamingBuffer()['demuxer-max-bytes'], '${8 * 1024 * 1024}');
    expect(Pref.initRoamingBuffer()['cache-secs'], '30.000');
  });
}
