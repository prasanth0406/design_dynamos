import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_theme.dart';
import 'attendance_screen.dart';
import 'attendance_backend.dart';
import 'device_crypto.dart';
import 'attendance_summary.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseProjectUrl = 'https://otfazpvwsxintyzcytvx.supabase.co';
const String supabasePublishableKey =
    'sb_publishable_dy9LkmDGDwFVHTzGdiqnbA_CwKgVJKZ';
const String _secureSupabaseSessionKey = 'oceanic_supabase_session_v1';
const String _deviceBindingKey = 'oceanic_device_account_binding_v1';
const String _legacySupabaseSessionKey = 'sb-otfazpvwsxintyzcytvx-auth-token';

final FlutterSecureStorage _secureStorage = FlutterSecureStorage();

/// Stores Supabase's refresh/access tokens encrypted on this device.
class SecureSupabaseLocalStorage extends LocalStorage {
  SecureSupabaseLocalStorage()
    : _legacyStorage = SharedPreferencesLocalStorage(
        persistSessionKey: _legacySupabaseSessionKey,
      );

  final SharedPreferencesLocalStorage _legacyStorage;

  @override
  Future<void> initialize() async {
    await _legacyStorage.initialize();
    final secureSession = await _secureStorage.read(
      key: _secureSupabaseSessionKey,
    );
    if (secureSession == null) {
      final legacySession = await _legacyStorage.accessToken();
      if (legacySession != null) {
        await _secureStorage.write(
          key: _secureSupabaseSessionKey,
          value: legacySession,
        );
      }
    }
    await _legacyStorage.removePersistedSession();
  }

  @override
  Future<bool> hasAccessToken() async =>
      await _secureStorage.read(key: _secureSupabaseSessionKey) != null;

  @override
  Future<String?> accessToken() =>
      _secureStorage.read(key: _secureSupabaseSessionKey);

  @override
  Future<void> removePersistedSession() =>
      _secureStorage.delete(key: _secureSupabaseSessionKey);

  @override
  Future<void> persistSession(String persistSessionString) => _secureStorage
      .write(key: _secureSupabaseSessionKey, value: persistSessionString);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseProjectUrl,
    publishableKey: supabasePublishableKey,
    authOptions: FlutterAuthClientOptions(
      localStorage: SecureSupabaseLocalStorage(),
    ),
  );

  runApp(const MyApp());
}

enum UserRole { student, teacher }

extension UserRoleLabel on UserRole {
  String get label => this == UserRole.student ? 'Student' : 'Teacher';
  String get value => this == UserRole.student ? 'student' : 'teacher';
}

UserRole? _userRoleFromValue(Object? value) {
  final normalized = value?.toString().toLowerCase();
  for (final role in UserRole.values) {
    if (role.value == normalized) return role;
  }
  return null;
}

class DeviceAccountBinding {
  const DeviceAccountBinding({
    required this.userId,
    required this.role,
    required this.deviceId,
  });

  final String userId;
  final UserRole role;
  final String deviceId;

  String encode() => jsonEncode({
    'userId': userId,
    'role': role.value,
    'deviceId': deviceId,
  });

  static DeviceAccountBinding decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid device account binding.');
    }
    final userId = decoded['userId'];
    final role = _userRoleFromValue(decoded['role']);
    final deviceId = decoded['deviceId']?.toString() ?? '';
    if (userId is! String || userId.isEmpty || role == null) {
      throw const FormatException('Invalid device account binding.');
    }
    return DeviceAccountBinding(
      userId: userId,
      role: role,
      deviceId: deviceId,
    );
  }
}

class DeviceAccountBindingStore {
  static Future<DeviceAccountBinding?> read() async {
    final encoded = await _secureStorage.read(key: _deviceBindingKey);
    return encoded == null ? null : DeviceAccountBinding.decode(encoded);
  }

  static Future<void> save(DeviceAccountBinding binding) =>
      _secureStorage.write(key: _deviceBindingKey, value: binding.encode());

  static Future<void> clear() => _secureStorage.delete(key: _deviceBindingKey);
}

class DeviceSessionValidationException implements Exception {
  const DeviceSessionValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Refreshes an expired session, validates it with Supabase, and ensures the
/// authenticated user and role still match this device's secure binding.
Future<User> _verifyBoundSupabaseSession(DeviceAccountBinding binding) async {
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession == null) {
    throw const DeviceSessionValidationException(
      'No saved Supabase session is available on this device.',
    );
  }

  final session = (await auth.refreshSession()).session;
  if (session == null || session.user.id != binding.userId) {
    throw const DeviceSessionValidationException(
      'The saved Supabase session no longer matches this device account.',
    );
  }

  final user = (await auth.getUser()).user;
  if (user == null) {
    throw const DeviceSessionValidationException(
      'Supabase did not return a valid account for this session.',
    );
  }
  if (user.id != binding.userId ||
      _userRoleFromValue(user.userMetadata?['role']) != binding.role) {
    throw const DeviceSessionValidationException(
      'The saved Supabase account or role is no longer valid for this device.',
    );
  }
  return user;
}

