import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_proof.dart';

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

  Future<ActiveAttendanceSession> createSession({
    required String title,
    required String initialQrCode,
    required String initialBleToken,
  }) async {
    final response = await _client.rpc(
      'create_attendance_session',
      params: {
        'p_title': title,
        'p_initial_qr_code': initialQrCode,
        'p_initial_ble_token': initialBleToken,
      },
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
    required String bleToken,
  }) async {
    await _client.rpc(
      'rotate_attendance_qr',
      params: {
        'p_session_id': sessionId,
        'p_qr_code': qrCode,
        'p_ble_token': bleToken,
      },
    );
  }

  Future<void> stopSession(String sessionId) async {
    await _client.rpc(
      'stop_attendance_session',
      params: {'p_session_id': sessionId},
    );
  }

  /// Marks attendance through the `device-attendance` Edge Function. The
  /// server checks the session, rotating QR code and rotating BLE token,
  /// then requires a fresh signature from this student's registered
  /// Keystore key (strong biometric per signature) before recording it.
  Future<AttendanceResult> markPresent({
    required String sessionId,
    required String sessionCode,
    required String qrCode,
    required String bleToken,
  }) async {
    final response = await DeviceProof(_client).markAttendance(
      sessionId: sessionId,
      sessionCode: sessionCode,
      qrCode: qrCode,
      bleToken: bleToken,
    );
    return AttendanceResult.fromJson(response);
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

  static Map<String, dynamic> _mapFromResponse(dynamic response) {
    if (response is Map<String, dynamic>) return response;
    if (response is Map) return Map<String, dynamic>.from(response);
    throw const FormatException(
      'Supabase returned an invalid attendance response.',
    );
  }
}
