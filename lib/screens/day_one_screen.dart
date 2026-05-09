import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../services/firestore_service.dart';
import '../services/storage_service.dart';
import '../utils/limiter.dart';
import '../main.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const String _dayOneQuestion =
    'Tell us about the last time you laughed so hard you cried.';

// ── State machine ─────────────────────────────────────────────────────────────

enum _D1State { idle, recording, waiting, results, blocked }

// ── Screen ────────────────────────────────────────────────────────────────────

class DayOneScreen extends StatefulWidget {
  const DayOneScreen({super.key});

  @override
  State<DayOneScreen> createState() => _DayOneScreenState();
}

class _DayOneScreenState extends State<DayOneScreen> {
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

  // ── Recorder ──────────────────────────────────────────────────────────────
  AudioRecorder _recorder = AudioRecorder();
  bool _pressActive = false;
  final List<double> _liveSamples = [];
  final _limiter = const SoftLimiter();
  Duration _recordDuration = Duration.zero;
  Timer? _clockTimer;
  Timer? _maxDurationTimer;
  StreamSubscription<Amplitude>? _ampSub;

  // ── Waiting room story ────────────────────────────────────────────────────
  static const _act1Setup = [
    'Having a quick chinwag...', 'Putting the kettle on...', 'Pulling up a chair...', 'Shooting the breeze...',
    'Chewing the fat...', 'Lending a sympathetic ear...', 'Having a proper natter...', 'Catching up on the latest...',
  ];
  static const _act2Observe = [
    'Having a quick neb...', 'Having a proper gander...', 'Peeking at the subtext...', 'Squinting at the syllables...',
    'Casting an eye over the details...', 'Having a nosey at the context...', 'Taking a magnifying glass to the mood...',
  ];
  static const _act3Empathy = [
    'Reading between the lines...', 'Weighing the heavy words...', 'Translating the exasperation...', 'Distilling the sheer essence...',
    'Listening to the silences...', 'Unpacking the baggage...', 'Measuring the exhaustion...', 'Feeling the actual vibe...', 'Finding the absolute flavor...',
  ];
  static const _act4Tech = [
    'Scanning diligently...', 'Consulting the emotional thesaurus...', 'Crunching the feelings...', 'Recalibrating the vibe-meter...',
    'Decoding the delivery...', 'Connecting the emotional dots...', 'Booting up the empathy engine...', 'Bypassing the sarcasm...',
  ];

  List<String> _currentStory = [];
  int _storyIndex = 0;
  Timer? _phraseTimer;

  // ── Pipeline ──────────────────────────────────────────────────────────────
  StreamSubscription? _firestoreSub;
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
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    _clockTimer?.cancel();
    _maxDurationTimer?.cancel();
    _phraseTimer?.cancel();
    _firestoreSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Recorder helpers ──────────────────────────────────────────────────────

  Future<void> _resetRecorder() async {
    await _ampSub?.cancel();
    _ampSub = null;
    await _recorder.dispose();
    _recorder = AudioRecorder();
  }

  List<String> _generateNewStory() {
    final rng = Random();
    return [
      _act1Setup  [rng.nextInt(_act1Setup.length)],
      _act2Observe[rng.nextInt(_act2Observe.length)],
      _act3Empathy[rng.nextInt(_act3Empathy.length)],
      _act4Tech   [rng.nextInt(_act4Tech.length)],
    ];
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _onPressDown() async {
    if (_state != _D1State.idle) return;
    _pressActive = true;
    setState(() => _state = _D1State.recording);
    HapticFeedback.mediumImpact();

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission || !mounted) {
      setState(() => _state = _D1State.idle);
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
      setState(() => _liveSamples.add(_limiter.process(amp.current)));
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

    final filePath = await _recorder.stop();
    if (filePath == null || !mounted) return;

    await _submit(filePath);
  }

  // ── Submission pipeline ───────────────────────────────────────────────────

  Future<void> _submit(String filePath) async {
    final uuid = const Uuid().v4();

    setState(() {
      _state        = _D1State.waiting;
      _storyIndex   = 0;
      _currentStory = _generateNewStory();
    });

    _phraseTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
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
        '',   // no poll ID — Day 1 is not tied to a Firestore poll
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
        setState(() => _state = _D1State.blocked);
      },
      onTimeout: () {
        sub?.cancel();
        _firestoreSub = null;
        _phraseTimer?.cancel();
        if (mounted) {
          setState(() => _state = _D1State.idle);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF1A1A1A),
              behavior: SnackBarBehavior.floating,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              content: Text(
                'Analysis timed out — please try again.',
                style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFF5F5F5)),
              ),
            ),
          );
        }
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

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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
                    _D1State.idle      => _buildIdle(),
                    _D1State.recording => _buildRecording(),
                    _D1State.waiting   => _buildWaiting(),
                    _D1State.results   => _buildResults(),
                    _D1State.blocked   => _buildBlocked(),
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

  // ── Waiting ───────────────────────────────────────────────────────────────

  Widget _buildWaiting() {
    return Column(
      key: const ValueKey('waiting'),
      mainAxisAlignment: MainAxisAlignment.center,
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

  // ── Blocked ───────────────────────────────────────────────────────────────

  Widget _buildBlocked() {
    return Column(
      key: const ValueKey('blocked'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.block_rounded, color: Color(0xFFFF3B30), size: 44),
        const SizedBox(height: 20),
        Text(
          "Your response couldn't be shared.",
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
          'This response contained content that goes against our community guidelines.',
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 13,
            color: const Color(0xFFAAAAAA),
            height: 1.6,
          ),
        ),
        const SizedBox(height: 32),
        _D1Button(
          label: 'Try again',
          onTap: () async {
            HapticFeedback.lightImpact();
            await _resetRecorder();
            if (mounted) {
              setState(() {
                _state          = _D1State.idle;
                _liveSamples.clear();
                _recordDuration = Duration.zero;
              });
            }
          },
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
