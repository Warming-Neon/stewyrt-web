import 'dart:math';

/// Soft-knee limiter applied to mic amplitude values before display.
///
/// ## What this does
/// Every raw dBFS sample from the `record` package is passed through a
/// soft-knee compression curve before being converted to a 0–1 bar height.
/// This means the waveform visualiser *never* clips visually, and loud
/// transients are compressed smoothly rather than hard-clipped.
///
/// ## What this does NOT do
/// It does not process the raw PCM data written to disk — that audio comes
/// directly from the OS mic pipeline. On iOS, AVAudioSession handles
/// system-level AGC; on Android, AudioRecord's built-in AGC is enabled via
/// `RecordConfig(autoGain: true)`. For true DSP limiting on the file itself
/// you would need a native plugin (e.g. flutter_soloud) or a platform channel.
class SoftLimiter {
  /// Gain reduction kicks in above this level (dBFS). Default: -6 dBFS.
  final double threshold;

  /// Compression ratio above the threshold. 8:1 is near-limiting behaviour.
  final double ratio;

  /// Soft-knee width in dB — smooths the transition into compression.
  final double kneeWidth;

  /// Below this level the signal is treated as silence (returns 0.0).
  final double noiseFloor;

  const SoftLimiter({
    this.threshold = -6.0,
    this.ratio = 8.0,
    this.kneeWidth = 4.0,
    this.noiseFloor = -60.0,
  });

  /// Apply soft-knee compression to a raw dBFS value.
  /// Returns a gain-reduced dBFS value.
  double processDb(double inputDb) {
    final halfKnee = kneeWidth / 2.0;
    if (inputDb <= threshold - halfKnee) {
      return inputDb; // below knee — pass through unchanged
    } else if (inputDb >= threshold + halfKnee) {
      // above knee — apply hard ratio reduction
      return threshold + (inputDb - threshold) / ratio;
    } else {
      // inside knee — smooth quadratic interpolation
      final x = inputDb - (threshold - halfKnee);
      return inputDb + ((1.0 / ratio - 1.0) * x * x) / (2.0 * kneeWidth);
    }
  }

  /// Convert a dBFS value → linear 0.0–1.0 for bar-height display.
  double dbToLinear(double db) {
    if (db <= noiseFloor) return 0.0;
    return pow(10.0, db / 20.0).toDouble().clamp(0.0, 1.0);
  }

  /// Full pipeline: limit then linearise. Feed raw `Amplitude.current` here.
  double process(double rawDb) => dbToLinear(processDb(rawDb));

  /// True when the raw signal is entering the limiting zone — use to show
  /// a clip-warning indicator in the UI.
  bool isNearCeiling(double rawDb) => rawDb > threshold - kneeWidth;
}
