import 'package:flutter/material.dart';

const Color midnightBlue = Color(0xFF10284B);
const Color deepNavy = Color(0xFF173D72);
const Color brandBlue = Color(0xFF24559A);
const Color brandOrange = Color(0xFFC2530B);
const Color ink = Color(0xFF203A5C);
const Color mutedInk = Color(0xFF5F7085);
const Color cardSurface = Colors.white;
const Color white = Colors.white;
const Color pageField = Color(0xFFF4F6FA);
const Color outlineColor = Color(0xFFDCE3ED);

abstract final class AppRadii {
  static const double card = 24;
  static const double tile = 20;
  static const double control = 15;
  static const double button = 16;
  static const double pill = 30;
}

abstract final class AppSpacing {
  static const double small = 8;
  static const double medium = 16;
  static const double large = 24;
  static const double page = 20;
}

abstract final class AttendanceAppTheme {
  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: brandBlue,
          brightness: Brightness.light,
        ).copyWith(
          primary: deepNavy,
          secondary: brandOrange,
          surface: cardSurface,
          onSurface: ink,
        );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Roboto',
      colorScheme: scheme,
      scaffoldBackgroundColor: midnightBlue,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: ink,
          fontSize: 26,
          height: 1.2,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: ink,
          fontSize: 21,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: TextStyle(
          color: ink,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: ink, fontSize: 16, height: 1.4),
        bodyMedium: TextStyle(color: ink, fontSize: 14, height: 1.4),
        bodySmall: TextStyle(color: mutedInk, fontSize: 12, height: 1.35),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: deepNavy,
        foregroundColor: white,
        elevation: 0,
        centerTitle: false,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brandOrange,
          foregroundColor: white,
          disabledBackgroundColor: const Color(0xFFCFD5DF),
          disabledForegroundColor: const Color(0xFF6F7886),
          minimumSize: const Size(48, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: deepNavy,
          side: const BorderSide(color: deepNavy),
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: deepNavy,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: pageField,
        hintStyle: const TextStyle(color: mutedInk),
        prefixIconColor: deepNavy,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 17,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: const BorderSide(color: outlineColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: const BorderSide(color: outlineColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: const BorderSide(color: brandOrange, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: cardSurface,
        elevation: 2,
        shadowColor: const Color(0x22102040),
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
          side: const BorderSide(color: Color(0xFFE8EDF4)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: deepNavy,
        contentTextStyle: const TextStyle(color: white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
      ),
    );
  }
}

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [midnightBlue, deepNavy, Color(0xFF24599B)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const CustomPaint(painter: _AttendanceWavePainter()),
          child,
        ],
      ),
    );
  }
}

class _AttendanceWavePainter extends CustomPainter {
  const _AttendanceWavePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final upper = Path()
      ..moveTo(size.width * 0.55, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.34)
      ..cubicTo(
        size.width * 0.78,
        size.height * 0.27,
        size.width * 0.72,
        size.height * 0.12,
        size.width * 0.55,
        0,
      )
      ..close();
    canvas.drawPath(
      upper,
      Paint()..color = const Color(0xFF2E67AE).withValues(alpha: 0.38),
    );

    final lower = Path()
      ..moveTo(0, size.height * 0.78)
      ..cubicTo(
        size.width * 0.28,
        size.height * 0.68,
        size.width * 0.58,
        size.height * 0.86,
        size.width,
        size.height * 0.72,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      lower,
      Paint()..color = const Color(0xFF3672BD).withValues(alpha: 0.28),
    );
  }

  @override
  bool shouldRepaint(covariant _AttendanceWavePainter oldDelegate) => false;
}

class AppSurfaceCard extends StatelessWidget {
  const AppSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.large),
    this.maxWidth = 440,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
        padding: padding,
        decoration: BoxDecoration(
          color: cardSurface,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: const Border.fromBorderSide(
            BorderSide(color: Color(0xFFE8EDF4)),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33102040),
              blurRadius: 26,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}
