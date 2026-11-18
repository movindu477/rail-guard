/// Firebase Authentication wrapper: handles sign in, registration, sign out,
/// password reset, and user-friendly error mapping for drivers.
///
/// Pure functions (like error code mapping and validation) have no Flutter/Firebase
/// dependency and are unit tested in test/account_test.dart.
library;

import 'package:firebase_auth/firebase_auth.dart';

/// Current authenticated user UID, or null if signed out.
String? get currentUid => FirebaseAuth.instance.currentUser?.uid;

/// Current authenticated Firebase user, or null if signed out.
User? get currentUser => FirebaseAuth.instance.currentUser;

/// True if a user is currently signed in.
bool get isSignedIn => FirebaseAuth.instance.currentUser != null;

/// User-friendly messages for FirebaseAuthException error codes.
/// Keeps error messages short, clear, and actionable in a locomotive cab.
String authCodeToMessage(String code) {
  switch (code) {
    case 'wrong-password':
      return 'Incorrect password. Please try again.';
    case 'invalid-credential':
      return 'Incorrect email or password. Please try again.';
    case 'user-not-found':
      return 'No account found for this email.';
    case 'email-already-in-use':
      return 'An account already exists for this email.';
    case 'weak-password':
      return 'Password is too weak. It must be at least 8 characters.';
    case 'invalid-email':
      return 'Please enter a valid email address.';
    case 'network-request-failed':
      return 'Network error. Check your phone’s connection.';
    case 'too-many-requests':
      return 'Too many failed attempts. Please try again in a few minutes.';
    case 'user-disabled':
      return 'This account has been disabled. Contact administration.';
    case 'operation-not-allowed':
      return 'Email/password sign-in is not enabled.';
    case 'requires-recent-login':
      return 'Please sign in again before continuing.';
    case 'channel-error':
      return 'Please enter both email and password.';
    default:
      return 'Authentication failed. Please check your details.';
  }
}

/// Converts any auth error to a readable driver-facing message.
String authErrorMessage(Object error) {
  if (error is FirebaseAuthException) {
    return authCodeToMessage(error.code);
  }
  if (error is AuthException) {
    return error.message;
  }
  return 'Authentication error. Please try again.';
}

class AuthException implements Exception {
  final String message;
  final String? code;
  const AuthException(this.message, {this.code});
  @override
  String toString() => message;
}

/// Signs in an existing driver with email and password.
Future<UserCredential> signIn(String email, String password) async {
  try {
    return await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  } on FirebaseAuthException catch (e) {
    throw AuthException(authCodeToMessage(e.code), code: e.code);
  } catch (e) {
    throw const AuthException('Failed to sign in. Check your connection.');
  }
}

/// Registers a new driver account with email and password.
Future<UserCredential> register(String email, String password) async {
  try {
    return await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  } on FirebaseAuthException catch (e) {
    throw AuthException(authCodeToMessage(e.code), code: e.code);
  } catch (e) {
    throw const AuthException('Failed to create account. Check your connection.');
  }
}

/// Signs out the current driver.
Future<void> signOut() async {
  await FirebaseAuth.instance.signOut();
}

/// Sends a password reset email.
Future<void> sendReset(String email) async {
  try {
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
  } on FirebaseAuthException catch (e) {
    throw AuthException(authCodeToMessage(e.code), code: e.code);
  } catch (e) {
    throw const AuthException('Failed to send reset email. Check your connection.');
  }
}

// ------------------------------------------------------------ validators

/// Validates email format.
String? validateEmail(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Email is required';
  final emailRegex = RegExp(
    r'^[a-zA-Z0-9.!#$%&’*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$',
  );
  if (!emailRegex.hasMatch(s)) return 'Enter a valid email address';
  return null;
}

/// Validates password length (at least 8 characters).
String? validatePassword(String? v) {
  final s = v ?? '';
  if (s.isEmpty) return 'Password is required';
  if (s.length < 8) return 'Password must be at least 8 characters';
  return null;
}

/// Validates that confirmation password matches the primary password.
String? validateConfirmPassword(String? v, String password) {
  final s = v ?? '';
  if (s.isEmpty) return 'Please confirm your password';
  if (s != password) return 'Passwords do not match';
  return null;
}
