import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StudentAttendanceSummary {
  const StudentAttendanceSummary({
    required this.present,
    required this.absent,
    required this.leaves,
    required this.total,
    required this.percentage,
  });

  final int present;
  final int absent;
  final int leaves;
  final int total;
  final double percentage;

  factory StudentAttendanceSummary.empty() {
    return const StudentAttendanceSummary(
      present: 0,
      absent: 0,
      leaves: 0,
      total: 0,
      percentage: 0.0,
    );
  }

  factory StudentAttendanceSummary.fromCounts({
    required int present,
    int? absent,
    int? totalEligible,
    int leaves = 0,
  }) {
    final validPresent = present < 0 ? 0 : present;
    final validLeaves = leaves < 0 ? 0 : leaves;
    int validAbsent;
    int validTotal;

    if (absent != null) {
      validAbsent = absent < 0 ? 0 : absent;
      validTotal = totalEligible != null && totalEligible > (validPresent + validAbsent + validLeaves)
          ? totalEligible
          : (validPresent + validAbsent + validLeaves);
    } else {
      validTotal = (totalEligible != null && totalEligible > validPresent)
          ? totalEligible
          : validPresent;
      validAbsent = (validTotal - validPresent - validLeaves) < 0
          ? 0
          : (validTotal - validPresent - validLeaves);
    }

    final percentage = validTotal == 0 ? 0.0 : (validPresent / validTotal) * 100;

    return StudentAttendanceSummary(
      present: validPresent,
      absent: validAbsent,
      leaves: validLeaves,
      total: validTotal,
      percentage: percentage,
    );
  }
}

class TeacherSession {
  const TeacherSession({
    required this.id,
    required this.title,
    required this.sessionCode,
    required this.startsAt,
    required this.endsAt,
    required this.isActive,
    this.presentCount = 0,
    this.absentCount = 0,
  });

  final String id;
  final String title;
  final String sessionCode;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool isActive;
  final int presentCount;
  final int absentCount;

  factory TeacherSession.fromJson(
    Map<String, dynamic> json, {
    int present = 0,
    int absent = 0,
  }) {
    return TeacherSession(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Attendance Session',
      sessionCode: json['session_code']?.toString() ?? '',
      startsAt:
          DateTime.tryParse(json['starts_at']?.toString() ?? '') ?? DateTime.now(),
      endsAt:
          DateTime.tryParse(json['ends_at']?.toString() ?? '') ?? DateTime.now(),
      isActive: json['is_active'] == true,
      presentCount: present,
      absentCount: absent,
    );
  }
}

class SessionStudentRosterItem {
  const SessionStudentRosterItem({
    required this.studentId,
    required this.email,
    required this.fullName,
    required this.registerNumber,
    required this.status,
    this.markedAt,
  });

  final String studentId;
  final String email;
  final String fullName;
  final String registerNumber;
  final String status; // 'present', 'absent', 'unmarked'
  final DateTime? markedAt;

  factory SessionStudentRosterItem.fromJson(Map<String, dynamic> json) {
    return SessionStudentRosterItem(
      studentId: json['student_id']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? 'Student',
      registerNumber: json['register_number']?.toString() ?? '',
      status: (json['status']?.toString() ?? 'unmarked').toLowerCase(),
      markedAt: DateTime.tryParse(json['marked_at']?.toString() ?? ''),
    );
  }

  SessionStudentRosterItem copyWith({
    String? status,
    DateTime? markedAt,
  }) {
    return SessionStudentRosterItem(
      studentId: studentId,
      email: email,
      fullName: fullName,
      registerNumber: registerNumber,
      status: status ?? this.status,
      markedAt: markedAt ?? this.markedAt,
    );
  }
}

class DeviceStatus {
  const DeviceStatus({
    required this.registered,
    this.deviceId,
    this.deviceName,
    this.registeredAt,
  });

  final bool registered;
  final String? deviceId;
  final String? deviceName;
  final DateTime? registeredAt;

  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    return DeviceStatus(
      registered: json['registered'] == true,
      deviceId: json['deviceId']?.toString(),
      deviceName: json['deviceName']?.toString(),
      registeredAt: DateTime.tryParse(json['registeredAt']?.toString() ?? ''),
    );
  }
}

class ChallengeResult {
  const ChallengeResult({
    required this.ok,
    required this.challenge,
    required this.expiresAt,
  });

  final bool ok;
  final String challenge;
  final DateTime expiresAt;

