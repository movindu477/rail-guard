// Registration: driver account creation and train setup.
// Shown on first launch, and in edit mode (from the top bar) when changing trains mid-shift.
// Restyled after the modern mobile auth reference design with individual rounded
// input fields, icons, safety terms acceptance, and pill CTA buttons.
//
// The local save is the offline cache; Firestore drivers/{uid} is the authoritative
// profile for other trains to see.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account.dart';
import '../driver.dart';
import '../l10n/app_localizations.dart';
import '../locale_store.dart';
import 'splash.dart';
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
    _email = TextEditingController(text: e?.email ?? (currentUser?.email ?? ''));
    _password = TextEditingController();
    _confirmPassword = TextEditingController();
    _name = TextEditingController(text: e?.driverName ?? '');
    _staff = TextEditingController(text: e?.driverId ?? '');
    _train = TextEditingController(text: e?.trainNo ?? '');
    _unit = TextEditingController(text: e?.unitId ?? defaultUnitId);
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
        // If not already signed in with this email, create Auth account
        if (uid == null || currentUser?.email?.toLowerCase() != userEmail.toLowerCase()) {
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

      // Write authoritative drivers/{uid}
      if (uid != null) {
        await saveDriverToFirestore(uid, p);
      }

      // Update offline local cache
      await saveDriver(p);

      if (!mounted) return;
      setState(() => _saving = false);
      widget.onDone(p);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Sign out?', style: TS.title),
        content: const Text(
          'Are you sure you want to sign out of RailGuard? '
          'You will need your email and password to sign back in.',
          style: TS.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: RG.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: RG.danger,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
        backgroundColor: RG.bg,
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
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: _buildForm(editing: true),
              ),
            ),
          ),
        ),
      );
    }

    final heroHeight = MediaQuery.sizeOf(context).height * 0.38;
    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: SingleChildScrollView(
        child: Stack(
          children: [
            // Top 38% hero photo with gradient scrim
            SizedBox(
              height: heroHeight,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'assets/images/train1.jpg',
                    fit: BoxFit.cover,
                    alignment: const Alignment(0, 0.35),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          splashDark.withValues(alpha: 0.0),
                          splashDark.withValues(alpha: 0.55),
                          splashDark.withValues(alpha: 0.92),
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 46,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'RailGuard',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Sri Lankan Railways driver registration',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: Colors.white.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // White sheet overlapping the photo upward by 28 px
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(top: heroHeight - 28),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 18,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
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
        _languageSelector(l10n),
        const SizedBox(height: 18),
        if (!editing) ...[
          // Mockup Title & Subtitle
          Text(
            l10n.createAccountTitle,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1F2937),
              letterSpacing: -0.2,
              fontFamilyFallback: scriptFontFallbacks,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Sign up with your railway staff credentials to start duty',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 22),

          _sectionLabel('ACCOUNT CREDENTIALS'),
          const SizedBox(height: 8),
          _roundedField(
            controller: _email,
            hintText: 'Enter Your Email',
            icon: Icons.mail_outline_rounded,
            keyboard: TextInputType.emailAddress,
            validator: validateEmail,
          ),
          const SizedBox(height: 12),
          _roundedField(
            controller: _password,
            hintText: 'Password (min 8 characters)',
            icon: Icons.lock_outline_rounded,
            obscure: _obscurePassword,
            validator: validatePassword,
            suffix: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                color: const Color(0xFF9CA3AF),
                size: 21,
              ),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 12),
          _roundedField(
            controller: _confirmPassword,
            hintText: 'Confirm Password',
            icon: Icons.lock_outline_rounded,
            obscure: _obscureConfirm,
            validator: (v) => validateConfirmPassword(v, _password.text),
            suffix: IconButton(
              icon: Icon(
                _obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                color: const Color(0xFF9CA3AF),
                size: 21,
              ),
              onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
          const SizedBox(height: 20),
        ],

        _sectionLabel(l10n.labelDriverDetails),
        const SizedBox(height: 8),
        _roundedField(
          controller: _name,
          hintText: 'Enter Driver Full Name',
          icon: Icons.person_outline_rounded,
          validator: (v) => validateRequired(v, 'Name'),
          capitalise: TextCapitalization.words,
        ),
        const SizedBox(height: 12),
        _roundedField(
          controller: _staff,
          hintText: 'Enter Staff ID (e.g. SLR4821)',
          icon: Icons.badge_outlined,
          validator: (v) => validateRequired(v, 'Staff number'),
        ),
        const SizedBox(height: 20),

        _sectionLabel(l10n.labelTrainAssignment),
        const SizedBox(height: 8),
        _roundedField(
          controller: _train,
          hintText: 'Enter Train Number (e.g. 1005)',
          icon: Icons.train_outlined,
          validator: validateTrainNo,
          keyboard: TextInputType.text,
        ),
        const SizedBox(height: 12),
        _roundedField(
          controller: _unit,
          hintText: 'Unit ID (e.g. unit-01)',
          icon: Icons.memory_rounded,
          validator: validateUnitId,
          helperText: 'Must match detection unit on laptop',
          formatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9-]')),
            LowerCaseFormatter(),
          ],
        ),
        const SizedBox(height: 20),

        _sectionLabel(l10n.labelDirection),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final s in Service.values) ...[
              Expanded(child: _serviceButton(s, l10n)),
              if (s != Service.values.last) const SizedBox(width: 12),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'You are only alerted about hazards and trains running the '
            'same way on the same line.',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        ),



        // Inline Error Banner
        if (_inlineError != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: RG.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: RG.danger.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, color: RG.danger, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _inlineError!,
                    style: TS.small.copyWith(
                      color: RG.danger,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 22),

        // Primary action pill button
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: RG.brand,
              disabledBackgroundColor: RG.brand.withValues(alpha: 0.5),
              elevation: 2,
              shadowColor: RG.brand.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
            ),
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    editing ? l10n.btnSaveChanges : l10n.btnStartDuty,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.2,
                      fontFamilyFallback: scriptFontFallbacks,
                    ),
                  ),
          ),
        ),

        // Mockup divider and bottom link
        if (!editing) ...[

          if (widget.onBackToLogin != null) ...[
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Already have an account? ',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF6B7280),
                  ),
                ),
                GestureDetector(
                  onTap: widget.onBackToLogin,
                  child: const Text(
                    'Sign In',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: RG.brand,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],

        if (editing) ...[
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: RG.danger,
              side: const BorderSide(color: RG.danger, width: 1.2),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            ),
            icon: const Icon(Icons.logout, size: 20),
            label: const Text('Sign out of RailGuard', style: TextStyle(fontWeight: FontWeight.w600)),
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
        _sectionLabel(l10n.labelLanguage),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final (loc, label) in options) ...[
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => setAppLocale(loc),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: activeCode == loc.languageCode
                          ? RG.blue.withValues(alpha: 0.10)
                          : const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: activeCode == loc.languageCode
                            ? RG.blue
                            : const Color(0xFFE5E7EB),
                        width: activeCode == loc.languageCode ? 1.8 : 1.2,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: activeCode == loc.languageCode
                            ? RG.blue
                            : const Color(0xFF1F2937),
                        fontFamily: fontFamilyForLocale(loc),
                        fontFamilyFallback: scriptFontFallbacks,
                      ),
                    ),
                  ),
                ),
              ),
              if (loc != options.last.$1) const SizedBox(width: 8),
            ],
          ],
        ),
        if (!translationsReviewed) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l10n.unreviewedTranslationNotice,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFF92400E),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionLabel(String t) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 2),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Color(0xFF9CA3AF),
        letterSpacing: 0.8,
        fontFamilyFallback: scriptFontFallbacks,
      ),
    ),
  );

  Widget _roundedField({
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
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: Color(0xFF1F2937),
    ),
    onChanged: (_) {
      if (_inlineError != null) setState(() => _inlineError = null);
    },
    decoration: InputDecoration(
      filled: true,
      fillColor: const Color(0xFFF9FAFB),
      hintText: hintText,
      hintStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: Color(0xFF9CA3AF),
      ),
      helperText: helperText,
      helperStyle: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
      prefixIcon: Icon(icon, color: const Color(0xFF9CA3AF), size: 21),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB), width: 1.2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB), width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: RG.brand, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: RG.danger, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: RG.danger, width: 1.6),
      ),
    ),
  );

  Widget _serviceButton(Service s, AppLocalizations l10n) {
    final on = _service == s;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _service = s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: on ? RG.blue.withValues(alpha: 0.08) : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: on ? RG.blue : const Color(0xFFE5E7EB),
            width: on ? 1.8 : 1.2,
          ),
        ),
        child: Column(
          children: [
            Icon(
              s == Service.up ? Icons.north_east_rounded : Icons.south_west_rounded,
              color: on ? RG.blue : const Color(0xFF6B7280),
              size: 22,
            ),
            const SizedBox(height: 6),
            Text(
              s.short,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: on ? RG.blue : const Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              s == Service.up ? l10n.serviceUpDesc : l10n.serviceDownDesc,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF6B7280),
                fontFamilyFallback: scriptFontFallbacks,
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
  TextEditingValue formatEditUpdate(TextEditingValue _, TextEditingValue next) =>
      next.copyWith(text: next.text.toLowerCase());
}
