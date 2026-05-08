import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/sentiment_data.dart';
import 'audio_player_widget.dart';

class SentimentExpandedSheet extends StatelessWidget {
  final SentimentData data;

  const SentimentExpandedSheet({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final text = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final sub = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final border = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEEEEEE);
    final handle = sub.withValues(alpha: 0.4);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: handle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 28),

            // Tag + topic header
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  data.tag,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: text,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'on ${data.topic}',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: sub,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Summary
            Text(
              data.summary,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                color: text,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 24),

            Divider(color: border, height: 1),
            const SizedBox(height: 24),

            // Audio player
            Text(
              'LISTEN',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: sub,
                letterSpacing: 2.5,
              ),
            ),
            const SizedBox(height: 12),
            AudioPlayerWidget(data: data),

            const SizedBox(height: 28),
            Divider(color: border, height: 1),
            const SizedBox(height: 24),

            // Sentiment breakdown
            Text(
              'BREAKDOWN',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: sub,
                letterSpacing: 2.5,
              ),
            ),
            const SizedBox(height: 16),
            ...data.breakdown.entries.map(
              (e) => _BreakdownRow(
                label: e.key,
                value: e.value,
                textColor: text,
                subColor: sub,
                borderColor: border,
                isDark: isDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final double value;
  final Color textColor;
  final Color subColor;
  final Color borderColor;
  final bool isDark;

  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.textColor,
    required this.subColor,
    required this.borderColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              Text(
                '$pct%',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: subColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (_, constraints) => Stack(
              children: [
                Container(
                  height: 3,
                  width: constraints.maxWidth,
                  decoration: BoxDecoration(
                    color: borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  height: 3,
                  width: constraints.maxWidth * value,
                  decoration: BoxDecoration(
                    color: textColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
