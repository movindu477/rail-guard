// Sound and vibration for the alert tiers.
//   caution(): one beep, short vibration
//   startStop(): repeating alarm and long repeating vibration until stopStop()
// Played on the phone's alarm channel, so it is heard even with media volume
// turned down. Failures (no vibrator, audio busy) are logged, never thrown:
// the on-screen alert still shows.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';

class Alarm {
  final _beep = AudioPlayer();
  final _alarm = AudioPlayer();
  bool _ringing = false;

  bool get ringing => _ringing;

  static final _alarmChannel = AudioContext(
    android: const AudioContextAndroid(
      usageType: AndroidUsageType.alarm,
      contentType: AndroidContentType.sonification,
      audioFocus: AndroidAudioFocus.gainTransient,
    ),
  );

  Future<void> init() async {
    try {
      await _beep.setAudioContext(_alarmChannel);
      await _alarm.setAudioContext(_alarmChannel);
      await _alarm.setReleaseMode(ReleaseMode.loop);
    } catch (e) {
      debugPrint('alarm init: $e');
    }
  }

  Future<void> caution() async {
    try {
      await _beep.stop();
      await _beep.play(AssetSource('sounds/beep.wav'));
    } catch (e) {
      debugPrint('beep: $e');
    }
    await _vibrate(() => Vibration.vibrate(duration: 300));
  }

  Future<void> startStop() async {
    if (_ringing) return;
    _ringing = true;
    try {
      await _alarm.play(AssetSource('sounds/alarm.wav')); // loops (ReleaseMode.loop)
    } catch (e) {
      debugPrint('alarm: $e');
    }
    // Long pulses, repeating from index 0 until cancelled.
    await _vibrate(() => Vibration.vibrate(pattern: [0, 900, 400], repeat: 0));
  }

  Future<void> stopStop() async {
    if (!_ringing) return;
    _ringing = false;
    try {
      await _alarm.stop();
    } catch (e) {
      debugPrint('alarm stop: $e');
    }
    await _vibrate(Vibration.cancel);
  }

  Future<void> _vibrate(Future<void> Function() f) async {
    try {
      if (await Vibration.hasVibrator()) await f();
    } catch (e) {
      debugPrint('vibration: $e');
    }
  }

  void dispose() {
    _beep.dispose();
    _alarm.dispose();
    Vibration.cancel();
  }
}
