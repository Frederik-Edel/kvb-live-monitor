import 'package:csv/csv.dart';
import 'package:flutter/services.dart';

import '../models/station.dart';

class StationCatalog {
  static const String assetPath = 'assets/kvb_koeln_stationen_nach_nummer.csv';

  static Future<List<Station>> load() async {
    return parse(await rootBundle.loadString(assetPath));
  }

  static List<Station> parse(String csvText) {
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(csvText.replaceAll('\r\n', '\n'));
    if (rows.isEmpty) {
      throw const FormatException('Der Stationskatalog ist leer.');
    }

    final headers = rows.first
        .map((value) => value.toString().replaceFirst('\uFEFF', '').trim())
        .toList();
    final idIndex = headers.indexOf('station_id');
    final nameIndex = headers.indexOf('name');
    final latIndex = headers.indexOf('lat');
    final lonIndex = headers.indexOf('lon');
    if ([idIndex, nameIndex, latIndex, lonIndex].contains(-1)) {
      throw const FormatException(
        'Im Stationskatalog fehlen benötigte Spalten.',
      );
    }

    final stations = <Station>[];
    for (var rowIndex = 1; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      if (row.every((value) => value.toString().trim().isEmpty)) {
        continue;
      }
      if ([idIndex, nameIndex, latIndex, lonIndex]
          .any((index) => index >= row.length)) {
        throw FormatException('Ungültige CSV-Zeile ${rowIndex + 1}.');
      }

      final id = row[idIndex].toString().trim();
      final name = row[nameIndex].toString().trim();
      final lat = double.tryParse(row[latIndex].toString().trim());
      final lon = double.tryParse(row[lonIndex].toString().trim());
      if (id.isEmpty ||
          name.isEmpty ||
          lat == null ||
          lon == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lon < -180 ||
          lon > 180) {
        throw FormatException(
            'Ungültige Stationsdaten in CSV-Zeile ${rowIndex + 1}.');
      }

      stations.add(Station(id: id, name: name, lat: lat, lon: lon));
    }

    if (stations.isEmpty) {
      throw const FormatException(
          'Der Stationskatalog enthält keine Stationen.');
    }
    return stations;
  }
}
