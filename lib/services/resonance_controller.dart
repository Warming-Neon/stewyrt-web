import 'package:flutter/material.dart';

// Coordinates tab switching, Resonance focus requests, and route observation
// across the app. Zero platform-specific imports — safe to use anywhere.
class ResonanceController {
  static final routeObserver = RouteObserver<ModalRoute<void>>();

  static void Function(int)? _switchTab;
  static void Function(String)? _focus;
  static BuildContext? _context;

  static void registerTabSwitcher(void Function(int) fn, BuildContext context) {
    _switchTab = fn;
    _context = context;
  }

  static void registerFocus(void Function(String) fn) => _focus = fn;
  static void unregisterFocus() => _focus = null;

  // Navigate to The Resonance tab and highlight the named synapse node.
  // If pollId is provided, push a new ResonanceScreen instance instead of tab switching.
  static void goToResonanceAndFocus(String tag, {String? pollId}) {
    if (pollId != null && _context != null) {
      // Import here or keep ResonanceScreen in a common layer. 
      // Assuming ResonanceScreen is available or handled via a router.
      // Since this file is 'safe to use anywhere', we use a callback or dynamic navigation if needed,
      // but for this specific overhaul we'll assume we can push to the context.
      Navigator.of(_context!, rootNavigator: true).push(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => 
            // Note: We need a way to create ResonanceScreen without circular imports if possible, 
            // but usually screens and services are separated.
            // For now, following the user's direct instruction to implement this logic here.
            _buildResonanceScreen(pollId, tag),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
        ),
      );
    } else {
      _switchTab?.call(1);
      _focus?.call(tag);
    }
  }

  // Helper to avoid circular imports if ResonanceScreen is defined in screens/
  static Widget Function(String, String)? resonanceScreenBuilder;

  static Widget _buildResonanceScreen(String pollId, String tag) {
    if (resonanceScreenBuilder != null) {
      return resonanceScreenBuilder!(pollId, tag);
    }
    return const SizedBox(); // Fallback
  }
}
