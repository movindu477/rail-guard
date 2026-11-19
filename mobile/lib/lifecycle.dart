/// Hazard lifecycle: pass detection ("Still there?"), driver confirmation,
/// "Did not see" logging, and two-driver clearing rules for camera reports.
///
/// Pure Dart: no Flutter or Firebase SDK dependencies, so every rule is unit
/// tested directly in test/lifecycle_test.dart.
library;

import 'warning.dart';

/// How close a train must pass to a hazard before a pass prompt is armed.
const double passProximityM = 100.0;

/// How far past the hazard along the track the train must move before prompting.
const double passPastMarginM = 15.0;

/// Camera-reported hazards (`reported_by == 'auto'`) require two independent
/// drivers to answer Cleared before leaving the map.
const int autoClearRequiredDrivers = 2;

/// Driver answers to the "Still there?" prompt after passing a hazard.
enum HazardPassAnswer {
  cleared, // "Cleared" — line is clear
  stillThere, // "Still there" — confirm present & refresh timestamp
  didNotSee, // "Did not see" — record pass without clearing
}

/// Human-readable confirmation count, e.g. "confirmed by 3 drivers".
String confirmedCountLabel(int count) =>
    'confirmed by $count ${count == 1 ? 'driver' : 'drivers'}';

/// Human-readable not-seen count, e.g. "not seen by 1 driver".
String notSeenCountLabel(int count) =>
    'not seen by $count ${count == 1 ? 'driver' : 'drivers'}';

/// True if [hazard] has exceeded the time expiry backstop ([hazardMaxAge]).
/// Unknown report time is kept active (fail-safe).
bool isHazardExpired(Hazard hazard, DateTime now) =>
    hazard.time != null && now.difference(hazard.time!) > hazardMaxAge;

/// True if [hazard] should currently be shown on drivers' maps:
/// status is 'active' AND it has not expired.
bool isHazardActiveOnMap(Hazard hazard, DateTime now) =>
    hazard.isActive && !isHazardExpired(hazard, now);

/// Outcome of applying a driver's lifecycle answer to a hazard.
class HazardLifecycleResult {
  /// Updated hazard snapshot.
  final Hazard hazard;

  /// Fields to send to Firestore via `.update(...)`. Never deletes a document.
  final Map<String, dynamic> firestoreUpdate;

  /// True when this answer transitioned the hazard to `status == 'cleared'`.
  final bool becameCleared;

  /// Short cab-readable feedback for the driver.
  final String feedbackMessage;

  const HazardLifecycleResult({
    required this.hazard,
    required this.firestoreUpdate,
    required this.becameCleared,
    required this.feedbackMessage,
  });
}

