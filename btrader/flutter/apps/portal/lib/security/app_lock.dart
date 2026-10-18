import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/biometric_auth.dart';
import '../crm/crm.dart';

/// App-level PIN / Face Lock. Device-local: nothing here goes to the server.
///
/// The settings (PIN hash, Face Lock on/off, "security prompt shown") live in the platform secure store, one set
/// PER ACCOUNT (keyed by the CRM user id). Signing out keeps them: the same client signing back in on this phone
/// meets their own PIN / Face Lock again, and another client signing in has their own. Only "Forgot PIN?" and too
/// many wrong PINs remove an account's lock (the password then gets the client back in, to set a new one).
const kPinLength = 6;

/// Wrong PINs in a row before the client is signed out (their password is then needed to get back in).
const kMaxPinAttempts = 5;

/// How long the app may sit in the background before it asks again.
const kLockAfterBackground = Duration(minutes: 1);

/// SharedPreferences key holding the signed-in CRM user's id (written at login, removed at logout).
const kCrmUserKey = 'crm_user_id';

const _kPrefix = 'bx_lock_';
const _kInstallMarker = 'bx_lock_install_marker';

/// The secure-store key of one setting of one account. The id is hashed: no personal data in key names.
String lockStorageKey(String userId, String name) =>
    '$_kPrefix${sha256.convert(utf8.encode(userId)).toString().substring(0, 20)}_$name';

/// Where the settings are kept; a fake one stands in for the Keychain / Keystore in tests.
abstract class LockStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Remove every lock setting of every account (a fresh install must not inherit the previous install's).
  Future<void> deleteAll();
}

class SecureLockStorage implements LockStorage {
  const SecureLockStorage();
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {}
  }

  @override
  Future<void> deleteAll() async {
    try {
      for (final k in (await _s.readAll()).keys) {
        if (k.startsWith(_kPrefix)) await _s.delete(key: k);
      }
    } catch (_) {}
  }
}

/// The PIN is never stored: a random salt and an iterated HMAC of it.
String hashPin(String pin, String salt) {
  List<int> d = utf8.encode('$salt:$pin');
  final key = utf8.encode(salt);
  for (var i = 0; i < 10000; i++) {
    d = Hmac(sha256, key).convert(d).bytes;
  }
  return base64Url.encode(d);
}

bool _sameString(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

String _newSalt() {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]);
}

class AppLockState {
  const AppLockState({
    this.loaded = false,
    this.pinEnabled = false,
    this.faceEnabled = false,
    this.promptDone = false,
    this.locked = false,
    this.biometrics = const [],
  });

  /// The saved settings have been read (until then nothing can be said about the lock).
  final bool loaded;
  final bool pinEnabled;
  final bool faceEnabled;

  /// The first sign-in security screen has been answered (enabled something, or skipped).
  final bool promptDone;

  /// The lock screen is up.
  final bool locked;

  /// The biometrics enrolled on this device (empty: none, or not supported).
  final List<BiometricType> biometrics;

  bool get enabled => pinEnabled || faceEnabled;
  bool get biometricsAvailable => biometrics.isNotEmpty;

  AppLockState copyWith({bool? loaded, bool? pinEnabled, bool? faceEnabled, bool? promptDone, bool? locked, List<BiometricType>? biometrics}) =>
      AppLockState(
        loaded: loaded ?? this.loaded,
        pinEnabled: pinEnabled ?? this.pinEnabled,
        faceEnabled: faceEnabled ?? this.faceEnabled,
        promptDone: promptDone ?? this.promptDone,
        locked: locked ?? this.locked,
        biometrics: biometrics ?? this.biometrics,
      );
}

/// Outcome of checking a typed PIN.
class PinCheck {
  const PinCheck.ok()
      : ok = true,
        signedOut = false,
        remaining = kMaxPinAttempts;
  const PinCheck.wrong(this.remaining)
      : ok = false,
        signedOut = false;
  const PinCheck.signedOut()
      : ok = false,
        signedOut = true,
        remaining = 0;
  final bool ok;
  final bool signedOut;
  final int remaining;
}

