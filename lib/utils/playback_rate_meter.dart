typedef PlaybackRate = ({double bytesPerSecond, bool appWide});

/// mpv reports the current demuxer's reads. DASH can download through a
/// different stream, so keep an independent baseline for the Android UID.
class PlaybackRateMeter {
  int? _bytes;
  int? _micros;

  void reset() {
    _bytes = null;
    _micros = null;
  }

  PlaybackRate? sample({
    required double? mediaRate,
    required int? appBytes,
    required int nowMicros,
  }) {
    final previous = _bytes;
    final time = _micros;
    _bytes = appBytes != null && appBytes >= 0 ? appBytes : null;
    _micros = _bytes == null ? null : nowMicros;

    if (mediaRate != null && mediaRate.isFinite && mediaRate > 0) {
      return (bytesPerSecond: mediaRate, appWide: false);
    }
    if (previous != null && time != null && appBytes != null &&
        appBytes >= previous && nowMicros > time) {
      final bytes = appBytes - previous;
      if (bytes > 0 || mediaRate != 0) {
        return (
          bytesPerSecond: bytes * Duration.microsecondsPerSecond / (nowMicros - time),
          appWide: true,
        );
      }
    }
    return mediaRate == 0 ? (bytesPerSecond: 0.0, appWide: false) : null;
  }

  static String format(double bytes) {
    if (bytes > 0 && bytes < 1024) return '${bytes.round()} B/s';
    final kib = bytes / 1024;
    return kib >= 1024
        ? '${(kib / 1024).toStringAsFixed(1)} MiB/s'
        : '${kib.toStringAsFixed(0)} KiB/s';
  }
}
