import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class PhraseService {
  PhraseService._();
  static final instance = PhraseService._();

  // Hardcoded fallbacks — used when Firestore fetch fails or hasn't resolved yet.
  static const _fallbackSetup = [
    'Having a quick chinwag...', 'Putting the kettle on...', 'Pulling up a chair...', 'Shooting the breeze...',
    'Chewing the fat...', 'Lending a sympathetic ear...', 'Having a proper natter...', 'Catching up on the latest...',
  ];
  static const _fallbackObservation = [
    'Having a quick neb...', 'Having a proper gander...', 'Peeking at the subtext...', 'Squinting at the syllables...',
    'Casting an eye over the details...', 'Having a nosey at the context...', 'Taking a magnifying glass to the mood...',
  ];
  static const _fallbackEmpathy = [
    'Reading between the lines...', 'Weighing the heavy words...', 'Translating the exasperation...', 'Distilling the sheer essence...',
    'Listening to the silences...', 'Unpacking the baggage...', 'Measuring the exhaustion...', 'Feeling the actual vibe...', 'Finding the absolute flavor...',
  ];
  static const _fallbackTechnical = [
    'Scanning diligently...', 'Consulting the emotional thesaurus...', 'Crunching the feelings...', 'Recalibrating the vibe-meter...',
    'Decoding the delivery...', 'Connecting the emotional dots...', 'Booting up the empathy engine...', 'Bypassing the sarcasm...',
  ];

  List<String>? _setup;
  List<String>? _observation;
  List<String>? _empathy;
  List<String>? _technical;
  bool _fetchStarted = false;

  /// Fire-and-forget from initState. Subsequent calls are no-ops.
  Future<void> prefetch() async {
    if (_fetchStarted) return;
    _fetchStarted = true;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('waiting_phrases')
          .where('active', isEqualTo: true)
          .get();
      final setup       = <String>[];
      final observation = <String>[];
      final empathy     = <String>[];
      final technical   = <String>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final act  = data['act']  as String? ?? '';
        final text = data['text'] as String? ?? '';
        if (text.isEmpty) continue;
        switch (act) {
          case 'setup':       setup.add(text);
          case 'observation': observation.add(text);
          case 'empathy':     empathy.add(text);
          case 'technical':   technical.add(text);
        }
      }
      if (setup.isNotEmpty)       _setup       = setup;
      if (observation.isNotEmpty) _observation = observation;
      if (empathy.isNotEmpty)     _empathy     = empathy;
      if (technical.isNotEmpty)   _technical   = technical;
      debugPrint('[STEWYRT][PHRASES] Fetched — '
          'setup: ${setup.length}, observation: ${observation.length}, '
          'empathy: ${empathy.length}, technical: ${technical.length}');
    } catch (e) {
      debugPrint('[STEWYRT][PHRASES] Fetch failed — using fallbacks: $e');
    }
  }

  /// Returns a 4-phrase story (one per act). Uses cached Firestore data if
  /// available, otherwise falls back to hardcoded phrases.
  List<String> generateStory() {
    final rng         = Random();
    final setup       = _setup       ?? _fallbackSetup;
    final observation = _observation ?? _fallbackObservation;
    final empathy     = _empathy     ?? _fallbackEmpathy;
    final technical   = _technical   ?? _fallbackTechnical;
    return [
      setup      [rng.nextInt(setup.length)],
      observation[rng.nextInt(observation.length)],
      empathy    [rng.nextInt(empathy.length)],
      technical  [rng.nextInt(technical.length)],
    ];
  }
}
