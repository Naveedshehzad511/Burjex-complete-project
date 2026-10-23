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
    this.html,
    this.height,
  });
  final NewsTab tab;
  final bool dark;
  final VoidCallback onLoaded;
  final VoidCallback onFailed;
  final void Function(String url) onOpen;

  /// A different embed page (the economic calendar) in place of the news list for [tab], and its height.
  final String? html;
  final double? height;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
