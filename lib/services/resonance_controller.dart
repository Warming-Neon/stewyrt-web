import 'package:flutter/widgets.dart';

// Coordinates tab switching, Resonance focus requests, and route observation
// across the app. Zero platform-specific imports — safe to use anywhere.
class ResonanceController {
  static final routeObserver = RouteObserver<ModalRoute<void>>();

  static void Function(int)? _switchTab;
  static void Function(String)? _focus;

  static void registerTabSwitcher(void Function(int) fn) => _switchTab = fn;

  static void registerFocus(void Function(String) fn) => _focus = fn;
  static void unregisterFocus() => _focus = null;

  // Navigate to The Resonance tab and highlight the named synapse node.
  static void goToResonanceAndFocus(String tag) {
    _switchTab?.call(1);
    _focus?.call(tag);
  }
}
