import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../crm/crm.dart';
import '../security/app_lock.dart';
import '../widgets/portal_ui.dart';

const _kGreen = Color(0xFF22C55E);

/// "Face ID" on an iPhone, "Face Lock" elsewhere (an Android phone uses whatever face / fingerprint it has enrolled).
String faceLockLabel() => defaultTargetPlatform == TargetPlatform.iOS ? 'Face ID' : 'Face Lock';

/// What the enrolled biometrics are, in words.
String _biometricWords(List<BiometricType> t) {
  final face = t.contains(BiometricType.face);
  final finger = t.contains(BiometricType.fingerprint);
  if (face && finger) return 'face or fingerprint';
  if (face) return 'face';
  if (finger) return 'fingerprint';
  return 'device biometrics';
}

// ── PIN entry ───────────────────────────────────────────────────────────────

/// Dots + keypad. [onCompleted] gets the full PIN and returns the error to show, or null when it was accepted
/// (the caller then moves on). The entry clears itself after every attempt.
class PinEntryView extends StatefulWidget {
  const PinEntryView({super.key, required this.title, this.subtitle, required this.onCompleted, this.footer});
  final String title;
  final String? subtitle;
  final Future<String?> Function(String pin) onCompleted;
  final Widget? footer;

  @override
  State<PinEntryView> createState() => _PinEntryViewState();
}

class _PinEntryViewState extends State<PinEntryView> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= kPinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == kPinLength) {
      setState(() => _busy = true);
      final err = await widget.onCompleted(_pin);
      if (!mounted) return;
      setState(() {
        _pin = '';
        _error = err;
        _busy = false;
      });
    }
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      // The keypad follows the width (and the height on a short screen) instead of fixed sizes.
      final pad = box.maxWidth.clamp(0.0, 360.0);
      final key = ((pad - 32) / 3).clamp(52.0, 88.0);
      final byHeight = box.hasBoundedHeight ? (box.maxHeight - 230) / 4 : key;
      final k = key < byHeight ? key : byHeight.clamp(44.0, 88.0);
      Widget keyBtn(String label, {VoidCallback? onTap, IconData? icon}) => SizedBox(
            width: k,
            height: k,
            child: Material(
              color: label.isEmpty && icon == null ? Colors.transparent : cs.onSurface.withValues(alpha: 0.07),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: label.isEmpty && icon == null ? null : onTap,
                child: Center(
                  child: icon != null
                      ? Icon(icon, size: k * 0.34)
                      : Text(label, style: TextStyle(fontSize: k * 0.4, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          );
      Widget row(List<Widget> c) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final w in c) Padding(padding: const EdgeInsets.symmetric(horizontal: 9), child: w)]),
          );
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.hasBoundedHeight ? box.maxHeight : 0),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(height: 12),
            Icon(Icons.lock_outline, size: 36, color: cs.primary),
            const SizedBox(height: 14),
            Text(widget.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(widget.subtitle!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: Theme.of(context).hintColor)),
              ),
            ],
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < kPinLength; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? cs.primary : Colors.transparent,
                    border: Border.all(color: _error != null ? const Color(0xFFE5484D) : cs.primary, width: 1.6),
                  ),
                ),
            ]),
            SizedBox(
              height: 40,
              child: Center(
                child: _error == null
                    ? null
                    : Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE5484D), fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            for (final r in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              row([for (final d in r) keyBtn(d, onTap: () => _digit(d))]),
            row([keyBtn(''), keyBtn('0', onTap: () => _digit('0')), keyBtn('', icon: Icons.backspace_outlined, onTap: _back)]),
            if (widget.footer != null) ...[const SizedBox(height: 6), widget.footer!],
            const SizedBox(height: 12),
          ]),
        ),
      );
    });
  }
}

// ── Lock screen ─────────────────────────────────────────────────────────────

