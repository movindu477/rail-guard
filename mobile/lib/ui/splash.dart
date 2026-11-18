// Splash screen shown on cold start while Firebase, Auth, and the saved driver
// profile load. Styled over the Class S14A coastal-line photo so a slow
// connection shows a proper welcome screen rather than a blank frame.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../account.dart';
import '../driver.dart';
import '../firebase_options.dart';
import 'theme.dart';

/// Minimum time the splash stays visible so fast startups never flicker.
const splashMinDuration = Duration(milliseconds: 1200);

/// Scrim base colour (#0E1013) shared with the native launch background and the
/// hero headers.
const splashDark = Color(0xFF0E1013);

enum SplashRoute { login, register, map }

class SplashScreen extends StatefulWidget {
  final void Function(SplashRoute route, DriverProfile? profile) onReady;

  const SplashScreen({super.key, required this.onReady});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final results = await Future.wait<Object?>([
      _resolveDestination(),
      Future<void>.delayed(splashMinDuration),
    ]);
    if (!mounted) return;
    final (route, profile) = results.first as (SplashRoute, DriverProfile?);
    widget.onReady(route, profile);
  }

  Future<(SplashRoute, DriverProfile?)> _resolveDestination() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
    } catch (e) {
      debugPrint('Firebase init error: $e');
    }

    final user = currentUser;
    if (user == null) {
      // No signed-in user -> Login screen
      return (SplashRoute.login, null);
    }

    // Signed in with a cached profile -> map immediately (offline capable)
    final cached = await loadDriver();
    if (cached != null) {
      // Best-effort background refresh from Firestore if network is present
      fetchDriverFromFirestore(user.uid).then((remote) {
        if (remote != null) saveDriver(remote);
      }).catchError((_) {});
      return (SplashRoute.map, cached);
    }

    // Signed in with no cached profile -> fetch drivers/{uid}
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

    // If profile is missing, send them to Register to complete their details
    return (SplashRoute.register, null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: splashDark,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Full-bleed train1.jpg, BoxFit.cover, locomotive nose in lower third
          Image.asset(
            'assets/images/train1.jpg',
            fit: BoxFit.cover,
            alignment: const Alignment(0, 0.35),
          ),
          // Dark vertical gradient scrim: transparent at top to #0E1013 at 92% bottom
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  splashDark.withValues(alpha: 0.0),
                  splashDark.withValues(alpha: 0.55),
                  splashDark.withValues(alpha: 0.92),
                ],
                stops: const [0.0, 0.48, 1.0],
              ),
            ),
          ),
          // Centred logo_mark.png, RailGuard, and subtitle
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/logo_mark.png',
                        width: 88,
                        height: 88,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'RailGuard',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Obstacle warning for Sri Lankan railways',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withValues(alpha: 0.70),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 2 px indeterminate progress bar at the bottom in brand red #E82529
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: RG.brand,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
