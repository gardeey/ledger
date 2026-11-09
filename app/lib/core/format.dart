import 'package:intl/intl.dart';

final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
final _moneyWhole = NumberFormat.currency(symbol: r'$', decimalDigits: 0);
final _compact = NumberFormat.compactCurrency(symbol: r'$', decimalDigits: 1);

/// Privacy mode (Settings > Hide amounts): every formatted amount becomes dots.
bool maskAmounts = false;
const _masked = r'$••••';

String money(num v, {bool whole = false}) => maskAmounts ? _masked : (whole ? _moneyWhole : _money).format(v);
String moneyCompact(num v) => maskAmounts ? '••' : _compact.format(v);
String monthLabel(String ym) =>
    DateFormat('MMM yyyy').format(DateTime.parse('$ym-01'));
String monthShort(String ym) => DateFormat('MMM').format(DateTime.parse('$ym-01'));
String dayLabel(String ymd) => DateFormat('MMM d, yyyy').format(DateTime.parse(ymd));
String dayShort(String ymd) => DateFormat('MMM d').format(DateTime.parse(ymd));
String fullDay(DateTime d) => DateFormat('EEEE, MMMM d').format(d);
