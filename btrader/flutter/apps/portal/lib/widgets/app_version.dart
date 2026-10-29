import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The commit the build was made from, passed by the build: `--dart-define=APP_COMMIT=$(git rev-parse --short HEAD)`.
/// Empty for a build made without it.
const String kAppCommit = String.fromEnvironment('APP_COMMIT');

/// "Version 1.0.3 (26102014) · 2200e76": what the installed app is, so support can tell which build a client runs.
String appVersionLabel(String version, String build, {String commit = kAppCommit}) {
  final b = build.isEmpty || build == version ? '' : ' ($build)';
  final c = commit.isEmpty ? '' : ' · $commit';
  return 'Version $version$b$c';
}

final Future<PackageInfo> _info = PackageInfo.fromPlatform();

/// Small grey version line; a tap copies it (to paste into a support chat).
class AppVersionText extends StatelessWidget {
  const AppVersionText({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox(height: 16);
        final label = appVersionLabel(info.version, info.buildNumber);
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            Clipboard.setData(ClipboardData(text: label));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Version copied')));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: color)),
          ),
        );
      },
    );
  }
}
