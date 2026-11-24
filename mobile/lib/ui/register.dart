// Registration: driver account creation and train setup.
// Uses train4.jpg without black opacity overlay, a 50px top border radius on the
// form section, a red-accented active language selector, and legible Poppins
// typography throughout.
//
// The local save is the offline cache; Firestore drivers/{uid} is the authoritative
// profile for other trains to see.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account.dart';
import '../driver.dart';
import '../l10n/app_localizations.dart';
import '../locale_store.dart';
import 'theme.dart';

class RegisterScreen extends StatefulWidget {
  /// The profile being edited, or null when registering.
  final DriverProfile? existing;

  /// Called with the saved profile once registration/edit is complete.
  final ValueChanged<DriverProfile> onDone;

  /// Optional callback to navigate back to Login screen.
  final VoidCallback? onBackToLogin;

  /// Optional callback when driver signs out in edit mode.
  final VoidCallback? onSignOut;

  const RegisterScreen({
    super.key,
    this.existing,
    required this.onDone,
    this.onBackToLogin,
    this.onSignOut,
  });

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _email;
  late final TextEditingController _password;
  late final TextEditingController _confirmPassword;
  late final TextEditingController _name;
  late final TextEditingController _staff;
  late final TextEditingController _train;
  late final TextEditingController _unit;
  late Service _service;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _saving = false;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _email =
        TextEditingController(text: e?.email ?? (currentUser?.email ?? ''));
    _password = TextEditingController();
    _confirmPassword = TextEditingController();
    _name = TextEditingController(text: e?.driverName ?? '');
    _staff = TextEditingController(text: e?.driverId ?? '');
    _train = TextEditingController(text: e?.trainNo ?? '');
    // Deliberately blank for a new driver. The field used to arrive holding
    // defaultUnitId, and on 24 Nov 2026 two phones were both registered as
    // unit-01 because neither driver changed it. A unit id has to be a choice.
    _unit = TextEditingController(text: e?.unitId ?? '');
    _service = e?.service ?? Service.up;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _name.dispose();
    _staff.dispose();
    _train.dispose();
    _unit.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;

    setState(() {
      _saving = true;
      _inlineError = null;
    });

