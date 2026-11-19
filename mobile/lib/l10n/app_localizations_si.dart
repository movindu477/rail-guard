// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Sinhala Sinhalese (`si`).
class AppLocalizationsSi extends AppLocalizations {
  AppLocalizationsSi([String locale = 'si']) : super(locale);

  @override
  String get alertStop => 'නවත්වන්න';

  @override
  String get alertCaution => 'අවවාදයයි';

  @override
  String get alertInfo => 'තොරතුරු';

  @override
  String get hazardAnimal => 'සතෙක්';

  @override
  String get hazardPerson => 'පුද්ගලයෙක්';

  @override
  String get hazardVehicle => 'වාහනයක්';

  @override
  String get hazardObstruction => 'බාධකයක්';

  @override
  String get severityBlocked => 'මාර්ගය අවහිරයි';

  @override
  String get severityBlockedHint => 'දුම්රියට ගමන් කළ නොහැක';

  @override
  String get severityNear => 'මාර්ගය අසල';

  @override
  String get severityNearHint => 'ප්‍රවේශමෙන් ගමන් කරන්න';

  @override
  String get stopLineBlocked => 'මාර්ගය අවහිරයි';

  @override
  String get stopNearLine => 'මාර්ගය අසල';

  @override
  String get stopAlongLine => 'දුම්රිය මාර්ගය දිගේ';

  @override
  String get stopAhead => 'ඉදිරියෙන්';

  @override
  String get stopDirectionUnknown => 'දිශාව නොදනී';

  @override
  String get btnAcknowledge => 'තහවුරු කරන්න';

  @override
  String get promptStillThereTitle => 'තවමත් එතැනද?';

  @override
  String promptYouJustPassed(String hazard) {
    return 'ඔබ දැන් පසු කළේ: $hazard';
  }

  @override
  String get answerCleared => 'ඉවත් වී ඇත';

  @override
  String get answerStillThere => 'තවමත් ඇත';

  @override
  String get answerDidNotSee => 'නොදුටුවෙමි';

  @override
  String get promptDidNotSeeHint =>
      '“නොදුටුවෙමි” තේරීමෙන් අනතුරු ඇඟවීම ඉවත් නොවේ.';

  @override
  String get btnReport => 'වාර්තා කරන්න';

  @override
  String get reportHazardTitle => 'අනතුරක් වාර්තා කරන්න';

  @override
  String get reportWhatIsIt => 'මාර්ගයේ ඇත්තේ කුමක්ද?';

  @override
  String get reportHowBad => 'තත්ත්වය කෙසේද?';

  @override
  String get btnCancel => 'අවලංගු කරන්න';

  @override
  String get btnClose => 'වසන්න';

  @override
  String get btnFollow => 'අනුගමනය';

  @override
  String get btnMarkCleared => 'ඉවත් කළ බව සලකුණු කරන්න';

  @override
  String get statusNoHazardsAhead => 'ඉදිරියේ අනතුරු නැත';

  @override
  String get statusLineClear3km => 'කි.මී. 3 ක් ඇතුළත මාර්ගය පැහැදිලිය';

  @override
  String get statusClearTag => 'පැහැදිලිය';

  @override
  String get statusCannotCheckNoSignal => 'පරීක්ෂා කළ නොහැක — signal නැත';

  @override
  String statusCachedDataOnly(String age) {
    return 'අවසන් යාවත්කාලීනය $age · පැරණි දත්ත පමණි';
  }

  @override
  String bannerNoSignal(String age) {
    return 'Signal නැත — පෙන්වන අනතුරු අවසන් වරට යාවත්කාලීන කළේ $age.';
  }

  @override
  String get badgeNotYetSent => 'තවම යවා නැත';

  @override
  String get pendingWaitingSingle => 'වාර්තා 1 ක් යැවීමට රැඳී ඇත';

  @override
  String pendingWaitingPlural(int count) {
    return 'වාර්තා $count ක් යැවීමට රැඳී ඇත';
  }

  @override
  String get advisoryTrainConflict => 'දුම්රිය ගැටුම් අවවාදය';

  @override
  String get advisoryOpposingTrain =>
      'ප්‍රතිවිරුද්ධ දුම්රියක් ඔබේ මාර්ගයේ ළඟා වේ';

  @override
  String get advisoryAlongTrackGap => 'මාර්ගය දිගේ දුර';

  @override
  String get advisoryClosingSpeed => 'ඒකාබද්ධ වේගය';

  @override
  String get advisoryTimeToMeet => 'හමුවීමට ඇස්තමේන්තු කාලය';

  @override
  String get advisoryDisclaimer =>
      'මෙය උපදේශන දර්ශනයක් පමණි; token working, signalling හෝ interlocking වෙනුවට නොවේ.';

  @override
  String get signInTitle => 'ගිණුමට පිවිසෙන්න';

  @override
  String get signInSubtitle => 'විද්‍යුත් තැපෑල සහ මුරපදය ඇතුළත් කරන්න';

  @override
  String get btnSignIn => 'පිවිසෙන්න';

  @override
  String get driverDetailsTitle => 'රියදුරු විස්තර';

  @override
  String get createAccountTitle => 'ගිණුමක් සාදන්න';

  @override
  String get labelDriverDetails => 'රියදුරු විස්තර';

  @override
  String get labelTrainAssignment => 'දුම්රිය පැවරුම';

  @override
  String get labelDirection => 'ගමන් දිශාව';

  @override
  String get serviceUpDesc => 'කොළඹ දෙසට';

  @override
  String get serviceDownDesc => 'කොළඹ සිට';

  @override
  String get btnSaveChanges => 'වෙනස්කම් සුරකින්න';

  @override
  String get btnStartDuty => 'ලියාපදිංචි වී රාජකාරිය අරඹන්න';

  @override
  String get labelLanguage => 'භාෂාව';

  @override
  String get unreviewedTranslationNotice =>
      'Sinhala and Tamil text has not yet been checked by a native speaker.';
}
