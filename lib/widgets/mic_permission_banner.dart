import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

class MicPermissionBanner extends StatelessWidget {
  const MicPermissionBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: kIsWeb ? null : () => openAppSettings(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFB74D).withValues(alpha: 0.10),
          border: Border.all(
            color: const Color(0xFFFFB74D).withValues(alpha: 0.4),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.mic_off_outlined,
              color: Color(0xFFFFB74D),
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  color: const Color(0xFFFFB74D),
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