    final editing = widget.existing != null;
    try {
      String? uid = currentUid;
      String userEmail = _email.text.trim();

      if (!editing) {
        if (uid == null ||
            currentUser?.email?.toLowerCase() != userEmail.toLowerCase()) {
          final cred = await register(userEmail, _password.text);
          uid = cred.user!.uid;
        }
      } else {
        userEmail = widget.existing?.email ?? (currentUser?.email ?? '');
      }

      final p = DriverProfile(
        unitId: _unit.text.trim(),
        driverName: _name.text.trim(),
        driverId: _staff.text.trim(),
        trainNo: _train.text.trim(),
        service: _service,
        email: userEmail,
      );

      if (uid != null) {
        // Claim first: a unit id already held by another driver must be
        // refused before anything is saved, or two trains share one
        // train_position document and one of them vanishes from the map.
        await claimUnitId(uid, p.unitId, releasing: widget.existing?.unitId);
        await saveDriverToFirestore(uid, p);
      }

      await saveDriver(p);

      if (!mounted) return;
      setState(() => _saving = false);
      widget.onDone(p);
    } on UnitIdTakenException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _inlineError = 'Unit ${e.unitId} is already used by another driver. '
            'Pick a different unit ID.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _inlineError = authErrorMessage(e);
      });
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RG.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Sign out?', style: TS.title),
        content: const Text(
          'Are you sure you want to sign out of RailGuard? '
          'You will need your email and password to sign back in.',
          style: TS.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                fontFamily: defaultFontFamily,
                fontWeight: FontWeight.w500,
                color: RG.textDim,
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: RG.danger,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out', style: TS.button),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await signOut();
      await clearDriver();
      if (!mounted) return;
      widget.onSignOut?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final editing = widget.existing != null;
    if (editing) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: RG.surface,
          surfaceTintColor: RG.surface,
          elevation: 0,
          title: Text(l10n.driverDetailsTitle, style: TS.title),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout, color: RG.danger),
              tooltip: 'Sign out',
              onPressed: _confirmSignOut,
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _buildForm(editing: true),
              ),
            ),
          ),
        ),
      );
    }

    final imageHeight =
        (MediaQuery.sizeOf(context).height * 0.34).clamp(230.0, 320.0);
    const double overlap = 46.0;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: SingleChildScrollView(
        child: Stack(
          children: [
            // Section 1: Top Image Section (train4.jpg, no black opacity)
            // with left-aligned Title and Description.
            SizedBox(
              height: imageHeight,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'assets/images/train4.jpg',
                    fit: BoxFit.cover,
                    alignment: const Alignment(0, 0.25),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: overlap + 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'RailGuard',
                          style: TextStyle(
                            fontFamily: defaultFontFamily,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: 0.2,
                            shadows: [
                              Shadow(
                                color: Color(0xB3000000),
                                blurRadius: 12,
                                offset: Offset(0, 2),
                              ),
                            ],
                            fontFamilyFallback: scriptFontFallbacks,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Sri Lankan Railways driver & unit registration',
                          style: TextStyle(
                            fontFamily: defaultFontFamily,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.95),
                            shadows: const [
                              Shadow(
                                color: Color(0xB3000000),
                                blurRadius: 10,
                                offset: Offset(0, 1),
                              ),
                            ],
                            fontFamilyFallback: scriptFontFallbacks,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Section 2: Separate Bottom Form Section with 50px top border radius
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(top: imageHeight - overlap),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(50),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x1F000000),
                    blurRadius: 24,
                    offset: Offset(0, -6),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: _buildForm(editing: false),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm({required bool editing}) {
    final l10n = AppLocalizations.of(context)!;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!editing) ...[
            Text(
              l10n.createAccountTitle,
              style: const TextStyle(
                fontFamily: defaultFontFamily,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
                letterSpacing: -0.2,
                fontFamilyFallback: scriptFontFallbacks,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sign up with your railway staff credentials to start duty',
              style: TextStyle(
                fontFamily: defaultFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 18),
          ],

          _languageSelector(l10n),
          const SizedBox(height: 18),

          if (!editing) ...[
            _sectionHeader('ACCOUNT CREDENTIALS'),
            const SizedBox(height: 10),
            _modernField(
              controller: _email,
              hintText: 'Email address',
              icon: Icons.mail_outline_rounded,
              keyboard: TextInputType.emailAddress,
              validator: validateEmail,
            ),
            const SizedBox(height: 10),
            _modernField(
              controller: _password,
              hintText: 'Password (min 8 characters)',
              icon: Icons.lock_outline_rounded,
              obscure: _obscurePassword,
              validator: validatePassword,
              suffix: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: const Color(0xFF64748B),
                  size: 20,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            const SizedBox(height: 10),
            _modernField(
              controller: _confirmPassword,
              hintText: 'Confirm password',
              icon: Icons.lock_outline_rounded,
              obscure: _obscureConfirm,
              validator: (v) => validateConfirmPassword(v, _password.text),
              suffix: IconButton(
                icon: Icon(
                  _obscureConfirm
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: const Color(0xFF64748B),
                  size: 20,
                ),
                onPressed: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),
            ),
            const SizedBox(height: 18),
          ],

          _sectionHeader(l10n.labelDriverDetails),
          const SizedBox(height: 10),
          _modernField(
            controller: _name,
            hintText: 'Driver full name',
            icon: Icons.person_outline_rounded,
            validator: (v) => validateRequired(v, 'Name'),
            capitalise: TextCapitalization.words,
          ),
          const SizedBox(height: 10),
          _modernField(
            controller: _staff,
            hintText: 'Staff ID (e.g. SLR4821)',
            icon: Icons.badge_outlined,
            validator: (v) => validateRequired(v, 'Staff number'),
          ),
          const SizedBox(height: 18),

          _sectionHeader(l10n.labelTrainAssignment),
          const SizedBox(height: 10),
          _modernField(
            controller: _train,
            hintText: 'Train number (e.g. 1005)',
            icon: Icons.train_outlined,
            validator: validateTrainNo,
            keyboard: TextInputType.text,
          ),
          const SizedBox(height: 10),
          _modernField(
            controller: _unit,
            hintText: 'Unit ID, unique to this train (e.g. unit-07)',
            icon: Icons.memory_rounded,
            validator: validateUnitId,
            helperText: 'Must match detection unit on laptop',
            formatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9-]')),
              LowerCaseFormatter(),
            ],
          ),
          const SizedBox(height: 18),

          _sectionHeader(l10n.labelDirection),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in Service.values) ...[
                Expanded(child: _serviceButton(s, l10n)),
                if (s != Service.values.last) const SizedBox(width: 10),
              ],
            ],
          ),
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              'You are only alerted about hazards and trains running the '
              'same way on the same line.',
              style: TextStyle(
                fontFamily: defaultFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF475569),
              ),
            ),
          ),

          if (_inlineError != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: RG.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: RG.danger.withValues(alpha: 0.30)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: RG.danger,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _inlineError!,
                      style: TS.small.copyWith(
                        color: RG.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Primary CTA button
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _saving ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: RG.brand,
                disabledBackgroundColor: RG.brand.withValues(alpha: 0.5),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      editing ? l10n.btnSaveChanges : l10n.btnStartDuty,
                      style: const TextStyle(
                        fontFamily: defaultFontFamily,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.3,
                        fontFamilyFallback: scriptFontFallbacks,
                      ),
                    ),
            ),
          ),

          if (!editing && widget.onBackToLogin != null) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Already have an account? ',
                  style: TextStyle(
                    fontFamily: defaultFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF475569),
                  ),
                ),
                GestureDetector(
                  onTap: widget.onBackToLogin,
                  child: const Text(
                    'Sign In',
                    style: TextStyle(
                      fontFamily: defaultFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: RG.brand,
                    ),
                  ),
                ),
              ],
            ),
          ],

          if (editing) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: RG.danger,
                side: const BorderSide(color: RG.danger, width: 1.2),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text(
                'Sign out of RailGuard',
                style: TextStyle(
                  fontFamily: defaultFontFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: _confirmSignOut,
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------ UI pieces

  Widget _languageSelector(AppLocalizations l10n) {
    final activeCode = Localizations.localeOf(context).languageCode;
    const options = [
      (Locale('en'), 'English'),
      (Locale('si'), 'සිංහල'),
      (Locale('ta'), 'தமிழ்'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(l10n.labelLanguage),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              for (final (loc, label) in options)
                Expanded(
                  child: GestureDetector(
                    onTap: () => setAppLocale(loc),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        // Selected language highlighted in our theme red color
                        color: activeCode == loc.languageCode
                            ? RG.brand
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: activeCode == loc.languageCode
                            ? [
                                BoxShadow(
                                  color: RG.brand.withValues(alpha: 0.28),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: activeCode == loc.languageCode
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: activeCode == loc.languageCode
                              ? Colors.white
                              : const Color(0xFF334155),
                          fontFamily:
                              fontFamilyForLocale(loc) ?? defaultFontFamily,
                          fontFamilyFallback: scriptFontFallbacks,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!translationsReviewed) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              l10n.unreviewedTranslationNotice,
              style: const TextStyle(
                fontFamily: defaultFontFamily,
                fontSize: 11.5,
                color: Color(0xFF92400E),
                fontWeight: FontWeight.w500,
                fontFamilyFallback: scriptFontFallbacks,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionHeader(String t) => Row(
    children: [
      Text(
        t,
        style: const TextStyle(
          fontFamily: defaultFontFamily,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFF334155),
          letterSpacing: 0.8,
          fontFamilyFallback: scriptFontFallbacks,
        ),
      ),
      const SizedBox(width: 10),
      const Expanded(
        child: Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),
      ),
    ],
  );

  Widget _modernField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    String? Function(String?)? validator,
    String? helperText,
    TextInputType keyboard = TextInputType.text,
    TextCapitalization capitalise = TextCapitalization.none,
    List<TextInputFormatter>? formatters,
    bool obscure = false,
    Widget? suffix,
  }) => TextFormField(
    controller: controller,
    validator: validator,
    keyboardType: keyboard,
    textCapitalization: capitalise,
    inputFormatters: formatters,
    obscureText: obscure,
    scrollPadding: const EdgeInsets.only(bottom: 140),
    style: const TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 14.5,
      fontWeight: FontWeight.w500,
      color: Color(0xFF0F172A),
      fontFamilyFallback: scriptFontFallbacks,
    ),
    onChanged: (_) {
      if (_inlineError != null) setState(() => _inlineError = null);
    },
    decoration: InputDecoration(
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      hintText: hintText,
      hintStyle: const TextStyle(
        fontFamily: defaultFontFamily,
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        color: Color(0xFF64748B),
      ),
      helperText: helperText,
      helperStyle: const TextStyle(
        fontFamily: defaultFontFamily,
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        color: Color(0xFF475569),
      ),
      prefixIcon: Icon(icon, color: const Color(0xFF475569), size: 20),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: RG.brand, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: RG.danger, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: RG.danger, width: 1.6),
      ),
    ),
  );

  Widget _serviceButton(Service s, AppLocalizations l10n) {
    final on = _service == s;
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: () => setState(() => _service = s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: on
              ? RG.brand.withValues(alpha: 0.08)
              : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: on ? RG.brand : const Color(0xFFCBD5E1),
            width: on ? 1.6 : 1.2,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              s == Service.up
                  ? Icons.north_east_rounded
                  : Icons.south_west_rounded,
              color: on ? RG.brand : const Color(0xFF475569),
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.short,
                    style: TextStyle(
                      fontFamily: defaultFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: on ? RG.brand : const Color(0xFF0F172A),
                    ),
                  ),
                  Text(
                    s == Service.up ? l10n.serviceUpDesc : l10n.serviceDownDesc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: defaultFontFamily,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF475569),
                      fontFamilyFallback: scriptFontFallbacks,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Unit ids are document ids: keep them lower case as the driver types.
class LowerCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue _,
    TextEditingValue next,
  ) => next.copyWith(text: next.text.toLowerCase());
}
