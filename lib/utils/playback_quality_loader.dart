import 'package:PiliPlus/models/video/play/url.dart';

/// Load only a missing selected quality before opening media. Other advertised
/// qualities can be filled after playback has been opened.
class PlaybackQualityLoader {
  PlaybackQualityLoader({
    required this.source,
    required this.request,
    required this.isCurrent,
  });

  final PlayUrlModel source;
  final Future<PlayUrlModel?> Function(int quality) request;
  final bool Function() isCurrent;
  final Map<int, Future<void>> _pending = {};

  Future<void> prepare(int preferredQuality) =>
      _load(source.missingQualityForPlayback(preferredQuality));

  Future<void> complete() => _load(source.missingVideoQualityBelowHighest);

  Future<void> _load(int quality) {
    if (quality < 0 || !isCurrent()) return Future.value();
    return _pending.putIfAbsent(
      quality,
      () => _requestAndMerge(quality).whenComplete(() {
        _pending.remove(quality);
      }),
    );
  }

  Future<void> _requestAndMerge(int quality) async {
    try {
      final response = await request(quality);
      if (!isCurrent() || response == null) return;
      // Never mix URLs issued for different media request profiles.
      if (response.mediaHttpProfile != source.mediaHttpProfile ||
          response.preserveStreamUrls != source.preserveStreamUrls) {
        return;
      }
      source.dash?.video?.merge(response.dash?.video);
    } catch (_) {
      // A failed optional quality must not prevent already available playback.
    }
  }
}
