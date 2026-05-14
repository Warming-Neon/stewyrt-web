// Platform router for the Resonance tab.
//
// dart.library.js_interop is TRUE on Flutter Web and FALSE on iOS/Android —
// confirmed by the iOS compiler rejecting dart:js_interop at build time.
// Each compiler only ever sees one of the two platform files.
import 'package:flutter/material.dart';
import 'resonance_native_screen.dart'
    if (dart.library.js_interop) 'resonance_web_screen.dart';

class ResonanceScreen extends StatelessWidget {
  const ResonanceScreen({
    super.key,
    this.pollId,
    this.initialFocusTag,
    this.showBackButton = false,
  });

  final String? pollId;
  final String? initialFocusTag;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) => ResonancePlatformScreen(
        pollId:         pollId,
        initialFocusTag: initialFocusTag,
        showBackButton:  showBackButton,
      );
}
