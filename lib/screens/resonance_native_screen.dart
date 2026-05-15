import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/resonance_controller.dart';

class ResonancePlatformScreen extends StatefulWidget {
  const ResonancePlatformScreen({
    super.key,
    this.pollId,
    this.initialFocusTag,
  });

  final String? pollId;
  final String? initialFocusTag;

  @override
  State<ResonancePlatformScreen> createState() => _ResonanceNativeScreenState();
}

class _ResonanceNativeScreenState extends State<ResonancePlatformScreen> {
  late final WebViewController _controller;
  // _pageLoaded is set true only after BrainChannel.postMessage('ready')
  // fires from the JS side, meaning Three.js is fully initialised.
  bool _pageLoaded = false;
  bool _hasData = false;
  String? _pendingJson;
  String? _pendingFocusTag;
  StreamSubscription? _pollSub;
  StreamSubscription? _firestoreSub;
  String? _currentPollId;
  String? _runtimePollId;

  @override
  void initState() {
    super.initState();
    ResonanceController.registerFocus(_focusNode);
    ResonanceController.registerScopeChanger(_changePollScope);
    if (widget.initialFocusTag != null) _pendingFocusTag = widget.initialFocusTag;

    _controller = WebViewController()
      ..addJavaScriptChannel(
        'BrainChannel',
        onMessageReceived: (msg) {
          // ignore: avoid_print
          print('[BrainChannel] ${msg.message}');
          if (msg.message != 'ready' || !mounted) return;
          _pageLoaded = true;
          final pending = _pendingJson;
          final tag = _pendingFocusTag;
          if (tag != null) _pendingFocusTag = null;
          // Embed focus in the data payload so JS focusOnNode runs after
          // nodes are built in the same processBrainData call, not in a
          // separate runJavaScript that may execute before nodes exist.
          if (pending != null) {
            _inject(pending, focusTag: tag);
          } else if (tag != null) {
            _focusNode(tag);
          }
        },
      )
      ..setOnConsoleMessage((msg) {
        // ignore: avoid_print
        print('[WV] ${msg.message}');
      })
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..loadFlutterAsset('web/brain_visualizer.html');

    _startSubscription();
  }

  @override
  void dispose() {
    ResonanceController.unregisterFocus();
    ResonanceController.unregisterScopeChanger();
    _pollSub?.cancel();
    _firestoreSub?.cancel();
    super.dispose();
  }

  void _focusNode(String tag) {
    // Always store as pending — if nodes aren't built yet (page just loaded,
    // or poll scope just changed), _processSnapshot will embed it in the next
    // inject. If nodes already exist, fire immediately too.
    _pendingFocusTag = tag;
    if (_pageLoaded && _pendingJson != null) {
      // Nodes exist — fire now and clear pending.
      _pendingFocusTag = null;
      _controller.runJavaScript(
        "if (typeof focusOnNode === 'function') { focusOnNode(${jsonEncode(tag)}); }",
      );
    }
  }

  void _changePollScope(String? pollId) {
    _pollSub?.cancel();
    _pollSub = null;
    _firestoreSub?.cancel();
    _firestoreSub = null;
    _currentPollId = null;
    _pendingJson = null;
    _runtimePollId = pollId;
    _startSubscription();
  }

  void _startSubscription() {
    final providedPollId = _runtimePollId ?? widget.pollId;
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

  void _processSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    final counts = <String, int>{};
    final regionVotes = <String, Map<String, int>>{};
    final edgeWeights = <String, int>{};
    var totalTags = 0;

    for (final doc in snap.docs) {
      final data = doc.data();
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

    final jsonString = jsonEncode({'nodes': nodes, 'edges': edges});
    _pendingJson = jsonString;
    if (_pageLoaded) {
      final tag = _pendingFocusTag;
      if (tag != null) _pendingFocusTag = null;
      _inject(jsonString, focusTag: tag);
    }
  }

  void _inject(String jsonString, {String? focusTag}) {
    // Embed focusTag in the payload so JS focusOnNode fires after nodes are
    // built in the same processBrainData call, avoiding the async-ordering race.
    String payloadString = jsonString;
    if (focusTag != null) {
      final map = jsonDecode(jsonString) as Map<String, dynamic>;
      map['focus'] = focusTag;
      payloadString = jsonEncode(map);
    }
    _controller.runJavaScript(
      "if (typeof updateBrainDataNative === 'function') {"
      "updateBrainDataNative(${jsonEncode(payloadString)});"
      "}",
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
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
        ],
      ),
    );
  }
}
