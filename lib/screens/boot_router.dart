import 'package:flutter/material.dart';
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
  }

  Future<void> _init() async {
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
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.black);
  }
}
