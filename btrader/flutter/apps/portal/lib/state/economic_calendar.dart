import 'dart:convert';

/// Home -> "Major News / Events": TradingView's official, free Economic Calendar widget (its embed code, unchanged).
///
/// Nothing is fetched or stored by the app: the widget loads its own live events. The app only chooses the
/// countries and impact levels, and tells the widget the colour theme.

/// The Forex majors' countries (US, Euro Area, Japan, UK, Australia, Canada, Switzerland, New Zealand).
const kCalendarCountries = 'us,eu,jp,gb,au,ca,ch,nz';

/// The widget's importance filter: -1 low, 0 medium, 1 high. Medium and High only.
const kCalendarImportance = '0,1';

/// Height of the widget; the Home page scrolls, the widget does not.
const kCalendarHeight = 900;

Map<String, Object> calendarWidgetConfig({required bool dark, int height = kCalendarHeight}) => {
      'isTransparent': true,
      'width': '100%',
      'height': height,
      'colorTheme': dark ? 'dark' : 'light',
      'locale': 'en',
      'importanceFilter': kCalendarImportance,
      'countryFilter': kCalendarCountries,
    };

/// The embed code of TradingView's Economic Calendar ("events") widget as a small page.
String calendarWidgetHtml({required bool dark, int height = kCalendarHeight}) {
  // `<` is escaped so the JSON can never close the script tag.
  final cfg = jsonEncode(calendarWidgetConfig(dark: dark, height: height)).replaceAll('<', r'<');
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}</style></head><body>'
      '<div class="tradingview-widget-container"><div class="tradingview-widget-container__widget"></div>'
      '<script type="text/javascript" src="https://s3.tradingview.com/external-embedding/embed-widget-events.js" async>'
      '$cfg'
      '</script></div></body></html>';
}
