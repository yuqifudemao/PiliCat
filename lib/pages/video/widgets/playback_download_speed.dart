import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:media_kit/media_kit.dart' show NativePlayer;

class PlaybackDownloadSpeed extends StatefulWidget {
  const PlaybackDownloadSpeed({
    super.key,
    required this.controller,
    this.alwaysVisible = false,
  });

  final PlPlayerController controller;
  final bool alwaysVisible;

  @override
  State<PlaybackDownloadSpeed> createState() => _PlaybackDownloadSpeedState();
}

class _PlaybackDownloadSpeedState extends State<PlaybackDownloadSpeed> {
  final _clock = Stopwatch()..start();
  Timer? _timer;
  String? _label;
  bool _appRate = false;
  bool _sampling = false;
  int? _previousBytes;
  int? _previousTime;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.of(context);
    if ((visible || widget.alwaysVisible) && _timer == null) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_update()),
      );
      unawaited(_update());
    } else if (!visible && !widget.alwaysVisible) {
      _timer?.cancel();
      _timer = null;
      _previousBytes = null;
      _previousTime = null;
      _label = null;
      _appRate = false;
    }
  }

  Future<void> _update() async {
    final timer = _timer;
    if (timer == null || _sampling) return;
    final player = widget.controller.videoPlayerController;
    var rate = player is NativePlayer && !player.state.completed
        ? double.tryParse(player.getProperty('cache-speed'))
        : null;
    var appRate = false;
    if ((rate == null || !rate.isFinite || rate < 0) &&
        Platform.isAndroid &&
        player != null &&
        (player.state.playing || player.state.buffering)) {
      _sampling = true;
      int? bytes;
      try {
        bytes = await Utils.channel.invokeMethod<int>('getAppRxBytes');
      } on MissingPluginException {
        // This platform build does not provide an app traffic counter.
      } on PlatformException {
        // Keep the unavailable indicator until a later sample succeeds.
      } finally {
        _sampling = false;
      }
      if (!mounted || _timer != timer) return;
      final now = _clock.elapsedMicroseconds;
      final previousBytes = _previousBytes;
      final previousTime = _previousTime;
      _previousBytes = bytes;
      _previousTime = bytes == null ? null : now;
      if (bytes != null &&
          previousBytes != null &&
          previousTime != null &&
          bytes >= previousBytes &&
          now > previousTime) {
        rate = (bytes - previousBytes) * Duration.microsecondsPerSecond /
            (now - previousTime);
        appRate = true;
      }
    } else {
      _previousBytes = null;
      _previousTime = null;
    }
    final label = rate != null && rate.isFinite && rate >= 0
        ? _formatRate(rate)
        : null;
    if (mounted && (label != _label || appRate != _appRate)) {
      setState(() {
        _label = label;
        _appRate = appRate;
      });
    }
  }

  String _formatRate(double bytesPerSecond) {
    final kib = bytesPerSecond / 1024;
    return kib >= 1024
        ? '${(kib / 1024).toStringAsFixed(1)} MiB/s'
        : '${kib.toStringAsFixed(0)} KiB/s';
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
