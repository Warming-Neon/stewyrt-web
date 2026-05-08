import 'dart:math';

/// Per-tag mock summaries shown in the expanded view.
const _summaries = {
  'Furious': 'People are at a breaking point. The anger here isn\'t noise — it\'s signal.',
  'Hopeful': 'Against the odds, optimism is surfacing. Something has shifted in the mood.',
  'Exhausted': 'The weight of it is showing. Collective burnout is running deep right now.',
  'Inspired': 'A rare wave of motivation. Something out there is cutting through the noise.',
  'Anxious': 'Uncertainty is dominating. People are bracing for something they can\'t name.',
  'Relieved': 'A moment of exhale. The pressure eased — at least for now.',
  'Skeptical': 'Trust is low. People are reading between the lines and not liking what they find.',
  'Energized': 'The energy is electric. Something has galvanised a meaningful chunk of people.',
  'Defeated': 'A sombre mood. People feel like the game is rigged and they\'re losing.',
  'Defiant': 'Resistance is building. The pushback is quiet but it\'s real.',
  'Grateful': 'Perspective is winning today. People are noticing what\'s still working.',
  'Overwhelmed': 'Too much, all at once. The signal-to-noise ratio has collapsed for many.',
  'Determined': 'People are locking in. There\'s a focused, almost stubborn energy here.',
  'Numb': 'Feelings have flatlined. The overload has pushed people past the point of reaction.',
  'Curious': 'Questions are outnumbering answers right now — and people seem okay with that.',
};

/// Sentiment breakdown weights for each primary tag.
const _breakdowns = {
  'Furious':       {'Furious': 0.52, 'Exhausted': 0.28, 'Defiant': 0.20},
  'Hopeful':       {'Hopeful': 0.48, 'Curious': 0.30, 'Grateful': 0.22},
  'Exhausted':     {'Exhausted': 0.55, 'Numb': 0.25, 'Defeated': 0.20},
  'Inspired':      {'Inspired': 0.50, 'Hopeful': 0.30, 'Energized': 0.20},
  'Anxious':       {'Anxious': 0.45, 'Overwhelmed': 0.35, 'Numb': 0.20},
  'Relieved':      {'Relieved': 0.54, 'Hopeful': 0.26, 'Grateful': 0.20},
  'Skeptical':     {'Skeptical': 0.50, 'Furious': 0.28, 'Numb': 0.22},
  'Energized':     {'Energized': 0.46, 'Inspired': 0.32, 'Hopeful': 0.22},
  'Defeated':      {'Defeated': 0.48, 'Exhausted': 0.30, 'Numb': 0.22},
  'Defiant':       {'Defiant': 0.50, 'Furious': 0.30, 'Determined': 0.20},
  'Grateful':      {'Grateful': 0.50, 'Relieved': 0.28, 'Hopeful': 0.22},
  'Overwhelmed':   {'Overwhelmed': 0.52, 'Anxious': 0.28, 'Exhausted': 0.20},
  'Determined':    {'Determined': 0.54, 'Defiant': 0.26, 'Energized': 0.20},
  'Numb':          {'Numb': 0.55, 'Exhausted': 0.25, 'Defeated': 0.20},
  'Curious':       {'Curious': 0.50, 'Hopeful': 0.28, 'Skeptical': 0.22},
};

class SentimentData {
  final String tag;
  final String topic;
  final DateTime timestamp;

  /// Placeholder — swap for a real CDN URL when audio backend is wired up.
  final String mockAudioUrl;

  /// Hardcoded to 30 seconds for all mock entries.
  final Duration audioLength;

  final String summary;
  final Map<String, double> breakdown;

  /// Normalised bar heights (0.0–1.0) for the waveform visualiser.
  final List<double> waveformData;

  SentimentData({
    required this.tag,
    required this.topic,
    required this.timestamp,
  })  : mockAudioUrl = 'https://mock.stewyrt.audio/$tag-${timestamp.millisecondsSinceEpoch}.mp3',
        audioLength = const Duration(seconds: 30),
        summary = _summaries[tag] ?? 'People are responding to this topic in unexpected ways.',
        breakdown = _breakdowns[tag] ?? {tag: 1.0},
        waveformData = _generateWaveform();

  static List<double> _generateWaveform() {
    final rng = Random();
    // 40 bars with slight smoothing so neighbouring bars aren't wildly different
    final raw = List.generate(40, (_) => rng.nextDouble());
    final smoothed = <double>[];
    for (var i = 0; i < raw.length; i++) {
      final prev = i > 0 ? raw[i - 1] : raw[i];
      final next = i < raw.length - 1 ? raw[i + 1] : raw[i];
      smoothed.add((prev * 0.25 + raw[i] * 0.5 + next * 0.25).clamp(0.15, 1.0));
    }
    return smoothed;
  }
}
