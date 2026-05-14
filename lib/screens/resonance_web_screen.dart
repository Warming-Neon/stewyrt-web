import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:web/web.dart' as web;

import '../services/resonance_controller.dart';

typedef ResonancePlatformScreen = ResonanceWebScreen;

class ResonanceWebScreen extends StatefulWidget {
  const ResonanceWebScreen({
    super.key,
    this.pollId,
    this.initialFocusTag,
    this.showBackButton = false,
  });

  final String? pollId;
  final String? initialFocusTag;
  final bool showBackButton;

  @override
  State<ResonanceWebScreen> createState() => _ResonanceWebScreenState();
}

class _ResonanceWebScreenState extends State<ResonanceWebScreen> {
  // Static so they survive hot-reload and state recreation.
  static bool _viewRegistered = false;
  static web.HTMLIFrameElement? _iframe;
  // Last serialised payload — replayed when the iframe fires its load event,
  // covering the race where Firestore resolves before the iframe JS is ready.
  static String? _pendingPayload;
  // Focus tag to deliver once the iframe is loaded AND data has been sent.
  static String? _pendingFocusTag;
  static bool _iframeLoaded = false;
  static bool _focusFired = false;

  bool _hasData = false;
  StreamSubscription? _pollSub;
  StreamSubscription? _firestoreSub;
  String? _currentPollId;

  @override
  void initState() {
    super.initState();
    _focusFired = false;
    if (widget.initialFocusTag != null) _pendingFocusTag = widget.initialFocusTag;

    ResonanceController.registerFocus((tag) {
      _pendingFocusTag = tag;
      _focusFired = false;
      if (_iframeLoaded) _triggerFocus(tag);
    });

    if (!_viewRegistered) {
      ui_web.platformViewRegistry.registerViewFactory(
        'brain-view',
        (int viewId) {
          final iframe =
              web.document.createElement('iframe') as web.HTMLIFrameElement;
          iframe.id = 'brain-iframe';
          iframe.src = 'brain_visualizer.html';
          iframe.style.setProperty('border', 'none');
          iframe.style.setProperty('width', '100%');
          iframe.style.setProperty('height', '100%');
          _iframe = iframe;
          // Replay the cached payload once the iframe's JS listener is alive.
          iframe.addEventListener(
            'load',
            ((web.Event _) {
              _iframeLoaded = true;
              final p = _pendingPayload;
              if (p != null) _post(p);
              // If data arrived before iframe loaded, fire focus now.
              final tag = _pendingFocusTag;
              if (tag != null && !_focusFired) {
                Future.delayed(
                  const Duration(milliseconds: 600),
                  () => _triggerFocus(tag),
                );
              }
            }).toJS,
          );
          return iframe;
        },
      );
      _viewRegistered = true;
    }

    final providedPollId = widget.pollId;
    if (providedPollId != null) {
      _currentPollId = providedPollId;
      _firestoreSub = FirebaseFirestore.instance
          .collection('responses')
          .where('pollId', isEqualTo: providedPollId)
          .where('blocked', isEqualTo: false)
          .orderBy('createdAt', descending: true)
          .limit(300)
          .snapshots()
          .listen(_processSnapshot);
    } else {
      _pollSub = FirebaseFirestore.instance
          .collection('polls')
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .limit(1)
          .snapshots()
          .listen((snap) {
        if (snap.docs.isEmpty) return;
        final pollId = snap.docs.first.id;
        if (pollId == _currentPollId) return;
        _currentPollId = pollId;
        _firestoreSub?.cancel();
        _firestoreSub = FirebaseFirestore.instance
            .collection('responses')
            .where('pollId', isEqualTo: pollId)
            .where('blocked', isEqualTo: false)
            .orderBy('createdAt', descending: true)
            .limit(300)
            .snapshots()
            .listen(_processSnapshot);
      });
    }
  }

  @override
  void dispose() {
    ResonanceController.unregisterFocus();
    _pollSub?.cancel();
    _firestoreSub?.cancel();
    super.dispose();
  }

