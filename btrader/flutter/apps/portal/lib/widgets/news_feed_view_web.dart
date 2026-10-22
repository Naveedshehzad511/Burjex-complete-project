import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../state/market_news.dart';

int _viewSeq = 0;

/// The widget in an iframe on the website. The iframe is sandboxed (scripts and pop-ups only, no access to the
/// portal's own storage or cookies), so TradingView's script cannot touch the signed-in page; a story opens in a
/// new browser tab through the pop-up permission.
class NewsFeedView extends StatefulWidget {
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
  State<NewsFeedView> createState() => _NewsFeedViewState();
}

class _NewsFeedViewState extends State<NewsFeedView> {
  late final String _viewType = 'bx-market-news-${_viewSeq++}';

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final frame = web.HTMLIFrameElement()
        ..setAttribute('sandbox', 'allow-scripts allow-popups allow-popups-to-escape-sandbox')
        ..srcdoc = newsWidgetHtml(widget.tab, dark: widget.dark).toJS
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      frame.addEventListener('load', ((web.Event _) => widget.onLoaded()).toJS);
      frame.addEventListener('error', ((web.Event _) => widget.onFailed()).toJS);
      return frame;
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: kNewsHeight.toDouble(), child: HtmlElementView(viewType: _viewType));
}
