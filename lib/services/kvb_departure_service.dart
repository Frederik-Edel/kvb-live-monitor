import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../models/departure.dart';

class KvbDepartureService {
  KvbDepartureService({http.Client? client})
      : _client = client ?? http.Client();

  static final Uri _endpoint = Uri.parse('https://auskunft.kvb.koeln/gate');
  final http.Client _client;

  Future<List<Departure>> fetch(String stationId) async {
    final now = DateTime.now();
    final payload = {
      'id': 'abfahrtsmonitor_req',
      'ver': '1.78',
      'lang': 'deu',
      'auth': {'type': 'AID', 'aid': 'Rt6foY5zcTTRXMQs'},
      'client': {
        'id': 'HAFAS',
        'type': 'WEB',
        'name': 'webapp',
        'l': 'vs_webapp',
        'v': 10008,
      },
      'formatted': false,
      'svcReqL': [
        {
          'meth': 'StationBoard',
          'id': '1|6|',
          'req': {
            'type': 'DEP',
            'stbLoc': {'extId': stationId},
            'date': DateFormat('yyyyMMdd').format(now),
            'time': DateFormat('HHmmss').format(now),
            'maxJny': 15,
            'sort': 'RT',
            'jnyFltrL': [
              {'type': 'PROD', 'mode': 'INC', 'value': 155},
              {'type': 'META', 'mode': 'EXC', 'meta': 'SURCHARGE'},
            ],
          },
        },
      ],
    };

    final response = await _client
        .post(
          _endpoint,
          headers: {
            'Accept': '*/*',
            'Content-Type': 'application/json',
            'X-correlation-id': 'd5c2566e-2fd4-4b0f-bedb-b9348ec7a616',
            if (!kIsWeb)
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:155.0) Gecko/20100101 Firefox/155.0',
            if (!kIsWeb) 'Origin': 'https://auskunft.kvb.koeln',
            if (!kIsWeb) 'Referer': 'https://auskunft.kvb.koeln/',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw KvbHttpException(
        'KVB antwortete mit HTTP ${response.statusCode}.',
      );
    }
    return parseDepartures(jsonDecode(response.body));
  }

  void close() {
    _client.close();
  }
}

class KvbHttpException implements Exception {
  const KvbHttpException(this.message);

  final String message;

  @override
  String toString() => message;
}
