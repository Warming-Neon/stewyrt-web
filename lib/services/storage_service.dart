import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

class StorageService {
  // Onboarding verification audio — filename is prefixed with `onboarding_`
  // so the Cloud Function routes it to the demographic verification flow.
  // No download URL is returned because the Cloud Function deletes the file
  // from the bucket immediately after acoustic analysis.
  static Future<void> uploadOnboardingAudio(
    String localFilePath,
    String uuid, {
    required String claimedAge,
    required String claimedGender,
    required String claimedEthnicity,
    required String claimedRegion,
  }) async {
    final file     = File(localFilePath);
    final fileSize = await file.length();
    debugPrint('[STEWYRT][STORAGE] Starting onboarding upload — uuid: $uuid');
    debugPrint('[STEWYRT][STORAGE] File: $localFilePath (${(fileSize / 1024).toStringAsFixed(1)} KB)');

    final ref  = FirebaseStorage.instance.ref('audio_uploads/onboarding_$uuid.m4a');
    final task = ref.putFile(
      file,
      SettableMetadata(
        contentType: 'audio/mp4',
        customMetadata: {
          'claimedAge':       claimedAge,
          'claimedGender':    claimedGender,
          'claimedEthnicity': claimedEthnicity,
          'claimedRegion':    claimedRegion,
        },
      ),
    );

    int lastLoggedPercent = -1;
    task.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes == 0) return;
      final pct = ((snapshot.bytesTransferred / snapshot.totalBytes) * 100).round();
      if (pct >= lastLoggedPercent + 25) {
        lastLoggedPercent = (pct ~/ 25) * 25;
        debugPrint('[STEWYRT][STORAGE] Onboarding upload: $pct%');
      }
    });

    final snapshot = await task;
    debugPrint('[STEWYRT][STORAGE] Onboarding upload complete — state: ${snapshot.state.name}');
  }

  static Future<String> uploadAudioClip(
    String localFilePath,
    String uuid,
    String pollQuestion,
    String pollId,
    String responseId, {
    Map<String, String> extraMetadata = const {},
  }) async {
    final file     = File(localFilePath);
    final fileSize = await file.length();
    debugPrint('[STEWYRT][STORAGE] Starting upload — uuid: $uuid');
    debugPrint('[STEWYRT][STORAGE] File: $localFilePath (${(fileSize / 1024).toStringAsFixed(1)} KB)');
    debugPrint('[STEWYRT][STORAGE] Metadata — question: "$pollQuestion" | pollId: $pollId');

    final ref  = FirebaseStorage.instance.ref('audio_uploads/$uuid.m4a');
    final task = ref.putFile(
      file,
      SettableMetadata(
        contentType: 'audio/mp4',
        customMetadata: {
          'question':   pollQuestion,
          'pollId':     pollId,
          'responseId': responseId,
          ...extraMetadata,
        },
      ),
    );

    // Log upload progress.
    int lastLoggedPercent = -1;
    task.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes == 0) return;
      final pct = ((snapshot.bytesTransferred / snapshot.totalBytes) * 100).round();
      // Log every 25% to avoid spam.
      if (pct >= lastLoggedPercent + 25) {
        lastLoggedPercent = (pct ~/ 25) * 25;
        debugPrint('[STEWYRT][STORAGE] Upload progress: $pct% '
            '(${snapshot.bytesTransferred}/${snapshot.totalBytes} bytes) '
            '— state: ${snapshot.state.name}');
      }
    });

    final snapshot = await task;
    debugPrint('[STEWYRT][STORAGE] Upload complete — state: ${snapshot.state.name}');

    final url = await ref.getDownloadURL();
    debugPrint('[STEWYRT][STORAGE] Download URL obtained: $url');
    return url;
  }
}
