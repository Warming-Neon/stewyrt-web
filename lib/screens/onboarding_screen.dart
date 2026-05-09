import 'dart:async';
import 'dart:math';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/firestore_service.dart';
import '../services/storage_service.dart';
import '../utils/limiter.dart';
import 'day_one_screen.dart';

const Color _bg = Colors.black;
const Color _offWhite = Color(0xFFF5F5F5);
const Color _subtle = Color(0xFFAAAAAA);
const Color _border = Color(0xFF333333);
const Color _dropdownCanvas = Color(0xFF0D0D0D);

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  // ── Dropdown state ────────────────────────────────────────────────────────
  String? _age;
  String? _gender;
  String? _ethnicity;
  String? _region;

  // ── Checkbox state ────────────────────────────────────────────────────────
  bool _confirmedAge = false;
  bool _consentRecording = false;
  bool _agreedTerms = false;

  // ── Recording state ───────────────────────────────────────────────────────
  AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _pressActive = false;
  Timer? _maxDurationTimer;

  // ── Waveform ───────────────────────────────────────────────────────────────
  final List<double> _liveSamples = [];
  StreamSubscription<Amplitude>? _ampSub;
  final SoftLimiter _limiter = const SoftLimiter();

  // ── Upload / verification state ───────────────────────────────────────────
  bool _isUploading = false;
  bool _isVerifying = false;
  StreamSubscription<dynamic>? _verificationSub;

  // ── Verifying waiting room ─────────────────────────────────────────────────
  static const _phrases = [
    'Listening for signs of life...',
    'Checking for human presence...',
    'Consulting the Zeitgeist...',
    'Unlocking the door...',
  ];
  int _phraseIndex = 0;
  Timer? _phraseTimer;

  // ── Link recognizers ──────────────────────────────────────────────────────
  late final TapGestureRecognizer _termsRecognizer;
  late final TapGestureRecognizer _privacyRecognizer;

  // ── Shake animation (invalid tap feedback) ────────────────────────────────
  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  // Dropdown options — values are passed verbatim to submitSelfReportedDemographics.
  static const _ages = ['18-24', '25-34', '35-44', '45-54', '55-64', '65+', 'Prefer not to say'];
  static const _genders = ['Male', 'Female', 'Non-Binary', 'Prefer not to say'];
  static const _ethnicities = [
    'Asian',
    'Black or African',
    'Hispanic/Latino',
    'White',
    'Mixed',
    'Other',
    'Prefer not to say',
  ];
  static const _regions = [
    'Northern Europe',
    'Western Europe',
    'Southern Europe',
    'Eastern Europe',
    'North America',
    'Latin America',
    'Middle East & North Africa',
    'Sub-Saharan Africa',
    'South Asia',
    'East Asia',
    'Southeast Asia',
    'Oceania',
    'Prefer not to say',
  ];

  @override
  void initState() {
    super.initState();

    _termsRecognizer = TapGestureRecognizer()
      ..onTap = () => _openUrl('https://stewyrt.com/terms.html');
    _privacyRecognizer = TapGestureRecognizer()
      ..onTap = () => _openUrl('https://stewyrt.com/privacy.html');

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    _shakeController.dispose();
    _maxDurationTimer?.cancel();
    _ampSub?.cancel();
    _phraseTimer?.cancel();
    _verificationSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Validation ────────────────────────────────────────────────────────────

  bool get _isFormValid =>
      _age != null &&
      _gender != null &&
      _ethnicity != null &&
      _region != null &&
      _confirmedAge &&
      _consentRecording &&
      _agreedTerms;

  // ── URL launcher ──────────────────────────────────────────────────────────

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      debugPrint('[STEWYRT][ONBOARDING] Could not launch $url');
    }
  }

  // ── Error feedback ────────────────────────────────────────────────────────

  void _onInvalidTap() {
    HapticFeedback.mediumImpact();
    _shakeController.forward(from: 0);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1A1A1A),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        content: Text(
          'Complete all fields and tick all boxes to continue.',
          style: GoogleFonts.spaceGrotesk(fontSize: 13, color: _offWhite),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    debugPrint('[BOUNCER] _startRecording — checking mic permission');
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission || !mounted) {
      if (mounted) setState(() => _isRecording = false);
      return;
    }

    final filePath = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/onboarding_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
      ),
      path: filePath,
    );

    // User released before start() finished — abort cleanly.
    if (!_pressActive) {
      await _recorder.stop();
      await _recorder.dispose();
      _recorder = AudioRecorder();
      if (mounted) setState(() => _isRecording = false);
      return;
    }

    if (!mounted) return;

    _liveSamples.clear();
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 50))
        .listen((amp) {
      if (!mounted) return;
      setState(() => _liveSamples.add(_limiter.process(amp.current)));
    });

    setState(() => _isRecording = true);
    debugPrint('[BOUNCER] Recording started');

    _maxDurationTimer = Timer(const Duration(seconds: 30), () {
      if (_isRecording) _stopAndUpload();
    });
  }

  Future<void> _stopAndUpload() async {
    if (!_isRecording) return;
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;

    await _ampSub?.cancel();
    _ampSub = null;

    HapticFeedback.heavyImpact();

    final recordedPath = await _recorder.stop();
    await _recorder.dispose();
    _recorder = AudioRecorder();

    if (!mounted) return;

    if (recordedPath == null) {
      setState(() {
        _isRecording = false;
        _liveSamples.clear();
      });
      return;
    }

    debugPrint('[BOUNCER] Recording stopped — path: $recordedPath — starting upload');

    setState(() {
      _isRecording = false;
      _isUploading = true;
      _liveSamples.clear();
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() { _isRecording = false; _liveSamples.clear(); });
      return;
    }
    final uid = user.uid;

    try {
      // Demographic fields are no longer sent as Storage metadata — the Cloud
      // Function only needs the audio to perform bot-detection, not demographics.
      await StorageService.uploadOnboardingAudio(recordedPath, uid);
    } catch (e) {
      debugPrint('[STEWYRT][ONBOARDING] Upload failed: $e');
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1A1A1A),
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text(
              'Upload failed — please try again.',
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: _offWhite),
            ),
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    debugPrint('[BOUNCER] Upload complete — attaching verification listener for uid: $uid');

    setState(() {
      _isUploading = false;
      _isVerifying = true;
    });

    _phraseIndex = 0;
    _phraseTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted) return;
      setState(() => _phraseIndex = (_phraseIndex + 1) % _phrases.length);
    });

    _verificationSub = FirestoreService.listenForVerification(
      uid,
      (_) {
        _phraseTimer?.cancel();
        _phraseTimer = null;
        _verificationSub = null;
        if (!mounted) return;
        // Fire-and-forget: store self-reported demographics via Cloud Function.
        // Navigation to DayOneScreen proceeds regardless of whether this call succeeds.
        FirebaseFunctions.instance
            .httpsCallable('submitSelfReportedDemographics')
            .call({
              'age':       _age,
              'gender':    _gender,
              'ethnicity': _ethnicity,
              'region':    _region,
            })
            .then<void>(
              (_) {},
              onError: (e) =>
                  debugPrint('[STEWYRT][ONBOARDING] Demographics CF error: $e'),
            );
        SharedPreferences.getInstance().then((prefs) {
          prefs.setBool('hasPassedBouncer', true);
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const DayOneScreen()),
            );
          }
        });
      },
      (errorMessage) {
        _phraseTimer?.cancel();
        _phraseTimer = null;
        _verificationSub = null;
        if (!mounted) return;
        setState(() => _isVerifying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1A1A1A),
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text(
              errorMessage,
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: _offWhite),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isVerifying) {
      return Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: _offWhite,
                    ),
                  ),
                  const SizedBox(height: 32),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: Text(
                      _phrases[_phraseIndex],
                      key: ValueKey(_phraseIndex),
                      textAlign: TextAlign.center,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: _offWhite,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Headline(),
              const SizedBox(height: 40),
              _sectionLabel('ABOUT YOU'),
              const SizedBox(height: 16),
              _StyledDropdown(
                label: 'Age Range',
                value: _age,
                items: _ages,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _age = v),
              ),
              const SizedBox(height: 12),
              _StyledDropdown(
                label: 'Gender',
                value: _gender,
                items: _genders,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _gender = v),
              ),
              const SizedBox(height: 12),
              _StyledDropdown(
                label: 'Ethnicity',
                value: _ethnicity,
                items: _ethnicities,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _ethnicity = v),
              ),
              const SizedBox(height: 12),
              _StyledDropdown(
                label: 'Region',
                value: _region,
                items: _regions,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _region = v),
              ),
              const SizedBox(height: 40),
              _sectionLabel('CONFIRM & CONSENT'),
              const SizedBox(height: 16),
              _SharpCheckbox(
                value: _confirmedAge,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _confirmedAge = v),
                label: const TextSpan(
                  text: 'I confirm I am 18 years of age or older.',
                ),
              ),
              const SizedBox(height: 16),
              _SharpCheckbox(
                value: _consentRecording,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _consentRecording = v),
                label: const TextSpan(
                  text: 'I consent to a one-time audio recording used solely to '
                      'confirm I am a real human. The recording is processed and '
                      'immediately deleted. It is NOT used to identify me or '
                      'estimate any personal characteristic.',
                ),
              ),
              const SizedBox(height: 16),
              _SharpCheckbox(
                value: _agreedTerms,
                onChanged: _isRecording || _isUploading
                    ? null
                    : (v) => setState(() => _agreedTerms = v),
                label: TextSpan(
                  children: [
                    const TextSpan(text: 'I agree to the '),
                    TextSpan(
                      text: 'Terms of Service',
                      style: const TextStyle(
                        color: Color(0xFF00FFCC),
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFF00FFCC),
                      ),
                      recognizer: _termsRecognizer,
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: const TextStyle(
                        color: Color(0xFF00FFCC),
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFF00FFCC),
                      ),
                      recognizer: _privacyRecognizer,
                    ),
                    const TextSpan(
                      text: ', and understand my anonymized demographic data will be aggregated and monetized.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 48),
              _buildHoldButton(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  // Outer Listener persists across recording/idle state changes so onPointerUp
  // is always delivered to the same render object that received onPointerDown.
  Widget _buildHoldButton() {
    return Listener(
      onPointerDown: (_) {
        if (_isRecording || _pressActive || _isUploading || _isVerifying) return;
        if (!_isFormValid) {
          _onInvalidTap();
          return;
        }
        _pressActive = true;
        HapticFeedback.heavyImpact();
        _startRecording();
      },
      onPointerUp: (_) {
        if (!_isRecording) return;
        _pressActive = false;
        _stopAndUpload();
      },
      onPointerCancel: (_) {
        if (!_isRecording) return;
        _pressActive = false;
        _stopAndUpload();
      },
      child: _buildHoldButtonContent(),
    );
  }

  Widget _buildHoldButtonContent() {
    if (_isUploading) {
      return Container(
        width: double.infinity,
        height: 64,
        decoration: BoxDecoration(
          border: Border.all(color: _offWhite, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: _offWhite,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Uploading...',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _offWhite,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      );
    }

    if (_isRecording) {
      return Column(
        children: [
          SizedBox(
            height: 64,
            width: double.infinity,
            child: CustomPaint(
              painter: _LiveWaveformPainter(
                samples: _liveSamples,
                barColor: _offWhite.withValues(alpha: 0.9),
                silenceColor: _offWhite.withValues(alpha: 0.12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Release to stop',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _subtle),
          ),
        ],
      );
    }

    final valid = _isFormValid;

    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) => Transform.translate(
        offset: Offset(_shakeAnimation.value, 0),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (valid) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                border: Border.all(color: _border),
                color: const Color(0xFF0A0A0A),
              ),
              child: Text(
                'Say a few words — anything at all. '
                'We just need to hear your voice.',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: _offWhite,
                  height: 1.5,
                ),
              ),
            ),
          ],
          AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: valid ? 1.0 : 0.35,
            child: Container(
              width: double.infinity,
              height: 64,
              decoration: BoxDecoration(
                border: Border.all(color: _offWhite, width: 1.5),
                color: Colors.black,
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mic_none_rounded, color: _offWhite, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    'Hold to Verify',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _offWhite,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.spaceGrotesk(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: _subtle,
        letterSpacing: 1.8,
      ),
    );
  }
}

// ── Stateless sub-widgets ─────────────────────────────────────────────────────

class _Headline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stewyrt is free for you, but servers aren\'t. We sell the trends of what the world is feeling to pay the bills, but we never sell who you are.',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: _offWhite,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Tell us about yourself, agree to the terms, then hold the button so we know you\'re human.',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: _subtle,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _StyledDropdown extends StatelessWidget {
  const _StyledDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: onChanged == null ? 0.4 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: _border),
          color: _dropdownCanvas,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            hint: Text(
              label,
              style: GoogleFonts.spaceGrotesk(fontSize: 14, color: _subtle),
            ),
            isExpanded: true,
            dropdownColor: _dropdownCanvas,
            icon: const Icon(Icons.keyboard_arrow_down, color: _subtle, size: 18),
            style: GoogleFonts.spaceGrotesk(fontSize: 14, color: _offWhite),
            items: items
                .map((item) => DropdownMenuItem(value: item, child: Text(item)))
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _SharpCheckbox extends StatelessWidget {
  const _SharpCheckbox({
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final InlineSpan label;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: onChanged == null ? 0.4 : 1.0,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: value ? _offWhite : Colors.transparent,
                  border: Border.all(
                    color: value ? _offWhite : _border,
                    width: 1.5,
                  ),
                ),
                child: value
                    ? const Icon(Icons.check, size: 14, color: Colors.black)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                label,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: _offWhite,
                  height: 1.55,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Painter ───────────────────────────────────────────────────────────────────

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
      final x = i * (barWidth + gap);
      final h = max(3.0, padded[i] * size.height);
      final top = (size.height - h) / 2;
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