class SecureStartupRouter extends StatefulWidget {
  const SecureStartupRouter({super.key});

  @override
  State<SecureStartupRouter> createState() => _SecureStartupRouterState();
}

class _SecureStartupRouterState extends State<SecureStartupRouter> {
  late final Future<Widget> _startupScreen = _resolveStartupScreen();

  Future<Widget> _resolveStartupScreen() async {
    final binding = await DeviceAccountBindingStore.read();
    final session = Supabase.instance.client.auth.currentSession;

    if (binding != null) {
      if (session == null) {
        return const SessionRecoveryScreen(
          message: 'The saved Supabase session is missing or expired. Secure account recovery is required before this account can be used.',
        );
      }
      if (session.user.id != binding.userId) {
        return const SessionRecoveryScreen(
          message: 'The saved Supabase account does not match this device binding. Secure account recovery is required before access can be restored.',
        );
      }
      if (binding.role == UserRole.student && binding.deviceId.isEmpty) {
        return DeviceAuthSetupScreen(userId: session.user.id, role: binding.role);
      }
      return DeviceUnlockScreen(binding: binding);
    }

    if (session != null) {
      final role = _userRoleFromValue(session.user.userMetadata?['role']);
      if (role == null) {
        return const SessionRecoveryScreen(
          message: 'This Supabase account has no valid attendance role. Contact your administrator to restore access.',
        );
      }
      return DeviceAuthSetupScreen(userId: session.user.id, role: role);
    }

    return const RoleSelectionScreen();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _startupScreen,
      builder: (context, snapshot) {
        if (snapshot.hasData) return snapshot.data!;
        if (snapshot.hasError) {
          return const SessionRecoveryScreen(
            message: 'Secure device sign-in could not be read. Secure account recovery is required before access can be restored.',
          );
        }
        return const Scaffold(
          backgroundColor: deepNavy,
          body: Center(child: CircularProgressIndicator(color: brandOrange)),
        );
      },
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Oceanic Attendance',
      theme: AttendanceAppTheme.light,
      home: const SecureStartupRouter(),
    );
  }
}

bool isValidStudentEmail(String email) {
  final pattern = RegExp(
    r'^(23bcs|24bcs|25bcs)\d{3}@iiitdwd\.ac\.in$',
    caseSensitive: false,
  );
  return pattern.hasMatch(email.trim());
}

bool isValidTeacherEmail(String email) {
  final pattern = RegExp(
    r'^[a-z][a-z0-9._-]*@iiitdwd\.ac\.in$',
    caseSensitive: false,
  );
  final normalized = email.trim();
  return pattern.hasMatch(normalized) && !isValidStudentEmail(normalized);
}

