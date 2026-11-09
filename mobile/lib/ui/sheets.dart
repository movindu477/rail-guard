// Bottom sheets, after the design reference:
//   showReportSheet   - pick what to report: four large rows, one tap each
//   showHazardList    - active hazards as a timeline, nearest first
//   showHazardDetail  - one hazard, with "Mark as cleared"

import 'package:flutter/material.dart';

import '../warning.dart';
import 'theme.dart';

Future<T?> _sheet<T>(BuildContext context, Widget Function(BuildContext) body) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RG.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: body(ctx),
        ),
      ),
    );

/// "Cancel    Title" row at the top of each sheet.
class _Header extends StatelessWidget {
  final String left, title;
  const _Header(this.left, this.title);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Column(children: [
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: RG.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: Stack(alignment: Alignment.center, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(left,
                      style: const TextStyle(fontSize: 18, color: RG.accent)),
                ),
              ),
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: RG.text)),
            ]),
          ),
        ]),
      );
}

Widget _emojiCircle(String emoji, {double size = 56, Color? ring}) => Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: RG.surfaceHigh,
        shape: BoxShape.circle,
        border: ring == null ? null : Border.all(color: ring, width: 3),
      ),
      child: Text(emoji, style: TextStyle(fontSize: size * 0.48)),
    );

/// Returns the chosen object_type, or null if cancelled.
Future<String?> showReportSheet(BuildContext context, {required double accuracyM}) =>
    _sheet<String>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        const _Header('Cancel', 'Report hazard'),
        Text('At your position  ·  ±${accuracyM.toStringAsFixed(0)} m',
            style: const TextStyle(fontSize: 16, color: RG.textDim)),
        const SizedBox(height: 8),
        for (final t in hazardTypes)
          InkWell(
            onTap: () => Navigator.pop(ctx, t.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(children: [
                _emojiCircle(t.emoji),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.label,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w600, color: RG.text)),
                    Text(t.hint, style: const TextStyle(fontSize: 15, color: RG.textDim)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: RG.textDim, size: 30),
              ]),
            ),
          ),
        const SizedBox(height: 12),
      ]),
    );

/// One row of the hazard list: the hazard, plus distance and direction when
/// the train's position is known.
class HazardRow {
  final Hazard hazard;
  final double? distanceM;
  final bool? ahead; // null: heading unknown
  const HazardRow(this.hazard, this.distanceM, this.ahead);

  /// "5 m" or "?" without GPS.
  String get distance => distanceM == null ? '?' : formatDistance(distanceM!);

  String get direction => distanceM == null
      ? 'Distance unknown (no GPS)'
      : ahead == null
          ? 'Direction unknown (not moving)'
          : (ahead! ? 'Ahead' : 'Behind');

  /// One line: "1.8 km ahead", "5 m, direction unknown".
  String get where => distanceM == null
      ? direction
      : ahead == null
          ? '$distance, direction unknown'
          : '$distance ${ahead! ? 'ahead' : 'behind'}';
}

/// Timeline of active hazards. Returns the one tapped, or null.
Future<Hazard?> showHazardList(BuildContext context, {required List<HazardRow> rows}) {
  final now = DateTime.now();
  return _sheet<Hazard>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
      const _Header('Close', 'Active hazards'),
      if (rows.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, 40),
          child: Text('No reports in the last 30 minutes.',
              style: TextStyle(fontSize: 18, color: RG.textDim)),
        )
      else
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i];
              final t = typeInfo(r.hazard.objectType);
              final time = r.hazard.time;
              return InkWell(
                onTap: () => Navigator.pop(ctx, r.hazard),
                child: IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // Timeline: icon, with a line down to the next one.
                    Column(children: [
                      _emojiCircle(t.emoji, size: 48, ring: r.ahead != false ? RG.danger : null),
                      if (i < rows.length - 1)
                        Expanded(child: Container(width: 2, color: RG.border)),
                    ]),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 20),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${t.label}  ·  ${r.distance}',
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w700, color: RG.text)),
                          Text(r.direction,
                              style: TextStyle(
                                  fontSize: 16,
                                  color: r.ahead != false ? RG.danger : RG.textDim)),
                          Text(
                              time == null
                                  ? 'Reported: time unknown'
                                  : 'Reported ${hhmm(time)}  ·  ${ago(time, now)}',
                              style: const TextStyle(fontSize: 15, color: RG.textDim)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
    ]),
  );
}

/// One hazard. Returns true if the driver chose "Mark as cleared".
Future<bool> showHazardDetail(BuildContext context, {required HazardRow row}) async {
  final t = typeInfo(row.hazard.objectType);
  final time = row.hazard.time;
  final cleared = await _sheet<bool>(
    context,
    (ctx) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const _Header('Close', 'Hazard'),
        const SizedBox(height: 16),
        _emojiCircle(t.emoji, size: 84, ring: RG.danger),
        const SizedBox(height: 16),
        Text('${t.label} reported',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: RG.text)),
        const SizedBox(height: 6),
        Text(row.where, style: const TextStyle(fontSize: 18, color: RG.text)),
        if (time != null)
          Text('Reported ${hhmm(time)}  ·  ${ago(time, DateTime.now())}',
              style: const TextStyle(fontSize: 16, color: RG.textDim)),
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 16, 28, 20),
          child: Text(
            'Clearing removes this warning for every train. '
            'Only clear it once the line is clear.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: RG.textDim, height: 1.4),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SizedBox(
            width: double.infinity,
            height: 60,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: RG.accent,
                  foregroundColor: RG.onAccent,
                  shape: const StadiumBorder()),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark as cleared',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ]),
    ),
  );
  return cleared ?? false;
}
