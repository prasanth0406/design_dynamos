import 'package:flutter_test/flutter_test.dart';
import 'package:att/main.dart';
import 'package:att/attendance_backend.dart';

void main() {
  group('DeviceAccountBinding Tests', () {
    test('encode and decode matches correctly', () {
      const original = DeviceAccountBinding(
        userId: '11111111-2222-3333-4444-555555555555',
        role: UserRole.student,
        deviceId: 'device-test-uuid-1234',
      );

      final encoded = original.encode();
      final decoded = DeviceAccountBinding.decode(encoded);

      expect(decoded.userId, equals(original.userId));
      expect(decoded.role, equals(original.role));
      expect(decoded.deviceId, equals(original.deviceId));
    });

    test('malformed json throws FormatException', () {
      expect(() => DeviceAccountBinding.decode('invalid json'), throwsFormatException);
      expect(() => DeviceAccountBinding.decode('{"userId": ""}'), throwsFormatException);
      expect(() => DeviceAccountBinding.decode('{"userId": "123", "role": "invalid"}'), throwsFormatException);
    });
  });

  group('Email Validation Tests', () {
    test('Student college emails are accepted', () {
      expect(isValidStudentEmail('23bcs101@iiitdwd.ac.in'), isTrue);
      expect(isValidStudentEmail('24bcs045@iiitdwd.ac.in'), isTrue);
      expect(isValidStudentEmail('25bcs999@iiitdwd.ac.in'), isTrue);
    });

    test('Invalid student emails are rejected', () {
      expect(isValidStudentEmail('22bcs101@iiitdwd.ac.in'), isFalse);
      expect(isValidStudentEmail('25bcs12@iiitdwd.ac.in'), isFalse);
      expect(isValidStudentEmail('student@gmail.com'), isFalse);
      expect(isValidStudentEmail('teacher@iiitdwd.ac.in'), isFalse);
    });

    test('Teacher college emails are accepted', () {
      expect(isValidTeacherEmail('prof.smith@iiitdwd.ac.in'), isTrue);
      expect(isValidTeacherEmail('teacher@iiitdwd.ac.in'), isTrue);
    });

    test('Student emails rejected as teacher emails', () {
      expect(isValidTeacherEmail('25bcs101@iiitdwd.ac.in'), isFalse);
    });
  });

  group('Data Model Parsing Tests', () {
    test('ChallengeResult from json', () {
      final json = {
        'ok': true,
        'challenge': 'SDTT:unlock:12345:uid:did:12345678',
        'expiresAt': '2026-10-29T10:00:00Z',
      };
      final result = ChallengeResult.fromJson(json);
      expect(result.ok, isTrue);
      expect(result.challenge, equals('SDTT:unlock:12345:uid:did:12345678'));
    });

    test('DeviceStatus from json', () {
      final json = {
        'registered': true,
        'deviceId': 'test-dev-1',
        'deviceName': 'Pixel 8',
        'registeredAt': '2026-10-29T09:00:00Z',
      };
      final status = DeviceStatus.fromJson(json);
      expect(status.registered, isTrue);
      expect(status.deviceId, equals('test-dev-1'));
      expect(status.deviceName, equals('Pixel 8'));
    });

    test('AttendanceResult from json', () {
      final json = {
        'ok': true,
        'code': 'present',
        'message': 'Attendance marked successfully.',
        'session_name': 'CS101',
        'student_email': '25bcs101@iiitdwd.ac.in',
        'status': 'Present',
      };
      final res = AttendanceResult.fromJson(json);
      expect(res.ok, isTrue);
      expect(res.code, equals('present'));
      expect(res.sessionName, equals('CS101'));
      expect(res.studentEmail, equals('25bcs101@iiitdwd.ac.in'));
    });
  });
}
