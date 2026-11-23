import 'package:PiliPlus/utils/playback_rate_meter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final meter = PlaybackRateMeter();
  setUp(meter.reset);

  test('falls back to measured Android traffic when mpv reports zero', () {
    meter.sample(mediaRate: 0, appBytes: 1024, nowMicros: 100000);
    expect(
      meter.sample(mediaRate: 0, appBytes: 4096, nowMicros: 1600000),
      (bytesPerSecond: 2048.0, appWide: true),
    );
    expect(
      meter.sample(mediaRate: 0, appBytes: 4096, nowMicros: 2600000),
      (bytesPerSecond: 0.0, appWide: false),
    );
  });

  test('prefers media bytes and keeps an app baseline across samples', () {
    expect(
      meter.sample(mediaRate: 4096, appBytes: 100, nowMicros: 200000),
      (bytesPerSecond: 4096.0, appWide: false),
    );
    expect(
      meter.sample(mediaRate: null, appBytes: 228, nowMicros: 1200000),
      (bytesPerSecond: 128.0, appWide: true),
    );
    expect(PlaybackRateMeter.format(128), '128 B/s');
  });

  test('unavailable and reset counters do not create spurious spikes', () {
    expect(meter.sample(mediaRate: null, appBytes: -1, nowMicros: 0), isNull);
    expect(meter.sample(mediaRate: null, appBytes: 5000, nowMicros: 10), isNull);
    expect(meter.sample(mediaRate: -1, appBytes: 10, nowMicros: 100), isNull);
    meter.reset();
    expect(meter.sample(mediaRate: double.nan, appBytes: 6000, nowMicros: 200), isNull);
  });
}
