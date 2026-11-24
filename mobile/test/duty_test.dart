/// Duty state decides whether a train keeps reporting its position once the
/// driver leaves the app. Getting this wrong is not a cosmetic fault: a train
/// that stops reporting while still moving disappears from other drivers'
/// maps, and they have no reason to doubt what they see.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:railguard_app/duty.dart';

void main() {
  group('duty state', () {
    test('on duty reads as on, off duty as off', () {
      expect(DutyState.onDuty.isOn, isTrue);
      expect(DutyState.offDuty.isOn, isFalse);
    });

    test('labels are plain words a driver can read at a glance', () {
      expect(DutyState.onDuty.label, 'On duty');
      expect(DutyState.offDuty.label, 'Off duty');
    });
  });

  group('location settings follow duty', () {
    test('off duty asks for no background behaviour at all', () {
      final s = dutyLocationSettings(
        duty: DutyState.offDuty,
        trainLabel: '1005 UP',
      );
      // Plain settings: the stream runs only while the app is open.
      expect(s, isNot(isA<AndroidSettings>()));
      expect(s, isNot(isA<AppleSettings>()));
    });

    test('off duty still tracks while the app is open', () {
      final s = dutyLocationSettings(
        duty: DutyState.offDuty,
        trainLabel: '1005 UP',
      );
      expect(s.accuracy, LocationAccuracy.high);
      expect(s.distanceFilter, 5);
    });

    test('on duty on Android carries a foreground notification', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final s = dutyLocationSettings(
        duty: DutyState.onDuty,
        trainLabel: '1005 UP',
      );
      expect(s, isA<AndroidSettings>());
      final cfg = (s as AndroidSettings).foregroundNotificationConfig;
      expect(cfg, isNotNull,
          reason: 'without it Android kills the stream when the app leaves the front');
      expect(cfg!.enableWakeLock, isTrue,
          reason: 'the screen sleeps for most of a long run');
      debugDefaultTargetPlatformOverride = null;
    });

    test('the notification names the train, so the driver knows what is sharing', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final s = dutyLocationSettings(
        duty: DutyState.onDuty,
        trainLabel: '1005 UP',
      ) as AndroidSettings;
      expect(s.foregroundNotificationConfig!.notificationText, contains('1005 UP'));
      debugDefaultTargetPlatformOverride = null;
    });

    test('an empty train label still produces readable notification text', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final s = dutyLocationSettings(duty: DutyState.onDuty, trainLabel: '')
          as AndroidSettings;
      final text = s.foregroundNotificationConfig!.notificationText;
      expect(text, isNotEmpty);
      expect(text, isNot(startsWith(' ·')));
      debugDefaultTargetPlatformOverride = null;
    });

    test('on duty on iOS shows the background indicator', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final s = dutyLocationSettings(
        duty: DutyState.onDuty,
        trainLabel: '1005 UP',
      );
      expect(s, isA<AppleSettings>());
      final apple = s as AppleSettings;
      expect(apple.allowBackgroundLocationUpdates, isTrue);
      expect(apple.showBackgroundLocationIndicator, isTrue,
          reason: 'the driver must be able to see that location is live');
      expect(apple.pauseLocationUpdatesAutomatically, isFalse,
          reason: 'iOS pausing updates would silently drop the train from the map');
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
