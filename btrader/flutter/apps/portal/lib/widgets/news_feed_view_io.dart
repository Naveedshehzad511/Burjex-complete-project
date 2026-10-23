import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/market_news.dart';

/// The widget in a web view (Android / iOS). Every story the widget links to is handed to the browser through
/// [onOpen]; the web view itself never leaves the widget.
class NewsFeedView extends StatefulWidget {
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
  State<NewsFeedView> createState() => _NewsFeedViewState();
}

class _NewsFeedViewState extends State<NewsFeedView> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    try {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (request) {
            if (newsNavigation(request.url) == NewsNavigation.stay) return NavigationDecision.navigate;
            widget.onOpen(request.url);
            return NavigationDecision.prevent;
          },
          onPageFinished: (_) => widget.onLoaded(),
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? false) widget.onFailed();
          },
        ))
        ..loadHtmlString((widget.html ?? newsWidgetHtml(widget.tab, dark: widget.dark)), baseUrl: kNewsBaseUrl);
    } catch (_) {
      // No web view on this platform (or not ready): say so instead of breaking the page.
      _controller = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onFailed();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return SizedBox(
      height: widget.height ?? kNewsHeight.toDouble(),
      child: c == null
          ? null
          // No gesture recognizers of its own: a vertical drag always scrolls the Home page (the widget is tall
          // enough to show its list, so there is nothing to scroll inside it), and taps still reach the stories.
          : WebViewWidget(controller: c),
    );
  }
}