/// Applies [answer] from driver ([driverUid], [unitId]) to [hazard] at [now].
///
/// Rules enforced:
/// - Never deletes a hazard; clearing sets `status: 'cleared'` with
///   `cleared_by`, `cleared_at` and `cleared_by_uid`.
/// - Driver-reported hazards (`reported_by != 'auto'`) clear on 1 Cleared answer.
/// - Camera-reported hazards (`reported_by == 'auto'`) require 2 independent
///   drivers (`clearedByUids` deduplicated by driver uid) before clearing.
///   The same driver clearing twice never satisfies the two-driver rule.
/// - "Still there" appends a confirmation (deduplicated by uid) and refreshes
///   `timestamp` to [now] so the hazard does not expire while still present.
/// - "Did not see" records the pass without clearing or refreshing expiry.
///
/// [firestoreTimestamp] optionally overrides the timestamp value placed in
/// [HazardLifecycleResult.firestoreUpdate] (e.g. Firestore `Timestamp.now()`
/// or `FieldValue.serverTimestamp()`), keeping this library free of Firebase.
HazardLifecycleResult applyHazardAnswer({
  required Hazard hazard,
  required HazardPassAnswer answer,
  required String driverUid,
  required String unitId,
  required DateTime now,
  Object? firestoreTimestamp,
}) {
  final actorUid = driverUid.trim().isNotEmpty ? driverUid.trim() : unitId.trim();
  final tsValue = firestoreTimestamp ?? now;

  switch (answer) {
    case HazardPassAnswer.cleared:
      final alreadyVoted = hazard.clearedByUids.contains(actorUid);
      final nextClearedUids = alreadyVoted
          ? List<String>.unmodifiable(hazard.clearedByUids)
          : List<String>.unmodifiable([...hazard.clearedByUids, actorUid]);

      final requiredClears = hazard.isAutoReport ? autoClearRequiredDrivers : 1;
      final canClear = nextClearedUids.length >= requiredClears;

      if (canClear) {
        final updated = hazard.copyWith(
          status: 'cleared',
          clearedBy: unitId,
          clearedByUid: actorUid,
          clearedAt: now,
          clearedByUids: nextClearedUids,
        );
        return HazardLifecycleResult(
          hazard: updated,
          firestoreUpdate: {
            'status': 'cleared',
            'cleared_by': unitId,
            'cleared_by_uid': actorUid,
            'cleared_at': tsValue,
            'cleared_by_uids': nextClearedUids,
            'cleared_votes_count': nextClearedUids.length,
          },
          becameCleared: true,
          feedbackMessage: 'Hazard cleared for all trains',
        );
      } else {
        // Camera-reported hazard with only 1 unique driver clear so far: stays active.
        final updated = hazard.copyWith(clearedByUids: nextClearedUids);
        return HazardLifecycleResult(
          hazard: updated,
          firestoreUpdate: {
            'cleared_by_uids': nextClearedUids,
            'cleared_votes_count': nextClearedUids.length,
          },
          becameCleared: false,
          feedbackMessage: alreadyVoted
              ? 'Already recorded your clear — a second driver must confirm to clear camera report'
              : '1 of $autoClearRequiredDrivers clears recorded — needs a second driver to clear camera report',
        );
      }

    case HazardPassAnswer.stillThere:
      final alreadyConfirmed = hazard.confirmedByUids.contains(actorUid);
      final nextConfirmedUids = alreadyConfirmed
          ? List<String>.unmodifiable(hazard.confirmedByUids)
          : List<String>.unmodifiable([...hazard.confirmedByUids, actorUid]);

      final updated = hazard.copyWith(
        time: now,
        confirmedByUids: nextConfirmedUids,
      );
      return HazardLifecycleResult(
        hazard: updated,
        firestoreUpdate: {
          'confirmed_by_uids': nextConfirmedUids,
          'confirmed_count': nextConfirmedUids.length,
          'timestamp': tsValue,
          'last_confirmed_at': tsValue,
        },
        becameCleared: false,
        feedbackMessage: 'Confirmed still there — warning kept active',
      );

    case HazardPassAnswer.didNotSee:
      final alreadyNotSeen = hazard.notSeenByUids.contains(actorUid);
      final nextNotSeenUids = alreadyNotSeen
          ? List<String>.unmodifiable(hazard.notSeenByUids)
          : List<String>.unmodifiable([...hazard.notSeenByUids, actorUid]);

      final updated = hazard.copyWith(notSeenByUids: nextNotSeenUids);
      return HazardLifecycleResult(
        hazard: updated,
        firestoreUpdate: {
          'not_seen_by_uids': nextNotSeenUids,
          'not_seen_count': nextNotSeenUids.length,
        },
        becameCleared: false,
        feedbackMessage: 'Pass recorded — warning stays active',
      );
  }
}

class _ApproachRecord {
  final double? entrySignedDiff;
  final String? sharedRouteId;
  const _ApproachRecord({this.entrySignedDiff, this.sharedRouteId});
}

/// Tracks hazards a train approaches within [passProximityM] (100 m) and
/// reports each hazard once the train moves past it along the track.
class HazardPassTracker {
  final Map<String, _ApproachRecord> _approached = {};
  final Set<String> _prompted = {};

  /// Marks [hazardId] as already prompted/handled in this session so it will
  /// not prompt again.
  void markPrompted(String hazardId) {
    _prompted.add(hazardId);
    _approached.remove(hazardId);
  }

  /// Drops state for hazards no longer in the active feed.
  void keepOnly(Set<String> activeIds) {
    _approached.removeWhere((id, _) => !activeIds.contains(id));
    _prompted.removeWhere((id) => !activeIds.contains(id));
  }

