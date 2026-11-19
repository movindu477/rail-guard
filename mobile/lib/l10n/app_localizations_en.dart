// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get alertStop => 'STOP';

  @override
  String get alertCaution => 'CAUTION';

  @override
  String get alertInfo => 'INFO';

  @override
  String get hazardAnimal => 'Animal';

  @override
  String get hazardPerson => 'Person';

  @override
  String get hazardVehicle => 'Vehicle';

  @override
  String get hazardObstruction => 'Obstruction';

  @override
  String get severityBlocked => 'Line blocked';

  @override
  String get severityBlockedHint => 'Train cannot pass';

  @override
  String get severityNear => 'Near the line';

  @override
  String get severityNearHint => 'Pass with caution';

  @override
  String get stopLineBlocked => 'LINE BLOCKED';

  @override
  String get stopNearLine => 'NEAR THE LINE';

  @override
  String get stopAlongLine => 'ALONG THE LINE';

  @override
  String get stopAhead => 'AHEAD';

  @override
  String get stopDirectionUnknown => 'DIRECTION UNKNOWN';

  @override
  String get btnAcknowledge => 'ACKNOWLEDGE';

  @override
  String get promptStillThereTitle => 'Still there?';

  @override
  String promptYouJustPassed(String hazard) {
    return 'You just passed: $hazard';
  }

  @override
  String get answerCleared => 'Cleared';

  @override
  String get answerStillThere => 'Still there';

  @override
  String get answerDidNotSee => 'Did not see';

  @override
  String get promptDidNotSeeHint =>
      '“Did not see” records your pass without clearing the warning.';

  @override
  String get btnReport => 'REPORT';

  @override
  String get reportHazardTitle => 'Report hazard';

  @override
  String get reportWhatIsIt => 'What is on the line?';

  @override
  String get reportHowBad => 'How bad is it?';

  @override
  String get btnCancel => 'Cancel';

  @override
  String get btnClose => 'Close';

  @override
  String get btnFollow => 'Follow';

  @override
  String get btnMarkCleared => 'Mark as cleared';

  @override
  String get statusNoHazardsAhead => 'No hazards ahead';

  @override
  String get statusLineClear3km => 'Line clear within 3 km';

  @override
  String get statusClearTag => 'CLEAR';

  @override
  String get statusCannotCheckNoSignal => 'Cannot check — no signal';

  @override
  String statusCachedDataOnly(String age) {
    return 'Last updated $age · cached data only';
  }

  @override
  String bannerNoSignal(String age) {
    return 'No signal — hazards shown were last updated $age.';
  }

  @override
  String get badgeNotYetSent => 'not yet sent';

  @override
  String get pendingWaitingSingle => '1 report waiting to send';

  @override
  String pendingWaitingPlural(int count) {
    return '$count reports waiting to send';
  }

  @override
  String get advisoryTrainConflict => 'TRAIN CONFLICT ADVISORY';

  @override
  String get advisoryOpposingTrain => 'Opposing train approaching on your line';

  @override
  String get advisoryAlongTrackGap => 'Along-track gap';

  @override
  String get advisoryClosingSpeed => 'Closing speed';

  @override
  String get advisoryTimeToMeet => 'Estimated time to meet';

  @override
  String get advisoryDisclaimer =>
      'Train conflict display is advisory only and does not replace token working, signalling or interlocking.';

  @override
  String get signInTitle => 'Sign in Your Account';

  @override
  String get signInSubtitle =>
      'Enter your email and password to access the cab dashboard';

  @override
  String get btnSignIn => 'Sign In';

  @override
  String get driverDetailsTitle => 'Driver details';

  @override
  String get createAccountTitle => 'Create An Account';

  @override
  String get labelDriverDetails => 'DRIVER DETAILS';

  @override
  String get labelTrainAssignment => 'TRAIN ASSIGNMENT';

  @override
  String get labelDirection => 'DIRECTION OF RUNNING';

  @override
  String get serviceUpDesc => 'to Colombo';

  @override
  String get serviceDownDesc => 'from Colombo';

  @override
  String get btnSaveChanges => 'Save Changes';

  @override
  String get btnStartDuty => 'Sign Up & Start Duty';

  @override
  String get labelLanguage => 'LANGUAGE';

  @override
  String get unreviewedTranslationNotice =>
      'Sinhala and Tamil text has not yet been checked by a native speaker.';
}
