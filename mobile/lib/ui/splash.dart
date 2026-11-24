// Splash screen shown on cold start while Firebase, Auth, and the saved driver
// profile load. Styled after the full-bleed Class S14A coastal-line design with
// the RAILGUARD header lockup in the sky and a red-to-white Slide-to-Start button
// at the bottom.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../account.dart';
import '../driver.dart';
import '../firebase_options.dart';
import '../locale_store.dart';
import 'theme.dart';

/// Base colour (#0E1013) shared with dark UI elements.
const splashDark = Color(0xFF0E1013);

enum SplashRoute { login, register, map }

class SplashScreen extends StatefulWidget {
  final void Function(SplashRoute route, DriverProfile? profile) onReady;

  const SplashScreen({super.key, required this.onReady});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final Future<(SplashRoute, DriverProfile?)> _destinationFuture;
  late final AnimationController _snapController;
  double _dragProgress = 0.0;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _destinationFuture = _resolveDestination();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        setState(() {
          _dragProgress = _snapController.value;
        });
      });
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  Future<void> _completeSlide() async {
    if (_completed) return;
    _completed = true;
    await _snapController.animateTo(1.0, curve: Curves.easeOutCubic);
    final (route, profile) = await _destinationFuture;
    if (!mounted) return;
    widget.onReady(route, profile);
  }

  Future<(SplashRoute, DriverProfile?)> _resolveDestination() async {
    try {
      final savedLocale = await loadSavedLocale();
      if (savedLocale != null) {
        appLocaleNotifier.value = savedLocale;
      }
    } catch (_) {}

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
    } catch (e) {
      debugPrint('Firebase init error: $e');
    }

    final user = currentUser;
    if (user == null) {
      return (SplashRoute.login, null);
    }

    final cached = await loadDriver();
    if (cached != null) {
      fetchDriverFromFirestore(user.uid).then((remote) {
        if (remote != null) saveDriver(remote);
      }).catchError((_) {});
      return (SplashRoute.map, cached);
    }

    try {
      final remote = await fetchDriverFromFirestore(user.uid)
          .timeout(const Duration(seconds: 4));
      if (remote != null) {
        await saveDriver(remote);
        return (SplashRoute.map, remote);
      }
    } catch (e) {
      debugPrint('remote profile lookup error: $e');
    }

    return (SplashRoute.register, null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFB5DDF0),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Full-bleed train1.jpg without dark opacity overlay
          Image.asset(
            'assets/images/train1.jpg',
            fit: BoxFit.cover,
            alignment: const Alignment(-0.30, 0.35),
          ),

          // Upper-middle horizontal lockup: RAILGUARD text on left, rounded
          // white squircle logo icon on right
          Align(
            alignment: const Alignment(0, -0.24),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'RAILGUARD',
                    style: TextStyle(
                      fontFamily: defaultFontFamily,
                      fontSize: 31,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0A0C10),
                      letterSpacing: 1.6,
                      fontFamilyFallback: scriptFontFallbacks,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Image.asset(
                          'assets/images/logo_mark.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Slide-in "Start" button at the bottom: red initially, smoothly
          // transitions to white as the user slides to the right.
          Positioned(
            left: 32,
            right: 32,
            bottom: 32,
            child: SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: _buildSlideToStartButton(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlideToStartButton() {
    const double trackHeight = 60.0;
    const double thumbSize = 50.0;
    const double padding = 5.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxTrackWidth = constraints.maxWidth;
        final maxSlide = (maxTrackWidth - thumbSize - padding * 2).clamp(
          1.0,
          double.infinity,
        );
        final p = _dragProgress.clamp(0.0, 1.0);

        // Width of the red trail filling behind the thumb as it slides right.
        final redFillWidth =
            (padding * 2 + thumbSize + p * maxSlide).clamp(0.0, maxTrackWidth);

        // Text turns from red (on default white button) to white as the red
        // trail sweeps behind the thumb across the center.
        final textProgress = ((p - 0.20) / 0.45).clamp(0.0, 1.0);
        final textColor = Color.lerp(RG.brand, Colors.white, textProgress)!;

        // Thumb starts red on the white button and transitions to white as the
        // red trail fills behind it so it remains clearly visible.
        final thumbColor = Color.lerp(
          RG.brand,
          Colors.white,
          (p * 1.4).clamp(0.0, 1.0),
        )!;
        final iconColor = Color.lerp(
          Colors.white,
          RG.brand,
          (p * 1.4).clamp(0.0, 1.0),
        )!;

        return GestureDetector(
          onHorizontalDragUpdate: (details) {
            if (_completed) return;
            _snapController.stop();
            setState(() {
              _dragProgress =
                  (_dragProgress + details.delta.dx / maxSlide).clamp(0.0, 1.0);
            });
          },
          onHorizontalDragEnd: (_) {
            if (_completed) return;
            if (_dragProgress >= 0.72) {
              _snapController.value = _dragProgress;
              _completeSlide();
            } else {
              _snapController.value = _dragProgress;
              _snapController.animateTo(0.0, curve: Curves.easeOutCubic);
            }
          },
          child: Container(
            height: trackHeight,
            width: maxTrackWidth,
            decoration: BoxDecoration(
              // Default button background is white
              color: Colors.white,
              borderRadius: BorderRadius.circular(trackHeight / 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(trackHeight / 2),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Red background fill expanding behind the thumb as it slides right
                  if (p > 0.0)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: redFillWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: RG.brand,
                          borderRadius: BorderRadius.circular(trackHeight / 2),
                        ),
                      ),
                    ),

                  // Centered "Start" text
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 24),
                      Text(
                        'Start',
                        style: TextStyle(
                          fontFamily: defaultFontFamily,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                          letterSpacing: 0.6,
                          fontFamilyFallback: scriptFontFallbacks,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: textColor.withValues(alpha: 0.80),
                        size: 22,
                      ),
                    ],
                  ),

                  // Draggable thumb knob
                  Positioned(
                    left: padding + p * maxSlide,
                    child: Container(
                      width: thumbSize,
                      height: thumbSize,
                      decoration: BoxDecoration(
                        color: thumbColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        color: iconColor,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