/// Covers the whole app while it is locked. It lives above the router's Navigator, so it uses no dialogs: the
/// "sign out" confirmation is inline.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});
  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _confirmSignOut = false;
  String? _faceError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted && ref.read(appLockProvider).faceEnabled) _face();
    });
  }

  Future<void> _face() async {
    setState(() => _faceError = null);
    final ok = await ref.read(appLockProvider.notifier).unlockWithFace();
    if (mounted && !ok) setState(() => _faceError = '${faceLockLabel()} did not match. Try again.');
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(appLockProvider);
    final ctrl = ref.read(appLockProvider.notifier);
    final face = lock.faceEnabled;
    Widget signOutPanel() => Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: InfoCard(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(lock.pinEnabled ? 'Forgot your PIN?' : 'Sign out?', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 6),
              Text(lock.pinEnabled
                      ? 'You will be signed out and your PIN removed. Sign in again with your email and password, then set a new PIN.'
                      : 'You will be signed out and ${faceLockLabel()} turned off. Sign in again with your email and password to set it up again.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => setState(() => _confirmSignOut = false), child: const Text('Cancel'))),
                const SizedBox(width: 10),
                Expanded(child: FilledButton(onPressed: ctrl.signOut, style: navyButton(), child: const Text('Sign out'))),
              ]),
            ]),
          ),
        );
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _confirmSignOut
            ? Center(child: signOutPanel())
            : lock.pinEnabled
                ? PinEntryView(
                    title: 'Enter your PIN',
                    subtitle: face ? 'Or use ${faceLockLabel()}' : 'Burjex Prime is locked',
                    onCompleted: (pin) async {
                      final r = await ctrl.verifyPin(pin);
                      if (r.ok) {
                        ctrl.unlock();
                        return null;
                      }
                      if (r.signedOut) return 'Too many wrong attempts. Signing you out…';
                      return 'Wrong PIN. ${r.remaining} ${r.remaining == 1 ? 'attempt' : 'attempts'} left.';
                    },
                    footer: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      if (face) TextButton.icon(onPressed: _face, icon: const Icon(Icons.face_outlined, size: 20), label: Text('Use ${faceLockLabel()}')),
                      // "Forgot PIN?" hidden for now (the flow behind it is kept); uncomment to offer it again.
                      // TextButton(onPressed: () => setState(() => _confirmSignOut = true), child: const Text('Forgot PIN?')),
                    ]),
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.lock_outline, size: 44, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 14),
                        const Text('Burjex Prime is locked', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Text('Unlock with ${faceLockLabel()}.', style: TextStyle(color: Theme.of(context).hintColor)),
                        if (_faceError != null) ...[
                          const SizedBox(height: 10),
                          Text(_faceError!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE5484D), fontWeight: FontWeight.w600)),
                        ],
                        const SizedBox(height: 22),
                        FilledButton.icon(onPressed: _face, style: navyButton(), icon: const Icon(Icons.face_outlined), label: Text('Unlock with ${faceLockLabel()}')),
                        TextButton(onPressed: () => setState(() => _confirmSignOut = true), child: const Text('Sign out')),
                      ]),
                    ),
                  ),
      ),
    );
  }
}

/// Puts [LockScreen] over the app while it is locked, and starts the "ask again after a minute away" clock.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final c = ref.read(appLockProvider.notifier);
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) c.onBackground();
    if (s == AppLifecycleState.resumed) c.onForeground();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return widget.child;
    final lock = ref.watch(appLockProvider);
    final authed = ref.watch(crmSessionProvider.select((s) => s.authenticated));
    // Until the saved settings are read (a split second at start) the app is covered, so nothing flashes by.
    final cover = authed && !lock.loaded;
    return Stack(children: [
      widget.child,
      if (authed && lock.locked) const Positioned.fill(child: LockScreen()),
      if (cover) Positioned.fill(child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor)),
    ]);
  }
}

// ── PIN set-up / identity check pages ───────────────────────────────────────

