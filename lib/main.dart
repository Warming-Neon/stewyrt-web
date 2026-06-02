import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/archive_screen.dart';
import 'screens/pulse_screen.dart';
import 'screens/resonance_screen.dart';
import 'screens/boot_router.dart';
import 'screens/settings_screen.dart';
import 'services/resonance_controller.dart';
import 'theme/app_theme.dart';
import 'theme/theme_notifier.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeNotifier(),
      child: const StewyrtApp(),
    ),
  );
}

class _TightBouncingPhysics extends BouncingScrollPhysics {
  const _TightBouncingPhysics({super.parent});

  @override
  _TightBouncingPhysics applyTo(ScrollPhysics? ancestor) =>
      _TightBouncingPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      const SpringDescription(mass: 0.5, stiffness: 500.0, damping: 24.0);
}

class _BouncingScrollBehavior extends ScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const _TightBouncingPhysics();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  Set<PointerDeviceKind> get dragDevices => kIsWeb
      ? {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        }
      : super.dragDevices;
}

class StewyrtApp extends StatelessWidget {
  const StewyrtApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    return MaterialApp(
      title: 'Stewyrt',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeNotifier.mode,
      scrollBehavior: _BouncingScrollBehavior(),
      navigatorObservers: [ResonanceController.routeObserver],
      home: const BootRouter(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    ResonanceController.registerTabSwitcher(_selectTab);
  }

  void _selectTab(int i) {
    if (_selectedIndex == 1 && i != 1) ResonanceController.stopSpin();
    setState(() => _selectedIndex = i);
  }

  static final _screens = [
    const PulseScreen(),
    const ResonanceScreen(),
    const ArchiveScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeNotifier = context.read<ThemeNotifier>();
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final textColor = isDark
        ? const Color(0xFFF5F5F5)
        : const Color(0xFF000000);
    final subColor = isDark ? const Color(0xFF888888) : const Color(0xFF666666);
    final borderColor = isDark
        ? const Color(0xFF1A1A1A)
        : const Color(0xFFEEEEEE);
    final isWide = MediaQuery.of(context).size.width >= 600;

    final tabs = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _NavItem(
          label: 'Stewyrt',
          icon: Icons.graphic_eq_rounded,
          iconWidget: Text(
            'S',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: _selectedIndex == 0 ? textColor : subColor,
              height: 1,
            ),
          ),
          selected: _selectedIndex == 0,
          textColor: textColor,
          subColor: subColor,
          onTap: () => _selectTab(0),
        ),
        const SizedBox(width: 24),
        _NavItem(
          label: 'The Resonance',
          icon: Icons.blur_on_rounded,
          selected: _selectedIndex == 1,
          textColor: textColor,
          subColor: subColor,
          onTap: () => _selectTab(1),
        ),
        const SizedBox(width: 24),
        _NavItem(
          label: 'The Archive',
          icon: Icons.grid_view_rounded,
          selected: _selectedIndex == 2,
          textColor: textColor,
          subColor: subColor,
          onTap: () => _selectTab(2),
        ),
      ],
    );

    return Scaffold(
      appBar: isWide
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: SafeArea(
                bottom: false,
                child: Container(
                  height: 40,
                  color: bgColor,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Icon(
                            Icons.settings_outlined,
                            color: subColor,
                            size: 20,
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
      body: IndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: borderColor, width: 1)),
          color: bgColor,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: isWide
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      tabs,
                      Positioned(
                        left: 4,
                        child: GestureDetector(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsScreen(),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Icon(
                              Icons.settings_outlined,
                              color: subColor,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : tabs,
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final Widget? iconWidget;
  final bool selected;
  final Color textColor;
  final Color subColor;
  final VoidCallback onTap;

  const _NavItem({
    required this.label,
    required this.icon,
    this.iconWidget,
    required this.selected,
    required this.textColor,
    required this.subColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? textColor : subColor;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconWidget ?? Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
