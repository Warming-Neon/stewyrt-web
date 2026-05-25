import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:auto_size_text/auto_size_text.dart';

class PollCard extends StatelessWidget {
  final String question;
  final String category;
  final String tier;
  final VoidCallback? onTap;
  final VoidCallback? onViewResonance;

  const PollCard({
    super.key,
    required this.question,
    required this.category,
    required this.tier,
    this.onTap,
    this.onViewResonance,
  });

  String get _label {
    switch (tier) {
      case 'horizon':     return 'HORIZON';
      case 'ice_breaker': return 'ICE BREAKER';
      default:            return 'THE PULSE';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0D0D0D) : const Color(0xFFF5F5F5);
    final border = isDark ? const Color(0xFF222222) : const Color(0xFFDDDDDD);
    final textColor = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final subColor = isDark ? const Color(0xFF888888) : const Color(0xFF666666);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.08),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _label,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: subColor,
                  letterSpacing: 2,
                ),
              ),
              Expanded(
                flex: 1,
                child: Center(
                  child: AutoSizeText(
                    question,
                    textAlign: TextAlign.center,
                    maxLines: 10,
                    minFontSize: 12,
                    maxFontSize: 28,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onTap != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          border: Border.all(color: border),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded, size: 14, color: subColor),
                            const SizedBox(width: 8),
                            Text(
                              'Press to respond',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 12,
                                color: subColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (onViewResonance != null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          onViewResonance!();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            border: Border.all(color: border.withValues(alpha: 0.6)),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.blur_on_rounded, size: 13, color: subColor),
                              const SizedBox(width: 6),
                              Text(
                                'View The Resonance',
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 11,
                                  color: subColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
