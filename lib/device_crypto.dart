import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

sealed class DeviceCryptoException implements Exception {
  const DeviceCryptoException(this.message);
  final String message;

  @override
  String toString() => message;
}

class KeyInvalidatedException extends DeviceCryptoException {
  const KeyInvalidatedException([
    super.message =
        'Biometric enrollment on this device has changed. The cryptographic attendance key has been permanently invalidated.',
  ]);
}

class BiometricCancelledException extends DeviceCryptoException {
  const BiometricCancelledException([
    super.message = 'Biometric authentication was cancelled by the user.',
  ]);
}

class BiometricLockoutException extends DeviceCryptoException {
  const BiometricLockoutException([
    super.message =
        'Biometric authentication is locked out due to too many attempts.',
  ]);
}

class BiometricNotEnrolledException extends DeviceCryptoException {
  const BiometricNotEnrolledException([
    super.message =
        'No biometrics are currently enrolled in device security settings.',
  ]);
}

class KeyNotFoundException extends DeviceCryptoException {
  const KeyNotFoundException([
    super.message = 'Cryptographic key not found in Android Keystore.',
  ]);
}

class DeviceCryptoGeneralException extends DeviceCryptoException {
  const DeviceCryptoGeneralException(super.message);
}

class DeviceCrypto {
  static const MethodChannel _channel = MethodChannel(
    'com.example.att/device_crypto',
  );
  static const String defaultKeyAlias = 'sdtt_student_auth_key_v1';
  static const String _deviceIdStorageKey = 'sdtt_hardware_device_id_v1';
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Retrieves or generates a persistent device UUID stored securely on this phone.
  static Future<String> getOrCreateDeviceId() async {
    var id = await _storage.read(key: _deviceIdStorageKey);
    if (id == null || id.isEmpty) {
      final bytes = List<int>.generate(16, (i) => (DateTime.now().microsecondsSinceEpoch >> (i * 4)) & 0xff);
      // Format as UUID v4
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      id = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      await _storage.write(key: _deviceIdStorageKey, value: id);
    }
    return id;
  }

  /// Checks if hardware-backed biometrics are available and ready to use.
  static Future<bool> canAuthenticate() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'canAuthenticate',
      );
      return result?['canAuthenticate'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Detailed biometric availability status.
  static Future<Map<String, dynamic>> checkBiometrics() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'canAuthenticate',
      );
      return result ?? {'canAuthenticate': false, 'status': 'UNKNOWN'};
    } catch (e) {
      return {'canAuthenticate': false, 'status': 'ERROR_$e'};
    }
  }

  /// Checks if a key pair with the given alias exists in Android Keystore.
  static Future<bool> hasKey([String alias = defaultKeyAlias]) async {
    try {
      final exists = await _channel.invokeMethod<bool>('hasKey', {
        'alias': alias,
      });
      return exists ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Generates a new hardware-bound EC P-256 key pair in Android Keystore.
  /// Key usage strictly requires biometric authorization and invalidates on new enrollment.
  /// Returns the Base64-encoded X.509 SubjectPublicKeyInfo.
  static Future<String> generateKeyPair([
    String alias = defaultKeyAlias,
  ]) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'generateKeyPair',
        {'alias': alias},
      );
      final publicKey = result?['publicKey']?.toString();
      if (publicKey == null || publicKey.isEmpty) {
        throw const DeviceCryptoGeneralException(
          'Failed to retrieve generated public key from Keystore.',
        );
      }
      return publicKey;
    } on PlatformException catch (e) {
      throw DeviceCryptoGeneralException(
        e.message ?? 'Key generation failed in Keystore.',
      );
    }
  }

  /// Prompts for biometric authentication and signs the challenge with the Keystore private key.
  /// Returns the Base64-encoded ECDSA signature.
  static Future<String> signChallenge({
    required String challenge,
    String alias = defaultKeyAlias,
    String title = 'Authorize Operation',
    String subtitle = 'Confirm your biometric to proceed',
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'signChallenge',
        {
          'alias': alias,
          'challenge': challenge,
          'title': title,
          'subtitle': subtitle,
        },
      );
      final signature = result?['signature']?.toString();
      if (signature == null || signature.isEmpty) {
        throw const DeviceCryptoGeneralException(
          'Android Keystore produced an empty signature.',
        );
      }
      return signature;
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'KEY_PERMANENTLY_INVALIDATED':
          throw const KeyInvalidatedException();
        case 'BIOMETRIC_CANCELLED':
          throw const BiometricCancelledException();
        case 'BIOMETRIC_LOCKED_OUT':
          throw const BiometricLockoutException();
        case 'BIOMETRIC_NOT_ENROLLED':
          throw const BiometricNotEnrolledException();
        case 'KEY_NOT_FOUND':
          throw const KeyNotFoundException();
        default:
          throw DeviceCryptoGeneralException(
            e.message ?? 'Biometric challenge signing failed.',
          );
      }
    }
  }

  /// Deletes a key pair from Android Keystore.
  static Future<bool> deleteKey([String alias = defaultKeyAlias]) async {
    try {
      final success = await _channel.invokeMethod<bool>('deleteKey', {
        'alias': alias,
      });
      return success ?? false;
    } catch (_) {
      return false;
    }
  }
}
