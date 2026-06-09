import 'dart:async';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/phrase_service.dart';
import '../services/resonance_controller.dart';
import '../services/auth_service.dart';
import '../widgets/mic_permission_banner.dart';
import '../services/firestore_service.dart';
import '../services/storage_service.dart';
import '../utils/limiter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ⚠️  PRODUCTION TOGGLE — flip to true before App Store / Play Store release.
//
// FALSE (beta): every submission gets a fresh UUID document so one device can
//               populate multiple test responses to the same poll.
//
// TRUE  (production): one response per user per poll.  The old document is
//               deleted BEFORE the listener is attached, so Firestore never
//               returns stale analysis. (This was the bug in beta — the listener
//               fired immediately on the existing doc and returned the previous
//               result instead of waiting for the new Cloud Function run.)
// ─────────────────────────────────────────────────────────────────────────────
const bool _kProductionMode = false;

enum _RecordState { idle, recording, previewing, waiting, results, blocked }

class RecordingSheet extends StatefulWidget {
  final String question;
  final String pollId;
  const RecordingSheet({super.key, required this.question, required this.pollId});

  @override
  State<RecordingSheet> createState() => _RecordingSheetState();
}

class _RecordingSheetState extends State<RecordingSheet>
    with WidgetsBindingObserver {
  _RecordState _state = _RecordState.idle;

  AudioRecorder _recorder = AudioRecorder(); // recreated between sessions
  final _player   = AudioPlayer();
  final _limiter  = const SoftLimiter();

  // Microphone permission
  bool _micPermissionDenied = false;

  // Live waveform
  final List<double> _liveSamples = [];
  final List<double> _rawAmplitudes = [];
  bool _pressActive = false; // tracks whether the pointer is still held down

  // Recording clock + 30-second hard cutoff
  DateTime? _recordStartTime;
  Duration _recordDuration = Duration.zero;
  Timer? _clockTimer;
  Timer? _maxDurationTimer;
  StreamSubscription<Amplitude>? _ampSub;

  // Playback
  Duration _playPosition = Duration.zero;
  Duration _playTotal    = Duration.zero;
  bool _isPlaying        = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;

  // Submission pipeline
  String? _pendingPath;
  Timer? _phraseTimer;
  StreamSubscription? _firestoreSub;
  String? _blockedResponseId;
  AnalysisResult? _result;

  // Staggered reveal flags
  bool _showTone    = false;
  bool _showFlavor  = false;
  bool _showEssence = false;
  bool _showSummary = false;
  bool _showDone    = false;

  // ── Waiting room story data ────────────────────────────────────────────────

  List<String> _currentStory = [];
  int _storyIndex = 0;

  List<String> _generateNewStory() => PhraseService.instance.generateStory();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    AuthService.signInAnonymously();
    PhraseService.instance.prefetch();
    WidgetsBinding.instance.addObserver(this);
    _checkMicPermission();
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    _clockTimer?.cancel();
    _maxDurationTimer?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _phraseTimer?.cancel();
    _firestoreSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkMicPermission() async {
    if (kIsWeb) return;
    final status = await Permission.microphone.status;
    if (!mounted) return;
    setState(() => _micPermissionDenied = !status.isGranted);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkMicPermission();
  }

  // ── Recorder reset ────────────────────────────────────────────────────────
  // The record package's onAmplitudeChanged stream is single-subscription and
  // tied to the AudioRecorder instance. Once listened+cancelled, you cannot
  // re-subscribe — you must dispose and create a fresh instance.

  Future<void> _resetRecorder() async {
    await _ampSub?.cancel();
    _ampSub = null;
    await _recorder.dispose();
    _recorder = AudioRecorder();
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _onPressDown() async {
    if (_state != _RecordState.idle) return;
    // Lock state and set press flag synchronously — before any await.
    // This prevents (a) a second rapid press slipping through the idle check
    // before state changes, and (b) _onPressUp seeing stale state.
    _pressActive = true;
    setState(() => _state = _RecordState.recording);
    HapticFeedback.mediumImpact();
    debugPrint('[STEWYRT][RECORD] Press down — checking mic permission...');

    // Permission was pre-requested in initState so this returns instantly.
    // If false, user denied in Settings after the initial prompt.
    final hasPermission = await _recorder.hasPermission();
    debugPrint('[STEWYRT][RECORD] Mic permission: $hasPermission');

    if (!hasPermission) {
      _pressActive = false;
      if (mounted) setState(() { _state = _RecordState.idle; _micPermissionDenied = true; });
      return;
    }
    if (!mounted) {
      _pressActive = false;
      return;
    }

    final path = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    debugPrint('[STEWYRT][RECORD] Recording to: $path');

    await _recorder.start(
      const RecordConfig(
        encoder:      AudioEncoder.aacLc,
        bitRate:      128000,
        sampleRate:   44100,
        numChannels:  1,
        autoGain:     true,
        noiseSuppress: true,
      ),
      path: path,
    );
    debugPrint('[STEWYRT][RECORD] Recording started');

    _recordStartTime = DateTime.now();
    _rawAmplitudes.clear();

    // If the press was released while start() was awaiting, abort cleanly.
    if (!_pressActive) {
      debugPrint('[STEWYRT][RECORD] Press released before start completed — aborting');
      await _recorder.stop();
      await _resetRecorder();
      if (mounted) setState(() => _state = _RecordState.idle);
      return;
    }

    _liveSamples.clear();

    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 50))
        .listen((amp) {
      if (!mounted) return;
      setState(() {
        _rawAmplitudes.add(kIsWeb
            ? SoftLimiter.webProcess(amp.current)
            : amp.current);
        _liveSamples.add(kIsWeb
            ? SoftLimiter.webProcess(amp.current)
            : _limiter.process(amp.current));
      });
    });

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordDuration += const Duration(seconds: 1));
    });

    // Auto-stop at 30 seconds.
    _maxDurationTimer = Timer(const Duration(seconds: 30), () {
      debugPrint('[STEWYRT][RECORD] 30s limit reached — auto-stopping recording');
      HapticFeedback.mediumImpact();
      _onPressUp();
    });

    setState(() => _recordDuration = Duration.zero);
  }

  Future<void> _onPressUp() async {
    _pressActive = false;
    if (_state != _RecordState.recording) return;
    HapticFeedback.lightImpact();
    debugPrint('[STEWYRT][RECORD] Press up — stopping recording after ${_recordDuration.inSeconds}s');

    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;
    await _ampSub?.cancel();
    _clockTimer?.cancel();

    // Calculate quality metrics BEFORE stopping (or right after)
    final startTime = _recordStartTime;
    final duration = startTime != null
        ? DateTime.now().difference(startTime)
        : _recordDuration;
    
    final avgAmp = _rawAmplitudes.isEmpty
        ? -100.0
        : _rawAmplitudes.reduce((a, b) => a + b) / _rawAmplitudes.length;
    
    debugPrint('[STEWYRT][RECORD] Quality check — duration: ${duration.inMilliseconds}ms, avg amplitude: ${avgAmp.toStringAsFixed(2)}dB');

    if (duration.inMilliseconds < 2000 || (kIsWeb ? avgAmp < 0.01 : avgAmp < -50.0)) {
      debugPrint('[STEWYRT][RECORD] ❌ Recording rejected — too short or silent');
      await _recorder.stop();
      await _resetRecorder();
      if (mounted) {
        setState(() {
          _state = _RecordState.idle;
          _liveSamples.clear();
          _rawAmplitudes.clear();
          _recordDuration = Duration.zero;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("We didn't catch anything — make sure your mic is on and give us a few seconds!"),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final path = await _recorder.stop();
    debugPrint('[STEWYRT][RECORD] Recorder stopped — file path: $path');
    if (path == null || !mounted) return;

    _pendingPath = path;
    await _setupPlayer(path);
    debugPrint('[STEWYRT][RECORD] Player ready — total duration: ${_player.duration}');
    setState(() => _state = _RecordState.previewing);
  }

  // ── Playback preview ──────────────────────────────────────────────────────

  Future<void> _setupPlayer(String path) async {
    if (kIsWeb) {
      await _player.setUrl(path); // record returns a blob:// URL on web
    } else {
      await _player.setFilePath(path);
    }
    _playTotal = _player.duration ?? Duration.zero;

    _positionSub = _player.positionStream.listen((pos) {
      if (mounted) setState(() => _playPosition = pos);
    });
    _playerStateSub = _player.playerStateStream.listen((s) {
      if (mounted) setState(() => _isPlaying = s.playing);
    });
  }

  Future<void> _togglePreview() async {
    HapticFeedback.lightImpact();
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_playPosition >= _playTotal && _playTotal > Duration.zero) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  Future<void> _reRecord() async {
    await _player.stop();
    await _positionSub?.cancel();
    await _playerStateSub?.cancel();
    _positionSub    = null;
    _playerStateSub = null;
    await _resetRecorder();
    setState(() {
      _state          = _RecordState.idle;
      _liveSamples.clear();
      _recordDuration = Duration.zero;
      _playPosition   = Duration.zero;
      _playTotal      = Duration.zero;
      _isPlaying      = false;
      _pendingPath    = null;
    });
  }

  // ── Submission pipeline ───────────────────────────────────────────────────

  Future<void> _onSubmit() async {
    if (_state != _RecordState.previewing) return;
    HapticFeedback.mediumImpact();
    debugPrint('[STEWYRT][SUBMIT] Submit tapped');

    final path = _pendingPath;
    if (path == null) {
      debugPrint('[STEWYRT][SUBMIT] ERROR — no pending file path');
      return;
    }

    debugPrint('[STEWYRT][SUBMIT] Stopping player...');
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[STEWYRT][SUBMIT] player.stop() threw (non-fatal): $e');
    }
    debugPrint('[STEWYRT][SUBMIT] Player stopped');
    final uuid = const Uuid().v4();
    final String responseId;
    if (_kProductionMode) {
      // Production: one response per user per poll.
      // No client-side delete needed — the Cloud Function uses tx.set() which
      // overwrites any existing document atomically, eliminating the stale-result race.
      final uid = FirebaseAuth.instance.currentUser?.uid ?? uuid;
      responseId = '${uid}_${widget.pollId}';
      debugPrint('[STEWYRT][SUBMIT] Production mode — Response ID: $responseId');
    } else {
      // Beta: fresh UUID every time so one device can submit multiple responses.
      responseId = uuid;
      debugPrint('[STEWYRT][SUBMIT] Beta mode — Response ID: $responseId');
    }
    debugPrint('[STEWYRT][SUBMIT] Poll ID: ${widget.pollId}');
    debugPrint('[STEWYRT][SUBMIT] Question: "${widget.question}"');

    setState(() {
      _state        = _RecordState.waiting;
      _storyIndex   = 0;
      _currentStory = _generateNewStory();
    });
    debugPrint('[STEWYRT][SUBMIT] State → waiting');

    _phraseTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!mounted) return;
      setState(() {
        _storyIndex++;
        if (_storyIndex >= _currentStory.length) {
          _storyIndex   = 0;
          _currentStory = _generateNewStory();
        }
      });
    });

    // ── Upload ───────────────────────────────────────────────────────────────
    debugPrint('[STEWYRT][SUBMIT] Starting Storage upload...');
    try {
      await StorageService.uploadAudioClip(
        path,
        uuid,
        widget.question,
        widget.pollId,
        responseId,
        extraMetadata: {
          'uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        },
      );
      debugPrint('[STEWYRT][SUBMIT] ✅ Upload complete — waiting for Cloud Function...');
    } catch (e) {
      debugPrint('[STEWYRT][SUBMIT] ❌ Upload FAILED: $e');
      _phraseTimer?.cancel();
      if (mounted) setState(() => _state = _RecordState.previewing);
      return;
    }

    // ── Firestore listener ───────────────────────────────────────────────────
    // Use a local ref to avoid a race where the callback fires before
    // _firestoreSub is assigned.
    StreamSubscription? sub;
    sub = FirestoreService.listenForResult(
      responseId,
      (result) {
        debugPrint('[STEWYRT][SUBMIT] ✅ Analysis received — '
            'tone: ${result.tone} | flavor: ${result.flavor} | '
            'essence: ${result.essence} | summary: "${result.summary}"');
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _result = result;
          _state  = _RecordState.results;
        });
        debugPrint('[STEWYRT][SUBMIT] State → results — starting staggered animation');
        _startResultAnimation();
      },
      onBlocked: (reason) {
        debugPrint('[STEWYRT][SUBMIT] 🚫 Content blocked — reason: $reason');
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _state             = _RecordState.blocked;
          _blockedResponseId = responseId;
        });
      },
      onTimeout: () {
        debugPrint('[STEWYRT][SUBMIT] ❌ TIMEOUT — Cloud Function did not respond. '
            'Check Firebase Functions logs for responseId: $responseId');
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (mounted) {
          setState(() => _state = _RecordState.previewing);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Analysis timed out — please try again')),
          );
        }
      },
    );
    _firestoreSub = sub;
    debugPrint('[STEWYRT][SUBMIT] Firestore listener attached — watching responses/$responseId');
  }

  void _onTagTap(String tag) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
    ResonanceController.goToResonanceAndFocus(tag, pollId: widget.pollId);
  }

  void _startResultAnimation() {
    Future.delayed(Duration.zero, () {
      if (mounted) setState(() => _showTone = true);
    });
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _showFlavor = true);
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showEssence = true);
    });
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _showSummary = true);
    });
    Future.delayed(const Duration(milliseconds: 1900), () {
      if (mounted) setState(() => _showDone = true);
    });
  }

  Future<void> _requestHumanReview() async {
    final id = _blockedResponseId;
    if (id == null) return;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('submitModerationReview')
          .call({'responseId': id});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Review request submitted — our team will take a look')),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Request failed — please try again')),
      );
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  List<double> _buildDisplayWaveform({int targetCount = 50}) {
    if (_liveSamples.isEmpty) return [];
    if (_liveSamples.length <= targetCount) return List.of(_liveSamples);
    final step = _liveSamples.length / targetCount;
    return List.generate(targetCount, (i) {
      final start = (i * step).floor();
      final end   = ((i + 1) * step).ceil().clamp(0, _liveSamples.length);
      final slice = _liveSamples.sublist(start, end);
      return slice.reduce((a, b) => a + b) / slice.length;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final fg     = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final sub    = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final handle = sub.withValues(alpha: 0.4);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: handle,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            widget.question,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: fg,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 36),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: switch (_state) {
              _RecordState.idle       => _buildIdle(fg, sub, isDark),
              _RecordState.recording  => _buildRecording(fg, sub, isDark),
              _RecordState.previewing => _buildPreviewing(fg, sub, isDark),
              _RecordState.waiting    => _buildWaiting(fg, sub),
              _RecordState.results    => _buildResults(fg, sub, isDark),
              _RecordState.blocked    => _buildBlocked(fg, sub, isDark),
            },
          ),
        ],
      ),
    );
  }

  // ── Idle ──────────────────────────────────────────────────────────────────

  Widget _buildIdle(Color fg, Color sub, bool isDark) {
    final buttonBg = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final buttonFg = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final shadow   = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.12);

    return Column(
      key: const ValueKey('idle'),
      children: [
        if (_micPermissionDenied) ...[
          MicPermissionBanner(
            message: 'Stewyrt needs your microphone to record. Tap to open Settings.',
          ),
          const SizedBox(height: 12),
        ],
        Listener(
          onPointerDown: (_) => _onPressDown(),
          onPointerUp:   (_) => _onPressUp(),
          onPointerCancel: (_) => _onPressUp(),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            decoration: BoxDecoration(
              color: buttonBg,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: shadow, blurRadius: 32, offset: const Offset(0, 8)),
              ],
            ),
            child: Text(
              "So, tell everyone what you're really thinking",
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: buttonFg,
                height: 1.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Press and hold to record',
          style: GoogleFonts.spaceGrotesk(fontSize: 12, color: sub),
        ),
      ],
    );
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Widget _buildRecording(Color fg, Color sub, bool isDark) {

    return Column(
      key: const ValueKey('recording'),
      children: [
        SizedBox(
          height: 56,
          width: double.infinity,
          child: CustomPaint(
            painter: _LiveWaveformPainter(
              samples:      _liveSamples,
              barColor:     fg.withValues(alpha: 0.9),
              silenceColor: fg.withValues(alpha: 0.12),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _fmtDuration(_recordDuration),
              style: GoogleFonts.spaceGrotesk(
                fontSize: 28,
                fontWeight: FontWeight.w300,
                color: fg,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Listener(
          onPointerUp:     (_) => _onPressUp(),
          onPointerCancel: (_) => _onPressUp(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: fg.withValues(alpha: 0.2)),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              'Release to stop',
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: sub),
            ),
          ),
        ),
      ],
    );
  }

  // ── Preview ───────────────────────────────────────────────────────────────

  Widget _buildPreviewing(Color fg, Color sub, bool isDark) {
    final displayWaveform = _buildDisplayWaveform();
    final progress = _playTotal.inMilliseconds > 0
        ? (_playPosition.inMilliseconds / _playTotal.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final buttonBg  = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final buttonFg  = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final surfaceBg = isDark ? const Color(0xFF111111) : const Color(0xFFF0F0F0);

    return Column(
      key: const ValueKey('preview'),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: surfaceBg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: _togglePreview,
                child: Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: buttonBg,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color:      buttonBg.withValues(alpha: isDark ? 0.15 : 0.20),
                        blurRadius: 12,
                        offset:     const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: buttonFg,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 36,
                      child: CustomPaint(
                        painter: _PlaybackWaveformPainter(
                          bars:     displayWaveform,
                          progress: progress,
                          played:   fg,
                          unplayed: sub.withValues(alpha: 0.3),
                        ),
                        size: const Size(double.infinity, 36),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fmtDuration(_playPosition),
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 11, fontWeight: FontWeight.w600, color: fg,
                          ),
                        ),
                        StreamBuilder<Duration?>(
                          stream: _player.durationStream,
                          builder: (context, snapshot) {
                            final d = snapshot.data ?? Duration.zero;
                            return Text(
                              _fmtDuration(d),
                              style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _OutlineButton(label: 'Re-record', fg: fg, onTap: _reRecord),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _FilledButton(
                label: 'Submit',
                bg: isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000),
                fg: isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
                onTap: _onSubmit,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Waiting Room ──────────────────────────────────────────────────────────

  Widget _buildWaiting(Color fg, Color sub) {
    return Column(
      key: const ValueKey('waiting'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: Text(
            _currentStory.isEmpty ? '' : _currentStory[_storyIndex],
            key: ValueKey(_storyIndex),
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: fg,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'stewyrt is listening...',
          style: GoogleFonts.spaceGrotesk(fontSize: 12, color: sub),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  // ── Results ───────────────────────────────────────────────────────────────

  Widget _buildResults(Color fg, Color sub, bool isDark) {
    final result = _result!;
    final chipBg = isDark ? const Color(0xFF111111) : const Color(0xFFF0F0F0);

    return Column(
      key: const ValueKey('results'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Tag row — each chip fades in sequentially; tappable to deep-link into Resonance
        Row(
          children: [
            Expanded(
              child: AnimatedOpacity(
                opacity: _showTone ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 500),
                child: _TagChip(
                  label: 'TONE', value: result.tone,
                  bg: chipBg, fg: fg, sub: sub,
                  onTap: _showTone ? () => _onTagTap(result.tone) : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedOpacity(
                opacity: _showFlavor ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 500),
                child: _TagChip(
                  label: 'FLAVOR', value: result.flavor,
                  bg: chipBg, fg: fg, sub: sub,
                  onTap: _showFlavor ? () => _onTagTap(result.flavor) : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedOpacity(
                opacity: _showEssence ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 500),
                child: _TagChip(
                  label: 'ESSENCE', value: result.essence,
                  bg: chipBg, fg: fg, sub: sub,
                  onTap: _showEssence ? () => _onTagTap(result.essence) : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedOpacity(
          opacity: _showTone ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 500),
          child: Text(
            'Tap a chip to explore in The Resonance',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(fontSize: 11, color: sub),
          ),
        ),
        const SizedBox(height: 28),
        // 4-word summary
        AnimatedOpacity(
          opacity: _showSummary ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 600),
          child: Text(
            '"${result.summary}"',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 19,
              fontWeight: FontWeight.w500,
              fontStyle: FontStyle.italic,
              color: fg,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 36),
        // Done — appears last
        AnimatedOpacity(
          opacity: _showDone ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 400),
          child: _FilledButton(
            label: 'Done',
            bg: isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000),
            fg: isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
            onTap: _showDone
                ? () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).pop();
                  }
                : () {},
          ),
        ),
      ],
    );
  }

  // ── Blocked ───────────────────────────────────────────────────────────────

  Widget _buildBlocked(Color fg, Color sub, bool isDark) {
    return Column(
      key: const ValueKey('blocked'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        const Icon(Icons.headset_off_outlined, color: Color(0xFFD4A574), size: 44),
        const SizedBox(height: 20),
        Text(
          "We couldn't share this one",
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 17, fontWeight: FontWeight.w600, color: fg, height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          "Our AI flagged this response. If you think that's a mistake, you can request a human review.",
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 13, color: sub, height: 1.6,
          ),
        ),
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(
              child: _OutlineButton(
                label: 'Try again',
                fg: fg,
                onTap: () async {
                  HapticFeedback.lightImpact();
                  await _resetRecorder();
                  setState(() {
                    _state             = _RecordState.idle;
                    _liveSamples.clear();
                    _recordDuration    = Duration.zero;
                    _pendingPath       = null;
                    _blockedResponseId = null;
                  });
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _FilledButton(
                label: 'Request review',
                bg: const Color(0xFFD4A574),
                fg: Colors.black,
                onTap: _requestHumanReview,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Painters ─────────────────────────────────────────────────────────────────

/// Live scrolling waveform: newest bar on the right.
class _LiveWaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color barColor;
  final Color silenceColor;

  const _LiveWaveformPainter({
    required this.samples,
    required this.barColor,
    required this.silenceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const totalBars = 60;
    const gap = 2.5;
    final barWidth = (size.width - (totalBars - 1) * gap) / totalBars;

    final padded = [
      ...List.filled(max(0, totalBars - samples.length), 0.0),
      ...samples.length > totalBars
          ? samples.sublist(samples.length - totalBars)
          : samples,
    ];

    for (var i = 0; i < totalBars; i++) {
      final x     = i * (barWidth + gap);
      final h     = max(3.0, padded[i] * size.height);
      final top   = (size.height - h) / 2;
      final color = padded[i] < 0.01 ? silenceColor : barColor;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, h),
          const Radius.circular(1.5),
        ),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveWaveformPainter old) =>
      old.samples.length != samples.length || old.barColor != barColor;
}

/// Playback waveform: fills left→right with playback progress.
class _PlaybackWaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color played;
  final Color unplayed;

  const _PlaybackWaveformPainter({
    required this.bars,
    required this.progress,
    required this.played,
    required this.unplayed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final count     = bars.length;
    const gap       = 2.0;
    final barWidth  = (size.width - (count - 1) * gap) / count;
    final progressX = size.width * progress;

    for (var i = 0; i < count; i++) {
      final x   = i * (barWidth + gap);
      final h   = max(3.0, bars[i] * size.height);
      final top = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, h),
          const Radius.circular(1.5),
        ),
        Paint()..color = x + barWidth <= progressX ? played : unplayed,
      );
    }
  }

  @override
  bool shouldRepaint(_PlaybackWaveformPainter old) =>
      old.progress != progress || old.played != played;
}

// ── Button widgets ────────────────────────────────────────────────────────────

class _OutlineButton extends StatelessWidget {
  final String label;
  final Color fg;
  final VoidCallback onTap;
  const _OutlineButton({required this.label, required this.fg, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: fg.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 14, fontWeight: FontWeight.w600, color: fg,
          ),
        ),
      ),
    );
  }
}

class _FilledButton extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;
  const _FilledButton({
    required this.label,
    required this.bg,
    required this.fg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 14, fontWeight: FontWeight.w600, color: fg,
          ),
        ),
      ),
    );
  }
}

// ── Tag chip ──────────────────────────────────────────────────────────────────

class _TagChip extends StatelessWidget {
  final String label;
  final String value;
  final Color bg;
  final Color fg;
  final Color sub;
  final VoidCallback? onTap;

  const _TagChip({
    required this.label,
    required this.value,
    required this.bg,
    required this.fg,
    required this.sub,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: onTap != null
            ? Border.all(color: fg.withValues(alpha: 0.12))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: sub,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return GestureDetector(onTap: onTap, child: chip);
  }
}
