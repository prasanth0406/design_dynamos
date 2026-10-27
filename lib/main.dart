import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'attendance_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseProjectUrl = 'https://otfazpvwsxintyzcytvx.supabase.co';
const String supabasePublishableKey = 'sb_publishable_dy9LkmDGDwFVHTzGdiqnbA_CwKgVJKZ';
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
  Future<void> persistSession(String persistSessionString) =>
      _secureStorage.write(
        key: _secureSupabaseSessionKey,
        value: persistSessionString,
      );
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

// Ocean theme colors
const Color midnightBlue = Color(0xFF081328);
const Color deepNavy = Color(0xFF102C51);
const Color aquamarine = Color(0xFF5BC0BE);
const Color white = Colors.white;

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

  static Future<void> clear() =>
      _secureStorage.delete(key: _deviceBindingKey);
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
          message: 'The saved Supabase session is missing or expired. Reauthenticate to use this account.',
        );
      }
      if (session.user.id != binding.userId) {
        return const SessionRecoveryScreen(
          message: 'The saved Supabase account does not match this device binding. Reauthenticate to recover access.',
        );
      }
      return DeviceUnlockScreen(binding: binding);
    }

    if (session != null) {
      final role = _userRoleFromValue(session.user.userMetadata?['role']);
      if (role == null) {
        return const SessionRecoveryScreen(
          message: 'This Supabase account has no valid attendance role. Sign out and reauthenticate to recover access.',
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
            message: 'Secure device sign-in could not be read. Use account recovery to sign in again.',
          );
        }
        return const Scaffold(
          backgroundColor: deepNavy,
          body: Center(child: CircularProgressIndicator(color: aquamarine)),
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
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(seedColor: aquamarine),
      ),
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
      body: OceanBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.waves_rounded,
                      size: 62,
                      color: aquamarine,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Oceanic Attendance',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Choose how you want to sign in',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: white.withValues(alpha: 0.82),
                        fontSize: 15,
                      ),
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
          gradient: const LinearGradient(
            colors: [Color(0xFF13C8D2), Color(0xFF377FAF)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: white.withValues(alpha: 0.7)),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Icon(icon, color: white, size: 34),
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
                            color: white.withValues(alpha: 0.85),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, color: white, size: 18),
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
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
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
          showMessage('Account was created, but secure setup could not start. Sign in to continue.');
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
      body: OceanBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back, color: white),
                      ),
                    ),
                    Icon(
                      widget.role == UserRole.teacher
                          ? Icons.cast_for_education_rounded
                          : Icons.school_rounded,
                      color: aquamarine,
                      size: 54,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$roleName ${isSignUp ? 'Sign Up' : 'Login'}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: white,
                        fontSize: 27,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      emailRuleMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: white.withValues(alpha: 0.8),
                        fontSize: 13,
                      ),
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
                          color: white,
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
                          const Icon(Icons.security, color: aquamarine, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'After your first sign-in, this phone will ask you to enable face, fingerprint, or screen-lock authentication.',
                              style: TextStyle(
                                color: white.withValues(alpha: 0.8),
                                fontSize: 12,
                              ),
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
                            colors: [Color(0xFF13C8D2), Color(0xFF377FAF)],
                          ),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: white.withValues(alpha: 0.8),
                          ),
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
                              borderRadius: BorderRadius.circular(30),
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
                          color: aquamarine,
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
      style: const TextStyle(color: white, fontSize: 15),
      cursorColor: aquamarine,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: white.withValues(alpha: 0.7)),
        prefixIcon: Icon(icon, color: aquamarine),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: white.withValues(alpha: 0.08),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: white.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: aquamarine, width: 1.5),
        ),
      ),
    );
  }
}

Future<void> _signOutAndReturnToRoleSelection(BuildContext context) async {
  try {
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    await DeviceAccountBindingStore.clear();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
      (route) => false,
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sign out could not finish. This device remains locked to its account.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    debugPrint('Secure sign-out failed: $error');
  }
}