bool isValidEmailForRole(String email, UserRole role) {
  return role == UserRole.student
      ? isValidStudentEmail(email)
      : isValidTeacherEmail(email);
}

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.waves_rounded,
                      size: 62,
                      color: brandOrange,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Oceanic Attendance',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Choose how you want to sign in',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk, fontSize: 15),
                    ),
                    const SizedBox(height: 32),
                    RoleButton(
                      title: 'Teacher Login',
                      subtitle: 'Manage student attendance',
                      icon: Icons.cast_for_education_rounded,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              RoleAuthScreen(role: UserRole.teacher),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    RoleButton(
                      title: 'Student Login',
                      subtitle: 'View and mark attendance',
                      icon: Icons.school_rounded,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              RoleAuthScreen(role: UserRole.student),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RoleButton extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const RoleButton({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [deepNavy, brandBlue]),
          borderRadius: BorderRadius.circular(AppRadii.tile),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33102C51),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.tile),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: const BoxDecoration(
                      color: Color(0x33F28A2E),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: brandOrange, size: 30),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: white.withValues(alpha: 0.78),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_ios,
                    color: brandOrange,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RoleAuthScreen extends StatefulWidget {
  final UserRole role;

  const RoleAuthScreen({super.key, required this.role});

  @override
  State<RoleAuthScreen> createState() => _RoleAuthScreenState();
}

class _RoleAuthScreenState extends State<RoleAuthScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool hidePassword = true;
  bool isLoading = false;
  bool isSignUp = false;

  Future<bool> _blockIfDeviceIsAlreadyBound() async {
    try {
      if (await DeviceAccountBindingStore.read() == null) return false;
      showMessage(
        'This phone is already linked to an account. Use the unlock screen or account recovery.',
      );
    } catch (_) {
      showMessage(
        'The secure device binding could not be read. Use account recovery to continue.',
      );
    }
    return true;
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String get emailRuleMessage {
    if (widget.role == UserRole.student) {
      return 'Use a student email such as 25bcs123@iiitdwd.ac.in';
    }
    return 'Use your teacher college email, e.g. name@iiitdwd.ac.in';
  }

  Future<void> signUp() async {
    if (await _blockIfDeviceIsAlreadyBound()) return;

    final email = emailController.text.trim().toLowerCase();
    final password = passwordController.text;

    if (!isValidEmailForRole(email, widget.role)) {
      showMessage(emailRuleMessage);
      return;
    }
    if (password.length < 6) {
      showMessage('Password must contain at least 6 characters.');
      return;
    }

    setState(() => isLoading = true);

    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
        data: {'role': widget.role.value},
      );

      if (!mounted) return;

      if (response.session != null) {
        final user = response.user;
        if (user == null) {
          showMessage(
            'Account was created, but secure setup could not start. Sign in to continue.',
          );
          return;
        }
        _openDeviceSetup(user.id, widget.role);
      } else {
        showMessage(
          'Signup submitted. Check your college email to confirm your account, then log in.',
        );
        setState(() => isSignUp = false);
      }
    } on AuthException catch (error) {
      showMessage(error.message);
    } catch (_) {
      showMessage('Signup failed. Please try again.');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> signIn() async {
    if (await _blockIfDeviceIsAlreadyBound()) return;

    final email = emailController.text.trim().toLowerCase();
    final password = passwordController.text;

    if (!isValidEmailForRole(email, widget.role)) {
      showMessage(emailRuleMessage);
      return;
    }
    if (password.isEmpty) {
      showMessage('Please enter your password.');
      return;
    }

    setState(() => isLoading = true);

    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = response.user;
      if (user == null) {
        showMessage('Login failed. Please try again.');
        return;
      }

      final storedRole = user.userMetadata?['role']?.toString().toLowerCase();

      if (storedRole != widget.role.value) {
        await Supabase.instance.client.auth.signOut();
        showMessage(
          'Access denied. This account is not registered as a ${widget.role.label.toLowerCase()}.',
        );
        return;
      }

      if (!mounted) return;
      _openDeviceSetup(user.id, widget.role);
    } on AuthException catch (error) {
      showMessage(error.message);
    } catch (_) {
      showMessage('Login failed. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _openDeviceSetup(String userId, UserRole role) {
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceAuthSetupScreen(userId: userId, role: role),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final roleName = widget.role.label;

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back, color: ink),
                      ),
                    ),
                    Icon(
                      widget.role == UserRole.teacher
                          ? Icons.cast_for_education_rounded
                          : Icons.school_rounded,
                      color: brandOrange,
                      size: 54,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$roleName ${isSignUp ? 'Sign Up' : 'Login'}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 27,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      emailRuleMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk, fontSize: 13),
                    ),
                    const SizedBox(height: 28),
                    glassTextField(
                      controller: emailController,
                      hint: 'College Email',
                      icon: Icons.mail_outline,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 16),
                    glassTextField(
                      controller: passwordController,
                      hint: 'Password',
                      icon: Icons.lock_outline,
                      obscureText: hidePassword,
                      suffixIcon: IconButton(
                        icon: Icon(
                          hidePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: ink,
                        ),
                        onPressed: () {
                          setState(() => hidePassword = !hidePassword);
                        },
                      ),
                    ),
                    const SizedBox(height: 26),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [brandOrange, Color(0xFFAA4709)],
                          ),
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x33E56F1F),
                              blurRadius: 15,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: isLoading
                              ? null
                              : (isSignUp ? signUp : signIn),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            disabledBackgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.pill,
                              ),
                            ),
                          ),
                          child: isLoading
                              ? const SizedBox(
                                  height: 23,
                                  width: 23,
                                  child: CircularProgressIndicator(
                                    color: white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  isSignUp ? 'CREATE ACCOUNT' : 'SIGN IN',
                                  style: const TextStyle(
                                    color: white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: isLoading
                          ? null
                          : () => setState(() => isSignUp = !isSignUp),
                      child: Text(
                        isSignUp
                            ? 'Already have an account? Sign in'
                            : "Don't have an account? Sign up",
                        style: const TextStyle(
                          color: brandOrange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget glassTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      style: const TextStyle(color: ink, fontSize: 15),
      cursorColor: brandOrange,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, color: brandOrange),
        suffixIcon: suffixIcon,
      ),
    );
  }
}

class DeviceAuthSetupScreen extends StatefulWidget {
  const DeviceAuthSetupScreen({
    super.key,
    required this.userId,
    required this.role,
  });

  final String userId;
  final UserRole role;

  @override
  State<DeviceAuthSetupScreen> createState() => _DeviceAuthSetupScreenState();
}

class _DeviceAuthSetupScreenState extends State<DeviceAuthSetupScreen> {
  bool _isLoading = false;
  String _status =
      'Bind this device to your student attendance account with hardware keys.';
  bool _showRecoveryOption = false;

