import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  static Future<void> signInAnonymously() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) {
      debugPrint('[STEWYRT][AUTH] Already signed in as ${current.uid}');
      return;
    }
    debugPrint('[STEWYRT][AUTH] Signing in anonymously...');
    try {
      final cred = await FirebaseAuth.instance.signInAnonymously();
      debugPrint('[STEWYRT][AUTH] Signed in — uid: ${cred.user?.uid}');
    } catch (e) {
      debugPrint('[STEWYRT][AUTH] ERROR: $e');
      rethrow;
    }
  }
}
