import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/poll_card.dart';
import '../widgets/recording_sheet.dart';
import '../widgets/sentiment_stream.dart';
import 'resonance_screen.dart';

// ── Firestore poll model ──────────────────────────────────────────────────────

class PollData {
  final String id;
  final String question;
  final String category;
  final String topic;
  final String tier;
  final bool isPlaceholder;

  const PollData({
    required this.id,
    required this.question,
    required this.category,
    required this.topic,
    required this.tier,
    this.isPlaceholder = false,
  });

  factory PollData.placeholder(String tier) => PollData(
        id:            '',
        question:      "Today's question is on its way.",
        category:      _categoryLabel(tier),
        topic:         tier,
        tier:          tier,
        isPlaceholder: true,
      );

  static String _categoryLabel(String tier) => switch (tier) {
        'horizon'     => 'Weekly',
        'ice_breaker' => 'Always On',
        _             => 'Daily',
      };

  factory PollData.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return PollData(
      id:       doc.id,
      question: d['question'] as String? ?? '',
      category: d['category'] as String? ?? '',
      topic:    d['topic']    as String? ?? '',
      tier:     d['tier']     as String? ?? 'pulse',
    );
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class PulseScreen extends StatefulWidget {
  const PulseScreen({super.key, this.pollId});

  // Reserved for future per-question detail view (Archive → Pulse+Resonance tab).
  final String? pollId;

  @override
  State<PulseScreen> createState() => _PulseScreenState();
}

class _PulseScreenState extends State<PulseScreen> {
  final PageController _pageController = PageController();
  late final Stream<List<PollData>> _rotationStream;

  @override
  void initState() {
    super.initState();
    _rotationStream = widget.pollId != null
        ? _singlePollStream(widget.pollId!)
        : _buildRotationStream();
    _pageController.addListener(_onPageScroll);
  }

  void _onPageScroll() {
    if (mounted) setState(() {});
  }

  int get _activeIndex {
    if (!_pageController.hasClients) return 0;
    return _pageController.page?.round() ?? 0;
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    super.dispose();
  }

  // ── Streams ───────────────────────────────────────────────────────────────

  Stream<List<PollData>> _singlePollStream(String pollId) {
    return FirebaseFirestore.instance
        .collection('polls')
        .doc(pollId)
        .snapshots()
        .map((doc) => doc.exists ? [PollData.fromFirestore(doc)] : <PollData>[]);
  }

  Stream<List<PollData>> _buildRotationStream() async* {
    debugPrint('[STEWYRT][PULSE] Attaching rotation stream');

    // Fetch ice_breaker once — it's a static card that never rotates out.
    final iceSnap = await FirebaseFirestore.instance
        .collection('polls')
        .where('tier', isEqualTo: 'ice_breaker')
        .limit(1)
        .get();

    final icePoll = iceSnap.docs.isEmpty
        ? null
        : PollData.fromFirestore(iceSnap.docs.first);

    // Live stream: pulse + horizon active polls, newest first per tier.
    await for (final snap in FirebaseFirestore.instance
        .collection('polls')
        .where('tier', whereIn: ['pulse', 'horizon'])
        .where('isActive', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()) {
      debugPrint('[STEWYRT][PULSE] rotation snapshot — ${snap.docs.length} docs');

      final docs    = snap.docs.map(PollData.fromFirestore).toList();
      final pulse   = docs.where((p) => p.tier == 'pulse').firstOrNull;
      final horizon = docs.where((p) => p.tier == 'horizon').firstOrNull;

      // TODO(reflex): When a Reflex question is active, prepend it here.
      // Shape becomes [reflex, pulse_or_placeholder, horizon_or_placeholder, ice_breaker_or_placeholder].
      // Reflex has no placeholder — the slot is absent when no Reflex question is active.
      yield <PollData>[
        pulse   ?? PollData.placeholder('pulse'),
        horizon ?? PollData.placeholder('horizon'),
        icePoll ?? PollData.placeholder('ice_breaker'),
      ];
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _viewResonance(String pollId) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, _, _) => ResonanceScreen(pollId: pollId, showBackButton: true),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  void _openRecording(String question, String pollId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordingSheet(question: question, pollId: pollId),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark   = Theme.of(context).brightness == Brightness.dark;
    final subColor = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final fg       = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final bg       = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final isDetail = widget.pollId != null;

    final body = SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isDetail)
            IconButton(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              icon: Icon(Icons.arrow_back_rounded, color: fg, size: 22),
              onPressed: () => Navigator.of(context).pop(),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, isDetail ? 4 : 20, 20, 0),
            child: Text(
              'The Pulse',
              style: Theme.of(context).textTheme.displayMedium,
            ),
          ),
          Expanded(
            child: StreamBuilder<List<PollData>>(
              stream: _rotationStream,
              builder: (context, snapshot) {
                // ── Loading ─────────────────────────────────────────────
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const _LoadingView();
                }

                // ── Error ────────────────────────────────────────────────
                if (snapshot.hasError) {
                  debugPrint('[STEWYRT][PULSE] rotation stream ERROR: ${snapshot.error}');
                  return _ErrorView(message: snapshot.error.toString());
                }

                final polls = snapshot.data ?? [];

                // ── Empty (detail mode only — rotation always yields 3 slots) ──
                if (polls.isEmpty) {
                  return const _EmptyView();
                }

                final activeIdx   = _activeIndex.clamp(0, polls.length - 1);
                final currentPoll = polls[activeIdx];

                // ── Loaded ───────────────────────────────────────────────
                return Column(
                  children: [
                    // Page swiper — top 60%
                    Expanded(
                      flex: 60,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: PageView.builder(
                          controller: _pageController,
                          physics: kIsWeb
                              ? const PageScrollPhysics()
                              : const ClampingScrollPhysics(),
                          itemCount: polls.length,
                          itemBuilder: (context, index) {
                            final poll = polls[index];
                            final card = PollCard(
                              question:        poll.question,
                              category:        poll.category,
                              tier:            poll.tier,
                              onTap:           poll.isPlaceholder ? null : () => _openRecording(poll.question, poll.id),
                              onViewResonance: poll.isPlaceholder ? null : () => _viewResonance(poll.id),
                            );
                            return poll.isPlaceholder
                                ? Opacity(opacity: 0.4, child: card)
                                : card;
                          },
                        ),
                      ),
                    ),

                    // Dot indicator — driven by PageController, not a state variable
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(polls.length, (i) {
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width:  i == _activeIndex ? 16 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _activeIndex
                                  ? Theme.of(context).colorScheme.primary
                                  : subColor,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Sentiment stream — bottom 40%
                    Expanded(
                      flex: 40,
                      child: SentimentStream(
                        currentTopic: currentPoll.topic,
                        pollId:       currentPoll.id,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );

    if (isDetail) {
      return Scaffold(backgroundColor: bg, body: body);
    }
    return body;
  }
}

// ── State views ───────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final sub = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF444444)
        : const Color(0xFFCCCCCC);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: sub),
          ),
          const SizedBox(height: 16),
          Text(
            'Loading questions...',
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: sub),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final sub = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF444444)
        : const Color(0xFFCCCCCC);
    return Center(
      child: Text(
        'No questions right now.\nCheck back soon.',
        textAlign: TextAlign.center,
        style: GoogleFonts.spaceGrotesk(
          fontSize: 14, color: sub, height: 1.6,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    final sub = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF444444)
        : const Color(0xFFCCCCCC);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Could not load questions.\n$message',
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(fontSize: 13, color: sub, height: 1.6),
        ),
      ),
    );
  }
}
