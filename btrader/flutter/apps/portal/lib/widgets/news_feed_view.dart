/// The official TradingView "Top Stories" widget, drawn by the platform: a web view on the phone apps, a sandboxed
/// iframe on the website. Same contract on both: [NewsFeedView].
export 'news_feed_view_stub.dart'
    if (dart.library.js_interop) 'news_feed_view_web.dart'
    if (dart.library.io) 'news_feed_view_io.dart';
