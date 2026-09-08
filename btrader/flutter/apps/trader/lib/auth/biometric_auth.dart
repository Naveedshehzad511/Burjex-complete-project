import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Trading-account credentials remembered for biometric re-login.
class SavedCredentials {
  const SavedCredentials(this.login, this.password);
  final String login;
  final String password;
}

/// Lets a client re-login with Face ID / fingerprint (or the device PIN) after
/// signing out, without re-typing their account number and password.
///
/// The credentials live in the platform secure store (iOS Keychain / Android
/// Keystore-backed EncryptedSharedPreferences) and are only handed back after a
/// successful biometric/device-credential check. Signing out does NOT clear
/// them — that's the point; only an explicit "forget" or a failed-account does.
class BiometricAuth {
  BiometricAuth({LocalAuthentication? auth, FlutterSecureStorage? storage})
      : _auth = auth ?? LocalAuthentication(),
        _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  final LocalAuthentication _auth;
  final FlutterSecureStorage _storage;

  static const _kLogin = 'bt_bio_login';
  static const _kPassword = 'bt_bio_password';

  /// True if the device can do a biometric or device-credential check at all.
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Which biometrics are enrolled (Face, fingerprint, iris) — for labelling.
  Future<List<BiometricType>> enrolledTypes() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  /// True once a credential has been remembered on this device.
  Future<bool> hasSaved() async {
    try {
      return await _storage.containsKey(key: _kLogin);
    } catch (_) {
      return false;
    }
  }

  /// Remember a credential for next time (call after a successful manual login,
  /// once the user opts in).
  Future<void> save(String login, String password) async {
    await _storage.write(key: _kLogin, value: login);
    await _storage.write(key: _kPassword, value: password);
  }

  /// Prompt the system biometric/device-credential sheet; on success return the
  /// stored credentials. Returns null if there's nothing saved, the prompt is
  /// cancelled, or it fails.
  Future<SavedCredentials?> authenticateAndRead({
    String reason = 'Sign in to your account',
  }) async {
    if (!await hasSaved()) return null;
    bool ok;
    try {
      ok = await _auth.authenticate(
        localizedReason: reason,
        // biometricOnly:false → the device PIN/pattern is an accepted fallback.
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
    } catch (_) {
      return null;
    }
    if (!ok) return null;
    final login = await _storage.read(key: _kLogin);
    final password = await _storage.read(key: _kPassword);
    if (login == null || password == null) return null;
    return SavedCredentials(login, password);
  }

  /// Forget the remembered credential on this device.
  Future<void> clear() async {
    await _storage.delete(key: _kLogin);
    await _storage.delete(key: _kPassword);
  }
}

final biometricAuthProvider = Provider<BiometricAuth>((_) => BiometricAuth());
