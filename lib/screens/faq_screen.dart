import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  static const _items = [
    (
      q: 'How does verification work?',
      a: 'You record a few seconds of audio. We use AI to confirm you\'re a real human — not a bot or synthesised voice. The recording is deleted immediately after. We never use it to identify you.',
    ),
    (
      q: 'Is my voice really anonymous?',
      a: 'Yes. Your verification audio is deleted within seconds. Your sentiment recordings are kept for 120 days then permanently deleted. The only data we retain is the structured analysis (tone, feeling, essence) — which can never be traced back to your voice.',
    ),
    (
      q: 'Why only 30 seconds?',
      a: 'Constraint breeds honesty. 30 seconds is enough to say something real without overthinking it.',
    ),
    (
      q: 'What is the brain visualisation?',
      a: 'The Resonance maps collective emotional responses to brain regions. It shows how the world is feeling right now — which emotions are active, how they connect, and where they sit in the human experience.',
    ),
    (
      q: 'How is my data used?',
      a: 'Anonymised, aggregated sentiment trends are shared with research institutions, journalists, and public health organisations. We never sell individual data or anything that could identify you.',
    ),
    (
      q: 'Can I delete my data?',
      a: 'Yes — go to Settings → Delete My Data. This permanently removes everything we hold about you.',
    ),
    (
      q: 'Why does Stewyrt exist?',
      a: 'To give everyone a voice in the global conversation — anonymously, honestly, without the performance of social media.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg  = isDark ? Colors.black : Colors.white;
    final fg  = isDark ? const Color(0xFFF5F5F5) : Colors.black;
    final sub = isDark ? const Color(0xFF888888) : const Color(0xFF777777);
    final divider = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEEEEEE);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Icon(Icons.arrow_back_ios_new_rounded, color: fg, size: 18),
        ),
        title: Text(
          'FAQ',
          style: GoogleFonts.spaceGrotesk(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        itemCount: _items.length,
        separatorBuilder: (_, _) => Divider(color: divider, height: 32),
        itemBuilder: (_, i) {
          final item = _items[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.q,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                item.a,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  color: sub,
                  height: 1.6,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
