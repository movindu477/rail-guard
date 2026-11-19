// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Tamil (`ta`).
class AppLocalizationsTa extends AppLocalizations {
  AppLocalizationsTa([String locale = 'ta']) : super(locale);

  @override
  String get alertStop => 'நிறுத்து';

  @override
  String get alertCaution => 'எச்சரிக்கை';

  @override
  String get alertInfo => 'தகவல்';

  @override
  String get hazardAnimal => 'விலங்கு';

  @override
  String get hazardPerson => 'நபர்';

  @override
  String get hazardVehicle => 'வாகனம்';

  @override
  String get hazardObstruction => 'தடை';

  @override
  String get severityBlocked => 'பாதை தடைப்பட்டுள்ளது';

  @override
  String get severityBlockedHint => 'ரயில் செல்ல முடியாது';

  @override
  String get severityNear => 'பாதைக்கு அருகில்';

  @override
  String get severityNearHint => 'கவனமாக செல்லவும்';

  @override
  String get stopLineBlocked => 'பாதை தடைப்பட்டுள்ளது';

  @override
  String get stopNearLine => 'பாதைக்கு அருகில்';

  @override
  String get stopAlongLine => 'ரயில் பாதை வழியே';

  @override
  String get stopAhead => 'முன்னால்';

  @override
  String get stopDirectionUnknown => 'திசை தெரியவில்லை';

  @override
  String get btnAcknowledge => 'ஒப்புக்கொள்';

  @override
  String get promptStillThereTitle => 'இன்னும் உள்ளதா?';

  @override
  String promptYouJustPassed(String hazard) {
    return 'நீங்கள் கடந்தது: $hazard';
  }

  @override
  String get answerCleared => 'அகற்றப்பட்டது';

  @override
  String get answerStillThere => 'இன்னும் உள்ளது';

  @override
  String get answerDidNotSee => 'பார்க்கவில்லை';

  @override
  String get promptDidNotSeeHint =>
      '“பார்க்கவில்லை” என்பது எச்சரிக்கையை அகற்றாமல் பதிவாகும்.';

  @override
  String get btnReport => 'புகார்';

  @override
  String get reportHazardTitle => 'ஆபத்தை புகாரளி';

  @override
  String get reportWhatIsIt => 'பாதையில் என்ன உள்ளது?';

  @override
  String get reportHowBad => 'நிலைமை எவ்வாறு உள்ளது?';

  @override
  String get btnCancel => 'ரத்து';

  @override
  String get btnClose => 'மூடு';

  @override
  String get btnFollow => 'பின்தொடர்';

  @override
  String get btnMarkCleared => 'அகற்றப்பட்டதாக குறி';

  @override
  String get statusNoHazardsAhead => 'முன்னால் ஆபத்து இல்லை';

  @override
  String get statusLineClear3km => '3 கி.மீ வரை பாதை தெளிவாக உள்ளது';

  @override
  String get statusClearTag => 'தெளிவு';

  @override
  String get statusCannotCheckNoSignal =>
      'சரிபார்க்க முடியவில்லை — signal இல்லை';

  @override
  String statusCachedDataOnly(String age) {
    return 'கடைசி புதுப்பிப்பு $age · பழைய தரவு மட்டும்';
  }

  @override
  String bannerNoSignal(String age) {
    return 'Signal இல்லை — காட்டப்படும் ஆபத்துகள் கடைசியாக புதுப்பிக்கப்பட்டது $age.';
  }

  @override
  String get badgeNotYetSent => 'இன்னும் அனுப்பப்படவில்லை';

  @override
  String get pendingWaitingSingle => '1 புகார் அனுப்ப காத்திருக்கிறது';

  @override
  String pendingWaitingPlural(int count) {
    return '$count புகார்கள் அனுப்ப காத்திருக்கின்றன';
  }

  @override
  String get advisoryTrainConflict => 'ரயில் மோதல் எச்சரிக்கை';

  @override
  String get advisoryOpposingTrain =>
      'எதிர் ரயில் உங்கள் பாதையில் நெருங்குகிறது';

  @override
  String get advisoryAlongTrackGap => 'பாதை வழியே தூரம்';

  @override
  String get advisoryClosingSpeed => 'இணைந்த வேகம்';

  @override
  String get advisoryTimeToMeet => 'சந்திக்கும் மதிப்பீட்டு நேரம்';

  @override
  String get advisoryDisclaimer =>
      'இது ஆலோசனை காட்சி மட்டுமே; token working, signalling அல்லது interlocking-க்கு மாற்று அல்ல.';

  @override
  String get signInTitle => 'கணக்கில் உள்நுழைக';

  @override
  String get signInSubtitle => 'மின்னஞ்சல் மற்றும் கடவுச்சொல்லை உள்ளிடவும்';

  @override
  String get btnSignIn => 'உள்நுழை';

  @override
  String get driverDetailsTitle => 'ஓட்டுநர் விவரங்கள்';

  @override
  String get createAccountTitle => 'கணக்கு உருவாக்கு';

  @override
  String get labelDriverDetails => 'ஓட்டுநர் விவரங்கள்';

  @override
  String get labelTrainAssignment => 'ரயில் ஒதுக்கீடு';

  @override
  String get labelDirection => 'பயண திசை';

  @override
  String get serviceUpDesc => 'கொழும்பு நோக்கி';

  @override
  String get serviceDownDesc => 'கொழும்பில் இருந்து';

  @override
  String get btnSaveChanges => 'மாற்றங்களை சேமி';

  @override
  String get btnStartDuty => 'பதிவு செய்து பணியை தொடங்கு';

  @override
  String get labelLanguage => 'மொழி';

  @override
  String get unreviewedTranslationNotice =>
      'Sinhala and Tamil text has not yet been checked by a native speaker.';
}