class AppLockController extends StateNotifier<AppLockState> {
  AppLockController(
    this._ref, {
    LockStorage storage = const SecureLockStorage(),
    BiometricAuth? bio,
    DateTime Function()? now,
  })  : _store = storage,
        _bio = bio ?? BiometricAuth(),
        _now = now ?? DateTime.now,
        super(const AppLockState()) {
    if (kIsWeb) {
      // No Keychain / Keystore / biometrics in a browser: the lock is an app feature.
      state = const AppLockState(loaded: true, promptDone: true);
    } else {
      _ref.listen<CrmAuthState>(crmSessionProvider, (_, next) => _onSession(next), fireImmediately: true);
    }
  }

  final Ref _ref;
  final LockStorage _store;
  final BiometricAuth _bio;
  final DateTime Function() _now;

  /// The signed-in account the settings belong to (the CRM user id), once known.
  String? _account;
  String? _token;
  int _seq = 0;
  bool _markerChecked = false;
  DateTime? _backgroundAt;
  bool _systemPromptOpen = false;

  String _k(String name) => lockStorageKey(_account ?? '', name);

  /// The session changed (restored at start, signed in, signed out): load the settings of whoever is signed in.
  /// Signed in, with a PIN / Face Lock on that account, means the lock is up - after a fresh sign-in too.
  Future<void> _onSession(CrmAuthState s) async {
    if (s.loading) return;
    if (!s.authenticated) {
      _token = null;
      _account = null;
      _seq++;
      state = const AppLockState();
      return;
    }
    if (s.token == _token && state.loaded) return;
    _token = s.token;
    final seq = ++_seq;
    state = const AppLockState(); // not loaded: the app stays covered until it is known whether to lock
    await _installCheck();
    final account = await _resolveAccount();
    if (!mounted || seq != _seq) return;
    _account = account;
    final pinOn = (await _store.read(_k('pin_hash'))) != null;
    final faceOn = (await _store.read(_k('face'))) == '1';
    final done = (await _store.read(_k('prompt_done'))) == '1' || pinOn || faceOn;
    final types = await _bio.enrolledTypes();
    if (!mounted || seq != _seq) return;
    state = AppLockState(loaded: true, pinEnabled: pinOn, faceEnabled: faceOn, promptDone: done, locked: pinOn || faceOn, biometrics: types);
  }

