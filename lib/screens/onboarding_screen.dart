import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../widgets/mic_permission_banner.dart';
import '../widgets/verification_timeout_widget.dart';
import 'package:permission_handler/permission_handler.dart';
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── Dropdown state ────────────────────────────────────────────────────────
  String? _age;
  String? _gender;
  String? _ethnicity;
  String? _ethnicityCode;
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
  DateTime? _recordStartTime;

  // ── Waveform ───────────────────────────────────────────────────────────────
  final List<double> _liveSamples = [];
  final List<double> _rawAmplitudes = [];
  StreamSubscription<Amplitude>? _ampSub;
  final SoftLimiter _limiter = const SoftLimiter();

  // ── Verification prompt (fetched from Firestore on init) ─────────────────
  String _verificationPrompt = 'Say a few words — anything at all.';

  // ── Microphone permission state ───────────────────────────────────────────
  bool _micPermissionDenied = false;

  // ── Upload / verification state ───────────────────────────────────────────
  bool _isUploading = false;
  bool _isVerifying = false;
  bool _verifyTimedOut = false;
  int _attemptsRemaining = _maxVerificationAttempts;
  StreamSubscription<dynamic>? _verificationSub;

  static const int _maxVerificationAttempts = 5;
  static const String _prefAttemptCount = 'verificationAttemptCount';
  static const String _prefWindowStart  = 'verificationWindowStart';

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
  // ONS 2021 Census categories. Display strings stored as selfReportedEthnicity;
  // codes stored as selfReportedEthnicityCode. Custom typed values get 'other_unlisted'.
  static const Map<String, String> _onsCodeMap = {
    'English, Welsh, Scottish, Northern Irish or British': 'White_British',
    'Irish':                                               'White_Irish',
    'Gypsy or Irish Traveller':                            'White_Gypsy_Irish_Traveller',
    'Roma':                                                'White_Roma',
    'Any other White background':                          'White_Other',
    'White and Black Caribbean':                           'Mixed_White_Black_Caribbean',
    'White and Black African':                             'Mixed_White_Black_African',
    'White and Asian':                                     'Mixed_White_Asian',
    'Any other Mixed or Multiple background':              'Mixed_Other',
    'Indian':                                              'Asian_Indian',
    'Pakistani':                                           'Asian_Pakistani',
    'Bangladeshi':                                         'Asian_Bangladeshi',
    'Chinese':                                             'Asian_Chinese',
    'Any other Asian background':                          'Asian_Other',
    'African':                                             'Black_African',
    'Caribbean':                                           'Black_Caribbean',
    'Any other Black, African or Caribbean background':    'Black_Other',
    'Arab':                                                'Other_Arab',
    'Any other ethnic group':                              'Other_Other',
    'Prefer not to say':                                   'prefer_not_to_say',
  };
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

    WidgetsBinding.instance.addObserver(this);
    _checkMicPermission();
    _fetchVerificationPrompt();
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkMicPermission() async {
    if (kIsWeb) return;
    final status = await Permission.microphone.status;
    if (!mounted) return;
    setState(() => _micPermissionDenied = status.isDenied || status.isPermanentlyDenied);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkMicPermission();
  }

  Future<void> _fetchVerificationPrompt() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('verification_prompts')
          .where('active', isEqualTo: true)
          .get();
      if (snap.docs.isEmpty || !mounted) return;
      final text = snap.docs[Random().nextInt(snap.docs.length)].data()['text'] as String?;
      if (text != null && text.isNotEmpty) setState(() => _verificationPrompt = text);
    } catch (e) {
      debugPrint('[STEWYRT][ONBOARDING] Failed to fetch verification prompt: $e');
    }
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

  // ── Attempt tracking (local, SharedPreferences) ───────────────────────────
  // Server is the source of truth; local count avoids extra Firestore reads.

  Future<void> _incrementAttemptCount() async {
    final prefs = await SharedPreferences.getInstance();
    final windowStart = prefs.getInt(_prefWindowStart) ?? 0;
    final count       = prefs.getInt(_prefAttemptCount) ?? 0;
    final now         = DateTime.now().millisecondsSinceEpoch;
    const window      = 24 * 60 * 60 * 1000;
    if (now - windowStart > window) {
      await prefs.setInt(_prefWindowStart, now);
      await prefs.setInt(_prefAttemptCount, 1);
    } else {
      await prefs.setInt(_prefAttemptCount, count + 1);
    }
  }

  Future<int> _computeAttemptsRemaining() async {
    final prefs = await SharedPreferences.getInstance();
    final windowStart = prefs.getInt(_prefWindowStart) ?? 0;
    final count       = prefs.getInt(_prefAttemptCount) ?? 0;
    final now         = DateTime.now().millisecondsSinceEpoch;
    const window      = 24 * 60 * 60 * 1000;
    if (now - windowStart > window) return _maxVerificationAttempts;
    return (_maxVerificationAttempts - count).clamp(0, _maxVerificationAttempts);
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

    // Permission was pre-requested in initState so this should return instantly.
    // If it's false the user denied in Settings after the initial prompt.
    if (!hasPermission) {
      _pressActive = false;
      if (mounted) setState(() { _isRecording = false; _micPermissionDenied = true; });
      return;
    }
    if (!mounted) { _pressActive = false; return; }

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

    _recordStartTime = DateTime.now();
    _rawAmplitudes.clear();

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
      setState(() {
        _rawAmplitudes.add(kIsWeb
            ? SoftLimiter.webProcess(amp.current)
            : amp.current);
        _liveSamples.add(kIsWeb
            ? SoftLimiter.webProcess(amp.current)
            : _limiter.process(amp.current));
      });
    });

    setState(() => _isRecording = true);
    debugPrint('[BOUNCER] Recording started');

    _maxDurationTimer = Timer(const Duration(seconds: 30), () {
      if (_isRecording) _stopAndUpload();
    });
  }

  Future<void> _cancelRecording() async {
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;
    await _ampSub?.cancel();
    _ampSub = null;
    await _recorder.stop();
    await _recorder.dispose();
    _recorder = AudioRecorder();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _liveSamples.clear();
        _rawAmplitudes.clear();
      });
    }
  }

  Future<void> _stopAndUpload() async {
    if (!_isRecording) return;
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;

    await _ampSub?.cancel();
    _ampSub = null;

    HapticFeedback.heavyImpact();

    final startTime = _recordStartTime;
    final duration = startTime != null
        ? DateTime.now().difference(startTime)
        : Duration.zero;

    final avgAmp = _rawAmplitudes.isEmpty
        ? -100.0
        : _rawAmplitudes.reduce((a, b) => a + b) / _rawAmplitudes.length;

    debugPrint('[BOUNCER] Quality check — duration: ${duration.inMilliseconds}ms, avg amplitude: ${avgAmp.toStringAsFixed(2)}dB');

    if (duration.inMilliseconds < 2000 || (kIsWeb ? avgAmp < 0.05 : avgAmp < -50.0)) {
      debugPrint('[BOUNCER] ❌ Recording rejected — too short or silent');
      await _recorder.stop();
      await _recorder.dispose();
      _recorder = AudioRecorder();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _liveSamples.clear();
          _rawAmplitudes.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1A1A1A),
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text(
              "We didn't catch anything — make sure your mic is on and give us a few seconds!",
              style: GoogleFonts.spaceGrotesk(fontSize: 13, color: _offWhite),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final recordedPath = await _recorder.stop();
    await _recorder.dispose();
    _recorder = AudioRecorder();

    if (!mounted) return;

    if (recordedPath == null) {
      setState(() {
        _isRecording = false;
        _liveSamples.clear();
        _rawAmplitudes.clear();
      });
      return;
    }

    debugPrint('[BOUNCER] Recording stopped — path: $recordedPath — starting upload');

    setState(() {
      _isRecording = false;
      _isUploading = true;
      _liveSamples.clear();
      _rawAmplitudes.clear();
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() { _isRecording = false; _liveSamples.clear(); });
      return;
    }
    final uid = user.uid;

    final uploadStartTime = DateTime.now();
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

    await _incrementAttemptCount();

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
      since: uploadStartTime,
      timeoutSeconds: 45,
      onTimeout: () async {
        _phraseTimer?.cancel();
        _phraseTimer = null;
        _verificationSub = null;
        if (!mounted) return;
        final remaining = await _computeAttemptsRemaining();
        if (!mounted) return;
        setState(() {
          _isVerifying    = false;
          _verifyTimedOut = true;
          _attemptsRemaining = remaining;
        });
      },
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
              'age':          _age,
              'gender':       _gender,
              'ethnicity':    _ethnicity,
              'ethnicityCode': _ethnicityCode,
              'region':       _region,
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
    if (_verifyTimedOut) {
      return Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: VerificationTimeoutWidget(
                attemptsRemaining: _attemptsRemaining,
                onRetry: () => setState(() => _verifyTimedOut = false),
              ),
            ),
          ),
        ),
      );
    }

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
              _EthnicitySearchField(
                value: _ethnicity,
                enabled: !_isRecording && !_isUploading,
                onChanged: (v) => setState(() {
                  _ethnicity = v;
                  _ethnicityCode = v != null ? (_onsCodeMap[v] ?? 'other_unlisted') : null;
                }),
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
                        color: Color(0xFF3DDEC0),
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFF3DDEC0),
                      ),
                      recognizer: _termsRecognizer,
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: const TextStyle(
                        color: Color(0xFF3DDEC0),
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFF3DDEC0),
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
        _pressActive = false;
        if (!_isRecording) return;
        _stopAndUpload();
      },
      onPointerCancel: (_) {
        _pressActive = false;
        if (!_isRecording) return;
        // Cancel = gesture stolen by scroll, not a deliberate release — discard.
        _cancelRecording();
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
          if (_micPermissionDenied) ...[
            MicPermissionBanner(
              message: "Stewyrt needs your microphone to verify you're human. Tap to open Settings.",
            ),
            const SizedBox(height: 12),
          ],
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
                _verificationPrompt,
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

// ── Ethnicity search field ────────────────────────────────────────────────────
// Replaces the static dropdown with a search-as-you-type field backed by the
// ONS 2021 Census category list. Custom text is accepted and stored as-is
// with ethnicityCode = 'other_unlisted'.

class _EthnicitySearchField extends StatefulWidget {
  const _EthnicitySearchField({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  State<_EthnicitySearchField> createState() => _EthnicitySearchFieldState();
}

class _EthnicitySearchFieldState extends State<_EthnicitySearchField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _showList = false;
  List<String> _filtered = _allOptions;

  static const _allOptions = [
    'English, Welsh, Scottish, Northern Irish or British',
    'Irish',
    'Gypsy or Irish Traveller',
    'Roma',
    'Any other White background',
    'White and Black Caribbean',
    'White and Black African',
    'White and Asian',
    'Any other Mixed or Multiple background',
    'Indian',
    'Pakistani',
    'Bangladeshi',
    'Chinese',
    'Any other Asian background',
    'African',
    'Caribbean',
    'Any other Black, African or Caribbean background',
    'Arab',
    'Any other ethnic group',
    'Prefer not to say',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.value != null) _controller.text = widget.value!;
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      setState(() {
        _filtered = _getFiltered(_controller.text);
        _showList = true;
      });
    } else {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _showList = false);
      });
    }
  }

  List<String> _getFiltered(String query) {
    if (query.isEmpty) return _allOptions;
    final q = query.toLowerCase();
    return _allOptions.where((e) => e.toLowerCase().contains(q)).toList();
  }

  void _onTextChanged(String text) {
    setState(() => _filtered = _getFiltered(text));
    widget.onChanged(text.isEmpty ? null : text);
  }

  void _select(String value) {
    _controller.text = value;
    _focusNode.unfocus();
    setState(() => _showList = false);
    widget.onChanged(value);
  }

  void _clear() {
    _controller.clear();
    setState(() {
      _showList = false;
      _filtered = _allOptions;
    });
    widget.onChanged(null);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listVisible = _showList && _filtered.isNotEmpty;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: widget.enabled ? 1.0 : 0.4,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(
                top:    const BorderSide(color: _border),
                left:   const BorderSide(color: _border),
                right:  const BorderSide(color: _border),
                bottom: listVisible ? BorderSide.none : const BorderSide(color: _border),
              ),
              color: _dropdownCanvas,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: widget.enabled,
                    onChanged: _onTextChanged,
                    style: GoogleFonts.spaceGrotesk(fontSize: 14, color: _offWhite),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Search your ethnicity...',
                      hintStyle: GoogleFonts.spaceGrotesk(fontSize: 14, color: _subtle),
                    ),
                  ),
                ),
                if (_controller.text.isNotEmpty)
                  GestureDetector(
                    onTap: _clear,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.close, color: _subtle, size: 18),
                    ),
                  ),
              ],
            ),
          ),
          if (listVisible)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: const BoxDecoration(
                border: Border(
                  left:   BorderSide(color: _border),
                  right:  BorderSide(color: _border),
                  bottom: BorderSide(color: _border),
                ),
                color: _dropdownCanvas,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filtered.length,
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => _select(_filtered[i]),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: i < _filtered.length - 1
                            ? const BorderSide(color: _border)
                            : BorderSide.none,
                      ),
                    ),
                    child: Text(
                      _filtered[i],
                      style: GoogleFonts.spaceGrotesk(fontSize: 14, color: _offWhite),
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
