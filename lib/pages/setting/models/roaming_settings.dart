import 'package:PiliPlus/http/bangumi_roaming.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/models/video_settings.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

List<SettingsModel> get roamingSettings => [
  ...roamingResolverSettings,
  videoCdnSetting,
  cdnSpeedTestSetting,
];

List<SettingsModel> get roamingResolverSettings => [
  NormalModel(
    title: '番剧漫游（网页解析）',
    getSubtitle: () => Pref.bangumiRoamingUrl.isEmpty ? '未配置' : '已配置解析服务',
    leading: const Icon(Icons.public),
    onTap: _showBangumiRoamingDialog,
  ),
  NormalModel(
    title: '安卓解析服务器',
    getSubtitle: () => Pref.bangumiAppUrl,
    leading: const Icon(Icons.dns_outlined),
    onTap: _showBangumiAppServerDialog,
  ),
  WidgetModel(
    searchTitle: '哔哩漫游安卓解析授权',
    child: StreamBuilder(
      stream: GStorage.setting.watch(key: SettingBoxKey.bangumiAppUrl),
      builder: (context, _) {
        final address = Pref.bangumiAppUrl;
        return SetSwitchItem(
          key: ValueKey(address),
          title: '哔哩漫游安卓解析授权',
          subtitle: '开启后将播放账号访问令牌发送至 $address',
          leading: const Icon(Icons.verified_user_outlined),
          setKey: SettingBoxKey.bangumiAppAuth,
          defaultVal: false,
        );
      },
    ),
  ),
  NormalModel(
    title: '安卓解析地区',
    getSubtitle: () => Pref.bangumiAppArea == 'hk' ? '香港' : '台湾',
    leading: const Icon(Icons.public),
    onTap: (context, setState) async {
      final area = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('安卓解析地区'),
          children: [
            SimpleDialogOption(
              onPressed: () => Get.back(result: 'tw'),
              child: const Text('台湾'),
            ),
            SimpleDialogOption(
              onPressed: () => Get.back(result: 'hk'),
              child: const Text('香港'),
            ),
          ],
        ),
      );
      if (area != null) {
        await GStorage.setting.put(SettingBoxKey.bangumiAppArea, area);
        if (context.mounted) setState();
      }
    },
  ),
  NormalModel(
    title: '外番搜索服务',
    getSubtitle: () => Pref.bangumiSearchUrl.isEmpty ? '未配置' : '已配置搜索服务',
    leading: const Icon(Icons.search),
    onTap: (context, setState) =>
        _showBangumiRoamingDialog(context, setState, search: true),
  ),
];

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
                ? '仅在台、港搜索标签使用，留空关闭'
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

Future<void> _showBangumiAppServerDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final original = Pref.bangumiAppUrl;
  var address = original;
  final formKey = GlobalKey<FormState>();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('安卓解析服务器'),
      content: Form(
        key: formKey,
        child: TextFormField(
          initialValue: original,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: Pref.defaultBangumiAppUrl,
            helperText: '留空恢复默认。更换后需重新开启安卓解析授权。',
            helperMaxLines: 2,
          ),
          onChanged: (value) => address = value.trim(),
          validator: (value) =>
              address.isNotEmpty && BangumiRoaming.appEndpoint(address) == null
              ? '请输入不带查询参数的 HTTPS 地址'
              : null,
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('取消')),
        TextButton(
          onPressed: () {
            if (formKey.currentState!.validate()) {
              Get.back(
                result: address.isEmpty ? Pref.defaultBangumiAppUrl : address,
              );
            }
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (result != null && result != original) {
    await GStorage.setting.put(SettingBoxKey.bangumiAppAuth, false);
    await GStorage.setting.put(SettingBoxKey.bangumiAppUrl, result);
    if (context.mounted) setState();
  }
}
