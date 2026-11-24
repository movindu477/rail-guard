// Login screen: email and password authentication with Firebase Auth.
// Structured into two distinct sections: the top train2.jpg photo section with
// a left-aligned title and description, and the bottom form section with a
// 50px top border radius and crisp Poppins typography.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account.dart';
import '../driver.dart';
import '../l10n/app_localizations.dart';
import '../locale_store.dart';
import 'theme.dart';

class LoginScreen extends StatefulWidget {
  final ValueChanged<DriverProfile> onLoggedIn;
  final VoidCallback onGoToRegister;

  const LoginScreen({
    super.key,
    required this.onLoggedIn,
    required this.onGoToRegister,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _rememberedEmailKey = 'remembered_login_email';
  static const _rememberMeKey = 'remember_me_preference';

  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;
  bool _rememberMe = true;
  String? _inlineError;
  String? _inlineInfo;

  @override
  void initState() {
    super.initState();
    _loadRememberedEmail();
  }

  Future<void> _loadRememberedEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool(_rememberMeKey) ?? true;
      final savedEmail = prefs.getString(_rememberedEmailKey) ?? '';
      if (mounted) {
        setState(() {
          _rememberMe = remember;
          if (remember && savedEmail.isNotEmpty) {
            _email.text = savedEmail;
          }
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading || !(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _inlineError = null;
      _inlineInfo = null;
    });

    try {
      final emailText = _email.text.trim();
      final cred = await signIn(emailText, _password.text);
      final uid = cred.user!.uid;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rememberMeKey, _rememberMe);
      if (_rememberMe) {
        await prefs.setString(_rememberedEmailKey, emailText);
      } else {
        await prefs.remove(_rememberedEmailKey);
      }

      DriverProfile? profile = await fetchDriverFromFirestore(uid);
      profile ??= await loadDriver();

      if (profile != null) {
        await saveDriver(profile);
        if (!mounted) return;
        widget.onLoggedIn(profile);
      } else {
        if (!mounted) return;
        widget.onGoToRegister();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _inlineError = authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final resetEmail = TextEditingController(text: _email.text.trim());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RG.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Reset password', style: TS.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your email address to receive a password reset link.',
              style: TS.body,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: resetEmail,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              style: TS.bodyStrong,
              decoration: InputDecoration(
                prefixIcon: const Icon(
                  Icons.mail_outline_rounded,
                  color: Color(0xFF64748B),
                  size: 20,
                ),
                hintText: 'name@railway.gov.lk',
                hintStyle: const TextStyle(
                  fontFamily: defaultFontFamily,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF64748B),
                ),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: RG.brand, width: 1.5),
                ),
              ),
            ),
          ],
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
              backgroundColor: RG.brand,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send link', style: TS.button),
          ),
        ],
      ),
    );

    if (confirmed == true && resetEmail.text.trim().isNotEmpty) {
      try {
        await sendReset(resetEmail.text.trim());
        if (!mounted) return;
        setState(() {
          _inlineError = null;
          _inlineInfo =
              'Password reset email sent to ${resetEmail.text.trim()}.';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _inlineInfo = null;
          _inlineError = authErrorMessage(e);
        });
      }
    }
    resetEmail.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewportHeight = constraints.maxHeight;
          // Top image section height (~45% of screen), overlapped by 48px
          // so the two sections meet with a 50px top border radius.
          final imageHeight =
              (viewportHeight * 0.46).clamp(260.0, 430.0);
          const double overlap = 46.0;
          final minCardHeight =
              (viewportHeight - imageHeight + overlap).clamp(360.0, 900.0);

          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: viewportHeight),
              child: Stack(
                children: [
                  // Section 1: Top Image Section (train2.jpg, no black opacity)
                  // with Title and Description on the left side.
                  SizedBox(
                    height: imageHeight,
                    width: double.infinity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.asset(
                          'assets/images/train2.jpg',
                          fit: BoxFit.cover,
                          alignment: const Alignment(0, 0.15),
                        ),
                        Positioned(
                          left: 24,
                          right: 24,
                          bottom: overlap + 18,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'RailGuard',
                                style: TextStyle(
                                  fontFamily: defaultFontFamily,
                                  fontSize: 30,
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
                              const SizedBox(height: 3),
                              Text(
                                'Obstacle warning & live railway safety console',
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
                    constraints: BoxConstraints(minHeight: minCardHeight),
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
                    padding: const EdgeInsets.fromLTRB(26, 30, 26, 20),
                    child: SafeArea(
                      top: false,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Form(
                            key: _form,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  l10n.signInTitle,
                                  style: const TextStyle(
                                    fontFamily: defaultFontFamily,
                                    fontSize: 23,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F172A),
                                    letterSpacing: -0.2,
                                    fontFamilyFallback: scriptFontFallbacks,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  l10n.signInSubtitle,
                                  style: const TextStyle(
                                    fontFamily: defaultFontFamily,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF475569),
                                    fontFamilyFallback: scriptFontFallbacks,
                                  ),
                                ),
                                const SizedBox(height: 20),

                                // Email field
                                _fieldLabel('Email'),
                                const SizedBox(height: 6),
                                _modernField(
                                  controller: _email,
                                  hintText: 'Enter your email',
                                  icon: Icons.mail_outline_rounded,
                                  keyboard: TextInputType.emailAddress,
                                  validator: validateEmail,
                                ),
                                const SizedBox(height: 14),

                                // Password field
                                _fieldLabel('Password'),
                                const SizedBox(height: 6),
                                _modernField(
                                  controller: _password,
                                  hintText: 'Enter your password',
                                  icon: Icons.lock_outline_rounded,
                                  obscure: _obscurePassword,
                                  validator: (v) => (v == null || v.isEmpty)
                                      ? 'Password is required'
                                      : null,
                                  suffix: IconButton(
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      color: const Color(0xFF64748B),
                                      size: 20,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscurePassword =
                                          !_obscurePassword,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Remember me + Forgot Password row
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(6),
                                      onTap: () => setState(
                                        () => _rememberMe = !_rememberMe,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              width: 19,
                                              height: 19,
                                              child: Checkbox(
                                                value: _rememberMe,
                                                activeColor: RG.brand,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                side: const BorderSide(
                                                  color: Color(0xFF94A3B8),
                                                  width: 1.5,
                                                ),
                                                onChanged: (v) => setState(
                                                  () =>
                                                      _rememberMe = v ?? true,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            const Text(
                                              'Remember me',
                                              style: TextStyle(
                                                fontFamily: defaultFontFamily,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w500,
                                                color: Color(0xFF334155),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 4,
                                        ),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      onPressed: _handleForgotPassword,
                                      child: const Text(
                                        'Forgot password?',
                                        style: TextStyle(
                                          fontFamily: defaultFontFamily,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: RG.brand,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),

                                // Inline Error Banner
                                if (_inlineError != null) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          RG.danger.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color:
                                            RG.danger.withValues(alpha: 0.30),
                                      ),
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

                                // Inline Info Banner
                                if (_inlineInfo != null) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: RG.blue.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: RG.blue.withValues(alpha: 0.30),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.check_circle_outline_rounded,
                                          color: RG.blue,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _inlineInfo!,
                                            style: TS.small.copyWith(
                                              color: RG.blue,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 18),

                                // Primary Sign In CTA button
                                SizedBox(
                                  height: 50,
                                  child: FilledButton(
                                    onPressed: _loading ? null : _submit,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: RG.brand,
                                      disabledBackgroundColor:
                                          RG.brand.withValues(alpha: 0.5),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: _loading
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : Text(
                                            l10n.btnSignIn,
                                            style: const TextStyle(
                                              fontFamily: defaultFontFamily,
                                              fontSize: 15.5,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.white,
                                              letterSpacing: 0.3,
                                              fontFamilyFallback:
                                                  scriptFontFallbacks,
                                            ),
                                          ),
                                  ),
                                ),

                                const SizedBox(height: 16),

                                // Compact bottom footer link
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Text(
                                      "Don't have an account? ",
                                      style: TextStyle(
                                        fontFamily: defaultFontFamily,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: widget.onGoToRegister,
                                      child: const Text(
                                        'Create account',
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
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _fieldLabel(String label) => Text(
    label,
    style: const TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF1E293B),
      fontFamilyFallback: scriptFontFallbacks,
    ),
  );

  Widget _modernField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    String? Function(String?)? validator,
    TextInputType keyboard = TextInputType.text,
    bool obscure = false,
    Widget? suffix,
  }) => TextFormField(
    controller: controller,
    validator: validator,
    keyboardType: keyboard,
    obscureText: obscure,
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
}