  factory ChallengeResult.fromJson(Map<String, dynamic> json) {
    final challenge = json['challenge']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(json['expiresAt']?.toString() ?? '') ??
        DateTime.now().add(const Duration(seconds: 60));
    return ChallengeResult(
      ok: json['ok'] == true,
      challenge: challenge,
      expiresAt: expiresAt,
    );
  }
}

class ActiveAttendanceSession {
  const ActiveAttendanceSession({
    required this.id,
    required this.sessionCode,
    required this.title,
    required this.endsAt,
    this.teacherId,
  });

  final String id;
  final String sessionCode;
  final String title;
  final DateTime endsAt;
  final String? teacherId;

  factory ActiveAttendanceSession.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final sessionCode = json['session_code']?.toString();
    final title = json['title']?.toString();
    final endsAt = DateTime.tryParse(json['ends_at']?.toString() ?? '');
    if (id == null || sessionCode == null || title == null || endsAt == null) {
      throw const FormatException(
        'Supabase returned incomplete session details.',
      );
    }
    return ActiveAttendanceSession(
      id: id,
      sessionCode: sessionCode,
      title: title,
      endsAt: endsAt,
      teacherId: json['teacher_id']?.toString(),
    );
  }
}

class AttendanceResult {
  const AttendanceResult({
    required this.ok,
    required this.code,
    required this.message,
    this.sessionName,
    this.studentEmail,
    this.status,
  });

  final bool ok;
  final String code;
  final String message;
  final String? sessionName;
  final String? studentEmail;
  final String? status;

  factory AttendanceResult.fromJson(Map<String, dynamic> json) {
    return AttendanceResult(
      ok: json['ok'] == true,
      code: json['code']?.toString() ?? 'unknown',
      message:
          json['message']?.toString() ?? 'Attendance could not be verified.',
      sessionName: json['session_name']?.toString(),
      studentEmail: json['student_email']?.toString(),
      status: json['status']?.toString(),
    );
  }
}

class AttendanceRecord {
  const AttendanceRecord({required this.email, required this.markedAt});

  final String email;
  final DateTime markedAt;

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    final email = json['student_email']?.toString() ?? '';
    final markedAt = DateTime.tryParse(json['marked_at']?.toString() ?? '');
    if (email.isEmpty || markedAt == null) {
      throw const FormatException(
        'Supabase returned an incomplete attendance record.',
      );
    }
    return AttendanceRecord(email: email, markedAt: markedAt);
  }
}

class AttendanceBackend {
  AttendanceBackend(this._client);

  final SupabaseClient _client;

  // --------------------------------------------------------------------------
  // Cryptographic Device Authentication via Supabase Edge Function
  // --------------------------------------------------------------------------

  Future<DeviceStatus> getDeviceStatus() async {
    try {
      final response = await _client.functions.invoke(
        'device-attendance',
        body: {'action': 'get_device_status'},
      );
      return DeviceStatus.fromJson(_mapFromResponse(response.data));
    } catch (e) {
      return const DeviceStatus(registered: false);
    }
  }

  Future<Map<String, dynamic>> registerDevice({
    required String deviceId,
    required String publicKeySpki,
    String deviceName = 'Android Device',
  }) async {
    try {
      final response = await _client.functions.invoke(
        'device-attendance',
        body: {
          'action': 'register_device',
          'deviceId': deviceId,
          'publicKeySpki': publicKeySpki,
          'deviceName': deviceName,
        },
      );
      return _mapFromResponse(response.data);
    } on FunctionException catch (e) {
      if (e.details is Map) {
        return Map<String, dynamic>.from(e.details as Map);
      }
      return {
        'ok': false,
        'code': 'function_error',
        'message': e.reasonPhrase ?? 'Server error (${e.status}).',
      };
    }
  }

  Future<ChallengeResult> createChallenge({
    required String deviceId,
    required String purpose,
    String? sessionId,
    String? sessionCode,
    String? qrCode,
  }) async {
    final response = await _client.functions.invoke(
      'device-attendance',
      body: {
        'action': 'create_challenge',
        'deviceId': deviceId,
        'purpose': purpose,
        'sessionId': sessionId,
        'sessionCode': sessionCode,
        'qrCode': qrCode,
      },
    );
    return ChallengeResult.fromJson(_mapFromResponse(response.data));
  }

  Future<bool> verifyUnlock({
    required String deviceId,
    required String challenge,
    required String signature,
  }) async {
    final response = await _client.functions.invoke(
      'device-attendance',
      body: {
        'action': 'verify_unlock',
        'deviceId': deviceId,
        'challenge': challenge,
        'signature': signature,
      },
    );
    final data = _mapFromResponse(response.data);
    return data['ok'] == true;
  }

