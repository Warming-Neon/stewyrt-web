import 'package:flutter/material.dart';

// Coordinates tab switching, Resonance focus requests, and route observation
// across the app. Zero platform-specific imports — safe to use anywhere.
class ResonanceController {
  static final routeObserver = RouteObserver<ModalRoute<void>>();

  static void Function(int)? _switchTab;
  static void Function(String)? _focus;
  static void Function(String?)? _scopePoll;
  static void Function()? _stopSpin;

  static void registerTabSwitcher(void Function(int) fn) => _switchTab = fn;

  static void registerFocus(void Function(String) fn) => _focus = fn;
  static void unregisterFocus() => _focus = null;

  static void registerScopeChanger(void Function(String?) fn) => _scopePoll = fn;
  static void unregisterScopeChanger() => _scopePoll = null;

  static void registerSpinStopper(void Function() fn) => _stopSpin = fn;
  static void unregisterSpinStopper() => _stopSpin = null;
  static void stopSpin() => _stopSpin?.call();

  // Switch to the Resonance tab, focus the named synapse, and optionally scope to a poll.
  static void goToResonanceAndFocus(String tag, {String? pollId}) {
    _switchTab?.call(1);
    if (pollId != null) _scopePoll?.call(pollId);
    _focus?.call(tag);
  }

  // Switch to the Resonance tab, optionally scoped to a specific poll.
  static void goToResonanceTab({String? pollId}) {
    _switchTab?.call(1);
    if (pollId != null) _scopePoll?.call(pollId);
  }
}
