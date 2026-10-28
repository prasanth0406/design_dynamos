import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Device-bound proof of possession for student accounts.
///
/// A non-exportable EC P-256 key lives in the Android Keystore and can only
/// sign after a strong biometric check for that specific signature. The server
/// issues single-use challenges and verifies signatures against the public key
/// it registered for this student; a local "authenticated" Boolean is never
/// sent or trusted.
///
/// Limitation: Android does not reveal *which* enrolled fingerprint or face
/// was used. Anyone whose biometric was enrolled on this phone before the key
/// was created can authorize a signature. Enrolling a new biometric afterwards
/// permanently invalidates the key, and re-registering requires admin approval.
class DeviceProofException implements Exception {
  const DeviceProofException(this.code, this.message);

  final String code;
  final String message;

  /// The phone needs a new key and an admin-approved re-registration.
  bool get requiresReRegistration => const {
    'key_invalidated',
    'no_key',
    'device_not_registered',
    'device_revoked',
    'device_rejected',
    'device_superseded',
    'key_retired',
  }.contains(code);

  @override
  String toString() => message;
}

enum DeviceRegistrationStatus { active, pending }

class DeviceRegistration {
  const DeviceRegistration({
    required this.userId,
    required this.deviceId,
    required this.status,
  });

  final String userId;
  final String deviceId;
  final DeviceRegistrationStatus status;

  String encode() => jsonEncode({
    'userId': userId,
    'deviceId': deviceId,
    'status': status.name,
  });

  static DeviceRegistration? decode(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final status = DeviceRegistrationStatus.values
          .where((s) => s.name == map['status'])
          .firstOrNull;
      final userId = map['userId'];
      final deviceId = map['deviceId'];
      if (userId is! String || deviceId is! String || status == null) {
        return null;
      }
      return DeviceRegistration(
        userId: userId,
        deviceId: deviceId,
        status: status,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Thin wrapper around the Kotlin `DeviceKeyPlugin` platform channel.
class DeviceKey {
  static const MethodChannel _channel = MethodChannel(
    'com.example.att/device_key',
  );

  static Future<Map<String, dynamic>> status() async =>
      Map<String, dynamic>.from(
        await _guard(() => _channel.invokeMethod<Map>('getStatus')) ?? {},
      );

  static Future<Map<String, dynamic>> generate(String attestationNonce) async =>
      Map<String, dynamic>.from(
        await _guard(
              () => _channel.invokeMethod<Map>('generateKey', {
                'attestationChallenge': attestationNonce,
              }),
            ) ??
            {},
      );

  static Future<String?> publicKey() =>
      _guard(() => _channel.invokeMethod<String>('getPublicKey'));

  static Future<void> delete() =>
      _guard(() => _channel.invokeMethod<void>('deleteKey'));

  /// Shows a strong-biometric prompt and signs [payload] (SHA256withECDSA,
  /// DER, base64). The private key never leaves the Keystore.
  static Future<String> sign(
    String payload, {
    required String title,
    required String subtitle,
  }) async {
    final signature = await _guard(
      () => _channel.invokeMethod<String>('sign', {
        'payload': payload,
        'title': title,
        'subtitle': subtitle,
      }),
    );
    if (signature == null || signature.isEmpty) {
      throw const DeviceProofException(
        'sign_failed',
        'The phone did not return a signature.',
      );
    }
    return signature;
  }

  static Future<T?> _guard<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } on MissingPluginException {
      throw const DeviceProofException(
        'unsupported_platform',
        'Device-bound attendance keys are only supported on Android phones.',
      );
    } on PlatformException catch (error) {
      throw errorFor(error.code, error.message);
    }
  }

  static DeviceProofException errorFor(String platformCode, [String? detail]) =>
      DeviceProofException(
        _platformCode(platformCode),
        _platformMessage(platformCode, detail),
      );

  static String _platformCode(String code) => switch (code) {
    'KEY_INVALIDATED' => 'key_invalidated',
    'NO_KEY' => 'no_key',
    'CANCELLED' => 'cancelled',
    'LOCKED_OUT' => 'locked_out',
    'BIOMETRIC_UNAVAILABLE' => 'biometric_unavailable',
    'IN_PROGRESS' => 'in_progress',
    _ => 'keystore_error',
  };

  static String _platformMessage(String code, String? detail) => switch (code) {
    'KEY_INVALIDATED' =>
      'A fingerprint or face was added or removed on this phone, so its '
          'attendance key was destroyed. Register this phone again; an '
          'administrator must approve it.',
    'NO_KEY' =>
      'This phone has no attendance key. Register this phone again; an '
          'administrator must approve it.',
    'CANCELLED' => 'Verification was cancelled.',
    'LOCKED_OUT' =>
      'Too many failed attempts. Unlock your phone with its PIN, pattern or '
          'password, then retry.',
    'BIOMETRIC_UNAVAILABLE' =>
      'Set up a fingerprint or face unlock (Class 3 / strong) in phone '
          'settings, then retry.',
    'IN_PROGRESS' => 'Another verification is already in progress.',
    _ => 'The phone security module reported an error: ${detail ?? code}',
  };
}

/// Calls the `device-attendance` Edge Function and stores this phone's
/// server-assigned device id.
class DeviceProof {
  DeviceProof(this._client);

