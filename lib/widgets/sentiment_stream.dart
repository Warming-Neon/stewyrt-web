import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import '../services/resonance_controller.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class ResponseItem {
  final String id;
  final String tone;
  final String flavor;
  final String essence;
  final String summary;
  final String question;
  final String audioPath;
  final DateTime? createdAt;
  final String uid;

  const ResponseItem({
    required this.id,
    required this.tone,
    required this.flavor,
    required this.essence,
    required this.summary,
    required this.question,
    required this.audioPath,
    required this.createdAt,
    required this.uid,
  });

  factory ResponseItem.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return ResponseItem(
      id:        doc.id,
      tone:      d['tone']      as String? ?? '',
      flavor:    d['flavor']    as String? ?? '',
      essence:   d['essence']   as String? ?? '',
      summary:   d['summary']   as String? ?? '',
      question:  d['question']  as String? ?? '',
      audioPath: _resolveAudioPath(d, doc.id),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      uid:       d['uid']       as String? ?? '',
    );
  }

  /// Resolves the Firebase Storage path for this response's audio clip.
  ///
  /// Priority:
  ///   1. `audioPath` field — written by current Cloud Function
  ///   2. `uuid` field — present in new-format docs
  ///   3. Doc ID — old responses used the upload UUID as their document ID
  static String _resolveAudioPath(Map<String, dynamic> d, String docId) {
    final stored = d['audioPath'] as String?;
    if (stored != null && stored.isNotEmpty) return stored;

    final uuid = d['uuid'] as String?;
    if (uuid != null && uuid.isNotEmpty) return 'audio_uploads/$uuid.m4a';

    // Old format: doc ID is the raw UUID (36 chars with hyphens).
    if (docId.length == 36 && docId.contains('-')) {
      return 'audio_uploads/$docId.m4a';
    }

    return '';
  }
}

// ── Widget ────────────────────────────────────────────────────────────────────

class SentimentStream extends StatefulWidget {
  final String currentTopic;
  final String pollId;

  const SentimentStream({
    super.key,
    required this.currentTopic,
    required this.pollId,
  });

  @override
  State<SentimentStream> createState() => _SentimentStreamState();
}

