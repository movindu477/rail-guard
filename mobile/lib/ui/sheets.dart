// Bottom sheets, white with rounded tops (after the design reference):
//   showReportSheet   - what is it (4 types), then how bad (2 severities): two taps
//   showHazardList    - active hazards as a timeline, most urgent first
//   showHazardDetail  - everything about one hazard, with "Mark as cleared"
//   showTrainList     - other trains on the line, nearest first
//   showTrainDetail   - driver, train number, service, speed, age and distance

import 'package:flutter/material.dart';

import '../driver.dart';
import '../trains.dart';
import '../warning.dart';
import 'theme.dart';

Future<T?> _sheet<T>(BuildContext context, Widget Function(BuildContext) body) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RG.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: body(ctx),
        ),
      ),
    );

/// "Cancel    Title" row at the top of each sheet.
class _Header extends StatelessWidget {
  final String left, title;
  final VoidCallback? onLeft; // default: close the sheet
  const _Header(this.left, this.title, {this.onLeft});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
    child: Column(
      children: [
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(color: RG.border, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onLeft ?? () => Navigator.pop(context),
                  child: Text(left, style: const TextStyle(fontSize: 15, color: RG.blue)),
                ),
              ),
              Text(title, style: TS.title),
            ],
          ),
        ),
        const Divider(height: 1, color: RG.border),
      ],
    ),
  );
}

Widget _choiceRow({
  required Widget lead,
  required String title,
  required String hint,
  required VoidCallback onTap,
}) => InkWell(
  onTap: onTap,
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    child: Row(
      children: [
        lead,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TS.bodyStrong),
              Text(hint, style: TS.small),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded, color: RG.textDim, size: 22),
      ],
    ),
  ),
);

/// How bad is it: two large buttons, one tap. Shared by both report paths.
Widget _severityStep(BuildContext ctx, HazardType t, {VoidCallback? onBack}) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    _Header(onBack == null ? 'Cancel' : 'Back', t.label, onLeft: onBack),
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: [
          iconCircle(t.icon, t.colour, size: 36),
          const SizedBox(width: 10),
          const Text('How bad is it?', style: TS.body),
        ],
      ),
    ),
    for (final s in severities)
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: SizedBox(
          width: double.infinity,
          height: 76,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: s.colour,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            onPressed: () => Navigator.pop(ctx, (t.id, s.id)),
            child: Row(
              children: [
                Icon(s.icon, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        s.label.toUpperCase(),
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      Text(s.hint, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    const SizedBox(height: 4),
  ],
);

/// Returns (object_type, severity), or null if cancelled. With [type] given
/// (a quick-report button), it opens straight at the severity step.
Future<(String, String)?> showReportSheet(
  BuildContext context, {
  required double accuracyM,
  HazardType? type,
}) {
  if (type != null) {
    return _sheet<(String, String)>(context, (ctx) => _severityStep(ctx, type));
  }
  HazardType? picked;
  return _sheet<(String, String)>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final t = picked;
        if (t != null) return _severityStep(ctx, t, onBack: () => setSheet(() => picked = null));
        // Step 1: what is it.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Header('Cancel', 'Report hazard'),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(
                'At your position  ·  ±${accuracyM.toStringAsFixed(0)} m',
                style: TS.small,
              ),
            ),
            for (final type in hazardTypes)
              _choiceRow(
                lead: iconCircle(type.icon, type.colour, size: 46),
                title: type.label,
                hint: type.hint,
                onTap: () => setSheet(() => picked = type),
              ),
            const SizedBox(height: 10),
          ],
        );
      },
    ),
  );
}

/// One row of the hazard list: the hazard, plus distance, direction and alert
/// level when the train's position is known.
class HazardRow {
  final Hazard hazard;
  final double? distanceM;
  final bool? ahead; // null: heading unknown
  final bool alongTrack;

