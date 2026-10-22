import 'dart:convert';

/// The "Market" news section on Home: TradingView's official, free "Top Stories" widget (its embed code, unchanged).
///
/// Nothing here is fetched or stored by the app: the widget loads its own live headlines. The app only chooses the
/// category, tells the widget the colour theme, and opens the tapped article in the phone's browser.

/// The categories the widget really supports (checked against the live widget): "all", and a single market each.
/// ETFs / Indices / Futures are not offered: the widget answers those with "Something went wrong".
enum NewsTab {
  all('All', null),
  stocks('Stocks', 'stock'),
  crypto('Crypto', 'crypto'),
  forex('Forex', 'forex');

  const NewsTab(this.label, this.market);
  final String label;

  /// The widget's `market` setting; null = every market.
  final String? market;
}

/// "Keep reading": TradingView's own top-stories page, in the browser.
const kNewsKeepReadingUrl = 'https://www.tradingview.com/news/#news_top_stories';

/// The page the widget believes it is on (it reports it to TradingView): our own site, not a made-up address.
const kNewsBaseUrl = 'https://portal.burjexprime.net/';

/// Height of the widget: its heading and about six stories, so the Home page scrolls (the widget does not).
const kNewsHeight = 720;

/// The widget's `timeline` settings for [tab] - exactly the options of TradingView's embed code.
Map<String, Object> newsWidgetConfig(NewsTab tab, {required bool dark, int height = kNewsHeight}) => {
      if (tab.market != null) ...{'feedMode': 'market', 'market': tab.market!} else 'feedMode': 'all_symbols',
      'isTransparent': true,
      // TradingView's compact layout: the smaller of its two official text sizes (the size itself is not ours to set).
      'displayMode': 'compact',
      'width': '100%',
      'height': height,
      'colorTheme': dark ? 'dark' : 'light',
      'locale': 'en',
    };

/// The embed code of TradingView's Top Stories ("timeline") widget as a small page. The script and the settings are
/// TradingView's documented embed code; the widget draws its own heading, stories and TradingView attribution.
String newsWidgetHtml(NewsTab tab, {required bool dark, int height = kNewsHeight}) {
  // `<` is escaped so the JSON can never close the script tag.
  final cfg = jsonEncode(newsWidgetConfig(tab, dark: dark, height: height)).replaceAll('<', r'<');
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}</style></head><body>'
      '<div class="tradingview-widget-container"><div class="tradingview-widget-container__widget"></div>'
      '<script type="text/javascript" src="https://s3.tradingview.com/external-embedding/embed-widget-timeline.js" async>'
      '$cfg'
      '</script></div></body></html>';
}

/// What the app does with an address the widget asks to go to.
enum NewsNavigation {
  /// Part of the widget itself (its page, script and frame): let it load.
  stay,

  /// A story (or anything else the widget links to): open it in the browser, never inside the app.
  openInBrowser,
}

NewsNavigation newsNavigation(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return NewsNavigation.stay; // about:blank and the like
  final s = u.scheme.toLowerCase();
  if (s == 'about' || s == 'data' || s == 'blob') return NewsNavigation.stay;
  final host = u.host.toLowerCase();
  bool isHost(String h) => host == h || host.endsWith('.$h');
  // The widget's own frame / script, and the page the widget sits in.
  if (isHost('tradingview-widget.com') || host == 's3.tradingview.com' || host == 's.tradingview.com') return NewsNavigation.stay;
  if (host == Uri.parse(kNewsBaseUrl).host) return NewsNavigation.stay;
  return NewsNavigation.openInBrowser;
}

/// Only web addresses are ever handed to the browser.
bool newsLinkOpenable(String url) {
  final u = Uri.tryParse(url.trim());
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}
