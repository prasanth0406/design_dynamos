import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'attendance_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://otfazpvwsxintyzcytvx.supabase.co',
    publishableKey: 'sb_publishable_dy9LkmDGDwFVHTzGdiqnbA_CwKgVJKZ',
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
      home: const RoleSelectionScreen(),
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

  final LocalAuthentication _localAuth = LocalAuthentication();

  /// Uses the phone's available biometric and permits its screen-lock fallback.
  /// Supabase still verifies the account after local device authentication.
  Future<bool> authenticateWithDeviceSecurity() async {
    try {
      final bool isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!isDeviceSupported) {
        showMessage('Set up face unlock, a fingerprint, or a phone screen lock first.');
        return false;
      }

      final bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify with face, fingerprint, or your phone screen lock.',
        // False allows Android to offer the device PIN, pattern, or password.
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );

      if (!authenticated) {
        showMessage('Device verification was cancelled or failed.');
      }
      return authenticated;
    } on LocalAuthException catch (error) {
      debugPrint('Local authentication error: ${error.code}');
      showMessage('Device verification failed. Try face, fingerprint, or phone lock again.');
      return false;
    } catch (error) {
      debugPrint('Unexpected local authentication error: $error');
      showMessage('Unable to start device verification on this phone.');
      return false;
    }
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
        showMessage('Account created successfully. You can now continue.');
        _openDashboard(widget.role);
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
      // Verify locally before asking Supabase to authenticate the account.
      final deviceVerified = await authenticateWithDeviceSecurity();
      if (!deviceVerified) return;

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
      _openDashboard(widget.role);
    } on AuthException catch (error) {
      showMessage(error.message);
    } catch (_) {
      showMessage('Login failed. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _openDashboard(UserRole role) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => DashboardScreen(role: role),
      ),
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
                              'Verify with face or fingerprint. You can use your phone PIN, pattern, or password from the system prompt.',
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

class DashboardScreen extends StatelessWidget {
  final UserRole role;

  const DashboardScreen({super.key, required this.role});

  Future<void> _signOut(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    if (!context.mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
          (route) => false,
    );
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
            tooltip: 'Sign out',
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

