/// On duty / off duty, and the location settings that follow from it.
///
/// Why this exists
/// ---------------
/// A driver cannot sit in the app for a whole run. They answer a call, check a
/// timetable, put the phone in a pocket. Before this, leaving the app stopped
/// the position stream, so the train vanished from every other driver's map
/// while still moving. A train that disappears is worse than one that was
/// never shown: the other drivers have no reason to doubt what they see.
///
/// So position reporting is tied to DUTY, not to whether the app is in front.
/// On duty, Android keeps a foreground service alive with a notification the
/// driver can always see. Off duty, nothing is reported at all.
///
/// Duty is an explicit choice, never inferred. The app does not decide that a
/// shift has ended because the phone stopped moving, and it does not keep
/// broadcasting because it forgot to stop: a driver who goes off duty stops
/// being tracked, which is both the safe reading and the honest one.
library;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _dutyKey = 'railguard.duty.v1';

/// Metres the train must move before the next position update.
const _distanceFilterM = 5;

enum DutyState { onDuty, offDuty }

extension DutyText on DutyState {
  bool get isOn => this == DutyState.onDuty;
  String get label => this == DutyState.onDuty ? 'On duty' : 'Off duty';
}

/// Last saved duty state. Defaults to on duty: a driver who signed in and
/// opened the cab map is working, and the Android permission prompt is the
/// real consent step.
Future<DutyState> loadDuty() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_dutyKey) == false ? DutyState.offDuty : DutyState.onDuty;
}

Future<void> saveDuty(DutyState state) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_dutyKey, state.isOn);
}

/// Location settings for the current duty state.
///
/// On duty on Android this carries a [ForegroundNotificationConfig], which is
/// what keeps the stream alive once the app is no longer in front. Android
/// requires the notification; that requirement happens to be right, because a
/// driver should always be able to see that their position is being sent.
///
/// Off duty the settings are plain, so the stream only runs while the app is
/// open — the map still works, nothing is broadcast in the background.
LocationSettings dutyLocationSettings({
  required DutyState duty,
  required String trainLabel,
}) {
  if (!duty.isOn) {
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _distanceFilterM,
    );
  }

  if (defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _distanceFilterM,
      // Without the wake lock Android suspends the stream when the screen
      // sleeps, which on a long run is most of the journey.
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: 'RailGuard — on duty',
        notificationText: trainLabel.isEmpty
            ? 'Sharing your position with other drivers'
            : '$trainLabel · sharing your position with other drivers',
        notificationChannelName: 'Train position',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
  }

  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _distanceFilterM,
      allowBackgroundLocationUpdates: true,
      // The blue bar: the driver can see at a glance that location is live.
      showBackgroundLocationIndicator: true,
      pauseLocationUpdatesAutomatically: false,
    );
  }

  return const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: _distanceFilterM,
  );
}

/// Asks for background location, which Android treats as a separate decision
/// from foreground location and will only grant from a second prompt.
///
/// Returns false if the driver refuses. That is not an error: the app keeps
/// working while open, and the caller tells the driver what they lose, rather
/// than nagging or pretending the position is still being shared.
Future<bool> ensureBackgroundLocation() async {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.whileInUse) {
    // Android shows "Allow all the time" only on a second ask.
    permission = await Geolocator.requestPermission();
  }
  return permission == LocationPermission.always;
}
