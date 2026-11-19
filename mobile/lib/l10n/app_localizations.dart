import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_si.dart';
import 'app_localizations_ta.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('si'),
    Locale('ta'),
  ];

  /// No description provided for @alertStop.
  ///
  /// In en, this message translates to:
  /// **'STOP'**
  String get alertStop;

  /// No description provided for @alertCaution.
  ///
  /// In en, this message translates to:
  /// **'CAUTION'**
  String get alertCaution;

  /// No description provided for @alertInfo.
  ///
  /// In en, this message translates to:
  /// **'INFO'**
  String get alertInfo;

  /// No description provided for @hazardAnimal.
  ///
  /// In en, this message translates to:
  /// **'Animal'**
  String get hazardAnimal;

  /// No description provided for @hazardPerson.
  ///
  /// In en, this message translates to:
  /// **'Person'**
  String get hazardPerson;

  /// No description provided for @hazardVehicle.
  ///
  /// In en, this message translates to:
  /// **'Vehicle'**
  String get hazardVehicle;

  /// No description provided for @hazardObstruction.
  ///
  /// In en, this message translates to:
  /// **'Obstruction'**
  String get hazardObstruction;

  /// No description provided for @severityBlocked.
  ///
  /// In en, this message translates to:
  /// **'Line blocked'**
  String get severityBlocked;

  /// No description provided for @severityBlockedHint.
  ///
  /// In en, this message translates to:
  /// **'Train cannot pass'**
  String get severityBlockedHint;

  /// No description provided for @severityNear.
  ///
  /// In en, this message translates to:
  /// **'Near the line'**
  String get severityNear;

  /// No description provided for @severityNearHint.
  ///
  /// In en, this message translates to:
  /// **'Pass with caution'**
  String get severityNearHint;

  /// No description provided for @stopLineBlocked.
  ///
  /// In en, this message translates to:
  /// **'LINE BLOCKED'**
  String get stopLineBlocked;

  /// No description provided for @stopNearLine.
  ///
  /// In en, this message translates to:
  /// **'NEAR THE LINE'**
  String get stopNearLine;

  /// No description provided for @stopAlongLine.
  ///
  /// In en, this message translates to:
  /// **'ALONG THE LINE'**
  String get stopAlongLine;

  /// No description provided for @stopAhead.
  ///
  /// In en, this message translates to:
  /// **'AHEAD'**
  String get stopAhead;

  /// No description provided for @stopDirectionUnknown.
  ///
  /// In en, this message translates to:
  /// **'DIRECTION UNKNOWN'**
  String get stopDirectionUnknown;

  /// No description provided for @btnAcknowledge.
  ///
  /// In en, this message translates to:
  /// **'ACKNOWLEDGE'**
  String get btnAcknowledge;

  /// No description provided for @promptStillThereTitle.
  ///
  /// In en, this message translates to:
  /// **'Still there?'**
  String get promptStillThereTitle;

  /// No description provided for @promptYouJustPassed.
  ///
  /// In en, this message translates to:
  /// **'You just passed: {hazard}'**
  String promptYouJustPassed(String hazard);

  /// No description provided for @answerCleared.
  ///
  /// In en, this message translates to:
  /// **'Cleared'**
  String get answerCleared;

  /// No description provided for @answerStillThere.
  ///
  /// In en, this message translates to:
  /// **'Still there'**
  String get answerStillThere;

  /// No description provided for @answerDidNotSee.
  ///
  /// In en, this message translates to:
  /// **'Did not see'**
  String get answerDidNotSee;

  /// No description provided for @promptDidNotSeeHint.
  ///
  /// In en, this message translates to:
  /// **'“Did not see” records your pass without clearing the warning.'**
  String get promptDidNotSeeHint;

  /// No description provided for @btnReport.
  ///
  /// In en, this message translates to:
  /// **'REPORT'**
  String get btnReport;

  /// No description provided for @reportHazardTitle.
  ///
  /// In en, this message translates to:
  /// **'Report hazard'**
  String get reportHazardTitle;

  /// No description provided for @reportWhatIsIt.
  ///
  /// In en, this message translates to:
  /// **'What is on the line?'**
  String get reportWhatIsIt;

  /// No description provided for @reportHowBad.
  ///
  /// In en, this message translates to:
  /// **'How bad is it?'**
  String get reportHowBad;

  /// No description provided for @btnCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get btnCancel;

  /// No description provided for @btnClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get btnClose;

  /// No description provided for @btnFollow.
  ///
  /// In en, this message translates to:
  /// **'Follow'**
  String get btnFollow;

  /// No description provided for @btnMarkCleared.
  ///
  /// In en, this message translates to:
  /// **'Mark as cleared'**
  String get btnMarkCleared;

  /// No description provided for @statusNoHazardsAhead.
  ///
  /// In en, this message translates to:
  /// **'No hazards ahead'**
  String get statusNoHazardsAhead;

  /// No description provided for @statusLineClear3km.
  ///
  /// In en, this message translates to:
  /// **'Line clear within 3 km'**
  String get statusLineClear3km;

  /// No description provided for @statusClearTag.
  ///
  /// In en, this message translates to:
  /// **'CLEAR'**
  String get statusClearTag;

  /// No description provided for @statusCannotCheckNoSignal.
  ///
  /// In en, this message translates to:
  /// **'Cannot check — no signal'**
  String get statusCannotCheckNoSignal;

  /// No description provided for @statusCachedDataOnly.
  ///
  /// In en, this message translates to:
  /// **'Last updated {age} · cached data only'**
  String statusCachedDataOnly(String age);

  /// No description provided for @bannerNoSignal.
  ///
  /// In en, this message translates to:
  /// **'No signal — hazards shown were last updated {age}.'**
  String bannerNoSignal(String age);

  /// No description provided for @badgeNotYetSent.
  ///
  /// In en, this message translates to:
  /// **'not yet sent'**
  String get badgeNotYetSent;

  /// No description provided for @pendingWaitingSingle.
  ///
  /// In en, this message translates to:
  /// **'1 report waiting to send'**
  String get pendingWaitingSingle;

  /// No description provided for @pendingWaitingPlural.
  ///
  /// In en, this message translates to:
  /// **'{count} reports waiting to send'**
  String pendingWaitingPlural(int count);

  /// No description provided for @advisoryTrainConflict.
  ///
  /// In en, this message translates to:
  /// **'TRAIN CONFLICT ADVISORY'**
  String get advisoryTrainConflict;

  /// No description provided for @advisoryOpposingTrain.
  ///
  /// In en, this message translates to:
  /// **'Opposing train approaching on your line'**
  String get advisoryOpposingTrain;

  /// No description provided for @advisoryAlongTrackGap.
  ///
  /// In en, this message translates to:
  /// **'Along-track gap'**
  String get advisoryAlongTrackGap;

  /// No description provided for @advisoryClosingSpeed.
  ///
  /// In en, this message translates to:
  /// **'Closing speed'**
  String get advisoryClosingSpeed;

  /// No description provided for @advisoryTimeToMeet.
  ///
  /// In en, this message translates to:
  /// **'Estimated time to meet'**
  String get advisoryTimeToMeet;

  /// No description provided for @advisoryDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'Train conflict display is advisory only and does not replace token working, signalling or interlocking.'**
  String get advisoryDisclaimer;

  /// No description provided for @signInTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in Your Account'**
  String get signInTitle;

  /// No description provided for @signInSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your email and password to access the cab dashboard'**
  String get signInSubtitle;

  /// No description provided for @btnSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get btnSignIn;

  /// No description provided for @driverDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Driver details'**
  String get driverDetailsTitle;

  /// No description provided for @createAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Create An Account'**
  String get createAccountTitle;

  /// No description provided for @labelDriverDetails.
  ///
  /// In en, this message translates to:
  /// **'DRIVER DETAILS'**
  String get labelDriverDetails;

  /// No description provided for @labelTrainAssignment.
  ///
  /// In en, this message translates to:
  /// **'TRAIN ASSIGNMENT'**
  String get labelTrainAssignment;

  /// No description provided for @labelDirection.
  ///
  /// In en, this message translates to:
  /// **'DIRECTION OF RUNNING'**
  String get labelDirection;

  /// No description provided for @serviceUpDesc.
  ///
  /// In en, this message translates to:
  /// **'to Colombo'**
  String get serviceUpDesc;

  /// No description provided for @serviceDownDesc.
  ///
  /// In en, this message translates to:
  /// **'from Colombo'**
  String get serviceDownDesc;

  /// No description provided for @btnSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save Changes'**
  String get btnSaveChanges;

  /// No description provided for @btnStartDuty.
  ///
  /// In en, this message translates to:
  /// **'Sign Up & Start Duty'**
  String get btnStartDuty;

  /// No description provided for @labelLanguage.
  ///
  /// In en, this message translates to:
  /// **'LANGUAGE'**
  String get labelLanguage;

  /// No description provided for @unreviewedTranslationNotice.
  ///
  /// In en, this message translates to:
  /// **'Sinhala and Tamil text has not yet been checked by a native speaker.'**
  String get unreviewedTranslationNotice;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'si', 'ta'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'si':
      return AppLocalizationsSi();
    case 'ta':
      return AppLocalizationsTa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
