const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String monthName(int month) => _months[month - 1];
String shortMonth(int month) => _months[month - 1].substring(0, 3);

/// "Today", "Yesterday", "Sat, 12 Sep" (this year) or "Sat, 12 Sep 2024".
String dayLabel(DateTime day, {DateTime? now}) {
  final today = _dateOnly(now ?? DateTime.now());
  final d = _dateOnly(day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final base = '${_weekdays[d.weekday - 1]}, ${d.day} ${shortMonth(d.month)}';
  return d.year == today.year ? base : '$base ${d.year}';
}

/// "September 2026", or just "September" in the current year.
String monthLabel(DateTime day, {DateTime? now}) {
  final year = (now ?? DateTime.now()).year;
  return day.year == year
      ? monthName(day.month)
      : '${monthName(day.month)} ${day.year}';
}

String fullDateTime(DateTime local, int? tzOffsetMinutes) {
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  var s =
      '${_weekdays[local.weekday - 1]}, ${local.day} ${monthName(local.month)} '
      '${local.year} · $h:$m';
  if (tzOffsetMinutes != null) {
    final sign = tzOffsetMinutes < 0 ? '−' : '+';
    final abs = tzOffsetMinutes.abs();
    final mins = abs % 60;
    s +=
        ' (UTC$sign${abs ~/ 60}${mins == 0 ? '' : ':${mins.toString().padLeft(2, '0')}'})';
  }
  return s;
}

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

DateTime _dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);
