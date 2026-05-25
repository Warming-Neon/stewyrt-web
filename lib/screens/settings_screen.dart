import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/theme_notifier.dart';
import 'faq_screen.dart';
import 'boot_router.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  bool _deletingData = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    final v = info.version.isNotEmpty ? info.version : '';
    final b = info.buildNumber.isNotEmpty ? info.buildNumber : '';
    setState(() => _version = [if (v.isNotEmpty) v, if (b.isNotEmpty) '($b)'].join(' '));
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      debugPrint('[STEWYRT][SETTINGS] Could not launch $url');
    }
  }

  Future<void> _confirmAndDeleteData(BuildContext context, bool isDark, Color fg) async {
    final nav       = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text(
          'Delete your data?',
          style: GoogleFonts.spaceGrotesk(color: fg, fontWeight: FontWeight.w600),
        ),
        content: Text(
          'This permanently deletes all your responses and account data. This cannot be undone.',
          style: GoogleFonts.spaceGrotesk(
            color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666),
            fontSize: 14,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: GoogleFonts.spaceGrotesk(
                color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete',
              style: GoogleFonts.spaceGrotesk(
                color: Colors.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _deletingData = true);

    try {
      await FirebaseFunctions.instance.httpsCallable('deleteUserData').call();
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const BootRouter()),
        (_) => false,
      );
    } catch (e) {
      debugPrint('[STEWYRT][SETTINGS] deleteUserData failed: $e');
      if (!mounted) return;
      setState(() => _deletingData = false);
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1A1A1A),
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          content: Text(
            'Failed to delete data — please try again.',
            style: GoogleFonts.spaceGrotesk(fontSize: 13, color: const Color(0xFFF5F5F5)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark        = Theme.of(context).brightness == Brightness.dark;
    final bg            = isDark ? Colors.black : Colors.white;
    final fg            = isDark ? const Color(0xFFF5F5F5) : Colors.black;
    final sub           = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final border        = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEEEEEE);
    final themeNotifier = context.watch<ThemeNotifier>();

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            Navigator.of(context).pop();
          },
          child: Icon(Icons.arrow_back_ios_new_rounded, color: fg, size: 18),
        ),
        title: Text(
          'Settings',
          style: GoogleFonts.spaceGrotesk(color: fg, fontWeight: FontWeight.w600),
        ),
      ),
      body: _deletingData
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: fg,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Deleting your data...',
                    style: GoogleFonts.spaceGrotesk(fontSize: 14, color: sub),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                _SectionHeader('APPEARANCE', sub),
                _SwitchRow(
                  label: 'Dark mode',
                  value: themeNotifier.mode == ThemeMode.dark,
                  fg: fg,
                  border: border,
                  onChanged: (_) {
                    HapticFeedback.lightImpact();
                    themeNotifier.toggle();
                  },
                ),
                _SectionHeader('LEGAL', sub),
                _TapRow(
                  label: 'Terms of Service',
                  fg: fg, sub: sub, border: border,
                  onTap: () => _openUrl('https://stewyrt.com/terms.html'),
                ),
                _TapRow(
                  label: 'Privacy Policy',
                  fg: fg, sub: sub, border: border,
                  onTap: () => _openUrl('https://stewyrt.com/privacy.html'),
                ),
                _TapRow(
                  label: 'Child Safety Policy',
                  fg: fg, sub: sub, border: border,
                  onTap: () => _openUrl('https://stewyrt.com/child-safety.html'),
                ),
                _SectionHeader('SUPPORT', sub),
                _TapRow(
                  label: 'Contact Support',
                  fg: fg, sub: sub, border: border,
                  onTap: () => _openUrl('mailto:support@stewyrt.com'),
                ),
                _TapRow(
                  label: 'FAQ',
                  fg: fg, sub: sub, border: border,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FaqScreen()),
                  ),
                ),
                _SectionHeader('ABOUT', sub),
                _TapRow(
                  label: 'About Stewyrt',
                  fg: fg, sub: sub, border: border,
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      title: Text(
                        'About Stewyrt',
                        style: GoogleFonts.spaceGrotesk(
                          color: fg, fontWeight: FontWeight.w600,
                        ),
                      ),
                      content: Text(
                        'Stewyrt is an anonymous, audio-only sentiment platform. We capture how the world '
                        'is feeling — not who is feeling it. Your voice is your data. We never sell it.\n\n'
                        'Version $_version',
                        style: GoogleFonts.spaceGrotesk(
                          color: sub, fontSize: 14, height: 1.6,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            'OK',
                            style: GoogleFonts.spaceGrotesk(color: fg, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _SectionHeader('ACCOUNT', sub),
                _TapRow(
                  label: 'Delete My Data',
                  fg: Colors.redAccent, sub: sub, border: border,
                  showChevron: false,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _confirmAndDeleteData(context, isDark, fg);
                  },
                ),
                const SizedBox(height: 48),
                Center(
                  child: Text(
                    _version.isNotEmpty ? 'Version $_version' : '',
                    style: GoogleFonts.spaceGrotesk(fontSize: 12, color: sub),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

// ── Private widgets ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
      child: Text(
        label,
        style: GoogleFonts.spaceGrotesk(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 1.8,
        ),
      ),
    );
  }
}

class _TapRow extends StatelessWidget {
  const _TapRow({
    required this.label,
    required this.fg,
    required this.sub,
    required this.border,
    required this.onTap,
    this.showChevron = true,
  });

  final String label;
  final Color fg;
  final Color sub;
  final Color border;
  final VoidCallback onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.spaceGrotesk(fontSize: 15, color: fg),
              ),
            ),
            if (showChevron)
              Icon(Icons.chevron_right_rounded, color: sub, size: 20),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.fg,
    required this.border,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final Color fg;
  final Color border;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.spaceGrotesk(fontSize: 15, color: fg),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFF3DDEC0),
          ),
        ],
      ),
    );
  }
}