class _SentimentStreamState extends State<SentimentStream> {
  StreamSubscription? _streamSub;
  StreamSubscription? _blocklistSub;
  final Set<String> _personallyBlocked = {};
  final List<ResponseItem> _displayItems = [];
  late GlobalKey<AnimatedListState> _listKey;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _subscribeToStream();
    _loadPersonalBlocklist();
  }

  @override
  void didUpdateWidget(SentimentStream old) {
    super.didUpdateWidget(old);
    if (old.pollId != widget.pollId) {
      _subscribeToStream();
    }
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _blocklistSub?.cancel();
    super.dispose();
  }

  void _loadPersonalBlocklist() {
    _blocklistSub?.cancel();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _blocklistSub = FirebaseFirestore.instance
        .collection('user_blocks')
        .doc(user.uid)
        .collection('blocked_responses')
        .snapshots()
        .listen((snapshot) {
      final blockedIds = snapshot.docs
          .map((doc) => doc.data()['responseId'] as String?)
          .whereType<String>()
          .toSet();
      if (mounted) {
        setState(() {
          _personallyBlocked.clear();
          _personallyBlocked.addAll(blockedIds);
          // Apply filter to current display items immediately
          for (int i = _displayItems.length - 1; i >= 0; i--) {
            if (_personallyBlocked.contains(_displayItems[i].id)) {
              final removedItem = _displayItems.removeAt(i);
              _listKey.currentState?.removeItem(
                i,
                (context, animation) => _buildItem(removedItem, animation),
                duration: const Duration(milliseconds: 600),
              );
            }
          }
        });
      }
    });
  }

  void _subscribeToStream() {
    _listKey = GlobalKey<AnimatedListState>();
    _streamSub?.cancel();
    _initialized = false;
    _displayItems.clear();

    _streamSub = FirebaseFirestore.instance
        .collection('responses')
        .where('pollId', isEqualTo: widget.pollId)
        .where('blocked', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .limit(30)
        .snapshots()
        .listen((snapshot) {
          final docs = snapshot.docs;
          final newItems = docs
              .map((d) => ResponseItem.fromFirestore(d))
              .where((r) => r.tone.isNotEmpty)
              .where((r) => !_personallyBlocked.contains(r.id))
              .toList();

          if (!mounted) return;

          if (!_initialized) {
            setState(() {
              _displayItems.addAll(newItems);
              _initialized = true;
            });
          } else {
            setState(() {
              _updateList(newItems);
            });
          }
        });
  }

  void _updateList(List<ResponseItem> newItems) {
    // 1. Removals
    for (int i = _displayItems.length - 1; i >= 0; i--) {
      final oldItem = _displayItems[i];
      final exists = newItems.any((item) => item.id == oldItem.id);
      if (!exists) {
        final removedItem = _displayItems.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, animation) => _buildItem(removedItem, animation),
          duration: const Duration(milliseconds: 600),
        );
      }
    }

    // 2. Insertions & Updates
    for (int i = 0; i < newItems.length; i++) {
      final newItem = newItems[i];
      final existingIndex = _displayItems.indexWhere((item) => item.id == newItem.id);
      if (existingIndex == -1) {
        _displayItems.insert(i, newItem);
        _listKey.currentState?.insertItem(
          i,
          duration: const Duration(milliseconds: 600),
        );
      } else if (existingIndex != i) {
        final item = _displayItems.removeAt(existingIndex);
        _displayItems.insert(i, item);
      }
    }
  }

  String _timeAgo(DateTime? dt) {
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _showPlayer(BuildContext context, List<ResponseItem> items, int index) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _FeedPlayerSheet(
        items: items,
        initialIndex: index,
        pollId: widget.pollId,
      ),
    );
  }

  void _showReportSheet(BuildContext context, ResponseItem item) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<dynamic>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReportSheet(item: item),
    ).then((result) {
      if (result == true) {
        if (mounted) {
          setState(() {
            _personallyBlocked.add(item.id);
            // Remove the item from display items immediately
            for (int i = _displayItems.length - 1; i >= 0; i--) {
              if (_displayItems[i].id == item.id) {
                final removedItem = _displayItems.removeAt(i);
                _listKey.currentState?.removeItem(
                  i,
                  (context, animation) => _buildItem(removedItem, animation),
                  duration: const Duration(milliseconds: 600),
                );
              }
            }
          });
        }
      }
    });
  }

  Widget _buildItem(ResponseItem item, Animation<double> animation) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final fg      = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final sub     = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final border  = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEEEEEE);

    return FadeTransition(
      opacity: animation,
      child: Column(
        children: [
          GestureDetector(
            onTap: () {
              final idx = _displayItems.indexWhere((r) => r.id == item.id);
              if (idx != -1) {
                _showPlayer(context, _displayItems, idx);
              }
            },
            onLongPress: () => _showReportSheet(context, item),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.tone,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: fg,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '"${item.summary}"',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 12,
                            color: sub,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _timeAgo(item.createdAt),
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 11, color: sub,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(color: border, height: 1),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final fg      = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final sub     = isDark ? const Color(0xFF666666) : const Color(0xFF999999);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            children: [
              Container(
                width: 6, height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF00BFA5), shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'LIVE · ${widget.currentTopic.toUpperCase()}',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: sub,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
              Text(
                'tap to listen',
                style: GoogleFonts.spaceGrotesk(fontSize: 10, color: sub),
              ),
            ],
          ),
        ),

        // Live feed
        Expanded(
          child: Builder(
            builder: (context) {
              if (!_initialized) {
                return Center(
                  child: SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: sub,
                    ),
                  ),
                );
              }

              if (_displayItems.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.mic_none_outlined,
                          size: 32,
                          color: sub.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Be the first to share what you really think.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 15, fontWeight: FontWeight.w500, color: fg,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Press and hold to record.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.spaceGrotesk(fontSize: 12, color: sub),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return AnimatedList(
                key: _listKey,
                initialItemCount: _displayItems.length,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemBuilder: (context, index, animation) {
                  return _buildItem(_displayItems[index], animation);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Feed player sheet ─────────────────────────────────────────────────────────

class _FeedPlayerSheet extends StatefulWidget {
  final List<ResponseItem> items;
  final int initialIndex;
  final String pollId;

  const _FeedPlayerSheet({
    required this.items,
    required this.initialIndex,
    required this.pollId,
  });

  @override
  State<_FeedPlayerSheet> createState() => _FeedPlayerSheetState();
}

class _FeedPlayerSheetState extends State<_FeedPlayerSheet> with SingleTickerProviderStateMixin {
  late List<int> _order;   // indices into widget.items, may be shuffled
  late int _orderIndex;    // current position in _order

  bool _shuffle    = false;
  bool _repeatAll  = false;
  bool _loadingUrl  = false;
  bool _isPlaying   = false;
  bool _audioError  = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  final _player = AudioPlayer();
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _blockSub;

  late AnimationController _animationController;

  ResponseItem? get _current {
    if (widget.items.isEmpty || 
        _orderIndex >= widget.items.length ||
        _order.isEmpty ||
        _orderIndex >= _order.length) return null;
    final idx = _order[_orderIndex];
    if (idx >= widget.items.length) return null;
    return widget.items[idx];
  }

  @override
  void initState() {
    super.initState();
    _order      = List.generate(widget.items.length, (i) => i);
    _orderIndex = widget.initialIndex;

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
      value: 1.0,
    );

    _positionSub = _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durationSub = _player.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d ?? Duration.zero);
    });
    _playerStateSub = _player.playerStateStream.listen((s) {
      if (mounted) setState(() => _isPlaying = s.playing);
      if (s.processingState == ProcessingState.completed) _onTrackCompleted();
    });

    _loadAndPlay(_orderIndex, play: false);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _blockSub?.cancel();
    _animationController.dispose();
    _player.dispose();
    super.dispose();
  }

  void _handleContentRemoved() async {
    if (!mounted) return;
    await _player.pause();
    try {
      await _player.setUrl('about:blank');
    } catch (_) {}
    if (!mounted) return;
    await _animationController.reverse();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'This response is no longer available',
          style: GoogleFonts.spaceGrotesk(),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _loadAndPlay(int orderIdx, {bool play = true}) async {
    if (mounted) setState(() { _loadingUrl = true; _audioError = false; _position = Duration.zero; _duration = Duration.zero; });
    final item = widget.items[_order[orderIdx]];

    _blockSub?.cancel();
    _blockSub = FirebaseFirestore.instance
        .collection('responses')
        .doc(item.id)
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          final data = snap.data();
          if (data != null && data['blocked'] == true) {
            _handleContentRemoved();
          }
        });

    if (item.audioPath.isEmpty) {
      debugPrint('[STEWYRT][PLAYER] No audioPath for item ${item.id}');
      if (mounted) setState(() { _loadingUrl = false; _audioError = true; });
      return;
    }

    try {
      final url = await FirebaseStorage.instance.ref(item.audioPath).getDownloadURL();
      debugPrint('[STEWYRT][PLAYER] Loading: ${item.audioPath}');
      await _player.setUrl(url);
      if (play) _player.play(); // intentionally not awaited — play() resolves on completion, not on start
    } catch (e) {
      debugPrint('[STEWYRT][PLAYER] Failed to load audio: $e');
      if (mounted) setState(() => _audioError = true);
    } finally {
      if (mounted) setState(() => _loadingUrl = false);
    }
  }

  void _onTrackCompleted() {
    if (_repeatAll || _orderIndex < _order.length - 1) {
      _goNext();
    }
  }

  Future<void> _goNext() async {
    HapticFeedback.lightImpact();
    await _player.stop();
    setState(() => _orderIndex = (_orderIndex + 1) % _order.length);
    _loadAndPlay(_orderIndex);
  }

  Future<void> _goPrev() async {
    HapticFeedback.lightImpact();
    // If more than 3s in, restart current; otherwise go back.
    if (_position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    await _player.stop();
    setState(() => _orderIndex = (_orderIndex - 1 + _order.length) % _order.length);
    _loadAndPlay(_orderIndex);
  }

  void _toggleShuffle() {
    HapticFeedback.lightImpact();
    setState(() {
      _shuffle = !_shuffle;
      if (_shuffle) {
        final currentItem = _order[_orderIndex];
        _order.shuffle();
        _order.remove(currentItem);
        _order.insert(0, currentItem);
        _orderIndex = 0;
      } else {
        final currentItem = _order[_orderIndex];
        _order      = List.generate(widget.items.length, (i) => i);
        _orderIndex = currentItem;
      }
    });
  }

  void _toggleRepeat() {
    HapticFeedback.lightImpact();
    setState(() => _repeatAll = !_repeatAll);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final fg     = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final sub    = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final chip   = isDark ? const Color(0xFF111111) : const Color(0xFFF0F0F0);
    final handle = sub.withValues(alpha: 0.4);
    final item   = _current;
    if (item == null) return const SizedBox.shrink();

    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return FadeTransition(
      opacity: _animationController,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: handle, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 24),

            // Tag chips — tap any to jump to Resonance and focus that synapse
            Row(
              children: [
                Expanded(child: _Chip(label: 'TONE',    value: item.tone,    bg: chip, fg: fg, sub: sub,
                  onTap: item.tone.isEmpty ? null : () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).pop();
                    ResonanceController.goToResonanceAndFocus(item.tone, pollId: widget.pollId);
                  },
                )),
                const SizedBox(width: 8),
                Expanded(child: _Chip(label: 'FLAVOR',  value: item.flavor,  bg: chip, fg: fg, sub: sub,
                  onTap: item.flavor.isEmpty ? null : () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).pop();
                    ResonanceController.goToResonanceAndFocus(item.flavor, pollId: widget.pollId);
                  },
                )),
                const SizedBox(width: 8),
                Expanded(child: _Chip(label: 'ESSENCE', value: item.essence, bg: chip, fg: fg, sub: sub,
                  onTap: item.essence.isEmpty ? null : () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).pop();
                    ResonanceController.goToResonanceAndFocus(item.essence, pollId: widget.pollId);
                  },
                )),
              ],
            ),
            const SizedBox(height: 18),

            // Summary
            Text(
              '"${item.summary}"',
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 17, fontWeight: FontWeight.w500,
                fontStyle: FontStyle.italic, color: fg, height: 1.4,
              ),
            ),
            const SizedBox(height: 20),

            // Progress slider
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape:   const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor:   fg,
                inactiveTrackColor: sub.withValues(alpha: 0.2),
                thumbColor:         fg,
                overlayColor:       fg.withValues(alpha: 0.08),
              ),
              child: Slider(
                value: progress,
                onChanged: _duration.inMilliseconds > 0
                    ? (v) => _player.seek(
                        Duration(milliseconds: (v * _duration.inMilliseconds).round()))
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(_position), style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub)),
                  Text(_fmt(_duration), style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub)),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Transport controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Shuffle
                IconButton(
                  icon: Icon(Icons.shuffle_rounded, size: 22,
                      color: _shuffle ? fg : sub.withValues(alpha: 0.5)),
                  onPressed: _toggleShuffle,
                ),
                // Previous
                IconButton(
                  icon: Icon(Icons.skip_previous_rounded, size: 34, color: fg),
                  onPressed: _goPrev,
                ),
                // Play / pause
                if (_loadingUrl)
                  SizedBox(
                    width: 56, height: 56,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                else if (_audioError)
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.mic_off_rounded,
                        color: Color(0xFFFF3B30), size: 24),
                  )
                else
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _isPlaying ? _player.pause() : _player.play();
                    },
                    child: Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                      child: Icon(
                        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: bg, size: 30,
                      ),
                    ),
                  ),
                // Next
                IconButton(
                  icon: Icon(Icons.skip_next_rounded, size: 34, color: fg),
                  onPressed: _goNext,
                ),
                // Repeat all
                IconButton(
                  icon: Icon(Icons.repeat_rounded, size: 22,
                      color: _repeatAll ? fg : sub.withValues(alpha: 0.5)),
                  onPressed: _toggleRepeat,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Question context
            Text(
              item.question,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tag chip ──────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  final Color bg;
  final Color fg;
  final Color sub;
  final VoidCallback? onTap;

  const _Chip({
    required this.label,
    required this.value,
    required this.bg,
    required this.fg,
    required this.sub,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: bg, borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 9, fontWeight: FontWeight.w700,
              color: sub, letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14, fontWeight: FontWeight.w700, color: fg,
            ),
          ),
        ],
      ),
    ),
    );
  }
}

