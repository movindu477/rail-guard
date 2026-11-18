// Account error mapping and credential validation tests.
// Pure Dart, runs offline with `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/account.dart';

void main() {
  group('authCodeToMessage', () {
    test('wrong-password produces actionable message', () {
      final msg = authCodeToMessage('wrong-password');
      expect(msg.toLowerCase(), contains('password'));
      expect(msg, isNot(contains('FirebaseAuthException')));
    });

    test('invalid-credential handles modern Auth errors', () {
      final msg = authCodeToMessage('invalid-credential');
      expect(msg.toLowerCase(), contains('email or password'));
    });

    test('user-not-found produces actionable message', () {
      final msg = authCodeToMessage('user-not-found');
      expect(msg.toLowerCase(), contains('no account found'));
    });

    test('email-already-in-use warns driver', () {
      final msg = authCodeToMessage('email-already-in-use');
      expect(msg.toLowerCase(), contains('already exists'));
    });

    test('weak-password instructs at least 8 characters', () {
      final msg = authCodeToMessage('weak-password');
      expect(msg, contains('8 characters'));
    });

    test('network-request-failed mentions connection', () {
      final msg = authCodeToMessage('network-request-failed');
      expect(msg.toLowerCase(), contains('network error'));
    });

    test('invalid-email instructs valid email', () {
      final msg = authCodeToMessage('invalid-email');
      expect(msg.toLowerCase(), contains('valid email'));
    });

    test('unknown codes give safe fallback without raw code exposure', () {
      final msg = authCodeToMessage('some-future-code-1234');
      expect(msg, isNot(contains('some-future-code-1234')));
      expect(msg.toLowerCase(), contains('authentication failed'));
    });
  });

  group('validation', () {
    test('validateEmail requires non-empty standard email', () {
      expect(validateEmail(''), isNotNull);
      expect(validateEmail('   '), isNotNull);
      expect(validateEmail('notanemail'), isNotNull);
      expect(validateEmail('driver@'), isNotNull);
      expect(validateEmail('driver@slr'), isNotNull);
      expect(validateEmail('driver@railway.gov.lk'), isNull);
      expect(validateEmail('driver1005@gmail.com'), isNull);
    });

    test('validatePassword requires at least 8 characters', () {
      expect(validatePassword(''), isNotNull);
      expect(validatePassword('1234567'), isNotNull);
      expect(validatePassword('12345678'), isNull);
      expect(validatePassword('secretPass123'), isNull);
    });

    test('validateConfirmPassword enforces matching', () {
      expect(validateConfirmPassword('', 'password123'), isNotNull);
      expect(validateConfirmPassword('password124', 'password123'), isNotNull);
      expect(validateConfirmPassword('password123', 'password123'), isNull);
    });
  });
}
