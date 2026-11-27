import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/services/ai_chat/cloud_voice.dart';
import 'package:PiliPlus/services/ai_chat/voice_options.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

Future<VoiceModelChoice?> pickVoiceModel(BuildContext context, {
  required VoiceModelChoice choice,
  required Map<String, String> current,
  bool notFound = false,
  Future<List<String>> Function({Map<String, String>? profile}) loadModels = AiChatService.fetchModels,
}) => showDialog<VoiceModelChoice>(context: context, builder: (_) =>
    _VoiceModelDialog(choice: choice, current: current, notFound: notFound, loadModels: loadModels));

class _VoiceModelDialog extends StatefulWidget {
  const _VoiceModelDialog({required this.choice, required this.current, required this.notFound, required this.loadModels});
  final VoiceModelChoice choice;
  final Map<String, String> current;
  final bool notFound;
  final Future<List<String>> Function({Map<String, String>? profile}) loadModels;

  @override
  State<_VoiceModelDialog> createState() => _VoiceModelDialogState();
}

class _VoiceModelDialogState extends State<_VoiceModelDialog> {
  late final draft = widget.choice.copy();
  late final model = TextEditingController(text: draft.model);
  List<Map<String, String>> profiles = Pref.aiApiProfiles;
  List<String> models = [];
  bool loading = false;
  int request = 0;
  String? notice;

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  void select(String id) {
    setState(() {
      draft.profileId = id;
      model.text = draft.model;
      request++;
      loading = false;
      models = [];
      notice = null;
    });
  }

  Future<void> fetchModels(Map<String, String> profile) async {
    final id = ++request;
    setState(() { loading = true; notice = null; });
    try {
      final result = await widget.loadModels(profile: profile);
      if (!mounted || request != id) return;
      setState(() {
        models = result.map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
        if (models.isEmpty) notice = '服务没有列出模型，可手动填写模型 ID。';
      });
    } catch (_) {
      if (!mounted || request != id) return;
      setState(() { models = []; notice = '未能获取模型列表，可手动填写服务商提供的模型 ID。'; });
    } finally {
      if (mounted && request == id) setState(() => loading = false);
    }
  }

  Future<void> addProfile() async {
    final profile = await showDialog<Map<String, String>>(context: context,
        builder: (_) => const _NewVoiceApiDialog());
    if (!mounted || profile == null) return;
    try {
      final all = [...Pref.aiApiProfiles, profile];
      await Pref.saveAiApiProfiles(all, Pref.activeAiApiProfile);
      if (!mounted) return;
      profiles = all;
      select(profile['id']!);
    } catch (_) {
      if (mounted) setState(() => notice = '接口配置保存失败，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = draft.profile(widget.current, profiles);
    final valid = CloudVoice.validBaseUrl(profile?['url'] ?? '');
    final purpose = draft.purpose;
    return AlertDialog(
      title: Text('${purpose.label}模型'),
      scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.notFound) Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('此${purpose.label}请求返回 HTTP 404。请核对接口基础地址和模型 ID。'),
        ),
        InputDecorator(
          decoration: const InputDecoration(labelText: 'API 接口'),
          child: DropdownButtonHideUnderline(child: DropdownButton<String>(
            isExpanded: true, isDense: true,
            value: profile == null ? null : draft.profileId,
            hint: const Text('原接口已删除，请重新选择'),
            items: [
              const DropdownMenuItem(value: '', child: Text('跟随当前视频的接口')),
              for (final p in profiles.where((p) => (p['url'] ?? '').isNotEmpty))
                DropdownMenuItem(value: p['id'], child: Text(p['name'] ?? 'API 配置', overflow: TextOverflow.ellipsis)),
              if (profile != null && draft.profileId.isNotEmpty && (profile['url'] ?? '').isEmpty)
                DropdownMenuItem(value: draft.profileId, child: Text(profile['name'] ?? '未配置地址')),
            ],
            onChanged: (v) { if (v != null) select(v); },
          )),
        ),
        Align(alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(onPressed: addProfile, icon: const Icon(Icons.add), label: const Text('新增接口'))),
        TextField(
          controller: model, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: '模型 ID'),
          onChanged: (v) => setState(() => draft.model = v),
        ),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton(
          onPressed: valid && profile != null && !loading ? () => fetchModels(profile) : null,
          child: Text(loading ? '正在获取模型…' : '获取模型列表'),
        )),
        if (models.isNotEmpty) DropdownButton<String>(
          isExpanded: true, menuMaxHeight: 320,
          hint: const Text('从列表选择模型'), value: models.contains(draft.model) ? draft.model : null,
          items: [for (final s in models) DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))],
          onChanged: (v) { if (v != null) setState(() { draft.model = v; model.text = v; }); },
        ),
        if (notice != null) Text(notice!),
        Text(valid ? '服务需支持 POST ${purpose.path} 及所选模型。' : '请选择或新增一个有效的 HTTPS 接口。'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: valid && draft.model.isNotEmpty ? () => Navigator.pop(context, draft) : null,
            child: const Text('使用此模型')),
      ],
    );
  }
}

class _NewVoiceApiDialog extends StatefulWidget {
  const _NewVoiceApiDialog();
  @override
  State<_NewVoiceApiDialog> createState() => _NewVoiceApiDialogState();
}

class _NewVoiceApiDialogState extends State<_NewVoiceApiDialog> {
  String name = '', url = '', apiKey = '';
  bool obscure = true;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新增 API 接口'),
    scrollable: true,
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(decoration: const InputDecoration(labelText: '配置名称'),
          onChanged: (v) => setState(() => name = v.trim())),
      TextField(keyboardType: TextInputType.url, autocorrect: false,
          decoration: const InputDecoration(labelText: '接口基础地址', hintText: 'https://api.example.com/v1',
              helperText: '填到服务商指定的版本路径。'),
          onChanged: (v) => setState(() => url = v.trim())),
      TextField(obscureText: obscure, autocorrect: false, enableSuggestions: false,
          decoration: InputDecoration(labelText: 'API Key', suffixIcon: IconButton(
              tooltip: obscure ? '显示密钥' : '隐藏密钥',
              icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => obscure = !obscure))),
          onChanged: (v) => apiKey = v.trim()),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: name.isEmpty || !CloudVoice.validBaseUrl(url) ? null :
          () => Navigator.pop(context, Pref.newAiApiProfile(name, url: url, key: apiKey)),
          child: const Text('保存接口')),
    ],
  );
}
