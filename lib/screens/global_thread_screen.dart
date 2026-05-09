import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';

import '../widgets/sentiment_stream.dart' show ResponseItem;

class GlobalThreadScreen extends StatefulWidget {
  const GlobalThreadScreen({super.key, required this.emotionTag});

  final String emotionTag;

  @override
  State<GlobalThreadScreen> createState() => _GlobalThreadScreenState();
}

class _GlobalThreadScreenState extends State<GlobalThreadScreen> {
  static const _heavyEmotions = [
    'Depressed', 'Hopeless', 'Suicidal',
    'Furious', 'Anxious', 'Sad', 'Numb',
  ];
  static const _safetyThreshold = 15;

  final _pageController = PageController();
  final _player         = AudioPlayer();

  List<ResponseItem> _items       = [];
  bool _loading                   = true;
  int  _currentPage               = 0;
  int  _clipsListened             = 0;
  bool _safetyShown               = false;
  bool _hasSwipedOnce             = false;

  // Live player state
  bool     _isPlaying   = false;
  bool     _loadingAudio = false;
  bool     _audioError  = false;
  Duration _position    = Duration.zero;
  Duration _duration    = Duration.zero;

  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playerStateSub;

  bool get _isSensitive => _heavyEmotions.contains(widget.emotionTag);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _positionSub = _player.positionStream.listen(
      (p) { if (mounted) setState(() => _position = p); },
    );
    _durationSub = _player.durationStream.listen(
      (d) { if (mounted) setState(() => _duration = d ?? Duration.zero); },
    );
    _playerStateSub = _player.playerStateStream.listen((s) {
      if (mounted) setState(() => _isPlaying = s.playing);
      if (s.processingState == ProcessingState.completed) _autoAdvance();
    });
    _loadData();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('responses')
          .where(Filter.and(
            Filter.or(
              Filter('tone',    isEqualTo: widget.emotionTag),
              Filter('flavor',  isEqualTo: widget.emotionTag),
              Filter('essence', isEqualTo: widget.emotionTag),
            ),
            Filter('blocked', isNotEqualTo: true),
          ))
          .limit(50)
          .get();

      // Sort client-side (avoids composite index requirement on each or-field + createdAt)
      final items = snap.docs
          .map(ResponseItem.fromFirestore)
          .where((r) => r.audioPath.isNotEmpty)
          .toList()
        ..sort((a, b) =>
            (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));

