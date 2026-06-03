import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/firestore_service.dart';
import '../services/storage_service.dart';
import '../utils/limiter.dart';
import '../services/phrase_service.dart';
import '../widgets/mic_permission_banner.dart';
import '../widgets/verification_timeout_widget.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const String _dayOneQuestion =
    'Tell us about the last time you laughed so hard you cried.';
const String _iceBreakerId = 'ice_breaker_v1';

// ── State machine ─────────────────────────────────────────────────────────────

enum _D1State { idle, recording, previewing, waiting, results, blocked, timedOut }

// ── Screen ────────────────────────────────────────────────────────────────────

class DayOneScreen extends StatefulWidget {
  const DayOneScreen({super.key});

  @override
  State<DayOneScreen> createState() => _DayOneScreenState();
}

class _DayOneScreenState extends State<DayOneScreen>
    with WidgetsBindingObserver {
  _D1State _state = _D1State.idle;

  // ── Intro phrase ──────────────────────────────────────────────────────────
  String _currentIntro = '';

  static const _intros = [
    'Stewyrt was supposed to write a profound first question, but he\'s currently hyper-fixated on a tapas recipe book. So we\'ll keep it simple:',
    'Stewyrt stayed up all night watching Bruce Lee documentaries and hasn\'t had his coffee yet. While he reboots, let\'s break the ice:',
    'Stewyrt is currently at the hardware store trying to buy replacement bubbles for a spirit level. Since he\'s occupied:',
    'Stewyrt fell out of his hammock last night and is currently filing an incident report. While he handles the paperwork:',
    'Stewyrt is deep down a Wikipedia rabbit hole researching how Bluetooth actually works. So we\'re flying solo today:',
    'Stewyrt tried to divide by zero this morning and is currently staring blankly at a wall. To fill the silence:',
    'Stewyrt is currently arguing with a toaster about the exact definition of "golden brown." While they sort that out:',
    'Stewyrt got his head stuck in a complex metaphor and is waiting for the fire brigade. In the meantime:',
    'Stewyrt is trying to teach a pigeon how to play chess in the park. Since he\'s currently losing:',
  ];

  // ── Microphone permission state ───────────────────────────────────────────
  bool _micPermissionDenied = false;

  // ── Recorder ──────────────────────────────────────────────────────────────
  AudioRecorder _recorder = AudioRecorder();
  final _player   = AudioPlayer();
  bool _pressActive = false;
  final List<double> _liveSamples = [];
  final List<double> _rawAmplitudes = [];
  final _limiter = const SoftLimiter();
  DateTime? _recordStartTime;
  Duration _recordDuration = Duration.zero;
  Timer? _clockTimer;
  Timer? _maxDurationTimer;
  StreamSubscription<Amplitude>? _ampSub;

  // ── Playback ──────────────────────────────────────────────────────────────
  Duration _playPosition = Duration.zero;
  Duration _playTotal    = Duration.zero;
  bool _isPlaying        = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;

  // ── Waiting room story ────────────────────────────────────────────────────

  List<String> _currentStory = [];
  int _storyIndex = 0;
  Timer? _phraseTimer;

  // ── Pipeline ──────────────────────────────────────────────────────────────
  StreamSubscription? _firestoreSub;
  String? _blockedResponseId;
  String? _pendingPath;
  AnalysisResult? _result;

  // ── Staggered results reveal ──────────────────────────────────────────────
  bool _showTone    = false;
  bool _showFlavor  = false;
  bool _showEssence = false;
  bool _showSummary = false;
  bool _showDone    = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _currentIntro = _intros[Random().nextInt(_intros.length)];
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

  // ── Recorder helpers ──────────────────────────────────────────────────────

  Future<void> _resetRecorder() async {
    await _ampSub?.cancel();
    _ampSub = null;
    await _recorder.dispose();
    _recorder = AudioRecorder();
  }

  List<String> _generateNewStory() => PhraseService.instance.generateStory();

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _onPressDown() async {
    if (_state != _D1State.idle) return;
    _pressActive = true;
    setState(() => _state = _D1State.recording);
    HapticFeedback.mediumImpact();

    final hasPermission = await _recorder.hasPermission();
    if (!mounted) return;
    if (!hasPermission) {
      setState(() { _state = _D1State.idle; _micPermissionDenied = true; });
      return;
    }

    final path = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/d1_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder:       AudioEncoder.aacLc,
        bitRate:       128000,
        sampleRate:    44100,
        numChannels:   1,
        autoGain:      true,
        noiseSuppress: true,
      ),
      path: path,
    );

    _recordStartTime = DateTime.now();
    _rawAmplitudes.clear();

    if (!_pressActive) {
      await _recorder.stop();
      await _resetRecorder();
      if (mounted) setState(() => _state = _D1State.idle);
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

    _maxDurationTimer = Timer(const Duration(seconds: 30), () {
      debugPrint('[STEWYRT][DAY1] 30s limit reached — auto-stopping');
      HapticFeedback.mediumImpact();
      _onPressUp();
    });

    setState(() => _recordDuration = Duration.zero);
  }

  Future<void> _onPressUp() async {
    _pressActive = false;
    if (_state != _D1State.recording) return;
    HapticFeedback.lightImpact();

    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;
    await _ampSub?.cancel();
    _clockTimer?.cancel();

    final startTime = _recordStartTime;
    final duration = startTime != null
        ? DateTime.now().difference(startTime)
        : _recordDuration;

    final avgAmp = _rawAmplitudes.isEmpty
        ? -100.0
        : _rawAmplitudes.reduce((a, b) => a + b) / _rawAmplitudes.length;

    debugPrint('[STEWYRT][DAY1] Quality check — duration: ${duration.inMilliseconds}ms, avg amplitude: ${avgAmp.toStringAsFixed(2)}dB');

    if (duration.inMilliseconds < 2000 || (kIsWeb ? avgAmp < 0.01 : avgAmp < -50.0)) {
      debugPrint('[STEWYRT][DAY1] ❌ Recording rejected — too short or silent');
      await _recorder.stop();
      await _resetRecorder();
      if (mounted) {
        setState(() {
          _state = _D1State.idle;
          _liveSamples.clear();
          _rawAmplitudes.clear();
          _recordDuration = Duration.zero;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1A1A1A),
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text(
              "We didn't catch anything — make sure your mic is on and give us a few seconds!",
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFF5F5F5)),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final filePath = await _recorder.stop();
    if (filePath == null || !mounted) return;

    _pendingPath = filePath;
    await _setupPlayer(filePath);
    if (mounted) setState(() => _state = _D1State.previewing);
  }

  // ── Playback preview ──────────────────────────────────────────────────────

  Future<void> _setupPlayer(String path) async {
    if (kIsWeb) {
      await _player.setUrl(path);
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
      _state          = _D1State.idle;
      _liveSamples.clear();
      _recordDuration = Duration.zero;
      _playPosition   = Duration.zero;
      _playTotal      = Duration.zero;
      _isPlaying      = false;
      _pendingPath    = null;
    });
  }

  Future<void> _onSubmit() async {
    if (_state != _D1State.previewing) return;
    final path = _pendingPath;
    if (path == null) return;

    HapticFeedback.mediumImpact();
    await _player.stop();
    await _submit(path);
  }

  // ── Submission pipeline ───────────────────────────────────────────────────

  Future<void> _submit(String filePath) async {
    final uuid = const Uuid().v4();

    setState(() {
      _state        = _D1State.waiting;
      _storyIndex   = 0;
      _currentStory = _generateNewStory();
    });

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

    try {
      await StorageService.uploadAudioClip(
        filePath,
        uuid,
        _dayOneQuestion,
        _iceBreakerId,
        uuid,
        extraMetadata: {'isDayOne': 'true'},
      );
    } catch (e) {
      debugPrint('[STEWYRT][DAY1] Upload failed: $e');
      _phraseTimer?.cancel();
      await _resetRecorder();
      if (mounted) {
        setState(() {
          _state          = _D1State.idle;
          _liveSamples.clear();
          _recordDuration = Duration.zero;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1A1A1A),
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text(
              'Upload failed — please try again.',
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFF5F5F5)),
            ),
          ),
        );
      }
      return;
    }

    StreamSubscription? sub;
    sub = FirestoreService.listenForResult(
      uuid,
      (result) {
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _result = result;
          _state  = _D1State.results;
        });
        _startResultAnimation();
      },
      onBlocked: (reason) {
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _state             = _D1State.blocked;
          _blockedResponseId = uuid;
        });
      },
      onTimeout: () {
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (mounted) setState(() => _state = _D1State.timedOut);
      },
    );
    _firestoreSub = sub;
  }

  void _startResultAnimation() {
    Future.delayed(Duration.zero,                          () { if (mounted) setState(() => _showTone    = true); });
    Future.delayed(const Duration(milliseconds:  400),    () { if (mounted) setState(() => _showFlavor  = true); });
    Future.delayed(const Duration(milliseconds:  800),    () { if (mounted) setState(() => _showEssence = true); });
    Future.delayed(const Duration(milliseconds: 1400),    () { if (mounted) setState(() => _showSummary = true); });
    Future.delayed(const Duration(milliseconds: 1900),    () { if (mounted) setState(() => _showDone    = true); });
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
        SnackBar(
          backgroundColor: const Color(0xFF1A1A1A),
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          content: Text(
            'Review request submitted — our team will take a look.',
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFF5F5F5)),
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1A1A1A),
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          content: Text(
            e.message ?? 'Request failed — please try again.',
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFF5F5F5)),
          ),
        ),
      );
    }
  }

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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header: always visible ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentIntro,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFFAAAAAA),
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _dayOneQuestion,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFF5F5F5),
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            // ── State machine ───────────────────────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: switch (_state) {
                    _D1State.idle       => _buildIdle(),
                    _D1State.recording  => _buildRecording(),
                    _D1State.previewing => _buildPreviewing(),
                    _D1State.waiting    => _buildWaiting(),
                    _D1State.results    => _buildResults(),
                    _D1State.blocked    => _buildBlocked(),
                    _D1State.timedOut   => _buildTimedOut(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Idle ──────────────────────────────────────────────────────────────────

  Widget _buildIdle() {
    return Column(
      key: const ValueKey('idle'),
      children: [
        const Spacer(),
        if (_micPermissionDenied) ...[
          MicPermissionBanner(
            message: 'Stewyrt needs your microphone to record. Tap to open Settings.',
          ),
          const SizedBox(height: 12),
        ],
        Listener(
          onPointerDown:  (_) => _onPressDown(),
          onPointerUp:    (_) => _onPressUp(),
          onPointerCancel:(_) => _onPressUp(),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 22),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Text(
              'Hold to answer',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Press and hold to record',
          style: GoogleFonts.spaceGrotesk(fontSize: 12, color: const Color(0xFFAAAAAA)),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('hasCompletedDayOne', true);
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const RootShell()),
            );
          },
          child: Text(
            'Maybe later',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 13,
              color: const Color(0xFFAAAAAA),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Widget _buildRecording() {
    final samples = _liveSamples;
    return Column(
      key: const ValueKey('recording'),
      children: [
        const Spacer(),
        SizedBox(
          height: 56,
          width: double.infinity,
          child: CustomPaint(
            painter: _LiveWaveformPainter(
              samples:      samples,
              barColor:     const Color(0xFFF5F5F5).withValues(alpha: 0.9),
              silenceColor: const Color(0xFFF5F5F5).withValues(alpha: 0.12),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _fmtDuration(_recordDuration),
          style: GoogleFonts.spaceGrotesk(
            fontSize: 28,
            fontWeight: FontWeight.w300,
            color: const Color(0xFFF5F5F5),
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 20),
        Listener(
          onPointerUp:     (_) => _onPressUp(),
          onPointerCancel: (_) => _onPressUp(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFF5F5F5).withValues(alpha: 0.2)),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              'Release to stop',
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFAAAAAA)),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Previewing ────────────────────────────────────────────────────────────

  Widget _buildPreviewing() {
    final displayWaveform = _buildDisplayWaveform();
    final progress = _playTotal.inMilliseconds > 0
        ? (_playPosition.inMilliseconds / _playTotal.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    const fg  = Color(0xFFF5F5F5);
    const sub = Color(0xFFAAAAAA);

    return Column(
      key: const ValueKey('previewing'),
      children: [
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: _togglePreview,
                child: Container(
                  width: 48, height: 48,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF5F5F5),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.black,
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
              child: _D1OutlineButton(label: 'Re-record', onTap: _reRecord),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _D1Button(label: 'Submit', onTap: _onSubmit),
            ),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Waiting ───────────────────────────────────────────────────────────────

  Widget _buildWaiting() {
    return Column(
      key: const ValueKey('waiting'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              color: const Color(0xFFF5F5F5),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'stewyrt is listening...',
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(fontSize: 12, color: const Color(0xFFAAAAAA)),
        ),
      ],
    );
  }

  // ── Results ───────────────────────────────────────────────────────────────

  Widget _buildResults() {
    final result  = _result!;
    const chipBg  = Color(0xFF111111);
    const fg      = Color(0xFFF5F5F5);
    const sub     = Color(0xFFAAAAAA);

    return SingleChildScrollView(
      key: const ValueKey('results'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 40),
          Row(
            children: [
              Expanded(
                child: AnimatedOpacity(
                  opacity: _showTone ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: _TagChip(label: 'TONE', value: result.tone, bg: chipBg, fg: fg, sub: sub),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedOpacity(
                  opacity: _showFlavor ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: _TagChip(label: 'FLAVOR', value: result.flavor, bg: chipBg, fg: fg, sub: sub),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedOpacity(
                  opacity: _showEssence ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: _TagChip(label: 'ESSENCE', value: result.essence, bg: chipBg, fg: fg, sub: sub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
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
          AnimatedOpacity(
            opacity: _showDone ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 400),
            child: _D1Button(
              label: 'Enter Stewyrt',
              onTap: _showDone
                  ? () {
                      HapticFeedback.lightImpact();
                      SharedPreferences.getInstance().then((prefs) {
                        prefs.setBool('hasCompletedDayOne', true);
                        if (mounted) {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => const RootShell()),
                          );
                        }
                      });
                    }
                  : () {},
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Timed out ─────────────────────────────────────────────────────────────

  Widget _buildTimedOut() {
    return Column(
      key: const ValueKey('timedOut'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        VerificationTimeoutWidget(
          attemptsRemaining: null,
          onRetry: () => setState(() {
            _state          = _D1State.idle;
            _liveSamples.clear();
            _recordDuration = Duration.zero;
          }),
        ),
      ],
    );
  }

  // ── Blocked ───────────────────────────────────────────────────────────────

  Widget _buildBlocked() {
    return Column(
      key: const ValueKey('blocked'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.headset_off_outlined, color: Color(0xFFD4A574), size: 44),
        const SizedBox(height: 20),
        Text(
          "We couldn't share this one",
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: const Color(0xFFF5F5F5),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          "Our AI flagged this response. If you think that's a mistake, you can request a human review.",
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 13,
            color: const Color(0xFFAAAAAA),
            height: 1.6,
          ),
        ),
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () async {
                  HapticFeedback.lightImpact();
                  await _resetRecorder();
                  if (!mounted) return;
                  setState(() {
                    _state             = _D1State.idle;
                    _liveSamples.clear();
                    _recordDuration    = Duration.zero;
                    _blockedResponseId = null;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFF5F5F5).withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Try again',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: const Color(0xFFF5F5F5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: _requestHumanReview,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4A574),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Request review',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Private widgets ───────────────────────────────────────────────────────────

class _D1Button extends StatelessWidget {
  const _D1Button({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        color: const Color(0xFFF5F5F5),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.bg,
    required this.fg,
    required this.sub,
    this.value = '',
  });

  final String  label;
  final String  value;
  final Color   bg;
  final Color   fg;
  final Color   sub;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      color: bg,
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
  }
}

// ── Waveform painter ──────────────────────────────────────────────────────────

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
    const gap       = 2.5;
    final barWidth  = (size.width - (totalBars - 1) * gap) / totalBars;

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

class _D1OutlineButton extends StatelessWidget {
  const _D1OutlineButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFF5F5F5).withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: const Color(0xFFF5F5F5),
          ),
        ),
      ),
    );
  }
}

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
