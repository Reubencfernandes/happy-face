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
const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Single letters for a calendar heading, starting on Sunday.
const weekdayInitials = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

String monthName(int month) => _months[month - 1];
String shortMonth(int month) => _months[month - 1].substring(0, 3);

/// "Today", "Yesterday", "Friday" (this past week), "Sat, 12 Sep" (this
/// year) or "Sat, 12 Sep 2024".
String dayLabel(DateTime day, {DateTime? now}) {
  final today = _dateOnly(now ?? DateTime.now());
  final d = _dateOnly(day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  // Within the last week a weekday name says it better than a date.
  if (diff > 1 && diff < 7) return _weekdayNames[d.weekday - 1];
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

/// Sizes the way storage is sold: 1 GB is 1000 MB, the same units Hugging
/// Face quotes its allowances in, so "2.15 GB of 1 TB" adds up against the
/// 997.85 GB left.
String storageSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(0)} KB';
  if (bytes < 1000000000) {
    return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  }
  if (bytes < 1000000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
  }
  return '${(bytes / 1000000000000).toStringAsFixed(2)} TB';
}

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// "3.4 MB/s", for a backup that is moving.
String transferRate(double bytesPerSecond) =>
    '${fileSize(bytesPerSecond.round())}/s';

/// Roughly how long is left, rounded to something worth saying out loud.
String timeLeft(Duration d) {
  if (d.inSeconds < 15) return 'a few seconds left';
  if (d.inSeconds < 90) return 'about ${(d.inSeconds / 15).round() * 15}s left';
  if (d.inMinutes < 60) return 'about ${d.inMinutes} min left';
  final hours = d.inMinutes / 60;
  return 'about ${hours.toStringAsFixed(hours < 10 ? 1 : 0)} h left';
}

/// "2.1 of 8.4 MB", the shape a per-file bar wants underneath it.
String bytesOf(int done, int total) =>
    total <= 0 ? fileSize(done) : '${fileSize(done)} of ${fileSize(total)}';

DateTime _dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);
