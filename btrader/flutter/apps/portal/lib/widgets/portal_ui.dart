import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../main.dart' show kNavy;

/// Outlined, rounded field used on the CRM-backed pages (matches the client's
/// white fields with a dark outline).
InputDecoration portalField(BuildContext context, String label, {Widget? suffix, String? helper}) {
  final line = Theme.of(context).brightness == Brightness.dark ? Colors.white54 : const Color(0xFF11141A);
  OutlineInputBorder b(Color c, [double w = 1]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    labelText: label,
    helperText: helper,
    suffixIcon: suffix,
    filled: true,
    fillColor: Theme.of(context).colorScheme.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    border: b(line),
    enabledBorder: b(line),
    focusedBorder: b(kNavy, 2),
  );
}

ButtonStyle navyButton({Color color = kNavy}) => FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    );

/// Page chrome for the full-screen CRM pages: back arrow + bold title.
class PortalPage extends StatelessWidget {
  const PortalPage({super.key, required this.title, required this.child, this.actions});
  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/home')),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 22)),
        actions: actions,
      ),
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? null : const Color(0xFFF6F7FA),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: child),
        ),
      ),
    );
  }
}

class ErrorBox extends StatelessWidget {
  const ErrorBox(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFFFDE8EA), borderRadius: BorderRadius.circular(12)),
        child: Text(message, style: const TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w600)),
      );
}

class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: child,
      );
}
