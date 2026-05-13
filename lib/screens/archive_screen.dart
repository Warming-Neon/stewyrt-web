import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'pulse_screen.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class _ArchivePoll {
  final String id;
  final String question;
  final String category;
  final String topic;
  final int totalSubmissions;
  final DateTime createdAt;

  const _ArchivePoll({
    required this.id,
    required this.question,
    required this.category,
    required this.topic,
    required this.totalSubmissions,
    required this.createdAt,
  });

  factory _ArchivePoll.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final ts = d['createdAt'];
    return _ArchivePoll(
      id:               doc.id,
      question:         d['question']           as String? ?? '',
      category:         d['category']           as String? ?? '',
      topic:            d['topic']              as String? ?? '',
      totalSubmissions: (d['total_submissions'] as num?)?.toInt() ?? 0,
      createdAt:        ts != null ? (ts as Timestamp).toDate() : DateTime(2024),
    );
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  static const _filters = [
    'All', 'Existential', 'Fun', 'Current Events',
    'Nostalgia', 'Family', '2024', '2025',
  ];
  static const _yearFilters = {'2024', '2025'};

  String _selected = 'All';
  StreamSubscription? _sub;
  List<_ArchivePoll> _polls = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseFirestore.instance
        .collection('polls')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _polls = snap.docs.map(_ArchivePoll.fromDoc).toList();
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<_ArchivePoll> get _filtered {
    if (_selected == 'All') return _polls;
    if (_yearFilters.contains(_selected)) {
      final year = int.parse(_selected);
      return _polls.where((p) => p.createdAt.year == year).toList();
    }
    return _polls.where((p) => p.category == _selected).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final bg      = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final fg      = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final sub     = isDark ? const Color(0xFF555555) : const Color(0xFFAAAAAA);
    final border  = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEEEEEE);
    final cardBg  = isDark ? const Color(0xFF080808) : const Color(0xFFF8F8F8);

    final filtered = _filtered;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text('The Archive', style: Theme.of(context).textTheme.displayMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              'Past questions',
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: sub),
            ),
          ),

          // ── Filter chips ─────────────────────────────────────────────────
          SizedBox(
            height: 34,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final f = _filters[i];
                final active = f == _selected;
                return GestureDetector(
                  onTap: () => setState(() => _selected = f),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: active ? fg : bg,
                      border: Border.all(color: active ? fg : border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      f,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: active ? bg : sub,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // ── Grid ─────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? Center(
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: sub),
                    ),
                  )
                : filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_outlined,
                              size: 32,
                              color: sub.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Nothing here yet.',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 15, fontWeight: FontWeight.w500, color: fg,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Try a different filter.',
                              style: GoogleFonts.spaceGrotesk(fontSize: 12, color: sub),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 0.78,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) =>
                            _PollCard(
                              poll: filtered[i],
                              fg: fg,
                              sub: sub,
                              border: border,
                              cardBg: cardBg,
                            ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Card widget ───────────────────────────────────────────────────────────────

class _PollCard extends StatelessWidget {
  final _ArchivePoll poll;
  final Color fg;
  final Color sub;
  final Color border;
  final Color cardBg;

  const _PollCard({
    required this.poll,
    required this.fg,
    required this.sub,
    required this.border,
    required this.cardBg,
  });

  @override
  Widget build(BuildContext context) {
    final label = poll.topic.isNotEmpty ? poll.topic : poll.category;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PulseScreen(pollId: poll.id)),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          border: Border.all(color: border, width: 1),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Category / topic label
            Text(
              label.toUpperCase(),
              style: GoogleFonts.spaceGrotesk(
                fontSize: 9,
                color: sub,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),

            // Question text
            Expanded(
              child: Text(
                poll.question,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  height: 1.4,
                ),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),

            // Divider
            Container(height: 1, color: border),
            const SizedBox(height: 10),

            // Response count
            Row(
              children: [
                Icon(Icons.mic_none_rounded, size: 11, color: sub),
                const SizedBox(width: 4),
                Text(
                  '${_fmt(poll.totalSubmissions)} responses',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11,
                    color: sub,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}