  /// Returns hazards that the train passed within [passProximityM] of and has
  /// now moved past along the track. Each hazard is returned at most once.
  List<Hazard> checkPassed({
    required double lat,
    required double lon,
    required TravelDirection travelDirection,
    required Iterable<Hazard> hazards,
    required DateTime now,
    RailNetwork? network,
    double? gpsAccuracyM,
    String? ownUid,
    String? ownUnitId,
  }) {
    final activeList = hazards.toList();
    keepOnly({for (final h in activeList) h.id});

    final trainPos = network?.snap(lat, lon, gpsAccuracyM: gpsAccuracyM);
    final newlyPassed = <Hazard>[];

    for (final h in activeList) {
      if (!isHazardActiveOnMap(h, now)) continue;
      if (_prompted.contains(h.id)) continue;

      // Do not re-prompt a driver who already answered this hazard.
      if (ownUid != null && ownUid.isNotEmpty) {
        if (h.confirmedByUids.contains(ownUid) ||
            h.notSeenByUids.contains(ownUid) ||
            h.clearedByUids.contains(ownUid)) {
          _prompted.add(h.id);
          continue;
        }
      }

      // Do not immediately prompt a driver who just manually reported this hazard.
      if (h.reportedBy == 'driver' &&
          ownUnitId != null &&
          h.unitId == ownUnitId &&
          h.time != null &&
          now.difference(h.time!) < const Duration(minutes: 2)) {
        continue;
      }

      if (network != null && trainPos != null) {
        final hazardPos = network.snap(h.latitude, h.longitude);
        if (hazardPos != null) {
          // Never prompt for hazards on a disjoint line.
          if (!trainPos.sharesLineWith(hazardPos)) continue;

          final sharedRoutes = trainPos.candidateRouteIds.intersection(hazardPos.candidateRouteIds);
          double? bestSignedDiff;
          double minAbs = double.infinity;
          String? chosenRoute;

          for (final rId in sharedRoutes) {
            final tCand = trainPos.candidateForRoute(rId);
            final hCand = hazardPos.candidateForRoute(rId);
            if (tCand != null && hCand != null) {
              final diff = hCand.chainageM - tCand.chainageM;
              if (diff.abs() < minAbs) {
                minAbs = diff.abs();
                bestSignedDiff = diff;
                chosenRoute = rId;
              }
            }
          }

          if (bestSignedDiff != null) {
            if (minAbs <= passProximityM) {
              _approached.putIfAbsent(
                h.id,
                () => _ApproachRecord(
                  entrySignedDiff: bestSignedDiff,
                  sharedRouteId: chosenRoute,
                ),
              );
            }

            final record = _approached[h.id];
            if (record != null) {
              final bool passed;
              if (travelDirection == TravelDirection.increasing) {
                // Moving towards higher chainage: hazard is behind when h - t <= -margin
                passed = bestSignedDiff <= -passPastMarginM;
              } else if (travelDirection == TravelDirection.decreasing) {
                // Moving towards lower chainage: hazard is behind when h - t >= +margin
                passed = bestSignedDiff >= passPastMarginM;
              } else {
                // Direction unknown: detect sign crossing across hazard chainage,
                // or moving beyond proximity + margin if started right on top of hazard.
                final entry = record.entrySignedDiff;
                if (entry != null && entry > 0 && bestSignedDiff <= -passPastMarginM) {
                  passed = true;
                } else if (entry != null && entry < 0 && bestSignedDiff >= passPastMarginM) {
                  passed = true;
                } else if (entry != null &&
                    entry.abs() <= passPastMarginM &&
                    minAbs >= passProximityM + passPastMarginM) {
                  passed = true;
                } else {
                  passed = false;
                }
              }

              if (passed) {
                _prompted.add(h.id);
                _approached.remove(h.id);
                newlyPassed.add(h);
              }
            }
            continue;
          }
        }
      }

      // Off-track fallback: straight-line proximity then departure.
      final straightD = distanceM(lat, lon, h.latitude, h.longitude);
      if (straightD <= passProximityM) {
        _approached.putIfAbsent(h.id, () => const _ApproachRecord());
      } else if (_approached.containsKey(h.id) && straightD >= passProximityM + passPastMarginM) {
        _prompted.add(h.id);
        _approached.remove(h.id);
        newlyPassed.add(h);
      }
    }

    return newlyPassed;
  }
}
