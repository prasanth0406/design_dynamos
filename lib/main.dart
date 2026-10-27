import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_theme.dart';
import 'attendance_screen.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseProjectUrl = 'https://otfazpvwsxintyzcytvx.supabase.co';
const String supabasePublishableKey =
    'sb_publishable_dy9LkmDGDwFVHTzGdiqnbA_CwKgVJKZ';
const String _secureSupabaseSessionKey = 'oceanic_supabase_session_v1';
const String _deviceBindingKey = 'oceanic_device_account_binding_v1';
const String _legacySupabaseSessionKey = 'sb-otfazpvwsxintyzcytvx-auth-token';

final FlutterSecureStorage _secureStorage = FlutterSecureStorage();

/// Stores Supabase's refresh/access tokens encrypted on this device.
/// Existing SharedPreferences sessions are migrated once to avoid forcing users
/// to sign in again after upgrading this app.
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
  const DeviceAccountBinding({required this.userId, required this.role});

  final String userId;
  final UserRole role;

  String encode() => jsonEncode({'userId': userId, 'role': role.value});

  static DeviceAccountBinding decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid device account binding.');
    }
    final userId = decoded['userId'];
    final role = _userRoleFromValue(decoded['role']);
    if (userId is! String || userId.isEmpty || role == null) {
      throw const FormatException('Invalid device account binding.');
    }
    return DeviceAccountBinding(userId: userId, role: role);
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

  // Refresh on every unlock so a revoked refresh token is rejected before the
  // app opens, even if the locally cached access JWT has not expired yet.
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

