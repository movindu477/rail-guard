/// Offline visibility and Firestore write-quota discipline.
/// Pure Dart: no Flutter or Firebase SDK dependencies, so every rule is unit
/// tested directly in test/offline_test.dart.
library;

import 'warning.dart';

/// Minimum distance moved (metres) before triggering an early position upload.
const double uploadMinMoveM = 10.0;

/// Maximum time between position uploads when standing still (30 s -> 120/hr).
const Duration uploadHeartbeatInterval = Duration(seconds: 30);

/// Cadence for checking/uploading position while moving (5 s -> 720/hr).
const Duration uploadMovingCadence = Duration(seconds: 5);

/// Feeds older than 60 seconds without a server update are considered stale.
const Duration feedStaleThreshold = Duration(seconds: 60);

/// Pending reports still unsent after 5 minutes trigger an explicit warning.
const Duration pendingReportWarnAge = Duration(minutes: 5);

/// Controls when train_position writes are sent to Firestore so standing trains
/// do not burn through the Spark daily write quota.
///
/// Rule: upload only on the first fix, when moved > 10 m since the last upload,
/// or when 30 seconds have elapsed since the last upload.
class PositionUploadGate {
  double? _lastLat;
  double? _lastLon;
  DateTime? _lastUploadedAt;
  int _uploadCount = 0;

  int get uploadCount => _uploadCount;
  DateTime? get lastUploadedAt => _lastUploadedAt;

  /// True if a position upload should fire for ([lat], [lon]) at [now].
  bool shouldUpload({
    required double lat,
    required double lon,
    required DateTime now,
  }) {
    if (_lastUploadedAt == null || _lastLat == null || _lastLon == null) {
      return true;
    }
    if (now.difference(_lastUploadedAt!) >= uploadHeartbeatInterval) {
      return true;
    }
    final movedM = distanceM(_lastLat!, _lastLon!, lat, lon);
    if (movedM > uploadMinMoveM) {
      return true;
    }
    return false;
  }

  /// Records that a position upload was dispatched at ([lat], [lon]) at [now].
  void recordUpload({
    required double lat,
    required double lon,
    required DateTime now,
  }) {
    _lastLat = lat;
    _lastLon = lon;
    _lastUploadedAt = now;
    _uploadCount++;
  }

  /// Convenience: if [shouldUpload] is true, calls [recordUpload] and returns true.
  bool tryUpload({
    required double lat,
    required double lon,
    required DateTime now,
  }) {
    if (!shouldUpload(lat: lat, lon: lon, now: now)) return false;
    recordUpload(lat: lat, lon: lon, now: now);
    return true;
  }
}

/// Formats a stale age duration for the persistent offline banner:
/// e.g. "1 minute ago", "4 minutes ago", "10 minutes ago".
String staleAgeText(Duration age) {
  final secs = age.inSeconds < 0 ? 0 : age.inSeconds;
  if (secs < 60) {
    return '$secs ${secs == 1 ? 'second' : 'seconds'} ago';
  }
  final mins = secs ~/ 60;
  if (mins < 60) {
    return '$mins ${mins == 1 ? 'minute' : 'minutes'} ago';
  }
  final hrs = mins ~/ 60;
  final remMins = mins % 60;
  if (remMins == 0) {
    return '$hrs ${hrs == 1 ? 'hour' : 'hours'} ago';
  }
  return '$hrs ${hrs == 1 ? 'hour' : 'hours'} $remMins min ago';
}

/// Tracks when the hazard and train feeds last received a real server update
/// (never counting cache-only snapshots).
class FeedFreshnessTracker {
  final DateTime startedAt;
  DateTime? lastHazardServerUpdate;
  DateTime? lastTrainServerUpdate;

  FeedFreshnessTracker({required this.startedAt});

  void recordHazardServerUpdate(DateTime now) {
    if (lastHazardServerUpdate == null || now.isAfter(lastHazardServerUpdate!)) {
      lastHazardServerUpdate = now;
    }
  }

  void recordTrainServerUpdate(DateTime now) {
    if (lastTrainServerUpdate == null || now.isAfter(lastTrainServerUpdate!)) {
      lastTrainServerUpdate = now;
    }
  }

