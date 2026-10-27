class Departure {
  final String line;
  final String destination;
  final String schedTime;
  final String realTime;
  final String status;
  final DateTime? departureAt;
  final bool isCancelled;

  const Departure({
    required this.line,
    required this.destination,
    required this.schedTime,
    required this.realTime,
    required this.status,
    this.departureAt,
    this.isCancelled = false,
  });
}

List<Departure> parseDepartures(Object? decoded) {
  final response = _asStringMap(decoded);
  if (response == null) {
    throw const FormatException('Ungültige Antwort vom KVB-Server.');
  }

  final serviceResponses = response['svcResL'];
  if (serviceResponses is! List || serviceResponses.isEmpty) {
    throw const FormatException('Die KVB-Antwort enthält keine Service-Daten.');
  }
  final serviceResponse = _asStringMap(serviceResponses.first);
  final serviceError = serviceResponse?['err'];
  if (serviceError != null) {
    final errorText = _asStringMap(serviceError)?['text'] ?? serviceError;
    if ('$errorText'.trim().toLowerCase() != 'ok') {
      throw FormatException('KVB-Serverfehler: $errorText');
    }
  }
  final result = _asStringMap(serviceResponse?['res']);
  if (result == null) {
    throw const FormatException('Die KVB-Antwort enthält keine Abfahrtsdaten.');
  }

  final productList = _asList(_asStringMap(result['common'])?['prodL']);
  final journeysValue = result['jnyL'];
  if (journeysValue == null) {
    return [];
  }
  if (journeysValue is! List) {
    throw const FormatException(
        'Die Abfahrtsliste der KVB-Antwort ist ungültig.');
  }

  return journeysValue.whereType<Map>().map((journeyValue) {
    final journey = _asStringMap(journeyValue)!;
    final productIndex = int.tryParse('${journey['prodX'] ?? ''}');
    var lineName = 'k.A.';
    if (productIndex != null &&
        productIndex >= 0 &&
        productIndex < productList.length) {
      final product = _asStringMap(productList[productIndex]);
      lineName = '${product?['name'] ?? lineName}'.trim();
      if (lineName.isEmpty) {
        lineName = 'k.A.';
      }
    }

    final stop = _asStringMap(journey['stbStop']) ?? <String, dynamic>{};
    final scheduled = '${stop['dTimeS'] ?? ''}';
    final realtime = '${stop['dTimeR'] ?? scheduled}';
    final scheduledTime = _formatTime(scheduled);
    final realTime = _formatTime(realtime);
    final cancelled = _isCancelled(journey, stop);
    final departureAt = _departureDateTime(
      realtime,
      '${stop['dDateR'] ?? ''}',
      DateTime.now(),
    );
    final delay = _delayMinutes(
      scheduled,
      realtime,
      '${stop['dDateS'] ?? ''}',
      '${stop['dDateR'] ?? ''}',
    );

    return Departure(
      line: lineName,
      destination: '${journey['dirTxt'] ?? 'Unbekannt'}',
      schedTime: scheduledTime ?? '--:--',
      realTime: realTime ?? scheduledTime ?? '--:--',
      departureAt: departureAt,
      isCancelled: cancelled,
      status: cancelled
          ? 'Fällt aus'
          : delay == null
              ? 'Unbekannt'
              : delay > 0
                  ? '+$delay min'
                  : delay < 0
                      ? '$delay min'
                      : 'Pünktlich',
    );
  }).toList();
}

bool _isCancelled(Map<String, dynamic> journey, Map<String, dynamic> stop) {
  for (final fields in [journey, stop]) {
    for (final key in ['isCncl', 'isCancelled', 'cancelled', 'cncl']) {
      final value = fields[key];
      if (value == true ||
          value == 1 ||
          '$value'.toLowerCase() == 'true' ||
          '$value' == '1') {
        return true;
      }
    }
  }
  return false;
}

DateTime? _departureDateTime(String time, String date, DateTime now) {
  final minutes = _minutesAfterMidnight(time);
  if (minutes == null) return null;
  final seconds = time.length >= 6 ? int.parse(time.substring(4, 6)) : 0;
  final day = _parseDate(date);
  if (day != null) {
    return DateTime(
      day.year,
      day.month,
      day.day,
      minutes ~/ 60,
      minutes % 60,
      seconds,
    );
  }

  var departure = DateTime(
    now.year,
    now.month,
    now.day,
    minutes ~/ 60,
    minutes % 60,
    seconds,
  );
  if (departure.isBefore(now)) {
    departure = departure.add(const Duration(days: 1));
  }
  return departure;
}

Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<dynamic> _asList(Object? value) => value is List ? value : [];

String? _formatTime(String value) {
  final match = RegExp(r'^(\d{2})(\d{2})(\d{2})?$').firstMatch(value);
  if (match == null) {
    return null;
  }
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  final second = int.parse(match[3] ?? '0');
  if (hour > 23 || minute > 59 || second > 59) {
    return null;
  }
  return '${match[1]}:${match[2]}';
}

int? _delayMinutes(
  String scheduled,
  String realtime,
  String scheduledDate,
  String realtimeDate,
) {
  final scheduledTime = _minutesAfterMidnight(scheduled);
  final realTime = _minutesAfterMidnight(realtime);
  if (scheduledTime == null || realTime == null) {
    return null;
  }

  final scheduledDay = _parseDate(scheduledDate);
  final realDay = _parseDate(realtimeDate);
  if (scheduledDay != null && realDay != null) {
    final scheduledDateTime = DateTime(
      scheduledDay.year,
      scheduledDay.month,
      scheduledDay.day,
      scheduledTime ~/ 60,
      scheduledTime % 60,
    );
    final realDateTime = DateTime(
      realDay.year,
      realDay.month,
      realDay.day,
      realTime ~/ 60,
      realTime % 60,
    );
    return realDateTime.difference(scheduledDateTime).inMinutes;
  }

  var difference = realTime - scheduledTime;
  if (difference < -720) {
    difference += 1440;
  } else if (difference > 720) {
    difference -= 1440;
  }
  return difference;
}

int? _minutesAfterMidnight(String value) {
  if (_formatTime(value) == null) {
    return null;
  }
  return int.parse(value.substring(0, 2)) * 60 +
      int.parse(value.substring(2, 4));
}

DateTime? _parseDate(String value) {
  if (!RegExp(r'^\d{8}$').hasMatch(value)) {
    return null;
  }
  final date = DateTime(
    int.parse(value.substring(0, 4)),
    int.parse(value.substring(4, 6)),
    int.parse(value.substring(6, 8)),
  );
  if (date.year.toString().padLeft(4, '0') != value.substring(0, 4) ||
      date.month.toString().padLeft(2, '0') != value.substring(4, 6) ||
      date.day.toString().padLeft(2, '0') != value.substring(6, 8)) {
    return null;
  }
  return date;
}