  static const String _registrationKey = 'sdtt_device_registration_v1';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  final SupabaseClient _client;

  static Future<DeviceRegistration?> storedRegistration(String userId) async {
    final registration = DeviceRegistration.decode(
      await _storage.read(key: _registrationKey),
    );
    return registration?.userId == userId ? registration : null;
  }

  static Future<void> _store(DeviceRegistration registration) =>
      _storage.write(key: _registrationKey, value: registration.encode());

  static Future<void> clearRegistration() =>
      _storage.delete(key: _registrationKey);

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    try {
      final response = await _client.functions.invoke(
        'device-attendance',
        body: body,
      );
      final data = response.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const DeviceProofException(
        'server_error',
        'The attendance server returned an invalid response.',
      );
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map) {
        throw DeviceProofException(
          details['code']?.toString() ?? 'server_error',
          details['message']?.toString() ??
              'The attendance server rejected the request.',
        );
      }
      throw DeviceProofException(
        'server_error',
        'The attendance server rejected the request (HTTP ${error.status}).',
      );
    }
  }

  Future<Map<String, dynamic>> _expectOk(Map<String, dynamic> body) async {
    final data = await _call(body);
    if (data['ok'] != true) {
      throw DeviceProofException(
        data['code']?.toString() ?? 'unknown',
        data['message']?.toString() ?? 'Device verification failed.',
      );
    }
    return data;
  }

  /// Generates a fresh Keystore key, signs a registration challenge and asks
  /// the server to bind the public key to this student. The first device is
  /// activated immediately; any later device stays pending until an admin
  /// approves it (which atomically revokes the old one).
  Future<DeviceRegistration> register({String reason = 'new_device'}) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const DeviceProofException(
        'invalid_session',
        'Sign in again before registering this phone.',
      );
    }
    final status = await DeviceKey.status();
    if (status['biometricStatus'] != 'available') {
      throw DeviceKey.errorFor('BIOMETRIC_UNAVAILABLE');
    }

    final challenge = await _expectOk({
      'operation': 'issue_challenge',
      'purpose': 'register_device',
    });
    final key = await DeviceKey.generate(challenge['nonce'] as String);
    final publicKey = key['publicKey'] as String?;
    if (publicKey == null) {
      throw const DeviceProofException(
        'keystore_error',
        'The phone did not return a public key.',
      );
    }
    final signature = await DeviceKey.sign(
      challenge['signing_payload'] as String,
      title: 'Register this phone',
      subtitle: 'Confirm with your fingerprint or face',
    );
    final result = await _expectOk({
      'operation': 'register_device',
      'challenge_id': challenge['challenge_id'],
      'public_key': publicKey,
      'signature': signature,
      'attestation_chain': key['attestationChain'] ?? const [],
      'request_reason': reason,
      'client_reported': {
        'sdk_int': status['sdkInt'],
        'manufacturer': status['manufacturer'],
        'model': status['model'],
        'strongbox': key['strongBox'],
        'security_level': key['securityLevel'],
      },
    });
    final registration = DeviceRegistration(
      userId: user.id,
      deviceId: result['device_id'].toString(),
      status: result['status'] == 'active'
          ? DeviceRegistrationStatus.active
          : DeviceRegistrationStatus.pending,
    );
    await _store(registration);
    return registration;
  }

  /// Reads this phone's registration status from the server (RLS limits the
  /// query to the signed-in student's own rows).
  Future<String?> serverStatus(DeviceRegistration registration) async {
    final row = await _client
        .from('student_devices')
        .select('status')
        .eq('id', registration.deviceId)
        .maybeSingle();
    final status = row?['status']?.toString();
    if (status == 'active' &&
        registration.status != DeviceRegistrationStatus.active) {
      await _store(
        DeviceRegistration(
          userId: registration.userId,
          deviceId: registration.deviceId,
          status: DeviceRegistrationStatus.active,
        ),
      );
    }
    return status;
  }

  Future<DeviceRegistration> _activeRegistration() async {
    final user = _client.auth.currentUser;
    final registration = user == null
        ? null
        : await storedRegistration(user.id);
    if (registration == null) {
      throw const DeviceProofException(
        'device_not_registered',
        'This phone is not registered for attendance. Register it first.',
      );
    }
    return registration;
  }

  Future<Map<String, dynamic>> _proveAndVerify({
    required Map<String, dynamic> challengeRequest,
    required String title,
    required String subtitle,
  }) async {
    final challenge = await _expectOk({
      'operation': 'issue_challenge',
      ...challengeRequest,
    });
    final signature = await DeviceKey.sign(
      challenge['signing_payload'] as String,
      title: title,
      subtitle: subtitle,
    );
    return _call({
      'operation': 'verify_challenge',
      'challenge_id': challenge['challenge_id'],
      'signature': signature,
    });
  }

  /// Server-verified unlock: succeeds only if this phone's registered key
  /// signs a fresh challenge after a strong biometric check.
  Future<void> unlock() async {
    final registration = await _activeRegistration();
    final result = await _proveAndVerify(
      challengeRequest: {
        'purpose': 'app_unlock',
        'device_id': registration.deviceId,
      },
      title: 'Unlock SDTT Attendance',
      subtitle: 'Confirm with your fingerprint or face',
    );
    if (result['ok'] != true) {
      throw DeviceProofException(
        result['code']?.toString() ?? 'unknown',
        result['message']?.toString() ?? 'Device verification failed.',
      );
    }
  }

  /// Requests a session-bound attendance challenge (the server checks the
  /// QR code and BLE token first), signs it and submits it. Returns the
  /// server's JSON verdict.
  Future<Map<String, dynamic>> markAttendance({
    required String sessionId,
    required String sessionCode,
    required String qrCode,
    required String bleToken,
  }) async {
    final registration = await _activeRegistration();
    return _proveAndVerify(
      challengeRequest: {
        'purpose': 'mark_attendance',
        'device_id': registration.deviceId,
        'session_id': sessionId,
        'session_code': sessionCode,
        'qr_code': qrCode,
        'ble_token': bleToken,
      },
      title: 'Mark attendance',
      subtitle: 'Confirm with your fingerprint or face',
    ).onError<DeviceProofException>(
      (error, _) => {'ok': false, 'code': error.code, 'message': error.message},
    );
  }
}