// Email format rules:
// Student: 23bcs123@iiitdwd.ac.in, 24bcs123@iiitdwd.ac.in,
//          or 25bcs123@iiitdwd.ac.in (three digits assumed).
// Teacher: a username beginning with a letter, e.g. name@iiitdwd.ac.in.
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
        data: {
          // This records the selected role as signup metadata.
          // For production security, enforce roles on the server/database too.
          'role': widget.role.value,
        },
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

      // Check the role saved when the account was created.
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
                    if (!isSignUp) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.security,
                            color: brandOrange,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'After your first sign-in, this phone will ask you to enable face, fingerprint, or screen-lock authentication.',
                              style: TextStyle(color: mutedInk, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
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
      'Link this account to this phone before opening the dashboard.';

  Future<void> _enableDeviceUnlock() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _status = 'Confirm your face, fingerprint, or phone screen lock.';
    });

    try {
      final localAuth = LocalAuthentication();
      if (!await localAuth.isDeviceSupported()) {
        setState(() {
          _status = 'Set up face unlock, a fingerprint, or a PIN, pattern, or password in phone settings, then retry.';
        });
        return;
      }

      final authenticated = await localAuth.authenticate(
        localizedReason: 'Enable secure sign-in for Oceanic Attendance.',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (!authenticated) {
        setState(
          () =>
              _status = 'Setup was cancelled. Retry to enable secure sign-in.',
        );
        return;
      }

      final binding = DeviceAccountBinding(
        userId: widget.userId,
        role: widget.role,
      );
      await _verifyBoundSupabaseSession(binding)
          .timeout(const Duration(seconds: 20));
      await DeviceAccountBindingStore.save(binding);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => DashboardScreen(role: widget.role),
        ),
        (route) => false,
      );
    } on DeviceSessionValidationException catch (error) {
      if (mounted) {
        setState(
          () => _status =
              '${error.message} Secure account recovery is required before the dashboard can open.',
        );
      }
    } on AuthRetryableFetchException catch (error) {
      debugPrint('Supabase setup could not reach the server: ${error.message}');
      if (mounted) {
        setState(
          () => _status = 'Supabase could not be reached. Check your connection and retry setup.',
        );
      }
    } on AuthException catch (error) {
      debugPrint('Supabase setup validation failed: ${error.message}');
      if (mounted) {
        setState(
          () => _status = 'Supabase could not validate this account. Check your connection and retry setup.',
        );
      }
    } catch (error) {
      debugPrint('Device unlock setup failed: $error');
      if (mounted) {
        setState(
          () => _status = 'Secure setup could not finish. Check your connection and device lock settings, then retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
                      'Enable secure sign-in',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'This ${widget.role.label.toLowerCase()} account will be linked to this phone. Future openings will show only the device-unlock screen.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Use the face, fingerprint, or PIN, pattern, or password configured in your phone security prompt.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: mutedInk, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
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
                                ),
                              )
                            : const Icon(Icons.lock_open),
                        label: Text(
                          _isLoading ? 'SETTING UP...' : 'ENABLE DEVICE UNLOCK',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: brandOrange,
                          foregroundColor: white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
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

class DeviceUnlockScreen extends StatefulWidget {
  const DeviceUnlockScreen({super.key, required this.binding});

  final DeviceAccountBinding binding;

  @override
  State<DeviceUnlockScreen> createState() => _DeviceUnlockScreenState();
}

class _DeviceUnlockScreenState extends State<DeviceUnlockScreen> {
  bool _isLoading = false;
  String _status = '';

  Future<void> _unlock() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _status = 'Waiting for device authentication...';
    });

    try {
      final localAuth = LocalAuthentication();
      final authenticated = await localAuth.authenticate(
        localizedReason: 'Unlock Oceanic Attendance with this phone.',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (!authenticated) {
        setState(
          () => _status =
              'Authentication failed or was cancelled. You can retry.',
        );
        return;
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
    } on DeviceSessionValidationException catch (error) {
      if (!mounted) return;
      setState(() {
        _status =
            '${error.message} Secure account recovery is required; the dashboard remains locked.';
      });
    } on AuthRetryableFetchException catch (error) {
      debugPrint(
        'Supabase unlock could not reach the server: ${error.message}',
      );
      if (!mounted) return;
      setState(() {
        _status = 'Supabase could not be reached to validate the session. Check your connection and retry.';
      });
    } on AuthException catch (error) {
      debugPrint('Supabase unlock validation failed: ${error.message}');
      if (!mounted) return;
      setState(() {
        _status = 'Supabase rejected the saved session. Secure account recovery is required; the dashboard remains locked.';
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _status = 'Supabase could not be reached to validate the session. Check your connection and retry.';
      });
    } catch (error) {
      debugPrint('Device unlock failed: $error');
      if (!mounted) return;
      setState(() {
        _status = 'The saved session could not be verified. Check your connection and retry.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

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
                    const Icon(Icons.lock_person, color: brandOrange, size: 64),
                    const SizedBox(height: 16),
                    const Text(
                      'Welcome back',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 27,
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
                          ? 'Unlock with your saved face, fingerprint, or phone screen lock.'
                          : _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: brandOrange),
                    ),
                    const SizedBox(height: 22),
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
                                ),
                              )
                            : const Icon(Icons.lock_open),
                        label: Text(
                          _isLoading ? 'VERIFYING...' : 'UNLOCK THIS DEVICE',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: brandOrange,
                          foregroundColor: white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
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

class DashboardScreen extends StatelessWidget {
  final UserRole role;

  const DashboardScreen({super.key, required this.role});

  @override
  Widget build(BuildContext context) {
    final isTeacher = role == UserRole.teacher;

    return Scaffold(
      appBar: AppBar(
        title: Text('${role.label} Dashboard'),
        backgroundColor: deepNavy,
        foregroundColor: white,
        actions: const [],
      ),
      body: AppBackground(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.large),
            child: AppSurfaceCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isTeacher ? Icons.cast_for_education : Icons.school,
                    color: brandOrange,
                    size: 60,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Welcome, ${role.label}!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isTeacher
                        ? 'Your teacher dashboard is ready. Attendance management features can be added here.'
                        : 'Your student dashboard is ready. Attendance viewing and marking features can be added here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: mutedInk, fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: Icon(
                        isTeacher ? Icons.bluetooth_searching : Icons.bluetooth,
                      ),
                      label: Text(
                        isTeacher ? 'Start BLE Attendance' : 'Find Teacher',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: brandOrange,
                        foregroundColor: white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => isTeacher
                                ? const TeacherBleScreen()
                                : const StudentBleScreen(),
                          ),
                        );
                      },
                    ),
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
