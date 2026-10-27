import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

class WalkingRouteService {
  WalkingRouteService({http.Client? client})
      : _client = client ?? http.Client();

  static const String _baseUrl = 'https://router.project-osrm.org';
  final http.Client _client;

  Future<WalkingRouteResult> distanceInMeters({
    required double startLat,
    required double startLon,
    required double endLat,
    required double endLon,
  }) async {
    try {
      final coordinates = '$startLon,$startLat;$endLon,$endLat';
      final uri = Uri.parse('$_baseUrl/route/v1/foot/$coordinates')
          .replace(queryParameters: const {'overview': 'false'});
      final response = await _client.get(uri).timeout(
            const Duration(seconds: 10),
          );
      if (response.statusCode != 200) {
        throw HttpException(
          'OSRM antwortete mit HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['code'] != 'Ok') {
        throw const FormatException('OSRM konnte keine Fußroute berechnen.');
      }
      final routes = decoded['routes'];
      if (routes is! List || routes.isEmpty || routes.first is! Map) {
        throw const FormatException('OSRM lieferte keine Fußroute.');
      }
      final distance = (routes.first as Map)['distance'];
      if (distance is! num || !distance.isFinite || distance < 0) {
        throw const FormatException('OSRM lieferte eine ungültige Wegstrecke.');
      }
      return WalkingRouteResult(
        distanceInMeters: distance.toDouble(),
        isApproximate: false,
      );
    } on Exception {
      return WalkingRouteResult(
        distanceInMeters: _airDistanceInMeters(
              startLat,
              startLon,
              endLat,
              endLon,
            ) *
            1.3,
        isApproximate: true,
      );
    }
  }

  void close() {
    _client.close();
  }
}

class WalkingRouteResult {
  const WalkingRouteResult({
    required this.distanceInMeters,
    required this.isApproximate,
  });

  final double distanceInMeters;
  final bool isApproximate;
}

double _airDistanceInMeters(
  double startLat,
  double startLon,
  double endLat,
  double endLon,
) {
  const earthRadiusMeters = 6371000.0;
  final latitudeDelta = _toRadians(endLat - startLat);
  final longitudeDelta = _toRadians(endLon - startLon);
  final startLatitude = _toRadians(startLat);
  final endLatitude = _toRadians(endLat);
  final a = pow(sin(latitudeDelta / 2), 2) +
      cos(startLatitude) * cos(endLatitude) * pow(sin(longitudeDelta / 2), 2);
  return earthRadiusMeters * 2 * asin(sqrt(a.clamp(0.0, 1.0)));
}

double _toRadians(double degrees) => degrees * pi / 180;

class HttpException implements Exception {
  const HttpException(this.message);

  final String message;

  @override
  String toString() => message;
}
