import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'attendance_backend.dart';

class AttendanceSummary extends StatelessWidget {
  const AttendanceSummary({
    super.key,
    required this.present,
    required this.absent,
    required this.leaves,
    this.totalEligible,
    this.percentage,
  });

  factory AttendanceSummary.fromSummary(StudentAttendanceSummary summary) {
    return AttendanceSummary(
      present: summary.present,
      absent: summary.absent,
      leaves: summary.leaves,
      totalEligible: summary.total,
      percentage: summary.percentage,
    );
  }

  final int present;
  final int absent;
  final int leaves;
  final int? totalEligible;
  final double? percentage;

  // The palette matching the uploaded reference design
  static const Color presentColor = Color(0xFFE5E6FD); // Soft Lavender
  static const Color presentBorderColor = Color(0xFFC7C5F4);
  static const Color absentColor = Color(0xFF7568F6); // Vibrant Purple / Violet
  static const Color leaveColor = Color(0xFF4C477A); // Deep Slate Indigo
  static const Color textDark = Color(0xFF1E293B);
  static const Color textMuted = Color(0xFF64748B);

  int get effectiveTotal {
    if (totalEligible != null && totalEligible! > 0) {
      return totalEligible!;
    }
    return present + absent + leaves;
  }

  double get effectivePercentage {
    if (percentage != null) return percentage!;
    if (effectiveTotal == 0) return 0.0;
    return (present / effectiveTotal) * 100;
  }

  @override
  Widget build(BuildContext context) {
    final total = effectiveTotal;
    final presentPct = total == 0 ? 0.0 : (present / total) * 100;
    final absentPct = total == 0 ? 0.0 : (absent / total) * 100;
    final leavePct = total == 0 ? 0.0 : (leaves / total) * 100;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x18102040),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Attendance Overview',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: textDark,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Your attendance at a glance',
                      style: TextStyle(
                        fontSize: 13,
                        color: textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: effectivePercentage >= 75
                      ? const Color(0xFFEFFBF5)
                      : const Color(0xFFFFF4EC),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: effectivePercentage >= 75
                        ? const Color(0xFF22C55E).withValues(alpha: 0.3)
                        : const Color(0xFFF97316).withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  '${effectivePercentage.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: effectivePercentage >= 75
                        ? const Color(0xFF16A34A)
                        : const Color(0xFFEA580C),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 26),

          // Circular Doughnut Chart
          Center(
            child: SizedBox(
              width: 170,
              height: 170,
              child: CustomPaint(
                size: const Size(170, 170),
                painter: _AttendanceDoughnutPainter(
                  present: present,
                  absent: absent,
                  leaves: leaves,
                  presentColor: presentColor,
                  presentBorderColor: presentBorderColor,
                  absentColor: absentColor,
                  leaveColor: leaveColor,
                ),
              ),
            ),
          ),

          const SizedBox(height: 26),

          // Legend
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                _LegendRow(
                  color: presentColor,
                  borderColor: presentBorderColor,
                  label: 'Present',
                  percentage: presentPct,
                ),
                const SizedBox(height: 14),
                _LegendRow(
                  color: absentColor,
                  label: 'Absent',
                  percentage: absentPct,
                ),
                const SizedBox(height: 14),
                _LegendRow(
                  color: leaveColor,
                  label: 'Leaves',
                  percentage: leavePct,
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const Divider(color: Color(0xFFEEF2F6), height: 1, thickness: 1),
          const SizedBox(height: 20),

          // Statistics Cards matching the reference layout
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFEDF2F7)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                _StatItem(
                  title: 'Present',
                  count: present,
                  isFirst: true,
                ),
                const Divider(
                  height: 1,
                  thickness: 1.5,
                  color: absentColor,
                ),
                _StatItem(
                  title: 'Absent',
                  count: absent,
                ),
                const Divider(
                  height: 1,
                  thickness: 1.5,
                  color: absentColor,
                ),
                _StatItem(
                  title: 'Leaves',
                  count: leaves,
                  isLast: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          Center(
            child: Text(
              total == 0
                  ? 'No eligible sessions recorded'
                  : 'Total conducted classes: $total',
              style: const TextStyle(
                color: textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    this.borderColor,
    required this.label,
    required this.percentage,
  });

  final Color color;
  final Color? borderColor;
  final String label;
  final double percentage;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: borderColor != null
                ? Border.all(color: borderColor!, width: 1.5)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AttendanceSummary.textDark,
            ),
          ),
        ),
        Text(
          '${percentage.toStringAsFixed(0)}%',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AttendanceSummary.textDark,
          ),
        ),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.title,
    required this.count,
    this.isFirst = false,
    this.isLast = false,
  });

  final String title;
  final int count;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(
          top: isFirst ? const Radius.circular(18) : Radius.zero,
          bottom: isLast ? const Radius.circular(18) : Radius.zero,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AttendanceSummary.textDark,
              ),
            ),
          ),
          Text(
            count.toString(),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: AttendanceSummary.textDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceDoughnutPainter extends CustomPainter {
  const _AttendanceDoughnutPainter({
    required this.present,
    required this.absent,
    required this.leaves,
    required this.presentColor,
    required this.presentBorderColor,
    required this.absentColor,
    required this.leaveColor,
  });

  final int present;
  final int absent;
  final int leaves;
  final Color presentColor;
  final Color presentBorderColor;
  final Color absentColor;
  final Color leaveColor;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 26.0;

    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width - strokeWidth,
      height: size.height - strokeWidth,
    );

    final total = present + absent + leaves;

    // If total is 0, draw an empty ring
    if (total == 0) {
      final emptyPaint = Paint()
        ..color = const Color(0xFFF1F3FA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;

      canvas.drawArc(rect, 0, math.pi * 2, false, emptyPaint);
      return;
    }

    // Segments ordered clockwise: Leaves, Absent, Present
    // matching the visual layout of media_1793223905481.png
    final segments = [
      (leaves, leaveColor, null),
      (absent, absentColor, null),
      (present, presentColor, presentBorderColor),
    ];

    var startAngle = -math.pi / 2;

    for (final segment in segments) {
      final value = segment.$1;
      final color = segment.$2;
      final outline = segment.$3;

      if (value <= 0) continue;

      final sweepAngle = (value / total) * (math.pi * 2);

      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;

      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);

      if (outline != null) {
        final outlinePaint = Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;

        // Draw inner and outer edge borders for light-colored segment
        final innerRadius = (size.width - strokeWidth * 2) / 2;
        final outerRadius = size.width / 2;
        final innerRect = Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: innerRadius * 2,
          height: innerRadius * 2,
        );
        final outerRect = Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: outerRadius * 2,
          height: outerRadius * 2,
        );
        canvas.drawArc(innerRect, startAngle, sweepAngle, false, outlinePaint);
        canvas.drawArc(outerRect, startAngle, sweepAngle, false, outlinePaint);
      }

      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _AttendanceDoughnutPainter oldDelegate) {
    return oldDelegate.present != present ||
        oldDelegate.absent != absent ||
        oldDelegate.leaves != leaves ||
        oldDelegate.presentColor != presentColor ||
        oldDelegate.absentColor != absentColor ||
        oldDelegate.leaveColor != leaveColor;
  }
}


