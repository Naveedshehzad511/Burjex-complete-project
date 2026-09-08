import 'package:intl/intl.dart';

final _money = NumberFormat('#,##0.00');
final _dt = DateFormat('MMM d, HH:mm');
final _hms = DateFormat('HH:mm:ss');

String money(num v) => _money.format(v);
String price(num v, int digits) => v.toStringAsFixed(digits);
String pct(num v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';
String dateTime(DateTime d) => _dt.format(d.toLocal());
String hms(DateTime d) => _hms.format(d.toLocal());

/// MT5 "big figure" price split: the bulk of the number is normal-size, the two
/// pip digits are enlarged, and (for 3/5-digit fractional-pip symbols) the last
/// digit is a small superscript. e.g. 1.10379 → normal "1.10", big "37", sup "9".
class BigFigure {
  final String normal;
  final String big;
  final String sup;
  const BigFigure(this.normal, this.big, this.sup);
}

BigFigure mt5Price(num value, int digits) {
  final s = value.toStringAsFixed(digits);
  final hasSup = digits == 3 || digits == 5; // fractional-pip brokers
  final sup = hasSup ? s.substring(s.length - 1) : '';
  final head = hasSup ? s.substring(0, s.length - 1) : s;
  final big = head.length >= 2 ? head.substring(head.length - 2) : head;
  final normal = head.length >= 2 ? head.substring(0, head.length - 2) : '';
  return BigFigure(normal, big, sup);
}