// ── Report sheet ──────────────────────────────────────────────────────────────

class _ReportSheet extends StatefulWidget {
  final ResponseItem item;
  const _ReportSheet({required this.item});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  bool _showReasons = false;
  bool _submitting  = false;
  bool _submitted   = false;
  bool _deleting    = false;

  static const _reasons = [
    'harassment',
    'hate_speech',
    'spam',
    'other',
    'child_safety',
  ];

  String _getReasonLabel(String reason) {
    switch (reason) {
      case 'harassment':
        return 'Harassment or abuse';
      case 'hate_speech':
        return 'Hate speech';
      case 'spam':
        return 'Spam or fake';
      case 'other':
        return 'Other';
      case 'child_safety':
        return 'Child safety concern';
      default:
        return reason;
    }
  }

  Future<void> _submit(String reason) async {
    final nav = Navigator.of(context);
    setState(() => _submitting = true);
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('submitContentReport')
          .call({'responseId': widget.item.id, 'reason': reason});
      
      bool isPersonalBlock = false;
      if (result.data is Map) {
        isPersonalBlock = (result.data['personalBlock'] == true);
      }

      if (!mounted) return;
      setState(() { _submitting = false; _submitted = true; });
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) nav.pop(isPersonalBlock);
    } catch (e) {
      debugPrint('[STEWYRT][REPORT] submitContentReport failed: $e');
      if (mounted) nav.pop();
    }
  }

  Future<void> _deleteResponse() async {
    final nav = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    setState(() => _deleting = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('deleteOwnResponse')
          .call({'responseId': widget.item.id});
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(
              'Your response has been removed',
              style: GoogleFonts.spaceGrotesk(),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
        nav.pop();
      }
    } catch (e) {
      debugPrint('[STEWYRT][REPORT] deleteOwnResponse failed: $e');
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(
              'Failed to remove response. Please try again.',
              style: GoogleFonts.spaceGrotesk(),
            ),
          ),
        );
        setState(() => _deleting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? const Color(0xFF111111) : Colors.white;
    final fg     = isDark ? const Color(0xFFF5F5F5) : Colors.black;
    final sub    = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEEEEEE);
    final handle = sub.withValues(alpha: 0.4);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: handle, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 24),

            if (_submitted) ...[
              const Icon(Icons.check_circle_outline_rounded,
                  color: Color(0xFF3DDEC0), size: 40),
              const SizedBox(height: 16),
              Text(
                'Report submitted',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 16, fontWeight: FontWeight.w600, color: fg),
              ),
              const SizedBox(height: 8),
              Text(
                'Thank you — our team will review this.',
                style: GoogleFonts.spaceGrotesk(fontSize: 13, color: sub),
              ),
              const SizedBox(height: 8),
            ] else if (_submitting) ...[
              SizedBox(
                width: 28, height: 28,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: fg),
              ),
              const SizedBox(height: 16),
              Text(
                'Submitting...',
                style: GoogleFonts.spaceGrotesk(fontSize: 14, color: sub),
              ),
              const SizedBox(height: 8),
            ] else if (_deleting) ...[
              SizedBox(
                width: 28, height: 28,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: fg),
              ),
              const SizedBox(height: 16),
              Text(
                'Removing response...',
                style: GoogleFonts.spaceGrotesk(fontSize: 14, color: sub),
              ),
              const SizedBox(height: 8),
            ] else if (!_showReasons) ...[
              Text(
                'OPTIONS',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: sub, letterSpacing: 1.8),
              ),
              const SizedBox(height: 16),
              if (widget.item.uid.isNotEmpty &&
                  widget.item.uid == FirebaseAuth.instance.currentUser?.uid)
                _SheetRow(
                  label: 'Remove my response',
                  fg: fg, border: border,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    _deleteResponse();
                  },
                ),
              _SheetRow(
                label: 'Report this response',
                fg: Colors.redAccent, border: border,
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _showReasons = true);
                },
              ),
              _SheetRow(
                label: 'Cancel',
                fg: fg, border: Colors.transparent,
                onTap: () => Navigator.of(context).pop(),
              ),
            ] else ...[
              Text(
                'Why are you reporting this?',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 15, fontWeight: FontWeight.w600, color: fg),
              ),
              const SizedBox(height: 20),
              ..._reasons.map((r) => _SheetRow(
                label: _getReasonLabel(r),
                fg: fg, border: border,
                onTap: () { HapticFeedback.lightImpact(); _submit(r); },
              )),
              _SheetRow(
                label: 'Back',
                fg: sub, border: Colors.transparent,
                onTap: () => setState(() => _showReasons = false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    required this.fg,
    required this.border,
    required this.onTap,
  });

  final String label;
  final Color fg;
  final Color border;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 15, fontWeight: FontWeight.w500, color: fg,
          ),
        ),
      ),
    );
  }
}
