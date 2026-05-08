import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/sentiment_data.dart';

class AudioPlayerWidget extends StatefulWidget {
  final SentimentData data;

  const AudioPlayerWidget({super.key, required this.data});

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Timer? _ticker;

  Duration get _total => widget.data.audioLength;

  void _togglePlayback() {
    HapticFeedback.lightImpact();
    if (_isPlaying) {
      _ticker?.cancel();
      setState(() => _isPlaying = false);
    } else {
      if (_position >= _total) _position = Duration.zero;
      setState(() => _isPlaying = true);
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() {
          _position += const Duration(milliseconds: 200);
          if (_position >= _total) {
            _position = _total;
            _isPlaying = false;
            _ticker?.cancel();
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF0F0F0);
    final sub = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final progress = _total.inMilliseconds > 0
        ? _position.inMilliseconds / _total.inMilliseconds
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // Play / Pause button
          GestureDetector(
            onTap: _togglePlayback,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: fg,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: fg.withValues(alpha: isDark ? 0.15 : 0.20),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
                size: 26,
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Waveform + timer
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _WaveformBar(
                  waveformData: widget.data.waveformData,
                  progress: progress,
                  isPlaying: _isPlaying,
                  foreground: fg,
                  muted: sub,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmt(_position),
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                    Text(
                      _fmt(_total),
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 11,
                        color: sub,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformBar extends StatelessWidget {
  final List<double> waveformData;
  final double progress;
  final bool isPlaying;
  final Color foreground;
  final Color muted;

  const _WaveformBar({
    required this.waveformData,
    required this.progress,
    required this.isPlaying,
    required this.foreground,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: CustomPaint(
        painter: _WaveformPainter(
          bars: waveformData,
          progress: progress,
          played: foreground,
          unplayed: muted.withValues(alpha: 0.35),
        ),
        size: const Size(double.infinity, 36),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color played;
  final Color unplayed;

  const _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.played,
    required this.unplayed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final count = bars.length;
    const gap = 2.0;
    final barWidth = (size.width - (count - 1) * gap) / count;
    final progressX = size.width * progress;

    for (var i = 0; i < count; i++) {
      final x = i * (barWidth + gap);
      final barHeight = max(3.0, bars[i] * size.height);
      final top = (size.height - barHeight) / 2;

      final paint = Paint()
        ..color = x + barWidth <= progressX ? played : unplayed
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, barHeight),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.played != played || old.unplayed != unplayed;
}
