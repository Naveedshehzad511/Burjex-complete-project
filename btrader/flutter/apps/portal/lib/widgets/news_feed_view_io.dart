import 'dart:async';

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

/// The loaded web views, kept for the life of the app. Home is rebuilt every time the user comes back from another
/// tab, which used to make TradingView load again (a spinner each time). On coming back, [newsViewReuse] decides:
/// a recent page is shown as it is, an older one is shown at once while a new copy loads out of sight underneath and
/// replaces it when ready, and an old one loads afresh. The sections' own timers, Retry and the category chips still
/// load it afresh (their keys carry a non-zero epoch, a first mount carries 0).
class _Loaded {
  _Loaded(this.controller);
  final WebViewController controller;
  DateTime? loadedAt; // null until the page has finished loading
  bool failed = false; // the page or TradingView's own frame inside it could not load (e.g. no internet)
  // The current owner's callbacks (the view is handed from one Home visit to the next).
  void Function(String url)? onOpen;
  VoidCallback? onLoaded;
  VoidCallback? onFailed;
}

final Map<String, _Loaded> _cache = {};
const int _cacheLimit = 8;
const Duration _quietLoadTimeout = Duration(seconds: 30);
final RegExp _epochOf = RegExp(r'-(\d+)-(?:true|false)$');

class _NewsFeedViewState extends State<NewsFeedView> {
  _Loaded? _shown; // what the user sees
  _Loaded? _pending; // a newer copy loading underneath (never shown until it has loaded)
  Timer? _pendingTimeout;
  String? _html;

  /// 0 for a first mount of the section, above 0 for a reload it asked for.
  int get _epoch {
    final k = widget.key;
    final v = k is ValueKey ? k.value : null;
    final m = v is String ? _epochOf.firstMatch(v) : null;
    return m == null ? 1 : int.parse(m.group(1)!); // an unknown key is never reused
  }

  /// A web view that loads [html] and reports to its current owner through the entry's callbacks.
  _Loaded _create(String html, {required void Function(_Loaded e) onFinished, required void Function(_Loaded e) onError}) {
    final entry = _Loaded(WebViewController())
      ..onOpen = widget.onOpen
      ..onLoaded = widget.onLoaded
      ..onFailed = widget.onFailed;
    entry.controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (newsNavigation(request.url) == NewsNavigation.stay) return NavigationDecision.navigate;
          entry.onOpen?.call(request.url);
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) {
          entry.loadedAt = DateTime.now();
          onFinished(entry);
        },
        onWebResourceError: (e) {
          // Our page is a small shell; TradingView draws the list in a frame of its own inside it. With no
          // internet that frame fails while the shell still "finishes", and Android then shows its own
          // "Webpage not available" page inside it. Treat that frame (and the embed script) like the page itself.
          final url = e.url ?? '';
          final widgetFrame = url.contains('/embed-widget/') || url.contains('/external-embedding/');
          if ((e.isForMainFrame ?? false) || widgetFrame) {
            if (entry.failed) return;
            entry.failed = true;
            onError(entry);
          }
        },
      ))
      ..loadHtmlString(html, baseUrl: kNewsBaseUrl);
    return entry;
  }

  void _remember(String html, _Loaded entry) {
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache.remove(html);
    _cache[html] = entry;
  }

  @override
  void initState() {
    super.initState();
    try {
      final html = widget.html ?? newsWidgetHtml(widget.tab, dark: widget.dark);
      _html = html;
      final hit = _cache[html];
      final loadedAt = hit?.loadedAt;
      final reuse = (hit != null && _epoch == 0 && loadedAt != null) ? newsViewReuse(DateTime.now().difference(loadedAt)) : NewsViewReuse.reload;
      if (hit != null && reuse != NewsViewReuse.reload) {
        // Back on Home with a recent copy: show it as it was, no spinner, no blank.
        _shown = hit
          ..onOpen = widget.onOpen
          ..onLoaded = widget.onLoaded
          ..onFailed = widget.onFailed;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.onLoaded();
          if (reuse == NewsViewReuse.refreshQuietly) _refreshQuietly(html);
        });
        return;
      }
      _shown = _create(
        html,
        onFinished: (e) {
          if (!e.failed) e.onLoaded?.call(); // a frame error that came first must not be undone
        },
        onError: (e) {
          _cache.remove(html);
          e.onFailed?.call();
        },
      );
      _remember(html, _shown!);
    } catch (_) {
      // No web view on this platform (or not ready): say so instead of breaking the page.
      _shown = null;
      if (_html != null) _cache.remove(_html);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onFailed();
      });
    }
  }

  /// Load a new copy underneath the one on screen. When it has loaded it takes its place (same size, same spot, the
  /// platform view is moved, not rebuilt). If it cannot load, nothing changes: no error, no blank.
  void _refreshQuietly(String html) {
    if (_pending != null) return;
    try {
      final fresh = _create(
        html,
        onFinished: (e) async {
          if (!mounted || !identical(_pending, e)) return;
          // TradingView's frame reports its failure just after the shell finishes: wait a moment, and never swap
          // a copy that failed in place of the good one on screen.
          await Future<void>.delayed(const Duration(seconds: 2));
          if (!mounted || !identical(_pending, e) || e.failed) return;
          _pendingTimeout?.cancel();
          e
            ..onOpen = widget.onOpen
            ..onLoaded = widget.onLoaded
            ..onFailed = widget.onFailed;
          _remember(html, e);
          setState(() {
            _shown = e;
            _pending = null;
          });
        },
        onError: (e) => _dropPending(e),
      );
      // Until it is swapped in, nothing from the new copy reaches the section (no loader, no error).
      fresh
        ..onLoaded = null
        ..onFailed = null;
      setState(() => _pending = fresh);
      _pendingTimeout = Timer(_quietLoadTimeout, () => _dropPending(fresh));
    } catch (_) {
      // Keep showing what is there.
    }
  }

  void _dropPending(_Loaded e) {
    if (!mounted || !identical(_pending, e)) return;
    _pendingTimeout?.cancel();
    setState(() => _pending = null);
  }

  @override
  void dispose() {
    _pendingTimeout?.cancel();
    // The page stays loaded in the cache, but nothing of this (gone) view is called any more.
    final e = _cache[_html];
    if (e != null && identical(e, _shown)) {
      e
        ..onOpen = null
        ..onLoaded = null
        ..onFailed = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final pending = _pending;
    return SizedBox(
      height: widget.height ?? kNewsHeight.toDouble(),
      child: shown == null
          ? null
          // No gesture recognizers of its own: a vertical drag always scrolls the Home page (the widget is tall
          // enough to show its list, so there is nothing to scroll inside it), and taps still reach the stories.
          // A newer copy loads underneath (same size) and is kept by key when it takes the place of the one on top.
          : Stack(children: [
              if (pending != null) Positioned.fill(key: ObjectKey(pending), child: WebViewWidget(key: ObjectKey(pending.controller), controller: pending.controller)),
              Positioned.fill(key: ObjectKey(shown), child: WebViewWidget(key: ObjectKey(shown.controller), controller: shown.controller)),
            ]),
    );
  }
}

/// Whether a recent copy of this page is already loaded and will be shown at once (phone apps only; false elsewhere).
bool newsViewCached(String html) {
  final at = _cache[html]?.loadedAt;
  return at != null && newsViewReuse(DateTime.now().difference(at)) != NewsViewReuse.reload;
}
