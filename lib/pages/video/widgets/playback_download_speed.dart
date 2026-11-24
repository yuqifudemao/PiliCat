import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/playback_rate_meter.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:material_ui/material_ui.dart';

class PlaybackDownloadSpeed extends StatefulWidget {
  const PlaybackDownloadSpeed({
    super.key,
    required this.controller,
  });

  final PlPlayerController controller;

  @override
  State<PlaybackDownloadSpeed> createState() => _PlaybackDownloadSpeedState();
}

class _PlaybackDownloadSpeedState extends State<PlaybackDownloadSpeed> {
  final _clock = Stopwatch()..start();
  Timer? _timer;
  String? _label;
  bool _appRate = false;
  bool _sampling = false;
  final _meter = PlaybackRateMeter();
  Object? _source;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.of(context);
    if (visible && _timer == null) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_update()),
      );
      unawaited(_update());
    } else if (!visible) {
      _timer?.cancel();
      _timer = null;
      _meter.reset();
      _label = null;
      _appRate = false;
    }
  }

  Future<void> _update() async {
    final timer = _timer;
    if (timer == null || _sampling) return;
    final player = widget.controller.videoPlayerController;
    if (player == null || player.disposed || player.state.completed) {
      _meter.reset();
      _show(null);
      return;
    }
    final source = widget.controller.dataSource;
    if (!identical(source, _source)) {
      _source = source;
      _meter.reset();
    }
    final mediaRate = double.tryParse(player.getProperty('cache-speed'));
    int? bytes;
    if (Platform.isAndroid) {
      _sampling = true;
      try {
        bytes = await Utils.channel.invokeMethod<int>('getAppRxBytes');
      } on MissingPluginException {
        // This platform build does not provide an app traffic counter.
      } on PlatformException {
        // Keep the unavailable indicator until a later sample succeeds.
      } finally {
        _sampling = false;
      }
      if (!mounted ||
          _timer != timer ||
          !identical(player, widget.controller.videoPlayerController) ||
          !identical(source, widget.controller.dataSource)) {
        return;
      }
    }
    _show(_meter.sample(
      mediaRate: mediaRate,
      appBytes: bytes,
      nowMicros: _clock.elapsedMicroseconds,
    ));
  }

  void _show(PlaybackRate? rate) {
    final label = rate == null ? null : PlaybackRateMeter.format(rate.bytesPerSecond);
    final appRate = rate?.appWide ?? false;
    if (mounted && (label != _label || appRate != _appRate)) {
      setState(() {
        _label = label;
        _appRate = appRate;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _appRate
          ? '当前 PiliCat 的接收速度，包含视频及 PiliCat 的其他请求'
          : '当前视频下载速度',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Text(
            '${_appRate ? 'App 网速' : '网速'} ${_label ?? '—'}',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
