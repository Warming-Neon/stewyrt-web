import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../main.dart';
import 'day_one_screen.dart';
import 'onboarding_screen.dart';

class BootRouter extends StatefulWidget {
  const BootRouter({super.key});

  @override
  State<BootRouter> createState() => _BootRouterState();
}

class _BootRouterState extends State<BootRouter> with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnim;
  final _termsRecognizer = TapGestureRecognizer();
  final _privacyRecognizer = TapGestureRecognizer();

  @override
  void initState() {
    super.initState();
    _termsRecognizer.onTap = () => launchUrl(Uri.parse('https://stewyrt.com/terms.html'));
    _privacyRecognizer.onTap = () => launchUrl(Uri.parse('https://stewyrt.com/privacy.html'));
    _fadeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeIn);
    _fadeController.forward();
    _init();
  }

  void _showComplianceBanner(BuildContext context, SharedPreferences prefs) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1A1A1A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 12),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        action: SnackBarAction(
          label: 'Got it',
          textColor: const Color(0xFF3DDEC0),
          onPressed: () {
            prefs.setBool('hasSeenComplianceBanner', true);
          },
        ),
        content: Text.rich(
          TextSpan(
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFAAAAAA), height: 1.5),
            children: [
              TextSpan(
                text: 'Mindful usage: ',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF3DDEC0),
                ),
              ),
              const TextSpan(
                text: 'Stewyrt is for emotional insight, not doom-scrolling. '
                    'Your voice is verified once then deleted immediately. '
                    'Sentiment recordings are kept for 120 days, then gone. '
                    'AI analysis is interpretation, not fact. '
                    'And we never sell who you are — only how the world feels. ',
              ),
              const TextSpan(text: 'By continuing you agree to our '),
              TextSpan(
                text: 'Terms',
                recognizer: _termsRecognizer,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  color: const Color(0xFF3DDEC0),
                  decoration: TextDecoration.underline,
                  decorationColor: const Color(0xFF3DDEC0),
                ),
              ),
              const TextSpan(text: ' and '),
              TextSpan(
                text: 'Privacy Policy',
                recognizer: _privacyRecognizer,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  color: const Color(0xFF3DDEC0),
                  decoration: TextDecoration.underline,
                  decorationColor: const Color(0xFF3DDEC0),
                ),
              ),
              const TextSpan(text: '.'),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _init() async {
    try {
      await AuthService.signInAnonymously();

      final prefs = await SharedPreferences.getInstance();
      final hasPassedBouncer   = prefs.getBool('hasPassedBouncer')   ?? false;
      final hasCompletedDayOne = prefs.getBool('hasCompletedDayOne') ?? false;
      final hasSeenBanner      = prefs.getBool('hasSeenComplianceBanner') ?? false;

      if (!mounted) return;

      if (!hasSeenBanner) {
        _showComplianceBanner(context, prefs);
      }

      final Widget destination;
      if (!hasPassedBouncer) {
        destination = const OnboardingScreen();
      } else if (!hasCompletedDayOne) {
        destination = const DayOneScreen();
      } else {
        destination = const RootShell();
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => destination),
      );
    } catch (e, s) {
      debugPrint('[STEWYRT][BOOT] Init failed: $e\n$s');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1A1A1A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          content: Text(
            'Connection error — please refresh the page.',
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFAAAAAA)),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Text(
            'stewyrt',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
