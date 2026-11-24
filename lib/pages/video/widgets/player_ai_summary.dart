import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/pages/video/ai_conclusion/view.dart';
import 'package:material_ui/material_ui.dart';

/// The player and the detail page share their assistant session and summary.
class PlayerAiSummary extends StatefulWidget {
  const PlayerAiSummary({
    super.key,
    this.assistant,
    this.loadConclusion,
    required this.onSeek,
  }) : assert(assistant != null || loadConclusion != null);

  final Widget? assistant;
  final Future<AiConclusionResult?> Function()? loadConclusion;
  final ValueChanged<int> onSeek;

  @override
  State<PlayerAiSummary> createState() => _PlayerAiSummaryState();
}

class _PlayerAiSummaryState extends State<PlayerAiSummary> {
  late bool _official = widget.assistant == null;
  Future<AiConclusionResult?>? _summary;

  Widget _officialSummary(ThemeData theme) {
    return FutureBuilder<AiConclusionResult?>(
      future: _summary ??= Future<AiConclusionResult?>.sync(widget.loadConclusion!),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final result = snapshot.data;
        if (result != null &&
            (result.summary?.isNotEmpty == true ||
                result.outline?.isNotEmpty == true)) {
          return AiConclusionPanel.buildContent(
            context,
            theme,
            result,
            onSeek: widget.onSeek,
          );
        }
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(snapshot.hasError ? '获取 B 站总结失败' : '当前视频暂无可用的 B 站总结'),
                TextButton(
                  onPressed: () => setState(() => _summary = null),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final both = widget.assistant != null && widget.loadConclusion != null;
    return Material(
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
            child: Row(
              children: [
                Expanded(
                  child: both
                      ? Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<bool>(
                              value: _official,
                              isDense: true,
                              items: const [
                                DropdownMenuItem(value: false, child: Text('AI 视频助手')),
                                DropdownMenuItem(value: true, child: Text('B 站 AI 总结')),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  FocusScope.of(context).unfocus();
                                  setState(() => _official = value);
                                }
                              },
                            ),
                          ),
                        )
                      : Text(
                          _official ? 'B 站 AI 总结' : 'AI 视频助手',
                          style: theme.textTheme.titleMedium,
                        ),
                ),
                IconButton(
                  tooltip: '关闭总结',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _official ? _officialSummary(theme) : widget.assistant!),
        ],
      ),
    );
  }
}
