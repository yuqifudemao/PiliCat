import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

class PlaybackDownloadSpeed extends StatefulWidget {
  const PlaybackDownloadSpeed({super.key, required this.controller});

  final PlPlayerController controller;

  @override
  State<PlaybackDownloadSpeed> createState() => _PlaybackDownloadSpeedState();
}

class _PlaybackDownloadSpeedState extends State<PlaybackDownloadSpeed> {
  Timer? _timer;
  String? _label;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (TickerMode.of(context)) {
      _timer = Timer.periodic(const Duration(seconds: 1), _update);
    } else {
      _timer = null;
      _label = null;
    }
  }

  void _update(Timer timer) {
    String? label;
    final player = widget.controller.videoPlayerController;
    if (player is NativePlayer &&
        !player.state.completed &&
        player.state.playlist.medias.isNotEmpty) {
      final bytesPerSecond = int.tryParse(player.getProperty('cache-speed'));
      if (bytesPerSecond != null && bytesPerSecond >= 0) {
        final kib = bytesPerSecond / 1024;
        label = kib >= 1024
            ? '${(kib / 1024).toStringAsFixed(1)} MiB/s'
            : '${kib.toStringAsFixed(0)} KiB/s';
      }
    }
    if (label != _label) {
      setState(() => _label = label);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    if (label == null) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: '当前视频下载速度',
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}
