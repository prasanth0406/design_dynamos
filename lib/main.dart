import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(

    url: 'https://otfazpvwsxintyzcytvx.supabase.co',
    publishableKey: 'sb_publishable_dy9LkmDGDwFVHTzGdiqnbA_CwKgVJKZ',
  );

  runApp(const MyApp());
}

// Colors
const Color midnightBlue = Color(0xFF081328);
const Color deepNavy = Color(0xFF102C51);
const Color aquamarine = Color(0xFF5BC0BE);
const Color white = Colors.white;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Oceanic Login',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController emailController =
  TextEditingController();

  final TextEditingController passwordController =
  TextEditingController();

  bool hidePassword = true;
  bool isLoading = false;

  // Dispose controllers
  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  // LOGIN
  Future<void> signIn() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter your email and password');
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (!mounted) return;

      showMessage('Login successful!');
    } on AuthException catch (error) {
      if (!mounted) return;
      showMessage(error.message);
    } catch (error) {
      if (!mounted) return;
      showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // SIGN UP
  Future<void> signUp() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter your email and password');
      return;
    }

    if (password.length < 6) {
      showMessage('Password must contain at least 6 characters');
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final response =
      await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
      );

      if (!mounted) return;

      if (response.session != null) {
        showMessage('Account created successfully!');
      } else {
        showMessage(
          'Account created! Check your email for confirmation.',
        );
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      showMessage(error.message);
    } catch (error) {
      if (!mounted) return;
      showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // SHOW MESSAGE
  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // GLOW CIRCLE
  Widget glowCircle(double size, Color color) {
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

  // GLASS TEXT FIELD
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
      style: const TextStyle(
        color: white,
        fontSize: 15,
      ),
      cursorColor: aquamarine,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          color: white.withValues(alpha: 0.7),
        ),
        prefixIcon: Icon(
          icon,
          color: aquamarine,
        ),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: white.withValues(alpha: 0.08),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: white.withValues(alpha: 0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: aquamarine,
            width: 1.5,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
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
            // Background glow effects
            Positioned(
              top: 100,
              right: -100,
              child: glowCircle(
                300,
                const Color(0xFF00D9E8),
              ),
            ),
            Positioned(
              bottom: 50,
              left: -120,
              child: glowCircle(
                280,
                const Color(0xFF00AFC1),
              ),
            ),

            // Login card
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: 18,
                        sigmaY: 18,
                      ),
                      child: Container(
                        width: 420,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 38,
                        ),
                        decoration: BoxDecoration(
                          color: white.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: white.withValues(alpha: 0.65),
                            width: 1.4,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: 0.12,
                              ),
                              blurRadius: 30,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Heading
                            const Text(
                              'Welcome Back',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: white,
                                fontSize: 30,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 10),

                            Text(
                              'Login to your account',
                              style: TextStyle(
                                color: white.withValues(alpha: 0.8),
                                fontSize: 16,
                              ),
                            ),

                            const SizedBox(height: 38),

                            // Email field
                            glassTextField(
                              controller: emailController,
                              hint: 'Email',
                              icon: Icons.mail_outline,
                              keyboardType: TextInputType.emailAddress,
                            ),

                            const SizedBox(height: 18),

                            // Password field
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
                                  setState(() {
                                    hidePassword = !hidePassword;
                                  });
                                },
                              ),
                            ),

                            const SizedBox(height: 30),

                            // Sign In button
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF13C8D2),
                                      Color(0xFF377FAF),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(
                                    color: white.withValues(alpha: 0.9),
                                    width: 1.2,
                                  ),
                                ),
                                child: ElevatedButton(
                                  onPressed: isLoading ? null : signIn,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    disabledBackgroundColor:
                                    Colors.transparent,
                                    shadowColor: Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                      BorderRadius.circular(30),
                                    ),
                                  ),
                                  child: isLoading
                                      ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      color: white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                      : const Text(
                                    'SIGN IN',
                                    style: TextStyle(
                                      color: white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 18),

                            // Sign Up option
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  "Don't have an account?",
                                  style: TextStyle(
                                    color: white.withValues(alpha: 0.85),
                                  ),
                                ),
                                TextButton(
                                  onPressed: isLoading ? null : signUp,
                                  child: const Text(
                                    'Sign Up',
                                    style: TextStyle(
                                      color: aquamarine,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}