  /// iOS keeps Keychain items across an uninstall; a fresh install must not inherit the old installs' PINs.
  Future<void> _installCheck() async {
    if (_markerChecked) return;
    _markerChecked = true;
    // Settings written before they were kept per account (one shared set) are of no account: drop them.
    for (final n in const ['pin_hash', 'pin_salt', 'face', 'attempts', 'prompt_done']) {
      await _store.delete('$_kPrefix$n');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_kInstallMarker)) {
        await _store.deleteAll();
        await prefs.setBool(_kInstallMarker, true);
      }
    } catch (_) {}
  }

  /// The CRM user id saved at login; a session older than that (restored from before this existed) asks the CRM once.
  Future<String> _resolveAccount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(kCrmUserKey);
      if (saved != null && saved.isNotEmpty) return saved;
      final res = await _ref.read(crmDioProvider).get('/me/');
      final user = ((res.data as Map)['data'] as Map)['user'] as Map;
      final id = '${user['id'] ?? user['email'] ?? ''}'.toLowerCase();
      if (id.isNotEmpty) {
        await prefs.setString(kCrmUserKey, id);
        return id;
      }
    } catch (_) {}
    return 'unknown';
  }

  /// Re-read what the device can do (the client may have enrolled a face since).
  Future<void> refreshDevice() async {
    final types = await _bio.enrolledTypes();
    if (mounted) state = state.copyWith(biometrics: types);
  }

  // ── PIN ──────────────────────────────────────────────────────────────────

  Future<void> setPin(String pin) async {
    final salt = _newSalt();
    await _store.write(_k('pin_salt'), salt);
    await _store.write(_k('pin_hash'), hashPin(pin, salt));
    await _store.write(_k('attempts'), '0');
    await _store.write(_k('prompt_done'), '1');
    if (mounted) state = state.copyWith(pinEnabled: true, promptDone: true);
  }

  Future<PinCheck> verifyPin(String pin) async {
    final salt = await _store.read(_k('pin_salt'));
    final hash = await _store.read(_k('pin_hash'));
    if (salt == null || hash == null) return const PinCheck.wrong(0);
    if (_sameString(hashPin(pin, salt), hash)) {
      await _store.write(_k('attempts'), '0');
      return const PinCheck.ok();
    }
    final used = (int.tryParse(await _store.read(_k('attempts')) ?? '') ?? 0) + 1;
    await _store.write(_k('attempts'), '$used');
    if (used >= kMaxPinAttempts) {
      await signOut();
      return const PinCheck.signedOut();
    }
    return PinCheck.wrong(kMaxPinAttempts - used);
  }

  Future<void> disablePin() async {
    await _store.delete(_k('pin_hash'));
    await _store.delete(_k('pin_salt'));
    await _store.delete(_k('attempts'));
    if (mounted) state = state.copyWith(pinEnabled: false, locked: state.faceEnabled ? state.locked : false);
  }

  // ── Face Lock ────────────────────────────────────────────────────────────

  /// Turn Face Lock on after the device itself has recognised the client. False when the device has no
  /// biometrics enrolled or the check failed / was cancelled.
  Future<bool> enableFace() async {
    await refreshDevice();
    if (!state.biometricsAvailable) return false;
    if (!await _authenticate('Confirm it is you to turn on Face Lock', biometricOnly: true)) return false;
    await _store.write(_k('face'), '1');
    await _store.write(_k('prompt_done'), '1');
    if (mounted) state = state.copyWith(faceEnabled: true, promptDone: true);
    return true;
  }

  Future<void> disableFace() async {
    await _store.delete(_k('face'));
    if (mounted) state = state.copyWith(faceEnabled: false, locked: state.pinEnabled ? state.locked : false);
  }

  /// The device's own check (face / fingerprint; its screen-lock code is the fallback). True when it passes.
  Future<bool> authenticateWithDevice(String reason) => _authenticate(reason, biometricOnly: false);

  Future<bool> _authenticate(String reason, {required bool biometricOnly}) async {
    _systemPromptOpen = true;
    try {
      return await _bio.authenticate(reason: reason, biometricOnly: biometricOnly);
    } finally {
      _systemPromptOpen = false;
      _backgroundAt = null; // the sheet pausing the app is not the app being left
    }
  }

  /// Lock-screen unlock with the face / fingerprint.
  Future<bool> unlockWithFace() async {
    if (!state.faceEnabled) return false;
    final ok = await _authenticate('Unlock Burjex Prime', biometricOnly: false);
    if (ok) _setLocked(false);
    return ok;
  }

  void unlock() => _setLocked(false);

  void _setLocked(bool v) {
    if (mounted && state.locked != v) state = state.copyWith(locked: v);
  }

  Future<void> markPromptDone() async {
    await _store.write(_k('prompt_done'), '1');
    if (mounted) state = state.copyWith(promptDone: true);
  }

  // ── Lock timing ──────────────────────────────────────────────────────────

  void onBackground() {
    if (_systemPromptOpen) return;
    _backgroundAt = _now();
  }

  void onForeground() {
    final at = _backgroundAt;
    _backgroundAt = null;
    if (at == null || !state.enabled || _systemPromptOpen) return;
    if (_now().difference(at) >= kLockAfterBackground) _setLocked(true);
  }

  /// "Forgot PIN?" and the last wrong attempt: remove this account's PIN / Face Lock and sign out; the password
  /// gets the client back in, and the security screen then offers a new PIN.
  Future<void> signOut() async {
    for (final n in const ['pin_hash', 'pin_salt', 'attempts', 'face', 'prompt_done']) {
      await _store.delete(_k(n));
    }
    await _ref.read(crmSessionProvider.notifier).logout();
  }
}

final appLockProvider = StateNotifierProvider<AppLockController, AppLockState>((ref) => AppLockController(ref));
