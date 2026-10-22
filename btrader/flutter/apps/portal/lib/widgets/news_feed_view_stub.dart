import 'package:flutter/widgets.dart';

import '../state/market_news.dart';

/// Placeholder for platforms with neither dart:io nor the web (not used by the app).
class NewsFeedView extends StatelessWidget {
  const NewsFeedView({
    super.key,
    required this.tab,
    required this.dark,
    required this.onLoaded,
    required this.onFailed,
    required this.onOpen,
  });
  final NewsTab tab;
  final bool dark;
  final VoidCallback onLoaded;
  final VoidCallback onFailed;
  final void Function(String url) onOpen;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
