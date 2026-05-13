import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared recovery UI shown when verification or sentiment analysis times out.
///
/// [attemptsRemaining] — when non-null, shows "You've got N attempts remaining
/// today." When null (no attempt limit, e.g. sentiment pipeline), shows a
/// generic retry prompt.
class VerificationTimeoutWidget extends StatelessWidget {
  const VerificationTimeoutWidget({
    super.key,
    required this.attemptsRemaining,
    required this.onRetry,
  });

  final int? attemptsRemaining;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final remaining = attemptsRemaining;
    final bodyText = remaining != null
        ? "Something's a bit slow on our end. You've got "
              "$remaining attempt${remaining == 1 ? '' : 's'} remaining today."
        : "Something's a bit slow on our end. Give it a moment and try again.";

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.timer_off_outlined,
          color: Color(0xFFFFB74D),
          size: 44,
        ),
        const SizedBox(height: 20),
        Text(
          "Stewyrt's taking longer than usual",
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
          bodyText,
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 13,
            color: const Color(0xFFAAAAAA),
            height: 1.6,
          ),
        ),
        const SizedBox(height: 32),
        GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            onRetry();
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFFF5F5F5).withValues(alpha: 0.25),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Text(
              'Try again',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFF5F5F5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
