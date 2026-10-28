import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:att/attendance_backend.dart';
import 'package:att/attendance_summary.dart';

void main() {
  group('StudentAttendanceSummary Model Calculations', () {
    test('computes percentage and absent count accurately for standard case', () {
      final summary = StudentAttendanceSummary.fromCounts(
        present: 2,
        totalEligible: 3,
        leaves: 0,
      );

      expect(summary.present, equals(2));
      expect(summary.absent, equals(1));
      expect(summary.leaves, equals(0));
      expect(summary.total, equals(3));
      expect(summary.percentage, closeTo(66.67, 0.01));
    });

    test('handles division by zero when no classes have been conducted', () {
      final summary = StudentAttendanceSummary.fromCounts(
        present: 0,
        totalEligible: 0,
        leaves: 0,
      );

      expect(summary.present, equals(0));
      expect(summary.absent, equals(0));
      expect(summary.leaves, equals(0));
      expect(summary.total, equals(0));
      expect(summary.percentage, equals(0.0));
    });

    test('handles empty() factory properly', () {
      final summary = StudentAttendanceSummary.empty();

      expect(summary.present, equals(0));
      expect(summary.absent, equals(0));
      expect(summary.leaves, equals(0));
      expect(summary.total, equals(0));
      expect(summary.percentage, equals(0.0));
    });

    test('handles 100% attendance rate', () {
      final summary = StudentAttendanceSummary.fromCounts(
        present: 10,
        totalEligible: 10,
        leaves: 0,
      );

      expect(summary.present, equals(10));
      expect(summary.absent, equals(0));
      expect(summary.percentage, equals(100.0));
    });

    test('protects against conducted sessions count lagging behind attended count', () {
      final summary = StudentAttendanceSummary.fromCounts(
        present: 5,
        totalEligible: 3, // edge case: cache or lag
        leaves: 0,
      );

      expect(summary.present, equals(5));
      expect(summary.total, equals(5)); // adjusted to at least present
      expect(summary.absent, equals(0));
      expect(summary.percentage, equals(100.0));
    });

    test('calculates correct absent count when leaves are recorded', () {
      final summary = StudentAttendanceSummary.fromCounts(
        present: 7,
        totalEligible: 10,
        leaves: 1,
      );

      expect(summary.present, equals(7));
      expect(summary.leaves, equals(1));
      expect(summary.absent, equals(2));
      expect(summary.total, equals(10));
      expect(summary.percentage, equals(70.0));
    });

    test('supports explicit present, absent, and leaves counts', () {
      // Direct teacher marked attendance: 2 present, 1 absent, 0 leaves
      final summary = StudentAttendanceSummary.fromCounts(
        present: 2,
        absent: 1,
        leaves: 0,
      );

      expect(summary.present, equals(2));
      expect(summary.absent, equals(1));
      expect(summary.leaves, equals(0));
      expect(summary.total, equals(3));
      expect(summary.percentage, closeTo(66.67, 0.01));
    });

    test('TeacherSession and SessionStudentRosterItem models parse correctly', () {
      final session = TeacherSession.fromJson({
        'id': 'sess-123',
        'title': 'Operating Systems',
        'session_code': '123456',
        'starts_at': '2026-10-29T10:00:00Z',
        'ends_at': '2026-10-29T10:01:00Z',
        'is_active': true,
      }, present: 45, absent: 5);

      expect(session.id, equals('sess-123'));
      expect(session.title, equals('Operating Systems'));
      expect(session.sessionCode, equals('123456'));
      expect(session.isActive, isTrue);
      expect(session.presentCount, equals(45));
      expect(session.absentCount, equals(5));

      final student = SessionStudentRosterItem.fromJson({
        'student_id': 'stud-456',
        'email': '25bcs109@iiitdwd.ac.in',
        'full_name': 'Prasanth Palchuri',
        'register_number': '25BCS109',
        'status': 'present',
      });

      expect(student.studentId, equals('stud-456'));
      expect(student.fullName, equals('Prasanth Palchuri'));
      expect(student.status, equals('present'));

      final updated = student.copyWith(status: 'absent');
      expect(updated.status, equals('absent'));
      expect(updated.studentId, equals('stud-456'));
    });
  });

  group('AttendanceSummary Widget', () {
    testWidgets('renders AttendanceSummary widget with correct values and colors', (tester) async {
      final summary = StudentAttendanceSummary.fromCounts(
        present: 8,
        totalEligible: 10,
        leaves: 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AttendanceSummary.fromSummary(summary),
            ),
          ),
        ),
      );

      expect(find.text('Attendance Overview'), findsOneWidget);
      expect(find.text('Your attendance at a glance'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.text('Total conducted classes: 10'), findsOneWidget);

      // Verify legend and stat items
      expect(find.text('Present'), findsNWidgets(2)); // legend + stat card
      expect(find.text('Absent'), findsNWidgets(2));  // legend + stat card
      expect(find.text('Leaves'), findsNWidgets(2));  // legend + stat card
      expect(find.text('8'), findsOneWidget); // present count
      expect(find.text('2'), findsOneWidget); // absent count
      expect(find.text('0'), findsOneWidget); // leaves count
    });

    testWidgets('renders zero state gracefully without errors', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AttendanceSummary.fromSummary(StudentAttendanceSummary.empty()),
            ),
          ),
        ),
      );

      expect(find.text('0.0%'), findsOneWidget);
      expect(find.text('No eligible sessions recorded'), findsOneWidget);
    });
  });
}
