// Login screen: email and password authentication with Firebase Auth.
// Restyled after the modern mobile auth reference design:
// individual rounded input fields with icons, Remember Me toggle,
// Forgot Password action, pill CTA button, and alternative auth options.
// Errors are rendered inline under the fields so the driver can read them calmly.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account.dart';
import '../driver.dart';
import '../l10n/app_localizations.dart';
import '../locale_store.dart';
import 'splash.dart';
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

      // Remember me preference persistence
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rememberMeKey, _rememberMe);
      if (_rememberMe) {
        await prefs.setString(_rememberedEmailKey, emailText);
      } else {
        await prefs.remove(_rememberedEmailKey);
      }

      // Authoritative profile from Firestore
      DriverProfile? profile = await fetchDriverFromFirestore(uid);
      profile ??= await loadDriver();

      if (profile != null) {
        await saveDriver(profile);
        if (!mounted) return;
        widget.onLoggedIn(profile);
      } else {
        // Authenticated but no profile saved yet -> send to Register to complete details
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                prefixIcon: const Icon(Icons.mail_outline_rounded, color: Color(0xFF9CA3AF), size: 22),
                hintText: 'Enter Your Email',
                filled: true,
                fillColor: const Color(0xFFF9FAFB),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: RG.brand, width: 1.6),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: RG.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: RG.brand,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
          _inlineInfo = 'Password reset email sent to ${resetEmail.text.trim()}.';
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
    final heroHeight = MediaQuery.sizeOf(context).height * 0.38;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: SingleChildScrollView(
        child: Stack(
          children: [
            // Top 38% hero photo with dark gradient scrim
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
                          'Obstacle warning & live safety console',
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
            // White sheet overlapping hero upward by 28 px
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
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Card header matching design reference
                          Text(
                            l10n.signInTitle,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1F2937),
                              letterSpacing: -0.2,
                              fontFamilyFallback: scriptFontFallbacks,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.signInSubtitle,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF6B7280),
                              fontFamilyFallback: scriptFontFallbacks,
                            ),
                          ),
                          const SizedBox(height: 22),

                          // Email field - individual rounded input box
                          _roundedField(
                            controller: _email,
                            hintText: 'Enter Your Email',
                            icon: Icons.mail_outline_rounded,
                            keyboard: TextInputType.emailAddress,
                            validator: validateEmail,
                          ),
                          const SizedBox(height: 14),

                          // Password field - individual rounded input box with eye toggle
                          _roundedField(
                            controller: _password,
                            hintText: 'Enter Your Password',
                            icon: Icons.lock_outline_rounded,
                            obscure: _obscurePassword,
                            validator: (v) =>
                                (v == null || v.isEmpty) ? 'Password is required' : null,
                            suffix: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                color: const Color(0xFF9CA3AF),
                                size: 21,
                              ),
                              onPressed: () =>
                                  setState(() => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          const SizedBox(height: 14),

                          // Controls row: "Remember me" checkbox + "Forgot Password?"
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: Checkbox(
                                      value: _rememberMe,
                                      activeColor: RG.brand,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      side: const BorderSide(
                                        color: Color(0xFFD1D5DB),
                                        width: 1.5,
                                      ),
                                      onChanged: (v) =>
                                          setState(() => _rememberMe = v ?? true),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _rememberMe = !_rememberMe),
                                    child: const Text(
                                      'Remember me',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF4B5563),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              GestureDetector(
                                onTap: _handleForgotPassword,
                                child: const Text(
                                  'Forgot Password?',
                                  style: TextStyle(
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
                            const SizedBox(height: 14),
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

                          // Inline Info Banner
                          if (_inlineInfo != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                              decoration: BoxDecoration(
                                color: RG.blue.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: RG.blue.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.check_circle_outline_rounded, color: RG.blue, size: 20),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _inlineInfo!,
                                      style: TS.small.copyWith(
                                        color: RG.blue,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          const SizedBox(height: 22),

                          // Primary action pill button (matching mockup)
                          SizedBox(
                            height: 52,
                            child: FilledButton(
                              onPressed: _loading ? null : _submit,
                              style: FilledButton.styleFrom(
                                backgroundColor: RG.brand,
                                disabledBackgroundColor: RG.brand.withValues(alpha: 0.5),
                                elevation: 2,
                                shadowColor: RG.brand.withValues(alpha: 0.4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                              ),
                              child: _loading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(
                                      l10n.btnSignIn,
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



                          const SizedBox(height: 22),

                          // Bottom footer prompt: "Don't have an account? Sign Up"
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                "Don't have an account? ",
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                              GestureDetector(
                                onTap: widget.onGoToRegister,
                                child: const Text(
                                  'Sign Up',
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
  }

  // Individual rounded input box with border and icons
  Widget _roundedField({
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


}
