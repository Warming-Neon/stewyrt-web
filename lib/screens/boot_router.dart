import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';
import '../main.dart';
import 'day_one_screen.dart';
import 'onboarding_screen.dart';

class BootRouter extends StatefulWidget {
  const BootRouter({super.key});

  @override
  State<BootRouter> createState() => _BootRouterState();
}

class _BootRouterState extends State<BootRouter> {
  @override
  void initState() {
    super.initState();
    _init();
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showComplianceBanner(context);
      });
    }
  }

  void _showComplianceBanner(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1A1A1A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 12),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        content: Text.rich(
          TextSpan(
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFAAAAAA), height: 1.5),
            children: [
              TextSpan(
                text: 'Mindful usage: ',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF00FFCC),
                ),
              ),
              const TextSpan(
                text: 'Stewyrt is for emotional insight, not "doom listening" or bias confirmation. '
                    'This data holds no legal standing. '
                    'We use local storage for your session only — no tracking. ',
              ),
              TextSpan(
                text: 'Note: Our AI can make mistakes. ',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF00FFCC),
                ),
              ),
              const TextSpan(
                text: 'All analysis is an interpretation — please use the platform mindfully.',
              ),
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

      if (!mounted) return;

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
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.black);
  }
}