  Future<AttendanceResult> verifyAndMarkAttendance({
    required String deviceId,
    required String challenge,
    required String signature,
    required String sessionId,
    required String sessionCode,
    required String qrCode,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'device-attendance',
        body: {
          'action': 'verify_and_mark_attendance',
          'deviceId': deviceId,
          'challenge': challenge,
          'signature': signature,
          'sessionId': sessionId,
          'sessionCode': sessionCode,
          'qrCode': qrCode,
        },
      );
      return AttendanceResult.fromJson(_mapFromResponse(response.data));
    } on FunctionException catch (e) {
      if (e.details is Map) {
        return AttendanceResult.fromJson(
          Map<String, dynamic>.from(e.details as Map),
        );
      }
      return AttendanceResult(
        ok: false,
        code: 'function_error',
        message: e.reasonPhrase ?? 'Server function error (${e.status}).',
      );
    } catch (e) {
      return AttendanceResult(
        ok: false,
        code: 'network_error',
        message: 'Could not connect to verification server: $e',
      );
    }
  }

  Future<Map<String, dynamic>> requestDeviceRecovery({
    required String newDeviceId,
    required String newPublicKeySpki,
    required String reason,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'device-attendance',
        body: {
          'action': 'request_device_recovery',
          'newDeviceId': newDeviceId,
          'newPublicKeySpki': newPublicKeySpki,
          'reason': reason,
        },
      );
      return _mapFromResponse(response.data);
    } on FunctionException catch (e) {
      if (e.details is Map) {
        return Map<String, dynamic>.from(e.details as Map);
      }
      return {
        'ok': false,
        'code': 'function_error',
        'message': e.reasonPhrase ?? 'Server error (${e.status}).',
      };
    }
  }

  // --------------------------------------------------------------------------
  // Existing Teacher Session Management & Realtime
  // --------------------------------------------------------------------------

  Future<ActiveAttendanceSession> createSession({
    required String title,
    required String initialQrCode,
  }) async {
    final response = await _client.rpc(
      'create_attendance_session',
      params: {'p_title': title, 'p_initial_qr_code': initialQrCode},
    );
    return ActiveAttendanceSession.fromJson(_mapFromResponse(response));
  }

  Future<ActiveAttendanceSession?> findActiveSession(String sessionCode) async {
    final response = await _client.rpc(
      'lookup_active_attendance_session',
      params: {'p_session_code': sessionCode},
    );
    if (response == null) return null;
    return ActiveAttendanceSession.fromJson(_mapFromResponse(response));
  }

  Future<void> rotateQr({
    required String sessionId,
    required String qrCode,
  }) async {
    await _client.rpc(
      'rotate_attendance_qr',
      params: {'p_session_id': sessionId, 'p_qr_code': qrCode},
    );
  }

  Future<void> stopSession(String sessionId) async {
    await _client.rpc(
      'stop_attendance_session',
      params: {'p_session_id': sessionId},
    );
  }

  Future<AttendanceResult> markPresent({
    required String sessionId,
    required String sessionCode,
    required String method,
    String? qrCode,
  }) async {
    final response = await _client.rpc(
      'mark_attendance',
      params: {
        'p_session_id': sessionId,
        'p_session_code': sessionCode,
        'p_method': method,
        'p_qr_code': qrCode,
      },
    );
    return AttendanceResult.fromJson(_mapFromResponse(response));
  }

  Future<List<AttendanceRecord>> loadPresentStudents(String sessionId) async {
    final response = await _client
        .from('attendance_records')
        .select('student_email, marked_at')
        .eq('session_id', sessionId)
        .order('marked_at');
    return (response as List)
        .map(
          (row) =>
              AttendanceRecord.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  RealtimeChannel watchPresentStudents({
    required String sessionId,
    required void Function(AttendanceRecord record) onRecord,
  }) {
    final channel = _client.channel('attendance-records-$sessionId');
    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'attendance_records',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'session_id',
        value: sessionId,
      ),
      callback: (payload) {
        try {
          onRecord(AttendanceRecord.fromJson(payload.newRecord));
        } on FormatException {
          // Ignore incomplete Realtime payloads; the teacher can still refresh
          // the record list from the attendance_records table.
        }
      },
    );
    return channel;
  }

  Future<StudentAttendanceSummary> getStudentAttendanceSummary({
    String? studentId,
    String? subject,
  }) async {
    final uid = studentId ?? _client.auth.currentUser?.id;
    if (uid == null) {
      return StudentAttendanceSummary.empty();
    }

    try {
      // 1. Fetch attendance records for this student with status
      // We join with attendance_sessions to filter by subject title if provided
      var query = _client
          .from('attendance_records')
          .select('session_id, status, attendance_sessions!inner(title)')
          .eq('student_id', uid);

      if (subject != null && subject.isNotEmpty) {
        query = query.ilike('attendance_sessions.title', '%$subject%');
      }

      final recordsResponse = await query;

      int present = 0;
      int absent = 0;
      int leaves = 0;

      final countedSessionIds = <String>{};

      for (final row in recordsResponse) {
        final sessionId = row['session_id']?.toString();
        if (sessionId == null || countedSessionIds.contains(sessionId)) {
          continue;
        }
        countedSessionIds.add(sessionId);

        final rawStatus =
            (row['status']?.toString() ?? 'present').toLowerCase().trim();
        if (rawStatus == 'present') {
          present++;
        } else if (rawStatus == 'absent') {
          absent++;
        } else if (rawStatus == 'leave') {
          leaves++;
        }
      }

      final total = present + absent + leaves;

      return StudentAttendanceSummary.fromCounts(
        present: present,
        absent: absent,
        leaves: leaves,
        totalEligible: total,
      );
    } catch (e) {
      debugPrint('Error loading student attendance summary: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getRecentUpdates() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return [];

    try {
      final response = await _client
          .from('attendance_records')
          .select('marked_at, status, attendance_sessions(title)')
          .eq('student_id', uid)
          .order('marked_at', ascending: false)
          .limit(5);

      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error loading recent updates: $e');
      return [];
    }
  }

  Future<ActiveAttendanceSession?> getLatestActiveSession() async {
    try {
      final now = DateTime.now().toIso8601String();
      final response = await _client
          .from('attendance_sessions')
          .select('id, session_code, title, ends_at')
          .eq('is_active', true)
          .gt('ends_at', now)
          .order('starts_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (response == null) return null;
      return ActiveAttendanceSession.fromJson(response);
    } catch (e) {
      debugPrint('Error fetching latest active session: $e');
      return null;
    }
  }

  // --------------------------------------------------------------------------
  // Teacher Session Roster & Manual Attendance Management
  // --------------------------------------------------------------------------

  Future<List<TeacherSession>> loadTeacherSessions() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return [];

    try {
      final sessionsResponse = await _client
          .from('attendance_sessions')
          .select('id, title, session_code, starts_at, ends_at, is_active')
          .eq('teacher_id', uid)
          .order('starts_at', ascending: false);

      final sessions = <TeacherSession>[];
      for (final row in sessionsResponse) {
        final sessionId = row['id']?.toString() ?? '';

        final records = await _client
            .from('attendance_records')
            .select('status')
            .eq('session_id', sessionId);

        int presentCount = 0;
        int absentCount = 0;
        for (final rec in records) {
          final st =
              (rec['status']?.toString() ?? 'present').toLowerCase().trim();
          if (st == 'present') {
            presentCount++;
          } else if (st == 'absent') {
            absentCount++;
          }
        }

        sessions.add(
          TeacherSession.fromJson(
            row,
            present: presentCount,
            absent: absentCount,
          ),
        );
      }
      return sessions;
    } catch (e) {
      debugPrint('Error loading teacher sessions: $e');
      return [];
    }
  }

  Future<List<SessionStudentRosterItem>> loadSessionRoster(
    String sessionId,
  ) async {
    try {
      final response = await _client.rpc(
        'get_teacher_session_roster',
        params: {'p_session_id': sessionId},
      );

      final list = <SessionStudentRosterItem>[];
      if (response is List) {
        for (final item in response) {
          if (item is Map) {
            list.add(
              SessionStudentRosterItem.fromJson(
                Map<String, dynamic>.from(item),
              ),
            );
          }
        }
      }
      return list;
    } catch (e) {
      debugPrint('Error loading session roster: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> teacherMarkAttendance({
    required String sessionId,
    required String studentId,
    required String status,
  }) async {
    try {
      final response = await _client.rpc(
        'teacher_mark_attendance',
        params: {
          'p_session_id': sessionId,
          'p_student_id': studentId,
          'p_status': status,
        },
      );
      return _mapFromResponse(response);
    } catch (e) {
      debugPrint('Error marking teacher attendance: $e');
      rethrow;
    }
  }

  static Map<String, dynamic> _mapFromResponse(dynamic response) {
    if (response is Map<String, dynamic>) return response;
    if (response is Map) return Map<String, dynamic>.from(response);
    if (response is String) {
      try {
        final decoded = jsonDecode(response);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    throw const FormatException(
      'Supabase returned an invalid attendance response.',
    );
  }
}
