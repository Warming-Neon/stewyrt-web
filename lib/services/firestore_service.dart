import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Strongly-typed model matching the JSON schema produced by the Gemini
/// Cloud Function and written into the `responses` collection.
class AnalysisResult {
  final String tone;
  final String flavor;
  final String essence;
  final String summary;
  final String analysisChain;

  const AnalysisResult({
    required this.tone,
    required this.flavor,
    required this.essence,
    required this.summary,
    required this.analysisChain,
  });

  factory AnalysisResult.fromMap(Map<String, dynamic> map) {
    return AnalysisResult(
      tone:          map['tone']           as String? ?? '',
      flavor:        map['flavor']         as String? ?? '',
      essence:       map['essence']        as String? ?? '',
      summary:       map['summary']        as String? ?? '',
      analysisChain: map['analysis_chain'] as String? ?? '',
    );
  }
}

class FirestoreService {
  /// Subscribes to `responses/{responseId}` and calls [onResult] the moment the
  /// document is created by the Cloud Function (all four tag fields present).
  /// Calls [onBlocked] if the Cloud Function flagged the content as policy-violating.
  ///
  /// [timeoutSeconds] (default 120) — if no result arrives in time, [onTimeout]
  /// is called so the UI can surface an error instead of hanging forever.
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>
      listenForResult(
    String responseId,
    void Function(AnalysisResult) onResult, {
    int timeoutSeconds = 120,
    void Function()? onTimeout,
    void Function(String reason)? onBlocked,
  }) {
    debugPrint('[STEWYRT][FIRESTORE] Attaching listener on responses/$responseId');
    debugPrint('[STEWYRT][FIRESTORE] Timeout set to ${timeoutSeconds}s');

    final docRef = FirebaseFirestore.instance.collection('responses').doc(responseId);
    int snapshotCount = 0;

    // Kick off the timeout clock.
    final timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
      debugPrint('[STEWYRT][FIRESTORE] ⚠️  TIMEOUT after ${timeoutSeconds}s — '
          'Cloud Function never wrote responses/$responseId');
      onTimeout?.call();
    });

    final sub = docRef.snapshots().listen((snap) {
      snapshotCount++;
      debugPrint('[STEWYRT][FIRESTORE] Snapshot #$snapshotCount — '
          'exists: ${snap.exists} | fields: ${snap.data()?.keys.toList()}');

      if (!snap.exists) {
        debugPrint('[STEWYRT][FIRESTORE] Document not yet created — waiting...');
        return;
      }
      final data = snap.data();
      if (data == null) {
        debugPrint('[STEWYRT][FIRESTORE] Document exists but data is null — waiting...');
        return;
      }

      // Check for content moderation block first.
      if (data['blocked'] == true) {
        final reason = data['blockedReason'] as String? ?? 'content_policy';
        debugPrint('[STEWYRT][FIRESTORE] 🚫 Content blocked — reason: $reason');
        timeoutTimer.cancel();
        onBlocked?.call(reason);
        return;
      }

      final tone    = data['tone'];
      final flavor  = data['flavor'];
      final essence = data['essence'];
      final summary = data['summary'];

      debugPrint('[STEWYRT][FIRESTORE] Fields — '
          'tone: $tone | flavor: $flavor | essence: $essence | summary: $summary');

      if (tone == null || flavor == null || essence == null || summary == null) {
        debugPrint('[STEWYRT][FIRESTORE] Missing required fields — waiting for full write...');
        return;
      }

      debugPrint('[STEWYRT][FIRESTORE] ✅ Result ready — cancelling timeout');
      timeoutTimer.cancel();
      onResult(AnalysisResult.fromMap(data));
    }, onError: (Object err) {
      debugPrint('[STEWYRT][FIRESTORE] ERROR on snapshot stream: $err');
      timeoutTimer.cancel();
    });

    return sub;
  }

  /// Listens to `users/{uid}` until the Cloud Function writes the verification
  /// result. Calls [onComplete] when `isFlagged == false`, or [onError] with
  /// the `verificationNote` when flagged, errored, or timed out.
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>
      listenForVerification(
    String uid,
    void Function(Map<String, dynamic> data) onComplete,
    void Function(String message) onError, {
    int timeoutSeconds = 120,
  }) {
    debugPrint('[STEWYRT][FIRESTORE] Attaching verification listener on users/$uid');

    final docRef = FirebaseFirestore.instance.collection('users').doc(uid);

    late StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;

    final timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
      debugPrint('[STEWYRT][FIRESTORE] ⚠️  Verification timeout after ${timeoutSeconds}s');
      sub.cancel();
      onError('Verification timed out — please try again.');
    });

    sub = docRef.snapshots().listen((snap) {
      debugPrint('[STEWYRT][VERIFY] Snapshot — exists: ${snap.exists} | data: ${snap.data()}');
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null || !data.containsKey('verifiedAt')) return;

      timeoutTimer.cancel();
      sub.cancel();

      if (data['verifiedAsHuman'] == false || data['error'] == true) {
        final note = data['verificationNote'] as String? ??
            'Verification failed. Please try again.';
        debugPrint('[STEWYRT][FIRESTORE] 🚫 Verification failed: $note');
        onError(note);
      } else {
        debugPrint('[STEWYRT][FIRESTORE] ✅ Verification passed — human confirmed');
        onComplete(data);
      }
    }, onError: (Object err) {
      debugPrint('[STEWYRT][FIRESTORE] ERROR on verification stream: $err');
      timeoutTimer.cancel();
      onError('Verification failed due to a connection error.');
    });

    return sub;
  }
}
