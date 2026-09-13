import 'package:flutter/material.dart';

const authNavy = Color(0xFF002D58);
const _fieldFill = Color(0xFFF4F6FA);

InputDecoration authField(String label, {Widget? suffix, String? helper, String? counterText}) {
  return InputDecoration(
    labelText: label,
    helperText: helper,
    counterText: counterText,
    filled: true,
    fillColor: _fieldFill,
    suffixIcon: suffix,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: authNavy, width: 1.4),
    ),
  );
}

ButtonStyle authPrimaryButton() => FilledButton.styleFrom(
      backgroundColor: authNavy,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

ButtonStyle authOutlineButton() => OutlinedButton.styleFrom(
      foregroundColor: authNavy,
      minimumSize: const Size.fromHeight(52),
      side: const BorderSide(color: Color(0xFFC9CED8)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

class AuthPage extends StatelessWidget {
  const AuthPage({
    super.key,
    required this.children,
    this.title,
    this.onBack,
  });

  final List<Widget> children;
  final String? title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: authNavy,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: onBack,
        ),
        title: title == null ? null : Text(title!),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