  Future<void> _enableDeviceUnlock() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _showRecoveryOption = false;
      _status = 'Configuring Android Keystore cryptographic keys...';
    });

    try {
      final deviceId = await DeviceCrypto.getOrCreateDeviceId();

      if (widget.role == UserRole.student) {
        final canAuth = await DeviceCrypto.canAuthenticate();
        if (!canAuth) {
          setState(() {
            _status =
                'Set up fingerprint or face unlock in phone security settings, then retry setup.';
          });
          return;
        }

        setState(() {
          _status = 'Generating hardware-protected EC P-256 key pair...';
        });

        // 1. Generate key in Android Keystore with biometric authorization
        final publicKeySpki = await DeviceCrypto.generateKeyPair();

        setState(() {
          _status = 'Registering device with Supabase server...';
        });

        // 2. Register public key with Supabase Edge Function
        final backend = AttendanceBackend(Supabase.instance.client);
        final regResult = await backend.registerDevice(
          deviceId: deviceId,
          publicKeySpki: publicKeySpki,
          deviceName: 'Android Student Phone',
        );

        if (regResult['ok'] != true) {
          if (regResult['code'] == 'device_already_registered') {
            setState(() {
              _showRecoveryOption = true;
              _status =
                  'An active attendance device is already registered for your account. You cannot link a new phone without an approved device recovery request.';
            });
            return;
          }
          setState(() {
            _status = 'Device registration rejected: ${regResult['message']}';
          });
          return;
        }
      } else {
        // Teacher setup uses local auth
        final localAuth = LocalAuthentication();
        if (!await localAuth.isDeviceSupported()) {
          setState(() {
            _status = 'Set up screen lock or biometrics in settings, then retry.';
          });
          return;
        }
        final authenticated = await localAuth.authenticate(
          localizedReason: 'Enable teacher access on this phone.',
          biometricOnly: false,
        );
        if (!authenticated) {
          setState(() => _status = 'Setup was cancelled. Retry to continue.');
          return;
        }
      }

      final binding = DeviceAccountBinding(
        userId: widget.userId,
        role: widget.role,
        deviceId: deviceId,
      );
      await _verifyBoundSupabaseSession(binding).timeout(const Duration(seconds: 20));
      await DeviceAccountBindingStore.save(binding);

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => DashboardScreen(role: widget.role),
        ),
        (route) => false,
      );
    } on DeviceCryptoException catch (error) {
      if (mounted) {
        setState(() => _status = 'Hardware security error: ${error.message}');
      }
    } on DeviceSessionValidationException catch (error) {
      if (mounted) {
        setState(() => _status = '${error.message} Secure recovery required.');
      }
    } catch (error) {
      debugPrint('Device setup failed: $error');
      if (mounted) {
        setState(() => _status = 'Setup error: $error. Check connection and retry.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openRecovery() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceRecoveryScreen(userId: widget.userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.phonelink_lock,
                      color: brandOrange,
                      size: 58,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Register This Device',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.role == UserRole.student
                          ? 'This phone will generate a hardware cryptographic key in Android Keystore bound to your biometric credentials. Only one registered phone is permitted per student.'
                          : 'Link this teacher account securely to this phone.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: brandOrange),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _enableDeviceUnlock,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.security),
                        label: Text(
                          _isLoading
                              ? 'SECURING DEVICE...'
                              : 'REGISTER ATTENDANCE KEY',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: brandOrange,
                          foregroundColor: white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ),
                    if (_showRecoveryOption) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _openRecovery,
                        icon: const Icon(Icons.phonelink_erase),
                        label: const Text('REQUEST DEVICE REPLACEMENT'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DeviceUnlockScreen extends StatefulWidget {
  const DeviceUnlockScreen({super.key, required this.binding});

  final DeviceAccountBinding binding;

  @override
  State<DeviceUnlockScreen> createState() => _DeviceUnlockScreenState();
}

class _DeviceUnlockScreenState extends State<DeviceUnlockScreen> {
  bool _isLoading = false;
  String _status = '';
  bool _keyInvalidated = false;
  bool _notRegistered = false;

  Future<void> _unlock() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _keyInvalidated = false;
      _notRegistered = false;
      _status = 'Requesting cryptographic challenge from server...';
    });

    try {
      final backend = AttendanceBackend(Supabase.instance.client);

      if (widget.binding.role == UserRole.student) {
        if (widget.binding.deviceId.isEmpty) {
          setState(() {
            _notRegistered = true;
            _status =
                'This phone has not completed cryptographic key registration yet. Please register your attendance key.';
          });
          return;
        }

        // 1. Request fresh single-use unlock challenge from Supabase
        final challengeResult = await backend.createChallenge(
          deviceId: widget.binding.deviceId,
          purpose: 'unlock',
        );

        setState(() {
          _status = 'Touch the biometric sensor to sign the challenge...';
        });

        // 2. Authorize and sign using Android Keystore private key
        final signature = await DeviceCrypto.signChallenge(
          challenge: challengeResult.challenge,
          title: 'Unlock Oceanic Attendance',
          subtitle: 'Authorize private key to sign server challenge',
        );

        setState(() {
          _status = 'Verifying cryptographic signature on Supabase...';
        });

        // 3. Verify signature on Supabase Edge Function
        final verified = await backend.verifyUnlock(
          deviceId: widget.binding.deviceId,
          challenge: challengeResult.challenge,
          signature: signature,
        );

        if (!verified) {
          setState(() {
            _status = 'Cryptographic signature verification failed on server.';
          });
          return;
        }
      } else {
        // Teacher uses local auth
        final localAuth = LocalAuthentication();
        final auth = await localAuth.authenticate(
          localizedReason: 'Unlock Oceanic Attendance on this device.',
        );
        if (!auth) {
          setState(() => _status = 'Authentication was cancelled.');
          return;
        }
      }

      await _verifyBoundSupabaseSession(widget.binding)
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => DashboardScreen(role: widget.binding.role),
        ),
        (route) => false,
      );
    } on KeyInvalidatedException {
      if (!mounted) return;
      setState(() {
        _keyInvalidated = true;
        _status =
            'CRITICAL SECURITY ALERT: Biometric enrollment on this phone has changed since key registration! For security, Android Keystore has permanently invalidated the private key. You must submit a device recovery request.';
      });
    } on BiometricCancelledException {
      if (!mounted) return;
      setState(() => _status = 'Biometric verification was cancelled.');
    } on BiometricLockoutException {
      if (!mounted) return;
      setState(() => _status = 'Biometric sensor locked out. Retry in 30 seconds.');
    } on DeviceCryptoException catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Keystore cryptographic error: ${error.message}');
    } on DeviceSessionValidationException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = '${error.message} Session recovery required.';
      });
    } on FunctionException catch (error) {
      debugPrint('Device unlock function error: ${error.status} ${error.details}');
      if (!mounted) return;
      final details = error.details;
      final code = (details is Map) ? details['code']?.toString() : null;
      final message = (details is Map)
          ? details['message']?.toString()
          : (error.reasonPhrase ?? 'Server error (${error.status}).');

      if (code == 'device_not_registered' || error.status == 403) {
        setState(() {
          _notRegistered = true;
          _status = message ??
              'This phone is not actively registered as an attendance device. Please register your attendance key.';
        });
      } else {
        setState(() {
          _status = message ?? 'Server verification error (${error.status})';
        });
      }
    } catch (error) {
      debugPrint('Device unlock failed: $error');
      if (!mounted) return;
      setState(() {
        _status = 'Unlock could not be verified: $error';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openSetup() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DeviceAuthSetupScreen(
          userId: widget.binding.userId,
          role: widget.binding.role,
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    await DeviceAccountBindingStore.clear();
    await Supabase.instance.client.auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
      (route) => false,
    );
  }

  void _openRecovery() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceRecoveryScreen(userId: widget.binding.userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _keyInvalidated ? Icons.warning_rounded : Icons.lock_person,
                      color: _keyInvalidated ? const Color(0xFFB3261E) : brandOrange,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _keyInvalidated ? 'Cryptographic Key Invalidation' : 'Welcome back',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.binding.role.label} account on this device',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _status.isEmpty
                          ? 'Unlock with your hardware-backed cryptographic biometric key.'
                          : _status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _keyInvalidated ? const Color(0xFFB3261E) : brandOrange,
                        fontWeight: _keyInvalidated ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (!_keyInvalidated && !_notRegistered)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _unlock,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.fingerprint),
                          label: Text(
                            _isLoading ? 'VERIFYING...' : 'SIGN & UNLOCK DEVICE',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandOrange,
                            foregroundColor: white,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                          ),
                        ),
                      ),
                    if (_notRegistered)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _openSetup,
                          icon: const Icon(Icons.app_registration),
                          label: const Text('REGISTER ATTENDANCE KEY'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandOrange,
                            foregroundColor: white,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                          ),
                        ),
                      ),
                    if (_keyInvalidated)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _openRecovery,
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('SUBMIT RECOVERY REQUEST'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFB3261E),
                            foregroundColor: white,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: _isLoading ? null : _signOut,
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Sign out of this device'),
                      style: TextButton.styleFrom(
                        foregroundColor: mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DeviceRecoveryScreen extends StatefulWidget {
  const DeviceRecoveryScreen({super.key, required this.userId});

  final String userId;

  @override
  State<DeviceRecoveryScreen> createState() => _DeviceRecoveryScreenState();
}

class _DeviceRecoveryScreenState extends State<DeviceRecoveryScreen> {
  final TextEditingController _reasonController = TextEditingController();
  bool _isLoading = false;
  String? _status;
  bool _submitted = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submitRecovery() async {
    final reason = _reasonController.text.trim();
    if (reason.length < 5) {
      setState(() => _status = 'Please provide a clear reason (at least 5 characters).');
      return;
    }

    setState(() {
      _isLoading = true;
      _status = 'Generating new Keystore key pair on this phone...';
    });

    try {
      final deviceId = await DeviceCrypto.getOrCreateDeviceId();
      final newPublicKeySpki = await DeviceCrypto.generateKeyPair();

      setState(() => _status = 'Submitting request to course administration...');

      final backend = AttendanceBackend(Supabase.instance.client);
      final result = await backend.requestDeviceRecovery(
        newDeviceId: deviceId,
        newPublicKeySpki: newPublicKeySpki,
        reason: reason,
      );

      if (!mounted) return;
      setState(() {
        _submitted = true;
        _status = result['message']?.toString() ??
            'Recovery request submitted. Please notify your course teacher to review and approve your device replacement.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Failed to submit recovery request: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Recovery'),
        backgroundColor: deepNavy,
        foregroundColor: white,
      ),
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.phonelink_setup, color: brandOrange, size: 54),
                    const SizedBox(height: 14),
                    const Text(
                      'Request Device Replacement',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Because each student is permitted only one active attendance phone, registering a new phone or resetting invalidated biometric keys requires verified teacher/admin approval.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    if (!_submitted) ...[
                      TextField(
                        controller: _reasonController,
                        maxLines: 3,
                        style: const TextStyle(color: ink),
                        decoration: const InputDecoration(
                          labelText: 'Reason for Device Replacement',
                          hintText: 'e.g., Phone was replaced, biometric template was reset, etc.',
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_status != null)
                        Text(
                          _status!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: brandOrange),
                        ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _submitRecovery,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: white,
                                  ),
                                )
                              : const Icon(Icons.send),
                          label: Text(_isLoading ? 'SUBMITTING...' : 'SUBMIT RECOVERY REQUEST'),
                        ),
                      ),
                    ] else ...[
                      const Icon(Icons.check_circle_outline, color: Color(0xFF287A45), size: 54),
                      const SizedBox(height: 12),
                      Text(
                        _status ?? 'Request submitted.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF287A45), fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 18),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('BACK TO LOGIN'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SessionRecoveryScreen extends StatelessWidget {
  const SessionRecoveryScreen({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_reset, color: brandOrange, size: 58),
                    const SizedBox(height: 16),
                    const Text(
                      'Secure sign-in needs recovery',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$message No dashboard will open until Supabase sign-in is valid again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk),
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      onPressed: () async {
                        await Supabase.instance.client.auth.signOut();
                        await DeviceAccountBindingStore.clear();
                        if (context.mounted) {
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RoleSelectionScreen(),
                            ),
                            (r) => false,
                          );
                        }
                      },
                      child: const Text('SIGN OUT AND RESET'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<String> getStudentDisplayName() async {
  final supabase = Supabase.instance.client;
  final email = supabase.auth.currentUser?.email?.trim().toLowerCase();

  if (email == null || email.isEmpty) {
    return 'Student';
  }

  try {
    final result = await supabase
        .from('student_directory')
        .select('full_name')
        .eq('email', email)
        .maybeSingle();

    if (result == null) {
      return 'Student';
    }

    final fullName = result['full_name']?.toString().trim() ?? '';
    if (fullName.isEmpty) {
      return 'Student';
    }

    final nameParts = fullName.split(RegExp(r'\s+'));
    final displayName = nameParts.last.toLowerCase();
    return displayName[0].toUpperCase() + displayName.substring(1);
  } catch (error) {
    debugPrint('Student name lookup failed: $error');
    return 'Student';
  }
}

class DashboardScreen extends StatefulWidget {
  final UserRole role;

  const DashboardScreen({super.key, required this.role});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Future<StudentAttendanceSummary>? _attendanceSummaryFuture;
  Future<List<TeacherSession>>? _teacherSessionsFuture;
  RealtimeChannel? _studentAttendanceChannel;
  String? _selectedSubject;

  @override
  void initState() {
    super.initState();
    if (widget.role == UserRole.student) {
      // Initially, we don't load summary until a subject is selected
      // Or we can load overall summary. The request says "subject-specific Attendance Overview card that appears... when a student clicks"
      _setupRealtimeSubscription();
    } else {
      _loadTeacherSessions();
    }
  }

  @override
  void dispose() {
    final ch = _studentAttendanceChannel;
    if (ch != null) {
      Supabase.instance.client.removeChannel(ch);
    }
    super.dispose();
  }

  void _setupRealtimeSubscription() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;

    final client = Supabase.instance.client;
    _studentAttendanceChannel = client.channel('student-attendance-summary-$uid')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'attendance_records',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'student_id',
          value: uid,
        ),
        callback: (_) {
          if (mounted && _selectedSubject != null) {
            _loadAttendanceSummary(subject: _selectedSubject);
          }
        },
      )
      ..subscribe();
  }

  void _loadAttendanceSummary({String? subject}) {
    final backend = AttendanceBackend(Supabase.instance.client);
    setState(() {
      _attendanceSummaryFuture = backend.getStudentAttendanceSummary(subject: subject);
    });
  }

  void _loadTeacherSessions() {
    final backend = AttendanceBackend(Supabase.instance.client);
    setState(() {
      _teacherSessionsFuture = backend.loadTeacherSessions();
    });
  }

  Future<void> _refreshSummary() async {
    if (widget.role == UserRole.teacher) {
      _loadTeacherSessions();
      await _teacherSessionsFuture;
    } else {
      if (_selectedSubject != null) {
        _loadAttendanceSummary(subject: _selectedSubject);
        await _attendanceSummaryFuture;
      }
    }
  }

  void _onViewAttendance(String subject) {
    setState(() {
      _selectedSubject = subject;
    });
    _loadAttendanceSummary(subject: subject);
  }

  @override
  Widget build(BuildContext context) {
    final isTeacher = widget.role == UserRole.teacher;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.role.label} Dashboard'),
        backgroundColor: deepNavy,
        foregroundColor: white,
        actions: [
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await Supabase.instance.client.auth.signOut();
              await DeviceAccountBindingStore.clear();
              if (context.mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RoleSelectionScreen(),
                  ),
                  (r) => false,
                );
              }
            },
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: FloatingActionButton.large(
        tooltip: isTeacher ? 'Start BLE Attendance' : 'Find Teacher',
        backgroundColor: brandOrange,
        foregroundColor: white,
        elevation: 7,
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => isTeacher
                  ? const TeacherBleScreen()
                  : const StudentBleScreen(),
            ),
          );
          if (mounted) {
            if (widget.role == UserRole.student) {
              if (_selectedSubject != null) {
                _loadAttendanceSummary(subject: _selectedSubject);
              }
            } else {
              _loadTeacherSessions();
            }
          }
        },
        child: const Icon(Icons.bluetooth_searching, size: 44),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.large),
            child: Column(
              children: [
                const SizedBox(height: 18),
                FutureBuilder<String>(
                  future: widget.role == UserRole.student
                      ? getStudentDisplayName()
                      : Future.value('Teacher'),
                  builder: (context, snapshot) {
                    final displayName = snapshot.data ?? widget.role.label;
                    return SizedBox(
                      width: double.infinity,
                      child: Text(
                        'Hello, $displayName!',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshSummary,
                    color: brandOrange,
                    backgroundColor: Colors.white,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Column(
                        children: [
                          if (widget.role == UserRole.teacher &&
                              _teacherSessionsFuture != null) ...[
                            _TeacherSessionsOverviewCard(
                              future: _teacherSessionsFuture!,
                              onRefresh: _loadTeacherSessions,
                            ),
                            const SizedBox(height: 80),
                          ],
                          if (widget.role == UserRole.student) ...[
                            _TodaysClassesSection(
                              onViewAttendance: _onViewAttendance,
                            ),
                            if (_selectedSubject != null && _attendanceSummaryFuture != null) ...[
                              const SizedBox(height: 24),
                              FutureBuilder<StudentAttendanceSummary>(
                                key: ValueKey(_selectedSubject),
                                future: _attendanceSummaryFuture,
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return Container(
                                      width: double.infinity,
                                      constraints:
                                          const BoxConstraints(maxWidth: 440),
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 12,
                                      ),
                                      padding: const EdgeInsets.all(36),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius:
                                            BorderRadius.circular(28),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x18102040),
                                            blurRadius: 24,
                                            offset: Offset(0, 10),
                                          ),
                                        ],
                                      ),
                                      child: const Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          CircularProgressIndicator(
                                            color: brandOrange,
                                          ),
                                          SizedBox(height: 18),
                                          Text(
                                            'Loading your attendance summary...',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: mutedInk,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  if (snapshot.hasError) {
                                    return Container(
                                      width: double.infinity,
                                      constraints:
                                          const BoxConstraints(maxWidth: 440),
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 12,
                                      ),
                                      padding: const EdgeInsets.all(26),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius:
                                            BorderRadius.circular(28),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x18102040),
                                            blurRadius: 24,
                                            offset: Offset(0, 10),
                                          ),
                                        ],
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.sync_problem_rounded,
                                            color: Color(0xFFDC2626),
                                            size: 42,
                                          ),
                                          const SizedBox(height: 12),
                                          const Text(
                                            'Could not load attendance summary',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: ink,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            '${snapshot.error}',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: mutedInk,
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          ElevatedButton.icon(
                                            onPressed: () => _loadAttendanceSummary(subject: _selectedSubject),
                                            icon: const Icon(Icons.refresh),
                                            label: const Text('RETRY'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: brandOrange,
                                              foregroundColor: white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  final summary = snapshot.data ??
                                      StudentAttendanceSummary.empty();

                                  return Column(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                                        child: Text(
                                          'Attendance Overview — $_selectedSubject',
                                          style: const TextStyle(
                                            color: white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      AttendanceSummary.fromSummary(summary),
                                    ],
                                  );
                                },
                              ),
                            ],
                            const SizedBox(height: 90),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TeacherSessionsOverviewCard extends StatelessWidget {
  const _TeacherSessionsOverviewCard({
    required this.future,
    required this.onRefresh,
  });

  final Future<List<TeacherSession>> future;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      padding: const EdgeInsets.all(22),
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
      child: FutureBuilder<List<TeacherSession>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: brandOrange),
              ),
            );
          }

          if (snapshot.hasError) {
            return Column(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Color(0xFFDC2626),
                  size: 36,
                ),
                const SizedBox(height: 8),
                Text(
                  'Could not load sessions: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: mutedInk),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: onRefresh,
                  child: const Text('RETRY'),
                ),
              ],
            );
          }

          final sessions = snapshot.data ?? [];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Conducted Sessions',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: ink,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Tap a session to mark attendance',
                        style: TextStyle(
                          fontSize: 13,
                          color: mutedInk,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${sessions.length} Total',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (sessions.isEmpty)
                Container(
                  padding: const EdgeInsets.all(28),
                  alignment: Alignment.center,
                  child: const Column(
                    children: [
                      Icon(Icons.event_note, size: 48, color: mutedInk),
                      SizedBox(height: 10),
                      Text(
                        'No attendance sessions yet.\nTap the orange Bluetooth button below to create your first session.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: mutedInk, fontSize: 13),
                      ),
                    ],
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: sessions.length,
                  separatorBuilder: (_, index) => const SizedBox(height: 10),
                  itemBuilder: (context, idx) {
                    final session = sessions[idx];
                    return _TeacherSessionCard(
                      session: session,
                      onReturn: onRefresh,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TeacherSessionCard extends StatelessWidget {
  const _TeacherSessionCard({
    required this.session,
    required this.onReturn,
  });

  final TeacherSession session;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${session.startsAt.day}/${session.startsAt.month}/${session.startsAt.year} · ${TimeOfDay.fromDateTime(session.startsAt).format(context)}';

    return InkWell(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TeacherSessionRosterScreen(
              sessionId: session.id,
              sessionTitle: session.title,
              sessionCode: session.sessionCode,
              startedAt: session.startsAt,
            ),
          ),
        );
        onReturn();
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: session.isActive
                    ? const Color(0xFFEFFBF5)
                    : const Color(0xFFEEF2F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                session.isActive
                    ? Icons.bluetooth_connected
                    : Icons.check_circle_outline,
                color: session.isActive
                    ? const Color(0xFF16A34A)
                    : brandOrange,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    dateStr,
                    style: const TextStyle(
                      fontSize: 12,
                      color: mutedInk,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFFBF5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${session.presentCount} Present',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF16A34A),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1F2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${session.absentCount} Absent',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                      ),
                      if (session.sessionCode.isNotEmpty) ...[
                        const Spacer(),
                        Text(
                          '#${session.sessionCode}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: mutedInk,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              color: Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodaysClassesSection extends StatelessWidget {
  final Function(String) onViewAttendance;

  const _TodaysClassesSection({required this.onViewAttendance});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_rounded,
                  size: 18,
                  color: brandOrange,
                ),
                SizedBox(width: 8),
                Text(
                  "Today's Classes",
                  style: TextStyle(
                    color: white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SubjectClassCard(
            subjectName: 'SDTT',
            icon: Icons.book_rounded,
            iconColor: Colors.blue.shade700,
            iconBgColor: const Color(0xFFEFF6FF),
            onViewAttendance: () => onViewAttendance('SDTT'),
          ),
          const SizedBox(height: 10),
          _SubjectClassCard(
            subjectName: 'DE',
            icon: Icons.book_rounded,
            iconColor: Colors.green.shade700,
            iconBgColor: const Color(0xFFF0FDF4),
            onViewAttendance: () => onViewAttendance('DE'),
          ),
          const SizedBox(height: 10),
          _SubjectClassCard(
            subjectName: 'DAA',
            icon: Icons.book_rounded,
            iconColor: Colors.orange.shade700,
            iconBgColor: const Color(0xFFFFF7ED),
            onViewAttendance: () => onViewAttendance('DAA'),
          ),
        ],
      ),
    );
  }
}

class _SubjectClassCard extends StatelessWidget {
  const _SubjectClassCard({
    required this.subjectName,
    required this.icon,
    required this.iconColor,
    required this.iconBgColor,
    required this.onViewAttendance,
  });

  final String subjectName;
  final IconData icon;
  final Color iconColor;
  final Color iconBgColor;
  final VoidCallback onViewAttendance;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x18102040),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBgColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                subjectName,
                style: const TextStyle(
                  color: ink,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: onViewAttendance,
              style: ElevatedButton.styleFrom(
                backgroundColor: deepNavy,
                foregroundColor: white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'View Attendance',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ClassDetailsScreen extends StatelessWidget {
  const ClassDetailsScreen({
    super.key,
    required this.subjectName,
  });

  final String subjectName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(subjectName),
        backgroundColor: deepNavy,
        foregroundColor: white,
      ),
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.large),
              child: AppSurfaceCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: Color(0x22F28A2E),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.school_rounded,
                        color: brandOrange,
                        size: 36,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      subjectName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Class Details',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: mutedInk,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Detailed timetable, classroom info, and syllabus for this class will appear here once timetable data is synced.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: mutedInk,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
