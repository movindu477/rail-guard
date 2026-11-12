// STOP tier: takes over the whole screen until the driver acknowledges.
// Acknowledging silences the alarm and drops back to the status card; it does
// not clear the hazard (only "Mark as cleared" does).

import 'package:flutter/material.dart';

import '../warning.dart';
import 'theme.dart';

class StopAlert extends StatelessWidget {
  final HazardWarning warning;
  final VoidCallback onAcknowledge;
  final bool simulated; // demo build: say so on the alert too
  const StopAlert({
    super.key,
    required this.warning,
    required this.onAcknowledge,
    this.simulated = false,
  });

  @override
  Widget build(BuildContext context) {
    final h = warning.hazard;
    final t = typeInfo(h.objectType);
    final s = severityInfo(h);
    final time = h.time;
    const white = TextStyle(color: Colors.white);
    return Material(
      color: RG.danger,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            children: [
              if (simulated)
                Text(
                  'SIMULATED GPS  ·  demo',
                  style: white.copyWith(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              const Spacer(),
              // Hazard icon in a white circle, with a soft ring.
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.2),
                ),
                child: Container(
                  width: 104,
                  height: 104,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                  child: Icon(t.icon, size: 56, color: RG.danger),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                s.label.toUpperCase(),
                textAlign: TextAlign.center,
                style: white.copyWith(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 1),
              ),
              Text(t.label, style: white.copyWith(fontSize: 16)),
              const SizedBox(height: 24),
              Text(
                formatDistance(warning.distanceM),
                style: white.copyWith(fontSize: 60, fontWeight: FontWeight.w700, height: 1),
              ),
              const SizedBox(height: 6),
              Text(
                warning.headingKnown ? 'AHEAD' : 'DIRECTION UNKNOWN',
                style: white.copyWith(fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: 2),
              ),
              const SizedBox(height: 24),
              if (time != null)
                Text('Reported ${ago(time, DateTime.now())}', style: white.copyWith(fontSize: 15)),
              Text(
                reporterText(h),
                textAlign: TextAlign.center,
                style: white.copyWith(fontSize: 13, color: Colors.white.withValues(alpha: 0.85)),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 60,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: RG.danger,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: onAcknowledge,
                  child: const Text(
                    'ACKNOWLEDGE',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
