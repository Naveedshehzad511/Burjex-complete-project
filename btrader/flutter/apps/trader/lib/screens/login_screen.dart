import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:btrader_core/btrader_core.dart';

import '../auth/biometric_auth.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  // Biometric state.
  bool _bioAvailable = false;
  bool _bioSaved = false;
  bool _enableBio = false; // opt-in checkbox for first-time enable
  IconData _bioIcon = Icons.fingerprint;
  String _bioLabel = 'biometrics';

  @override
  void initState() {
    super.initState();
    _initBiometric();
  }

  Future<void> _initBiometric() async {
    final bio = ref.read(biometricAuthProvider);
    final available = await bio.isAvailable();
    final saved = available && await bio.hasSaved();
    final types = available ? await bio.enrolledTypes() : const <BiometricType>[];
    if (!mounted) return;
    setState(() {
      _bioAvailable = available;
      _bioSaved = saved;
      if (types.contains(BiometricType.face)) {
        _bioIcon = Icons.face;
        _bioLabel = 'Face ID';
      } else if (types.contains(BiometricType.fingerprint) || types.contains(BiometricType.strong)) {
        _bioIcon = Icons.fingerprint;
        _bioLabel = 'fingerprint';
      } else {
        _bioIcon = Icons.lock_outline;
        _bioLabel = 'biometrics';
      }
    });
    // Offer the prompt immediately when a credential is remembered.
    if (saved) _biometricSignIn();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final login = _account.text.trim();
    final password = _password.text;
    try {
      await ref.read(authControllerProvider.notifier).loginByAccount(login, password);
      // Remember for biometric re-login if the user opted in.
      if (_enableBio && _bioAvailable) {
        await ref.read(biometricAuthProvider).save(login, password);
      }
    } catch (e) {
      setState(() => _error = 'Sign in failed. Check your account number and password.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometricSignIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final bio = ref.read(biometricAuthProvider);
    final brand = ref.read(brandingProvider).valueOrNull ?? Branding.fallback;
    try {
      final creds = await bio.authenticateAndRead(reason: 'Sign in to your ${brand.appName} account');
      if (creds == null) {
        // Cancelled or unavailable — fall back to the password form silently.
        if (mounted) setState(() => _busy = false);
        return;
      }
      await ref.read(authControllerProvider.notifier).loginByAccount(creds.login, creds.password);
    } catch (e) {
      // Stored credential is stale (e.g. password changed) — forget it so we
      // don't keep failing, and ask the user to sign in with their password.
      await bio.clear();
      if (mounted) {
        setState(() {
          _bioSaved = false;
          _error = 'Biometric sign in failed. Please sign in with your password.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    await ref.read(biometricAuthProvider).clear();
    if (mounted) setState(() => _bioSaved = false);
  }

  /// Lead-gen self-serve demo: full account-opening form. Creates the lead +
  /// demo account and auto-logs in (the router then routes into the app).
  Future<void> _openDemoSignup() async {
    final first = TextEditingController();
    final last = TextEditingController();
    final email = TextEditingController();
    final phone = TextEditingController();
    final pass = TextEditingController();
    final bal = TextEditingController(text: '10000');
    String currency = 'USD';
    String leverage = '100';
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        bool busy = false;
        String? err;
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> submit() async {
            final e = email.text.trim();
            if (!e.contains('@') || !e.contains('.')) {
              setSheet(() => err = 'Enter a valid email');
              return;
            }
            if (pass.text.length < 6) {
              setSheet(() => err = 'Password must be at least 6 characters');
              return;
            }
            if (phone.text.trim().isEmpty) {
              setSheet(() => err = 'Phone number is required');
              return;
            }
            setSheet(() {
              busy = true;
              err = null;
            });
            try {
              await ref.read(authControllerProvider.notifier).registerDemo({
                'firstName': first.text.trim(),
                'lastName': last.text.trim(),
                'email': e,
                'phone': phone.text.trim(),
                'password': pass.text,
                'currency': currency,
                'leverage': int.tryParse(leverage) ?? 100,
                'balance': double.tryParse(bal.text) ?? 0,
              });
              // Auto-logged in — GoRouter redirects into the app.
            } catch (_) {
              setSheet(() {
                busy = false;
                err = 'Could not create the demo account. That email may already be registered.';
              });
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Center(child: Text('Open a free demo account', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                const SizedBox(height: 2),
                Center(child: Text('Practice with virtual funds and real prices', style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 12))),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: TextField(controller: first, decoration: const InputDecoration(labelText: 'First name'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: last, decoration: const InputDecoration(labelText: 'Last name'))),
                ]),
                const SizedBox(height: 10),
                TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
                const SizedBox(height: 10),
                TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
                const SizedBox(height: 10),
                TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password', helperText: 'At least 6 characters')),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: currency,
                      decoration: const InputDecoration(labelText: 'Currency'),
                      items: const ['USD', 'EUR', 'GBP', 'AED', 'JPY'].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: (v) => setSheet(() => currency = v ?? 'USD'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: leverage,
                      decoration: const InputDecoration(labelText: 'Leverage 1:'),
                      items: const ['50', '100', '200', '500', '1000'].map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
                      onChanged: (v) => setSheet(() => leverage = v ?? '100'),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(controller: bal, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Starting balance', helperText: 'Virtual funds — choose any amount')),
                if (err != null) ...[
                  const SizedBox(height: 12),
                  Text(err!, style: const TextStyle(color: Color(0xFFE5484D))),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : submit,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: Text(busy ? 'Creating…' : 'Create demo account'),
                ),
                const SizedBox(height: 8),
              ]),
            ),
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(brandingProvider).valueOrNull ?? Branding.fallback;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Row(children: [
                  BrandLogo(branding: brand, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(brand.appName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 6),
                Text('Sign in with your trading account number', style: TextStyle(color: Theme.of(context).hintColor)),
                const SizedBox(height: 28),

                // Fast path: remembered credential → biometric button up top.
                if (_bioSaved) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _biometricSignIn,
                    icon: Icon(_bioIcon),
                    label: Text('Sign in with $_bioLabel'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: brand.primary,
                      side: BorderSide(color: brand.primary),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('or', style: TextStyle(color: Theme.of(context).hintColor))),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 18),
                ],

                TextField(controller: _account, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Account number')),
                const SizedBox(height: 14),
                TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),

                // First-time opt-in to remember the credential for biometrics.
                if (_bioAvailable && !_bioSaved) ...[
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    value: _enableBio,
                    onChanged: _busy ? null : (v) => setState(() => _enableBio = v ?? false),
                    title: Text('Enable $_bioLabel sign-in next time'),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(backgroundColor: brand.primary, padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: Text(_busy ? 'Signing in…' : 'Sign in'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openDemoSignup,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Open a free demo account'),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),

                if (_bioSaved) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _forget,
                    child: const Text('Forget saved login on this device'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
