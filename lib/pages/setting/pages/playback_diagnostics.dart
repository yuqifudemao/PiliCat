import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/services/playback_diagnostics.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:material_ui/material_ui.dart';

class PlaybackDiagnosticsPage extends StatelessWidget {
  const PlaybackDiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: PlaybackDiagnostics.entries,
      builder: (context, entries, _) => Scaffold(
        appBar: AppBar(
          title: const Text('播放诊断日志'),
          actions: [
            IconButton(
              tooltip: '复制日志',
              icon: const Icon(Icons.copy_outlined),
              onPressed: entries.isEmpty
                  ? null
                  : () => Utils.copyText([
                      'PiliCat ${BuildConfig.versionName}+${BuildConfig.versionCode}',
                      ...entries,
                    ].join('\n')),
            ),
            IconButton(
              tooltip: '清空日志',
              icon: const Icon(Icons.delete_outline),
              onPressed: entries.isEmpty ? null : PlaybackDiagnostics.clear,
            ),
          ],
        ),
        body: entries.isEmpty
            ? const Center(child: Text('播放一次网络视频后，诊断记录会显示在这里。'))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, index) =>
                    SelectableText(entries[entries.length - 1 - index]),
              ),
      ),
    );
  }
}
