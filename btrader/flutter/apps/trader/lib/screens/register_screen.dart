import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import 'signup_countries.dart';

const _navy = Color(0xFF002D58);

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
  bool _human = true;
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void initState() {
    super.initState();
    final q = Uri.base.queryParameters;
    final fromUrl = (q['ref'] ?? q['ib'] ?? '').trim();
    final seed = widget.initialIbId.trim().isNotEmpty ? widget.initialIbId.trim() : fromUrl;
    if (seed.isNotEmpty) _refCode.text = seed;
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
      builder: (ctx) => const _CountryPicker(),
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  Future<void> _submit() async {
    if (_first.text.trim().isEmpty) {
      setState(() => _error = 'First name is required');
      return;
    }
    if (_last.text.trim().isEmpty) {
      setState(() => _error = 'Last name is required');
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
    if (_pass.text.isEmpty) {
      setState(() => _error = 'Password is required');
      return;
    }
    if (_pass.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    if (!_human) {
      setState(() => _error = 'Confirm you are human');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final local = _phone.text.trim().replaceAll(RegExp(r'\D'), '');
      final phone = '+${_country!.dial}$local';
      final msg = await ref.read(authControllerProvider.notifier).signupCrm({
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
      if (!mounted) return;
      setState(() => _ok = msg);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) context.go('/login');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _dec(String label) => InputDecoration(labelText: label);

  @override
  Widget build(BuildContext context) {
    final countryLabel = _country == null
        ? 'Select country'
        : '${_country!.flag}  ${_country!.name}';
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _navy,
        elevation: 0,
        title: const Text('Register'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              children: [
                TextField(controller: _first, textCapitalization: TextCapitalization.words, decoration: _dec('First name *')),
                const SizedBox(height: 10),
                TextField(controller: _last, textCapitalization: TextCapitalization.words, decoration: _dec('Last name *')),
                const SizedBox(height: 10),
                TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: _dec('Email *')),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickCountry,
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Country *'),
                    child: Text(
                      countryLabel,
                      style: TextStyle(color: _country == null ? Theme.of(context).hintColor : null),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  SizedBox(
                    width: 78,
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: ' '),
                      child: Text(_country == null ? '+—' : '+${_country!.dial}', textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: _dec('Phone *'),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(controller: _address, decoration: _dec('Address')),
                const SizedBox(height: 10),
                TextField(controller: _pass, obscureText: true, decoration: _dec('Password *')),
                const SizedBox(height: 10),
                TextField(controller: _confirm, obscureText: true, decoration: _dec('Confirm password *')),
                const SizedBox(height: 10),
                TextField(controller: _refCode, decoration: _dec('IB ID (optional)')),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.trailing,
                  value: _human,
                  onChanged: (v) => setState(() => _human = v ?? false),
                  title: const Text('I am human / not a robot'),
                ),
                if (_ok != null) Text(_ok!, style: const TextStyle(color: Color(0xFF0B7A4B))),
                if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFE5484D))),
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    child: Text(_busy ? 'Creating…' : 'Create Account'),
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/login'),
                  child: const Text('Back to Login'),
                ),
              ],
            ),
          ),
        ),
      ),
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
    final q = _q.trim().toLowerCase();
    final rows = signupCountries.where((c) {
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) || c.iso.toLowerCase().contains(q) || c.dial.contains(q);
    }).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Search country', hintText: 'Name or dial code'),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final c = rows[i];
                return ListTile(
                  leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                  title: Text(c.name),
                  trailing: Text('+${c.dial}'),
                  onTap: () => Navigator.pop(context, c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
