import 'package:PiliPlus/http/bangumi_roaming.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/pages/playback_diagnostics.dart';
import 'package:PiliPlus/pages/setting/widgets/cdn_select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

List<SettingsModel> get roamingSettings => [
  SwitchModel(
    title: '解锁番剧限制',
    subtitle: '在番剧受地区限制时使用已配置的解析服务器',
    leading: const Icon(Icons.lock_open_outlined),
    setKey: SettingBoxKey.bangumiRoamingEnabled,
    defaultVal: Pref.bangumiRoamingEnabled,
  ),
  NormalModel(
    title: '设置解析服务器',
    subtitle: '分别设置中国大陆、香港、台湾和泰国/东南亚服务器',
    leading: const Icon(Icons.dns_outlined),
    onTap: _showRegionServers,
  ),
  NormalModel(
    title: 'UPOS 服务器设置',
    getSubtitle: () => Pref.bangumiUpos?.desc ?? '跟随音视频设置',
    leading: const Icon(Icons.cloud_outlined),
    onTap: (context, setState) => _showUpos(context, setState, speedTest: false),
  ),
  NormalModel(
    title: 'UPOS 服务器测速',
    subtitle: '测试并选择 UPOS 节点',
    leading: const Icon(Icons.speed),
    onTap: (context, setState) => _showUpos(context, setState, speedTest: true),
  ),
  const SwitchModel(
    title: '应用 UPOS 服务器到所有视频',
    subtitle: '同时应用于普通视频、番剧和电影',
    leading: Icon(Icons.video_settings_outlined),
    setKey: SettingBoxKey.bangumiUposForAll,
  ),
  WidgetModel(
    searchTitle: '哔哩漫游高级设置',
    child: ExpansionTile(
      leading: const Icon(Icons.settings_outlined),
      title: const Text('高级设置'),
      children: _roamingAdvancedSettings.map((item) => item.widget).toList(),
    ),
  ),
];

List<SettingsModel> get _roamingAdvancedSettings => [
  WidgetModel(
    searchTitle: '哔哩漫游安卓解析授权',
    child: StreamBuilder(
      stream: GStorage.setting.watch(key: SettingBoxKey.bangumiRegionServers),
      builder: (context, _) {
        final servers = Pref.bangumiRegionServers.values.toSet().join('、');
        return SetSwitchItem(
          key: ValueKey(servers),
          title: '哔哩漫游安卓解析授权',
          subtitle: servers.isEmpty
              ? '请先设置解析服务器'
              : '开启后将播放账号访问令牌发送至配置的服务器：$servers',
          leading: const Icon(Icons.verified_user_outlined),
          setKey: SettingBoxKey.bangumiAppAuth,
        );
      },
    ),
  ),
  NormalModel(
    title: '播放诊断日志',
    subtitle: '查看、复制或清空最近的播放记录',
    leading: const Icon(Icons.receipt_long_outlined),
    onTap: (context, setState) => Get.to(() => const PlaybackDiagnosticsPage()),
  ),
  NormalModel(
    title: '番剧漫游（网页解析）',
    getSubtitle: () => Pref.bangumiRoamingUrl.isEmpty ? '未配置' : '已配置解析服务',
    leading: const Icon(Icons.public),
    onTap: _showBangumiRoamingDialog,
  ),
  NormalModel(
    title: '外番搜索服务',
    getSubtitle: () =>
        Pref.bangumiSearchUrl.isEmpty ? '跟随地区服务器' : '已配置搜索服务',
    leading: const Icon(Icons.search),
    onTap: (context, setState) =>
        _showBangumiRoamingDialog(context, setState, search: true),
  ),
];

Future<void> _showUpos(
  BuildContext context,
  VoidCallback setState, {
  required bool speedTest,
}) async {
  final result = await showDialog<CdnSelectResult>(
    context: context,
    builder: (context) => CdnSelectDialog(uposOnly: true, speedTest: speedTest),
  );
  if (result case CdnBuiltinResult(:final service)) {
    await GStorage.setting.put(SettingBoxKey.bangumiUpos, service.name);
  } else if (result is CdnClearCustomResult) {
    await GStorage.setting.delete(SettingBoxKey.bangumiUpos);
  }
  if (result != null && context.mounted) setState();
}

String _serverAddress(String value) {
  final address = value.trim();
  return address.isEmpty || address.contains('://')
      ? address
      : 'https://$address';
}

Future<void> _showRegionServers(
  BuildContext context,
  VoidCallback setState,
) async {
  final original = Pref.bangumiRegionServers;
  final values = Map<String, String>.of(original);
  final formKey = GlobalKey<FormState>();
  final result = await showDialog<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('设置解析服务器'),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final MapEntry(key: area, value: label) in Pref.bangumiRegions.entries)
                TextFormField(
                  initialValue: values[area],
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: label),
                  onChanged: (value) => values[area] = _serverAddress(value),
                  validator: (value) {
                    final address = values[area] ?? '';
                    if (address.isNotEmpty &&
                        BangumiRoaming.appEndpoint(address, area: area) == null) {
                      return '请输入有效的 HTTPS 解析地址';
                    }
                    return null;
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('取消')),
        TextButton(
          onPressed: () => launchUrl(
            Uri.parse('https://github.com/yujincheng08/BiliRoaming/wiki/公共解析服务器'),
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('获取公共解析服务器'),
        ),
        TextButton(
          onPressed: () {
            if (formKey.currentState!.validate()) {
              values.removeWhere((area, address) => address.isEmpty);
              Get.back(result: values);
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (result == null ||
      Pref.bangumiRegions.keys.every((area) => original[area] == result[area])) {
    return;
  }
  await GStorage.setting.put(SettingBoxKey.bangumiAppAuth, false);
  await GStorage.setting.put(SettingBoxKey.bangumiRegionServers, result);
  if (context.mounted) setState();
}

Future<void> _showBangumiRoamingDialog(
  BuildContext context,
  VoidCallback setState, {
  bool search = false,
}) async {
  var address = search ? Pref.bangumiSearchUrl : Pref.bangumiRoamingUrl;
  final formKey = GlobalKey<FormState>();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(search ? '外番搜索服务地址' : '番剧漫游解析地址'),
      content: Form(
        key: formKey,
        child: TextFormField(
          initialValue: address,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: 'https://example.com',
            helperText: search
                ? '供地区搜索标签使用，留空时跟随地区服务器'
                : '仅在番剧详情或播放需要漫游时使用，留空关闭',
            helperMaxLines: 2,
          ),
          onChanged: (value) => address = value.trim(),
          validator: (value) {
            if (address.isNotEmpty && BangumiRoaming.endpoint(address) == null) {
              return '请输入有效的 HTTPS 解析地址';
            }
            return null;
          },
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('取消')),
        TextButton(
          onPressed: () {
            if (formKey.currentState!.validate()) Get.back(result: address);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (result != null) {
    await GStorage.setting.put(
      search ? SettingBoxKey.bangumiSearchUrl : SettingBoxKey.bangumiRoamingUrl,
      result,
    );
    if (context.mounted) setState();
  }
}