  void _processSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    final counts = <String, int>{};
    final regionVotes = <String, Map<String, int>>{};
    final edgeWeights = <String, int>{};
    var totalTags = 0;

    for (final doc in snap.docs) {
      final data = doc.data();

      // Collect valid tags for this document (word → safeRegion)
      final docTags = <String, String>{};
      for (final field in ['tone', 'flavor', 'essence']) {
        final word = (data[field] as String?)?.trim();
        if (word == null || word.isEmpty) continue;
        final region = (data['${field}Region'] as String?)?.trim();
        final safeRegion =
            const {'Prefrontal', 'Amygdala', 'Nucleus', 'Insula'}
                    .contains(region)
                ? region!
                : 'Prefrontal';

        counts[word] = (counts[word] ?? 0) + 1;
        final wordVotes = regionVotes.putIfAbsent(word, () => {});
        wordVotes[safeRegion] = (wordVotes[safeRegion] ?? 0) + 1;
        totalTags++;
        docTags[word] = safeRegion;
      }

      // Edge for every unique pair that co-occurred in this exact document.
      // Key is alphabetically sorted so A|B and B|A are the same edge.
      final words = docTags.keys.toList();
      for (int i = 0; i < words.length; i++) {
        for (int j = i + 1; j < words.length; j++) {
          final pair = [words[i], words[j]]..sort();
          final key = '${pair[0]}|${pair[1]}';
          edgeWeights[key] = (edgeWeights[key] ?? 0) + 1;
        }
      }
    }

    if (totalTags == 0) return;

    if (!_hasData && mounted) setState(() => _hasData = true);

    String dominantRegion(String word) {
      final votes = regionVotes[word];
      if (votes == null || votes.isEmpty) return 'Prefrontal';
      return votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }

    final nodes = counts.entries
        .map((e) => {
              'name': e.key,
              'percent': double.parse(
                  (e.value / totalTags * 100).toStringAsFixed(1)),
              'region': dominantRegion(e.key),
            })
        .toList();

    final edges = edgeWeights.entries.map((e) {
      final parts = e.key.split('|');
      return <String, dynamic>{
        'source': parts[0],
        'target': parts[1],
        'weight': e.value,
      };
    }).toList();

    _sendDataToBrain(nodes, edges);
  }

  void _sendDataToBrain(
    List<Map<String, dynamic>> nodes,
    List<Map<String, dynamic>> edges,
  ) {
    final payload = jsonEncode({'nodes': nodes, 'edges': edges});
    _pendingPayload = payload;
    _post(payload);
    // If iframe is already loaded, fire focus now (data → nodes created synchronously in JS).
    final tag = _pendingFocusTag;
    if (tag != null && !_focusFired && _iframeLoaded) {
      Future.delayed(
        const Duration(milliseconds: 600),
        () => _triggerFocus(tag),
      );
    }
  }

  // Static so the iframe's onload closure can call it without capturing `this`.
  static void _post(String payload) {
    final cw = _iframe?.contentWindow;
    if (cw == null) return;
    cw.postMessage(payload.toJS, '*'.toJS);
  }

  static void _triggerFocus(String tag) {
    if (_focusFired) return;
    _focusFired = true;
    _pendingFocusTag = null;
    _post(jsonEncode({'focus': tag}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 3D brain canvas (fully interactive) ─────────────────────────────
          const SizedBox.expand(
            child: HtmlElementView(viewType: 'brain-view'),
          ),

          // ── Header overlay — IgnorePointer so all touches reach the canvas ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'The Resonance',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFF5F5F5),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Live global sentiment',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFFAAAAAA),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SafeArea(
                top: false,
                child: AnimatedOpacity(
                  opacity: _hasData ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 600),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 32),
                    child: Text(
                      'No voices yet. Be the first.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.showBackButton)
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, left: 16),
                  child: GestureDetector(
                    onTap: () => Navigator.maybePop(context),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