  /// Age since the hazard feed last received a server update (or since start).
  Duration hazardAge(DateTime now) {
    final ref = lastHazardServerUpdate ?? startedAt;
    final diff = now.difference(ref);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// Age since the train feed last received a server update (or since start).
  Duration trainAge(DateTime now) {
    final ref = lastTrainServerUpdate ?? startedAt;
    final diff = now.difference(ref);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// The stalest (largest) age across both the hazard feed and train feed.
  Duration oldestFeedAge(DateTime now) {
    final h = hazardAge(now);
    final t = trainAge(now);
    return h >= t ? h : t;
  }

  /// True when either the hazard feed or the train feed is stale by MORE than
  /// 60 seconds (59 s -> false, 60 s -> false, 61 s -> true).
  bool isStale(DateTime now) => oldestFeedAge(now) > feedStaleThreshold;

  /// Persistent offline banner text when stale, or null when fresh.
  /// Always names the age, e.g.:
  /// "No signal — hazards shown were last updated 4 minutes ago."
  String? staleBannerText(DateTime now) {
    if (!isStale(now)) return null;
    final age = oldestFeedAge(now);
    return 'No signal — hazards shown were last updated ${staleAgeText(age)}.';
  }
}

/// Visual state for the status card when there is no active hazard warning ahead.
class StatusCardDisplay {
  final String title;
  final String subtitle;
  final String tag;
  final bool isAmberWarning;

  const StatusCardDisplay({
    required this.title,
    required this.subtitle,
    this.tag = '',
    this.isAmberWarning = false,
  });
}

/// Computes the hazard status card copy when no cached hazard warning is ahead.
///
/// Safety rule: while the feed is stale, the status card MUST NEVER read
/// "No hazards ahead". It reads "Cannot check — no signal" in amber.
StatusCardDisplay resolveNoHazardStatus({
  required bool feedIsStale,
  Duration? staleAge,
  String? hazardProblem,
  required bool hasGps,
  String? gpsProblem,
  int nearbyCount = 0,
}) {
  if (feedIsStale) {
    return StatusCardDisplay(
      title: 'Cannot check — no signal',
      subtitle: staleAge != null
          ? 'Last updated ${staleAgeText(staleAge)} · cached data only'
          : 'Waiting for server connection',
      isAmberWarning: true,
    );
  }
  if (hazardProblem != null || !hasGps) {
    return StatusCardDisplay(
      title: 'Hazards not checked',
      subtitle: hazardProblem ?? gpsProblem ?? 'No GPS position',
      isAmberWarning: true,
    );
  }
  return StatusCardDisplay(
    title: 'No hazards ahead',
    subtitle: nearbyCount == 0
        ? 'Line clear within 3 km'
        : '$nearbyCount active report${nearbyCount == 1 ? '' : 's'} nearby',
    tag: 'CLEAR',
    isAmberWarning: false,
  );
}

/// Top-bar pending report count label, e.g. "1 report waiting to send".
String pendingReportsLabel(int count) =>
    '$count ${count == 1 ? 'report' : 'reports'} waiting to send';

/// Tracks locally queued hazard reports that have not yet been confirmed by
/// the Firestore server.
class PendingReportTracker {
  final Map<String, DateTime> _pending = {};

  /// Marks [hazardId] as queued locally at [queuedAt] (idempotent: preserves
  /// original queue timestamp if already tracked).
  void markPending(String hazardId, DateTime queuedAt) {
    _pending.putIfAbsent(hazardId, () => queuedAt);
  }

  /// Clears the pending state once the server confirms the write.
  void confirmSent(String hazardId) {
    _pending.remove(hazardId);
  }

  bool isPending(String hazardId) => _pending.containsKey(hazardId);

  int get count => _pending.length;

  bool get hasPending => _pending.isNotEmpty;

  /// Top-bar text when anything is pending, or null when nothing is pending.
  String? get topBarLabel => _pending.isEmpty ? null : pendingReportsLabel(_pending.length);

  /// Pending report IDs that have remained unsent for at least 5 minutes.
  List<String> overdueIds(DateTime now) => [
    for (final entry in _pending.entries)
      if (now.difference(entry.value) >= pendingReportWarnAge) entry.key,
  ];

  /// Plain warning text when one or more reports are still unsent after 5 minutes.
  String? overdueWarningText(DateTime now) {
    final overdue = overdueIds(now);
    if (overdue.isEmpty) return null;
    final n = overdue.length;
    return '$n ${n == 1 ? 'report has' : 'reports have'} not been sent after 5 minutes — '
        'trains behind have NOT been warned.';
  }
}