      if (!mounted) return;
      setState(() {
        _items   = items;
        _loading = false;
      });
      if (items.isNotEmpty) _loadAndPlay(0);
    } catch (e) {
      debugPrint('[THREAD] Load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Audio ─────────────────────────────────────────────────────────────────

  Future<void> _loadAndPlay(int index) async {
    if (index < 0 || index >= _items.length) return;

    setState(() {
      _loadingAudio = true;
      _audioError   = false;
      _position     = Duration.zero;
      _duration     = Duration.zero;
    });

    try {
      await _player.stop();
      final url = await FirebaseStorage.instance
          .ref(_items[index].audioPath)
          .getDownloadURL();
      await _player.setUrl(url);
      _player.play();

      if (_isSensitive) {
        _clipsListened++;
        if (_clipsListened >= _safetyThreshold && !_safetyShown) {
          _safetyShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showSafetyModal();
          });
        }
      }
    } catch (e) {
      debugPrint('[THREAD] Audio error for index $index: $e');
      if (mounted) setState(() => _audioError = true);
    } finally {
      if (mounted) setState(() => _loadingAudio = false);
    }
  }

  void _autoAdvance() {
    if (_currentPage < _items.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage    = page;
      _hasSwipedOnce  = true;
    });
    _loadAndPlay(page);
  }

  // ── Safety net ────────────────────────────────────────────────────────────

  void _showSafetyModal() {
    _player.pause();
    showModalBottomSheet(
      context: context,
      isDismissible:     false,
      enableDrag:        false,
      backgroundColor:   Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SafetySheet(
        onContinue: () {
          Navigator.of(context).pop();
          setState(() {
            _clipsListened = 0;
            _safetyShown   = false;
          });
          _player.play();
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 1.5, color: Color(0xFF444444),
            ),
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return _EmptyState(tag: widget.emotionTag);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Vertical PageView ──────────────────────────────────────────────
          PageView.builder(
            controller:     _pageController,
            scrollDirection: Axis.vertical,
            onPageChanged:  _onPageChanged,
            itemCount:      _items.length,
            itemBuilder: (context, i) {
              final isCurrent = i == _currentPage;
              return _PageCard(
                item:       _items[i],
                isCurrent:  isCurrent,
                isPlaying:  isCurrent && _isPlaying,
                isLoading:  isCurrent && _loadingAudio,
                hasError:   isCurrent && _audioError,
                position:   isCurrent ? _position : Duration.zero,
                duration:   isCurrent ? _duration : Duration.zero,
                onPlayPause: () {
                  HapticFeedback.lightImpact();
                  _isPlaying ? _player.pause() : _player.play();
                },
                onSeek: (v) => _player.seek(
                  Duration(milliseconds: (v * _duration.inMilliseconds).round()),
                ),
                index: i,
                total: _items.length,
              );
            },
          ),

          // ── Fixed header ───────────────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Color(0xFFF5F5F5), size: 22),
                      onPressed: () {
                        _player.stop();
                        Navigator.of(context).pop();
                      },
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Text(
                        widget.emotionTag,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFF5F5F5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Swipe hint — fades after first swipe ───────────────────────────
          if (!_hasSwipedOnce && _items.length > 1)
            Positioned(
              bottom: 36, left: 0, right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.keyboard_arrow_down_rounded,
                      color: Color(0xFF3A3A3A), size: 22),
                  const SizedBox(height: 2),
                  Text(
                    'swipe to navigate',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 11, color: const Color(0xFF3A3A3A),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Page card ─────────────────────────────────────────────────────────────────

class _PageCard extends StatelessWidget {
  final ResponseItem item;
  final bool isCurrent;
  final bool isPlaying;
  final bool isLoading;
  final bool hasError;
  final Duration position;
  final Duration duration;
  final VoidCallback onPlayPause;
  final ValueChanged<double> onSeek;
  final int index;
  final int total;

  const _PageCard({
    required this.item,
    required this.isCurrent,
    required this.isPlaying,
    required this.isLoading,
    required this.hasError,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onSeek,
    required this.index,
    required this.total,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    const fg   = Color(0xFFF5F5F5);
    const sub  = Color(0xFF555555);
    const chipBg = Color(0xFF111111);

    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Question context — small, subdued at top
            Text(
              item.question,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 12, color: sub, height: 1.5,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),

            const Spacer(),

            // Native-language summary — the centrepiece
            Text(
              '"${item.summary}"',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
                color: fg,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 28),

            // Tone / flavor / essence chips
            Wrap(
              spacing: 8,
              children: [
                if (item.tone.isNotEmpty)    _chip(item.tone,    chipBg, fg),
                if (item.flavor.isNotEmpty)  _chip(item.flavor,  chipBg, fg),
                if (item.essence.isNotEmpty) _chip(item.essence, chipBg, fg),
              ],
            ),
            const SizedBox(height: 28),

            // Progress bar
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 1.5,
                thumbShape:   const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor:   fg,
                inactiveTrackColor: sub.withValues(alpha: 0.25),
                thumbColor:         fg,
                overlayColor:       fg.withValues(alpha: 0.08),
              ),
              child: Slider(
                value: progress,
                onChanged: duration.inMilliseconds > 0 ? onSeek : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(position),
                      style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub)),
                  Text(_fmt(duration),
                      style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub)),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Play / pause + counter
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLoading)
                  const SizedBox(
                    width: 56, height: 56,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFFF5F5F5),
                    ),
                  )
                else if (hasError)
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                        Icons.mic_off_rounded, color: Color(0xFFFF3B30), size: 24),
                  )
                else
                  GestureDetector(
                    onTap: onPlayPause,
                    child: Container(
                      width: 56, height: 56,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF5F5F5), shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.black, size: 30,
                      ),
                    ),
                  ),
                const SizedBox(width: 20),
                Text(
                  '${index + 1} / $total',
                  style: GoogleFonts.spaceGrotesk(fontSize: 12, color: sub),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg, borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.spaceGrotesk(
          fontSize: 12, fontWeight: FontWeight.w600, color: fg,
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String tag;
  const _EmptyState({required this.tag});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              icon: const Icon(Icons.arrow_back_rounded,
                  color: Color(0xFF555555), size: 22),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tag,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF333333),
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No voices here yet.',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 15, color: const Color(0xFF444444), height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Safety sheet ──────────────────────────────────────────────────────────────

class _SafetySheet extends StatelessWidget {
  final VoidCallback onContinue;
  const _SafetySheet({required this.onContinue});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 52),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 28),

          const Icon(Icons.favorite_rounded, color: Color(0xFFFF6B6B), size: 30),
          const SizedBox(height: 20),

          Text(
            "You've been sitting\nin the dark for a while.",
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFF5F5F5),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),

          Text(
            'Stewyrt is here to listen — and so are we. '
            'But if things are getting too heavy right now, '
            'there are humans who can help.',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14,
              color: const Color(0xFF888888),
              height: 1.65,
            ),
          ),
          const SizedBox(height: 28),

          _HotlineTile(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Crisis Text Line',
            detail: 'Text HOME to 741741',
          ),
          const SizedBox(height: 10),
          _HotlineTile(
            icon: Icons.call_outlined,
            label: 'Suicide & Crisis Lifeline',
            detail: 'Call or text 988',
          ),
          const SizedBox(height: 10),
          _HotlineTile(
            icon: Icons.language_rounded,
            label: 'Find local support',
            detail: 'findahelpline.com',
          ),
          const SizedBox(height: 28),

          GestureDetector(
            onTap: onContinue,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF222222)),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Text(
                "I'm okay — continue listening",
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF777777),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HotlineTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;

  const _HotlineTile({
    required this.icon,
    required this.label,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E1E1E)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFFF6B6B), size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFF5F5F5),
                  ),
                ),
                Text(
                  detail,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 12, color: const Color(0xFF777777),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              color: Color(0xFF333333), size: 20),
        ],
      ),
    );
  }
}
