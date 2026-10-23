import 'dart:async';
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
  late final String _viewType = 'bx-market-news-${_viewSeq++}';

  /// A browser hands every scroll over an iframe to the iframe, so the page could not be scrolled with the pointer
  /// on the widget. The widget is therefore covered until it is tapped: drags and the wheel scroll the page, a tap
  /// unlocks the widget for a few seconds (its own list, its links), then it is covered again.
  bool _unlocked = false;
  Timer? _relock;

  void _unlock() {
    _relock?.cancel();
    setState(() => _unlocked = true);
    _relock = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _unlocked = false);
    });
  }

  @override
  void dispose() {
    _relock?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final frame = web.HTMLIFrameElement()
        ..setAttribute('sandbox', 'allow-scripts allow-popups allow-popups-to-escape-sandbox')
        ..srcdoc = (widget.html ?? newsWidgetHtml(widget.tab, dark: widget.dark)).toJS
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      frame.addEventListener('load', ((web.Event _) => widget.onLoaded()).toJS);
      frame.addEventListener('error', ((web.Event _) => widget.onFailed()).toJS);
      return frame;
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height ?? kNewsHeight.toDouble(),
        child: Stack(children: [
          HtmlElementView(viewType: _viewType),
          if (!_unlocked) Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _unlock)),
        ]),
      );
}
