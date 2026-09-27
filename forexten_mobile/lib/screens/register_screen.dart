import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../auth/auth_page.dart';
import '../pending_signup.dart';
import 'signup_countries.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.initialIbId = ''});
  final String initialIbId;
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  final _refCode = TextEditingController();
  SignupCountry? _country;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialIbId.trim().isNotEmpty) _refCode.text = widget.initialIbId.trim();
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    _pass.dispose();
    _confirm.dispose();
    _refCode.dispose();
    super.dispose();
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<SignupCountry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CountryPicker(),
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  Future<void> _submit() async {
    if (_first.text.trim().isEmpty || _last.text.trim().isEmpty) {
      setState(() => _error = 'First and last name are required');
      return;
    }
    if (_email.text.trim().isEmpty) {
      setState(() => _error = 'Email is required');
      return;
    }
    if (_country == null) {
      setState(() => _error = 'Select country');
      return;
    }
    if (_phone.text.trim().isEmpty) {
      setState(() => _error = 'Phone is required');
      return;
    }
    if (_pass.text.length < 8) {
      setState(() => _error = 'Use at least 8 characters');
      return;
    }
    if (_pass.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final local = _phone.text.trim().replaceAll(RegExp(r'\D'), '');
      final phone = '+${_country!.dial}$local';
      await ref.read(authControllerProvider.notifier).signupCrm({
        'first_name': _first.text.trim(),
        'last_name': _last.text.trim(),
        'full_name': '${_first.text.trim()} ${_last.text.trim()}',
        'email': _email.text.trim(),
        'phone': phone,
        'country': _country!.name,
        'address': _address.text.trim(),
        'password': _pass.text,
        'confirm_password': _confirm.text,
        'captcha': 'on',
        if (_refCode.text.trim().isNotEmpty) 'signup_ref': _refCode.text.trim(),
      });
      ref.read(pendingSignupProvider.notifier).state =
          PendingSignup(email: _email.text.trim(), password: _pass.text);
      if (!mounted) return;
      context.go('/verify-otp?email=${Uri.encodeQueryComponent(_email.text.trim())}');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      onBack: () => context.canPop() ? context.pop() : context.go('/login'),
      title: 'Create Account',
      children: [
        TextField(controller: _first, decoration: authField('First name'), textCapitalization: TextCapitalization.words),
        const SizedBox(height: 12),
        TextField(controller: _last, decoration: authField('Last name'), textCapitalization: TextCapitalization.words),
        const SizedBox(height: 12),
        TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: authField('Email')),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_country == null ? 'Country' : '${_country!.flag}  ${_country!.name}'),
          trailing: const Icon(Icons.expand_more),
          onTap: _pickCountry,
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: authField(_country == null ? 'Phone' : 'Phone (+${_country!.dial})'),
        ),
        const SizedBox(height: 12),
        TextField(controller: _address, decoration: authField('Address')),
        const SizedBox(height: 12),
        TextField(controller: _pass, obscureText: true, decoration: authField('Password')),
        const SizedBox(height: 12),
        TextField(controller: _confirm, obscureText: true, decoration: authField('Confirm password')),
        const SizedBox(height: 12),
        TextField(controller: _refCode, decoration: authField('IB / referral (optional)')),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: authPrimaryButton(),
          child: Text(_busy ? 'Creating…' : 'Create Account', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

class _CountryPicker extends StatefulWidget {
  const _CountryPicker();
  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final rows = signupCountries.where((c) => c.name.toLowerCase().contains(q) || c.dial.contains(q)).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search country'),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final c = rows[i];
              return ListTile(
                title: Text('${c.flag}  ${c.name}'),
                trailing: Text('+${c.dial}'),
                onTap: () => Navigator.pop(context, c),
              );
            },
          ),
        ),
      ]),
    );
  }
}