/// Set a new PIN (enter, then confirm). With [verifyFirst] the current PIN is asked for before anything else.
class PinSetupPage extends ConsumerStatefulWidget {
  const PinSetupPage({super.key, this.verifyFirst = false});
  final bool verifyFirst;
  @override
  ConsumerState<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends ConsumerState<PinSetupPage> {
  late int _step = widget.verifyFirst ? 0 : 1; // 0 current, 1 new, 2 confirm
  String _first = '';
  String? _notice;

  @override
  Widget build(BuildContext context) {
    final ctrl = ref.read(appLockProvider.notifier);
    final changing = widget.verifyFirst;
    final Widget body;
    switch (_step) {
      case 0:
        body = PinEntryView(
          key: const ValueKey(0),
          title: 'Enter your current PIN',
          onCompleted: (pin) async {
            final r = await ctrl.verifyPin(pin);
            if (r.ok) {
              setState(() => _step = 1);
              return null;
            }
            return r.signedOut ? 'Too many wrong attempts. Signing you out…' : 'Wrong PIN. ${r.remaining} ${r.remaining == 1 ? 'attempt' : 'attempts'} left.';
          },
        );
      case 1:
        body = PinEntryView(
          key: const ValueKey(1),
          title: changing ? 'Enter a new PIN' : 'Create your PIN',
          subtitle: _notice ?? 'Choose $kPinLength digits',
          onCompleted: (pin) async {
            _first = pin;
            setState(() => _step = 2);
            return null;
          },
        );
      default:
        body = PinEntryView(
          key: const ValueKey(2),
          title: 'Confirm your PIN',
          subtitle: 'Enter the same $kPinLength digits again',
          onCompleted: (pin) async {
            if (pin != _first) {
              setState(() {
                _step = 1;
                _notice = 'The two PINs did not match. Try again.';
              });
              return null;
            }
            await ctrl.setPin(pin);
            if (mounted) Navigator.of(context).pop(true);
            return null;
          },
        );
    }
    return Scaffold(
      appBar: AppBar(title: Text(changing ? 'Change PIN' : 'PIN Lock')),
      body: SafeArea(child: body),
    );
  }
}

/// Asks for the PIN before a security setting is changed. True when it is right.
class _PinVerifyPage extends ConsumerWidget {
  const _PinVerifyPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(appLockProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm it is you')),
      body: SafeArea(
        child: PinEntryView(
          title: 'Enter your PIN',
          onCompleted: (pin) async {
            final r = await ctrl.verifyPin(pin);
            if (r.ok) {
              if (context.mounted) Navigator.of(context).pop(true);
              return null;
            }
            return r.signedOut ? 'Too many wrong attempts. Signing you out…' : 'Wrong PIN. ${r.remaining} ${r.remaining == 1 ? 'attempt' : 'attempts'} left.';
          },
        ),
      ),
    );
  }
}

/// Authenticate before changing or turning off a security method: the PIN when there is one, else the device's
/// face / fingerprint. True when the client passed (or there is nothing to pass).
Future<bool> confirmIdentity(BuildContext context, WidgetRef ref) async {
  final lock = ref.read(appLockProvider);
  if (lock.pinEnabled) {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const _PinVerifyPage()));
    return ok == true;
  }
  if (lock.faceEnabled) return ref.read(appLockProvider.notifier).authenticateWithDevice('Confirm it is you to change security settings');
  return true;
}

// ── First sign-in prompt ────────────────────────────────────────────────────

/// Shown once after the first sign-in: Enable Face Lock, Enable PIN, or Skip (both can be done later in Profile).
class SecuritySetupScreen extends ConsumerStatefulWidget {
  const SecuritySetupScreen({super.key});
  @override
  ConsumerState<SecuritySetupScreen> createState() => _SecuritySetupScreenState();
}