  const HazardRow(
    this.hazard,
    this.distanceM,
    this.ahead, {
    this.alongTrack = false,
  });

  /// Alert level this hazard is at for this train (none if behind or no GPS).
  AlertLevel get level => distanceM == null || ahead == false
      ? AlertLevel.none
      : alertLevel(distanceM!, blocked: hazard.blocked);

  /// "5 m" or "?" without GPS.
  String get distance => distanceM == null ? '?' : formatDistance(distanceM!);

  String get direction => distanceM == null
      ? 'Distance unknown (no GPS)'
      : ahead == null
      ? (alongTrack ? 'Along the line (direction unknown)' : 'Direction unknown (not moving)')
      : (ahead! ? (alongTrack ? 'Ahead along the line' : 'Ahead') : 'Behind');

  /// One line: "1.8 km along the line", "1.8 km ahead", "5 m, direction unknown".
  String get where => distanceM == null
      ? direction
      : alongTrack
      ? '$distance along the line${ahead == null ? '' : (ahead! ? '' : ' (behind)')}'
      : (ahead == null ? '$distance, direction unknown' : '$distance ${ahead! ? 'ahead' : 'behind'}');
}

/// Timeline of active hazards. Returns the one tapped, or null.
Future<Hazard?> showHazardList(BuildContext context, {required List<HazardRow> rows}) {
  final now = DateTime.now();
  return _sheet<Hazard>(
    context,
    (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Header('Close', 'Active hazards'),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 36),
            child: Text('No reports in the last 30 minutes.', style: TS.body),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final r = rows[i];
                final t = typeInfo(r.hazard.objectType);
                final s = severityInfo(r.hazard);
                final time = r.hazard.time;
                final colour = levelColour(r.level);
                return InkWell(
                  onTap: () => Navigator.pop(ctx, r.hazard),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Timeline: icon, with a line down to the next one.
                        Column(
                          children: [
                            iconCircle(
                              t.icon,
                              r.level == AlertLevel.none ? t.colour : colour,
                              size: 40,
                              filled: r.level != AlertLevel.none,
                            ),
                            if (i < rows.length - 1)
                              Expanded(child: Container(width: 2, color: RG.border)),
                          ],
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 1, bottom: 18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${t.label}  ·  ${r.distance}', style: TS.bodyStrong),
                                Text(
                                  '${s.label}  ·  ${r.direction}',
                                  style: TS.small.copyWith(
                                    color: r.level == AlertLevel.none ? RG.textDim : colour,
                                  ),
                                ),
                                Text(
                                  time == null
                                      ? 'Reported: time unknown'
                                      : 'Reported ${hhmm(time)}  ·  ${ago(time, now)}'
                                            '${r.hazard.reportedBy == 'auto' ? '  ·  camera' : ''}',
                                  style: TS.small,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
}

Widget _fact(IconData icon, String text, {Color colour = RG.text}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Row(
    children: [
      Icon(icon, size: 18, color: RG.blue),
      const SizedBox(width: 12),
      Expanded(
        child: Text(text, style: TS.body.copyWith(color: colour)),
      ),
    ],
  ),
);

/// Everything the driver needs about one hazard. Returns true if the driver
/// chose "Mark as cleared".
Future<bool> showHazardDetail(BuildContext context, {required HazardRow row}) async {
  final h = row.hazard;
  final t = typeInfo(h.objectType);
  final s = severityInfo(h);
  final time = h.time;
  final colour = row.level == AlertLevel.none ? t.colour : levelColour(row.level);
  final cleared = await _sheet<bool>(
    context,
    (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Header('Close', 'Hazard'),
          const SizedBox(height: 16),
          iconCircle(t.icon, colour, size: 68, filled: true),
          const SizedBox(height: 10),
          Text(t.label, style: TS.title.copyWith(fontSize: 18)),
          const SizedBox(height: 6),
          // Severity chip.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: s.colour.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(s.icon, size: 15, color: s.colour),
                const SizedBox(width: 6),
                Text('${s.label}  ·  ${s.hint}', style: TS.small.copyWith(color: s.colour)),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: RG.surfaceHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _fact(
                  Icons.near_me_rounded,
                  row.where,
                  colour: row.level == AlertLevel.none ? RG.text : colour,
                ),
                _fact(
                  Icons.schedule_rounded,
                  time == null
                      ? 'Time unknown'
                      : 'Reported ${ago(time, DateTime.now())}  (${hhmm(time)})',
                ),
                _fact(
                  h.reportedBy == 'auto' ? Icons.videocam_rounded : Icons.person_rounded,
                  reporterText(h),
                ),
                if (h.cameraDistanceM != null)
                  _fact(
                    Icons.straighten_rounded,
                    'Camera measured ${formatDistance(h.cameraDistanceM!)} to it',
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 10, 28, 14),
            child: Text(
              'Clearing removes this warning for every train. Only clear it once the line is clear.',
              textAlign: TextAlign.center,
              style: TS.small,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: RG.pill,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Mark as cleared', style: TS.button),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  return cleared ?? false;
}

/// Details of another train on the line when its marker or list row is tapped.
Future<void> showTrainDetail(
  BuildContext context, {
  required OtherTrain train,
  required double? distanceM,
  double? alongTrackM,
  TrainConflictInfo? conflictInfo,
}) {
  final now = DateTime.now();
  final live = train.isLive(now);
  final isApproaching = conflictInfo?.conflict == TrainConflict.approaching;
  final isOtherLine = conflictInfo?.conflict == TrainConflict.otherLine;
  final colour = isApproaching ? const Color(0xFF5E35B1) : (live ? RG.blue : RG.info);
  final kmh = train.speedKmh;
  final distText = isOtherLine
      ? (distanceM == null
          ? 'Distance unknown (other line)'
          : '${formatDistance(distanceM)} (other line)')
      : (alongTrackM != null
          ? '${formatDistance(alongTrackM)} along the line from your train'
          : (distanceM == null
              ? 'Distance unknown (no GPS)'
              : '${formatDistance(distanceM)} (straight-line) from your train'));
  return _sheet<void>(
    context,
    (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Header('Close', 'Train on the line'),
          if (isApproaching) ...[
            Container(
              margin: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFEDE7F6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF7E57C2), width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFF512DA8), size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'TRAIN CONFLICT ADVISORY',
                          style: TS.title.copyWith(
                            color: const Color(0xFF311B92),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (conflictInfo!.isDirectionUnknown)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF512DA8).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'direction unknown',
                            style: TextStyle(
                              color: Color(0xFF311B92),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Opposing train approaching on your line',
                    style: TS.bodyStrong.copyWith(color: const Color(0xFF311B92), fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  _conflictDetailRow(
                    'Along-track gap',
                    formatDistance(conflictInfo.alongTrackGapM ?? alongTrackM ?? 0),
                  ),
                  _conflictDetailRow(
                    'Closing speed',
                    conflictInfo.closingSpeedKmh == null
                        ? 'unknown'
                        : '${conflictInfo.closingSpeedKmh} km/h',
                  ),
                  _conflictDetailRow('Estimated time to meet', conflictInfo.timeToMeetText),
                  const SizedBox(height: 8),
                  Text(
                    'Train conflict display is advisory only and does not replace token working, signalling or interlocking.',
                    style: TS.small.copyWith(
                      color: const Color(0xFF512DA8),
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          iconCircle(Icons.train_rounded, colour, size: 68, filled: true),
          const SizedBox(height: 10),
          Text(
            train.trainNo.isEmpty ? train.unitId : 'Train ${train.trainNo}',
            style: TS.title.copyWith(fontSize: 18),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: colour.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  train.service == Service.up ? Icons.north_east : Icons.south_west,
                  size: 15,
                  color: colour,
                ),
                const SizedBox(width: 6),
                Text(
                  '${train.service.short}  ·  ${train.service.label}',
                  style: TS.small.copyWith(color: colour),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: RG.surfaceHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _fact(
                  Icons.person_rounded,
                  train.driverName.isEmpty ? 'Driver not given' : train.driverName,
                ),
                _fact(
                  Icons.confirmation_number_outlined,
                  'Train ${train.trainNo.isEmpty ? '—' : train.trainNo}  ·  ${train.unitId}',
                ),
                _fact(
                  train.service == Service.up ? Icons.north_east : Icons.south_west,
                  'Direction: ${train.service.short} (${train.service.label})',
                ),
                _fact(
                  Icons.speed_rounded,
                  kmh == null ? 'Speed unknown' : '$kmh km/h',
                ),
                _fact(
                  Icons.schedule_rounded,
                  '${trainUpdatedAgo(train.lastSeen, now)}${live ? '' : '  ·  stale'}',
                  colour: live ? RG.text : RG.textDim,
                ),
                _fact(Icons.straighten_rounded, distText),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _conflictDetailRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: const TextStyle(color: Color(0xFF4527A0), fontSize: 12)),
      Text(
        value,
        style: const TextStyle(
          color: Color(0xFF311B92),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  ),
);

/// Lists active trains on the line, nearest first. Returns the one tapped, or null.
Future<OtherTrain?> showTrainList(
  BuildContext context, {
  required List<OtherTrain> trains,
  required double? fromLat,
  required double? fromLon,
  Map<String, double>? alongTrackDistances,
  Map<String, TrainConflictInfo>? conflicts,
}) {
  final now = DateTime.now();
  return _sheet<OtherTrain>(
    context,
    (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Header('Close', 'Trains on the line'),
        if (trains.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 36),
            child: Text('No other trains active in the last 5 minutes.', style: TS.body),
          )
        else
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
              itemCount: trains.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: RG.border),
              itemBuilder: (_, i) {
                final t = trains[i];
                final live = t.isLive(now);
                final conflict = conflicts?[t.unitId];
                final isApproaching = conflict?.conflict == TrainConflict.approaching;
                final isOtherLine = conflict?.conflict == TrainConflict.otherLine;
                final alongDist = alongTrackDistances?[t.unitId];
                final dist = t.distanceFrom(fromLat, fromLon);

                String distLabel;
                if (isOtherLine) {
                  distLabel = dist == null ? 'other line' : '${formatDistance(dist)} (other line)';
                } else if (alongDist != null) {
                  distLabel = '${formatDistance(alongDist)} along line';
                } else {
                  distLabel = dist == null ? '? away' : formatDistance(dist);
                }

                final kmh = t.speedKmh;
                final speedLabel = kmh == null ? '' : '  ·  $kmh km/h';
                final driverLabel = t.driverName.isEmpty ? t.unitId : '${t.driverName} (${t.unitId})';
                final circleColor = isApproaching
                    ? const Color(0xFF5E35B1)
                    : (live ? RG.blue : RG.info);

                return InkWell(
                  onTap: () => Navigator.pop(ctx, t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        iconCircle(
                          Icons.train_rounded,
                          circleColor,
                          size: 42,
                          filled: live,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${t.trainLabel}  ·  $distLabel$speedLabel', style: TS.bodyStrong),
                              if (isApproaching)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEDE7F6),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'APPROACHING · ${formatDistance(conflict!.alongTrackGapM ?? 0)} · ${conflict.timeToMeetText}'
                                      '${conflict.isDirectionUnknown ? ' (dir unknown)' : ''}',
                                      style: const TextStyle(
                                        color: Color(0xFF4A148C),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              Text(driverLabel, style: TS.small),
                              Text(
                                '${trainUpdatedAgo(t.lastSeen, now)}${live ? '' : '  ·  stale'}',
                                style: TS.small,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: RG.textDim, size: 22),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
}
