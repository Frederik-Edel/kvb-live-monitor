import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvb_live_monitor/data/station_catalog.dart';
import 'package:kvb_live_monitor/models/departure.dart';
import 'package:kvb_live_monitor/services/kvb_departure_service.dart';
import 'package:kvb_live_monitor/services/walking_route_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StationCatalog', () {
    test('loads all stations from the bundled CSV asset', () async {
      final stations = await StationCatalog.load();

      expect(stations, hasLength(886));
      expect(stations.first.name, 'Köln Heumarkt');
      expect(stations[1].name, 'Köln Neumarkt');
    });

    test('parses a BOM-prefixed CSV and quoted station names', () {
      final stations = StationCatalog.parse(
        '\uFEFFstation_id,haltestellennr,name,lat,lon\r\n'
        '900000001,1,"Köln, Heumarkt",50.9,6.9\r\n',
      );

      expect(stations, hasLength(1));
      expect(stations.single.id, '900000001');
      expect(stations.single.name, 'Köln, Heumarkt');
      expect(stations.single.lat, 50.9);
    });

    test('rejects invalid coordinates', () {
      expect(
        () => StationCatalog.parse(
          'station_id,name,lat,lon\n900000001,Heumarkt,91,6.9\n',
        ),
        throwsFormatException,
      );
    });
  });

  group('parseDepartures', () {
    test('handles an overnight departure without explicit dates', () {
      final departures = parseDepartures({
        'svcResL': [
          {
            'res': {
              'common': {
                'prodL': [
                  {'name': 'Linie 1'},
                ],
              },
              'jnyL': [
                {
                  'prodX': 0,
                  'dirTxt': 'Bensberg',
                  'stbStop': {'dTimeS': '235800', 'dTimeR': '000300'},
                },
              ],
            },
          },
        ],
      });

      expect(departures.single.schedTime, '23:58');
      expect(departures.single.realTime, '00:03');
      expect(departures.single.status, '+5 min');
      expect(departures.single.line, 'Linie 1');
      expect(departures.single.departureAt, isNotNull);
    });

    test('treats an OK service status as a successful response', () {
      final departures = parseDepartures({
        'svcResL': [
          {
            'err': 'ok',
            'res': {
              'jnyL': [
                {
                  'dirTxt': 'Bensberg',
                  'stbStop': {'dTimeS': '120000'},
                },
              ],
            },
          },
        ],
      });

      expect(departures, hasLength(1));
      expect(departures.single.destination, 'Bensberg');
    });

    test('marks a cancelled journey from the response', () {
      final departures = parseDepartures({
        'svcResL': [
          {
            'res': {
              'jnyL': [
                {
                  'isCncl': true,
                  'dirTxt': 'Bensberg',
                  'stbStop': {'dTimeS': '120000'},
                },
              ],
            },
          },
        ],
      });

      expect(departures.single.isCancelled, isTrue);
      expect(departures.single.status, 'Fällt aus');
    });

    test('uses service dates when scheduled and real times cross midnight', () {
      final departures = parseDepartures({
        'svcResL': [
          {
            'res': {
              'jnyL': [
                {
                  'stbStop': {
                    'dTimeS': '235800',
                    'dDateS': '20261019',
                    'dTimeR': '000300',
                    'dDateR': '20261020',
                  },
                },
              ],
            },
          },
        ],
      });

      expect(departures.single.status, '+5 min');
    });

    test('handles early actual times across midnight as an early departure',
        () {
      final departures = parseDepartures({
        'svcResL': [
          {
            'res': {
              'jnyL': [
                {
                  'stbStop': {'dTimeS': '000500', 'dTimeR': '235500'},
                },
              ],
            },
          },
        ],
      });

      expect(departures.single.status, '-10 min');
    });

    test('tolerates absent journeys and invalid optional times', () {
      expect(
        parseDepartures({
          'svcResL': [
            {
              'res': {'jnyL': []},
            },
          ],
        }),
        isEmpty,
      );
      final departures = parseDepartures({
        'svcResL': [
          {
            'res': {
              'jnyL': [
                {
                  'stbStop': {'dTimeS': '999999'},
                },
              ],
            },
          },
        ],
      });

      expect(departures.single.schedTime, '--:--');
      expect(departures.single.status, 'Unbekannt');
    });

    test('reports an invalid response envelope', () {
      expect(() => parseDepartures({}), throwsFormatException);
    });
  });

  test('requests departures for the selected station from KVB', () async {
    final service = KvbDepartureService(
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://auskunft.kvb.koeln/gate');
        expect(request.method, 'POST');
        expect(request.headers['content-type'], 'application/json');
        expect(request.body, contains('"extId":"900000001"'));
        return http.Response(
          '{"svcResL":[{"err":"ok","res":{"jnyL":[]}}]}',
          200,
        );
      }),
    );

    expect(await service.fetch('900000001'), isEmpty);
    service.close();
  });

  test('requests a walking route and returns its distance', () async {
    final service = WalkingRouteService(
      client: MockClient((request) async {
        expect(request.url.path, contains('/route/v1/foot/'));
        return http.Response(
          '{"code":"Ok","routes":[{"distance":1234.5}]}',
          200,
        );
      }),
    );

    final result = await service.distanceInMeters(
      startLat: 50.9,
      startLon: 6.9,
      endLat: 50.91,
      endLon: 6.91,
    );
    expect(result.distanceInMeters, 1234.5);
    expect(result.isApproximate, isFalse);
    service.close();
  });

  test('uses the estimated fallback when the walking router has no route',
      () async {
    final service = WalkingRouteService(
      client: MockClient((_) async => http.Response('{"code":"NoRoute"}', 200)),
    );

    final result = await service.distanceInMeters(
      startLat: 50.9,
      startLon: 6.9,
      endLat: 50.91,
      endLon: 6.91,
    );
    expect(result.isApproximate, isTrue);
    expect(result.distanceInMeters, greaterThan(1000));
    service.close();
  });
}
