import 'package:appinio_swiper/appinio_swiper.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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

  const PollData({
    required this.id,
    required this.question,
    required this.category,
    required this.topic,
    required this.tier,
  });

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

// ── Stream ────────────────────────────────────────────────────────────────────

Stream<List<PollData>> _pollsStream({String? filterPollId}) {
  if (filterPollId != null) {
    return FirebaseFirestore.instance
        .collection('polls')
        .doc(filterPollId)
        .snapshots()
        .map((doc) => doc.exists ? [PollData.fromFirestore(doc)] : <PollData>[]);
  }
  debugPrint('[STEWYRT][PULSE] Attaching polls stream');
  return FirebaseFirestore.instance
      .collection('polls')
      .where('isActive', isEqualTo: true)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) {
        debugPrint('[STEWYRT][PULSE] polls snapshot — ${snap.docs.length} docs');
        return snap.docs.map(PollData.fromFirestore).toList();
      });
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
  AppinioSwiperController _swiperController = AppinioSwiperController();
  int _currentIndex = 0;

  // Track the last known poll list so we can reset the swiper when it changes.
  List<PollData> _lastPolls = [];

  @override
  void dispose() {
    _swiperController.dispose();
    super.dispose();
  }

  void _viewResonance(String pollId) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, _, _) => ResonanceScreen(pollId: pollId),
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
              stream: _pollsStream(filterPollId: widget.pollId),
              builder: (context, snapshot) {
                // ── Loading ────────────────────────────────────────────────
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const _LoadingView();
                }

                // ── Error ──────────────────────────────────────────────────
                if (snapshot.hasError) {
                  debugPrint('[STEWYRT][PULSE] polls stream ERROR: ${snapshot.error}');
                  return _ErrorView(message: snapshot.error.toString());
                }

                final polls = snapshot.data ?? [];

                // ── Empty ──────────────────────────────────────────────────
                if (polls.isEmpty) {
                  return const _EmptyView();
                }

                // Clamp index and reset swiper controller if the list changed.
                if (polls.length != _lastPolls.length) {
                  _lastPolls = polls;
                  _currentIndex = _currentIndex.clamp(0, polls.length - 1);
                  _swiperController.dispose();
                  _swiperController = AppinioSwiperController();
                }

                final currentPoll = polls[_currentIndex];

                // ── Loaded ─────────────────────────────────────────────────
                return Column(
                  children: [
                    // Swiper — top 60%
                    Expanded(
                      flex: 60,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: AppinioSwiper(
                          key: ValueKey(polls.length),
                          controller: _swiperController,
                          cardCount: polls.length,
                          loop: true,
                          onSwipeEnd: (previousIndex, targetIndex, activity) {
                            setState(() {
                              _currentIndex = targetIndex % polls.length;
                            });
                          },
                          cardBuilder: (context, index) {
                            final poll = polls[index % polls.length];
                            return PollCard(
                              question: poll.question,
                              category: poll.category,
                              tier: poll.tier,
                              onTap: () => _openRecording(poll.question, poll.id),
                              onViewResonance: () => _viewResonance(poll.id),
                            );
                          },
                        ),
                      ),
                    ),

                    // Dot indicator
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(polls.length, (i) {
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width:  i == _currentIndex ? 16 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _currentIndex
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
                      child: SentimentStream(currentTopic: currentPoll.topic),
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
