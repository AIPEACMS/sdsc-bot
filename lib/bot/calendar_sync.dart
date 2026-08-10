import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/calendar.dart';
import '../core/config.dart';
import '../core/models.dart';
import '../core/repo.dart';
import '../core/log.dart';
import '../core/week.dart';

/// Result of a calendar sync.
class CalendarSyncResult {
  final String academicYear;
  final int weeks;
  final int holidays;
  const CalendarSyncResult({
    required this.academicYear,
    required this.weeks,
    required this.holidays,
  });
}

/// Parses an NTU academic-calendar YAML and applies it to the bot's holiday
/// table. Shared by the IPC endpoint and the console /sync-calendar command.
class CalendarSync {
  final Repo repo;
  final Config config;

  CalendarSync({required this.repo, required this.config});

  /// Parses [source] and updates the calendar + derived holidays.
  ///
  /// Returns the sync result, or throws [FormatException] on bad YAML.
  CalendarSyncResult apply(String source) {
    final year = CalendarYear.fromYaml(source);
    final s1 = year.semester('semester_1');
    final s2 = year.semester('semester_2');
    if (s1 == null || s2 == null) {
      throw FormatException('calendar needs semester_1 and semester_2');
    }

    // Store the raw YAML (idempotent re-sync).
    repo.saveCalendarYaml(year.academicYear, source);

    // The calendar governs weeks from S1's first Monday onward; anything the
    // admin set before that (old manual holidays) is left alone.
    final from = s1.firstStart ?? DateTime.now();
    repo.clearDerivedHolidays(from);

    // Every calendar week from S1 to S2-end gets a holiday row if the
    // calendar labels it (recess → middle, winter gap, summer tail).
    final weeks = <CalendarWeek>[
      ...s1.weeks,
      ...s2.weeks,
    ];

    // Winter break: the gap weeks between S1 end and S2 start.
    final s1End = s1.lastEnd!;
    final s2Start = s2.firstStart!;
    for (var d = s1End.add(const Duration(days: 1));
        !d.isAfter(s2Start.subtract(const Duration(days: 1)));
        d = d.add(const Duration(days: 7))) {
      final w = CalendarWeek(
        week: 0,
        type: 'winter',
        start: d,
        end: d.add(const Duration(days: 6)),
      );
      weeks.add(w);
    }

    // Summer tail: weeks after S2's last week up to 31 Aug of the academic
    // year's ending calendar year.
    final s2End = s2.lastEnd!;
    final summerEnd = DateTime(s2End.year, 8, 31);
    for (var d = s2End.add(const Duration(days: 1));
        !d.isAfter(summerEnd);
        d = d.add(const Duration(days: 7))) {
      final w = CalendarWeek(
        week: 0,
        type: 'summer',
        start: d,
        end: d.add(const Duration(days: 6)),
      );
      weeks.add(w);
    }

    // Sort by start and insert holiday rows (Monday-keyed).
    weeks.sort((a, b) => a.start.compareTo(b.start));
    var holidays = 0;
    for (final w in weeks) {
      final kind = _kindFor(w);
      if (kind == null) continue;
      repo.addHoliday(WeekMath.mondayOf(w.start), kind);
      holidays++;
    }

    return CalendarSyncResult(
      academicYear: year.academicYear,
      weeks: weeks.length,
      holidays: holidays,
    );
  }

  /// Maps a calendar week to a bot holiday kind:
  /// recess → middle, winter-gap → winter, summer-tail → summer.
  static HolidayKind? _kindFor(CalendarWeek w) {
    switch (w.type) {
      case 'recess':
        return HolidayKind.middle;
      case 'winter':
        return HolidayKind.winter;
      case 'summer':
        return HolidayKind.summer;
      default:
        return null; // teaching / exam weeks are not holidays
    }
  }
}

/// Loopback TCP listener that lets the cron script push a calendar YAML into
/// the running bot. Protocol (one connection, no half-close needed):
///
///   request:  `"TOKEN {token}\nLEN {byteCount}\n{yaml exactly LEN bytes}"`
///   response: `"OK {year} {weeks} {holidays}\n"` | `"ERR {message}\n"`
///
/// Bound to 127.0.0.1 only; the cron must present the CALENDAR_IPC_TOKEN.
class CalendarIpcServer {
  final CalendarSync sync;
  final String token;
  final int port;

  ServerSocket? _server;

  CalendarIpcServer({
    required this.sync,
    required this.token,
    required this.port,
  });

  /// The actual bound port (differs from [port] when 0 = ephemeral).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
        LogRing.log('calendar IPC listening on 127.0.0.1:$boundPort');
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handle(Socket socket) async {
    String reply;
    try {
      reply = await _process(socket);
    } catch (e) {
      reply = 'ERR $e';
    }
    try {
      socket.write('$reply\n');
      await socket.flush();
    } catch (_) {}
    await socket.close();
  }

  /// Reads the framed request without waiting for EOF: parses the header as
  /// soon as it arrives, then consumes exactly `LEN` payload bytes and
  /// responds. The client may keep its write side open.
  Future<String> _process(Socket socket) {
    final buffer = <int>[];
    final done = Completer<String>();
    int? expectedTotal; // total bytes (header + payload) needed

    void tryComplete() {
      if (done.isCompleted) return;
      final text = utf8.decode(buffer, allowMalformed: true);
      final tokenEnd = text.indexOf('\n');
      final lenEnd = text.indexOf('\n', tokenEnd + 1);
      if (tokenEnd < 0 || lenEnd < 0) return; // header not complete yet
      if (expectedTotal == null) {
        final presented = text.substring(0, tokenEnd).trim();
        if (presented != 'TOKEN $token') {
          done.complete('ERR bad token');
          return;
        }
        final lenLine = text.substring(tokenEnd + 1, lenEnd).trim();
        final len = int.tryParse(lenLine.replaceFirst('LEN ', ''));
        if (len == null || len <= 0) {
          done.complete('ERR bad length');
          return;
        }
        expectedTotal = lenEnd + 1 + len;
      }
      if (buffer.length >= expectedTotal!) {
        // Decode only the payload bytes as UTF-8 (the header is ASCII).
        final yaml = utf8.decode(
            buffer.sublist(lenEnd + 1, expectedTotal),
            allowMalformed: true);
        try {
          done.complete(_apply(yaml));
        } catch (e) {
          done.complete('ERR $e');
        }
      }
    }

    socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        tryComplete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.complete('ERR $e');
      },
      onDone: () {
        if (!done.isCompleted) done.complete('ERR truncated payload');
      },
    );

    return done.future;
  }

  String _apply(String yaml) {
    if (yaml.trim().isEmpty) return 'ERR empty payload';
    final result = sync.apply(yaml);
    return 'OK ${result.academicYear} ${result.weeks} ${result.holidays}';
  }
}