Future<void> _confirmSignOutAndReturn(BuildContext context) async {
  final shouldSignOut = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sign out and unlink this device?'),
      content: const Text(
        'This clears the saved account on this phone. The next sign-in will require your Supabase email and password, then device unlock setup again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('SIGN OUT'),
        ),
      ],
    ),
  );
  if (shouldSignOut == true && context.mounted) {
    await _signOutAndReturnToRoleSelection(context);
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
  String _status = 'Link this account to this phone before opening the dashboard.';

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
        setState(() => _status = 'Setup was cancelled. Retry to enable secure sign-in.');
        return;
      }

      final binding = DeviceAccountBinding(
        userId: widget.userId,
        role: widget.role,
      );
      await _verifyBoundSupabaseSession(binding).timeout(
        const Duration(seconds: 20),
      );
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
        setState(() => _status = '${error.message} Sign out and reauthenticate to recover access.');
      }
    } on AuthRetryableFetchException catch (error) {
      debugPrint('Supabase setup could not reach the server: ${error.message}');
      if (mounted) {
        setState(() => _status = 'Supabase could not be reached. Check your connection and retry setup.');
      }
    } on AuthException catch (error) {
      debugPrint('Supabase setup validation failed: ${error.message}');
      if (mounted) {
        setState(() => _status = 'Supabase could not validate this account. Check your connection and retry, or sign out and reauthenticate.');
      }
    } catch (error) {
      debugPrint('Device unlock setup failed: $error');
      if (mounted) {
        setState(() => _status = 'Secure setup could not finish. Check your connection and device lock settings, then retry.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: OceanBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.phonelink_lock, color: aquamarine, size: 58),
                    const SizedBox(height: 16),
                    const Text(
                      'Enable secure sign-in',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white, fontSize: 25, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'This ${widget.role.label.toLowerCase()} account will be linked to this phone. Future openings will show only the device-unlock screen.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white.withValues(alpha: 0.85)),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Use the face, fingerprint, or PIN, pattern, or password configured in your phone security prompt.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white.withValues(alpha: 0.75), fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: aquamarine),
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
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.lock_open),
                        label: Text(_isLoading ? 'SETTING UP...' : 'ENABLE DEVICE UNLOCK'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: aquamarine,
                          foregroundColor: deepNavy,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => _confirmSignOutAndReturn(context),
                      child: const Text('Sign out and use another account'),
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
  bool _needsRecovery = false;
  String _status = '';

  Future<void> _unlock() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _needsRecovery = false;
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
        setState(() => _status = 'Authentication failed or was cancelled. You can retry.');
        return;
      }

      await _verifyBoundSupabaseSession(widget.binding).timeout(
        const Duration(seconds: 20),
      );
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
        _needsRecovery = true;
        _status = '${error.message} Account recovery or reauthentication is required.';
      });
    } on AuthRetryableFetchException catch (error) {
      debugPrint('Supabase unlock could not reach the server: ${error.message}');
      if (!mounted) return;
      setState(() {
        _status = 'Supabase could not be reached to validate the session. Check your connection and retry.';
      });
    } on AuthException catch (error) {
      debugPrint('Supabase unlock validation failed: ${error.message}');
      if (!mounted) return;
      setState(() {
        _needsRecovery = true;
        _status = 'Supabase rejected the saved session. Account recovery or reauthentication is required.';
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
      body: OceanBackground(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_person, color: aquamarine, size: 64),
                    const SizedBox(height: 16),
                    const Text(
                      'Welcome back',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white, fontSize: 27, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.binding.role.label} account on this device',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white.withValues(alpha: 0.82)),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _status.isEmpty
                          ? 'Unlock with your saved face, fingerprint, or phone screen lock.'
                          : _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: aquamarine),
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
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.lock_open),
                        label: Text(_isLoading ? 'VERIFYING...' : 'UNLOCK THIS DEVICE'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: aquamarine,
                          foregroundColor: deepNavy,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ),
                    if (_needsRecovery) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Your dashboard stays locked until the Supabase account is recovered.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () => _confirmSignOutAndReturn(context),
                        child: const Text('Account recovery / sign out'),
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
      body: OceanBackground(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_reset, color: aquamarine, size: 58),
                    const SizedBox(height: 16),
                    const Text(
                      'Secure sign-in needs recovery',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white, fontSize: 23, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$message No dashboard will open until Supabase sign-in is valid again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: white.withValues(alpha: 0.85)),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _signOutAndReturnToRoleSelection(context),
                        icon: const Icon(Icons.logout),
                        label: const Text('SIGN OUT AND REAUTHENTICATE'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: aquamarine,
                          foregroundColor: deepNavy,
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

class DashboardScreen extends StatelessWidget {
  final UserRole role;

  const DashboardScreen({super.key, required this.role});

  Future<void> _signOut(BuildContext context) async {
    await _confirmSignOutAndReturn(context);
  }

  @override
  Widget build(BuildContext context) {
    final isTeacher = role == UserRole.teacher;

    return Scaffold(
      appBar: AppBar(
        title: Text('${role.label} Dashboard'),
        backgroundColor: deepNavy,
        foregroundColor: white,
        actions: [
          IconButton(
            tooltip: 'Sign out and unlink this device',
            onPressed: () => _signOut(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: OceanBackground(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isTeacher ? Icons.cast_for_education : Icons.school,
                    color: aquamarine,
                    size: 60,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Welcome, ${role.label}!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: white,
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
                    style: TextStyle(
                      color: white.withValues(alpha: 0.88),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: Icon(isTeacher ? Icons.bluetooth_searching : Icons.bluetooth),
                      label: Text(isTeacher ? 'Start BLE Attendance' : 'Find Teacher'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: aquamarine,
                        foregroundColor: deepNavy,
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

class OceanBackground extends StatelessWidget {
  final Widget child;

  const OceanBackground({super.key, required this.child});

  Widget _glowCircle(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.3),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 100,
            spreadRadius: 20,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            midnightBlue,
            deepNavy,
            Color(0xFF006B8F),
            Color(0xFF08B9C5),
            deepNavy,
          ],
          stops: [0.0, 0.28, 0.55, 0.72, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 100,
            right: -100,
            child: _glowCircle(300, const Color(0xFF00D9E8)),
          ),
          Positioned(
            bottom: 50,
            left: -120,
            child: _glowCircle(280, const Color(0xFF00AFC1)),
          ),
          child,
        ],
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;

  const GlassCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: 440,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          decoration: BoxDecoration(
            color: white.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: white.withValues(alpha: 0.65),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 30,
                spreadRadius: 2,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