class _SecuritySetupScreenState extends ConsumerState<SecuritySetupScreen> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(appLockProvider.notifier).refreshDevice();
  }

  Future<void> _done() async {
    await ref.read(appLockProvider.notifier).markPromptDone();
    if (mounted) context.go('/home');
  }

  Future<void> _face() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref.read(appLockProvider.notifier).enableFace();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      context.go('/home');
    } else {
      setState(() => _error = '${faceLockLabel()} was not turned on. Check that a face or fingerprint is set up on this phone.');
    }
  }

  Future<void> _pin() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const PinSetupPage()));
    if (ok == true && mounted) context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(appLockProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              children: [
                Icon(Icons.shield_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                const Text('Secure your account', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('Protect Burjex Prime so only you can open it. This is optional, and you can change it any time in Profile.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, height: 1.4, color: Theme.of(context).hintColor)),
                const SizedBox(height: 28),
                if (lock.biometricsAvailable) ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : _face,
                    style: navyButton(),
                    icon: const Icon(Icons.face_outlined),
                    label: const Text('Enable Face Lock'),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _busy ? null : _pin,
                  style: navyButton(),
                  icon: const Icon(Icons.pin_outlined),
                  label: const Text('Enable PIN'),
                ),
                if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
                const SizedBox(height: 8),
                TextButton(onPressed: _busy ? null : _done, child: const Text('Skip')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Profile ─────────────────────────────────────────────────────────────────

/// Profile → Security: PIN Lock and Face Lock, each with its status and Enable / Change / Disable.
class SecuritySettingsCard extends ConsumerStatefulWidget {
  const SecuritySettingsCard({super.key});
  @override
  ConsumerState<SecuritySettingsCard> createState() => _SecuritySettingsCardState();
}

class _SecuritySettingsCardState extends ConsumerState<SecuritySettingsCard> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(appLockProvider.notifier).refreshDevice();
  }

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _enablePin() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const PinSetupPage()));
    if (ok == true && mounted) _say('PIN Lock enabled');
  }

  Future<void> _changePin() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const PinSetupPage(verifyFirst: true)));
    if (ok == true && mounted) _say('PIN changed');
  }

  Future<void> _disablePin() async {
    if (!await confirmIdentity(context, ref)) return;
    await ref.read(appLockProvider.notifier).disablePin();
    if (mounted) _say('PIN Lock disabled');
  }

  Future<void> _toggleFace(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ctrl = ref.read(appLockProvider.notifier);
    if (on) {
      final ok = await ctrl.enableFace();
      if (mounted) _say(ok ? '${faceLockLabel()} enabled' : '${faceLockLabel()} was not turned on.');
    } else if (await confirmIdentity(context, ref)) {
      await ctrl.disableFace();
      if (mounted) _say('${faceLockLabel()} disabled');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink(); // the lock is an app feature (Keychain / Keystore / biometrics)
    final lock = ref.watch(appLockProvider);
    final hint = Theme.of(context).hintColor;
    Widget status(bool on, {String? off}) => Text(on ? 'Enabled' : (off ?? 'Disabled'),
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: on ? _kGreen : hint));
    return InfoCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(children: [
            Icon(Icons.shield_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Security', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(height: 10),
        // PIN Lock
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('PIN Lock', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              status(lock.pinEnabled),
            ]),
          ),
          if (!lock.pinEnabled)
            TextButton(onPressed: _enablePin, child: const Text('Enable'))
          else ...[
            TextButton(onPressed: _changePin, child: const Text('Change')),
            TextButton(onPressed: _disablePin, child: const Text('Disable')),
          ],
        ]),
        const Divider(height: 18),
        // Face Lock / Face ID
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(faceLockLabel(), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              if (lock.biometricsAvailable || lock.faceEnabled)
                status(lock.faceEnabled)
              else
                Text('Not available on this device', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: hint)),
              if (lock.biometricsAvailable && !lock.faceEnabled)
                Text('Unlock with your ${_biometricWords(lock.biometrics)}', style: TextStyle(fontSize: 12, color: hint)),
            ]),
          ),
          Switch(
            value: lock.faceEnabled,
            onChanged: (lock.biometricsAvailable || lock.faceEnabled) && !_busy ? _toggleFace : null,
          ),
        ]),
      ]),
    );
  }
}
