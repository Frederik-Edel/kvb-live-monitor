import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/station_catalog.dart';
import 'models/departure.dart';
import 'models/station.dart';
import 'services/kvb_departure_service.dart';
import 'services/walking_route_service.dart';

enum DepartureTimeDisplay { time, countdown, both }

const MethodChannel _widgetChannel =
    MethodChannel('com.example.kvb_live_monitor/widget');

void main() {
  runApp(const KVBMonitorApp());
}

class KVBMonitorApp extends StatefulWidget {
  const KVBMonitorApp({super.key});

  @override
  State<KVBMonitorApp> createState() => _KVBMonitorAppState();
}

class _KVBMonitorAppState extends State<KVBMonitorApp> {
  bool _darkMode = false;

  void _setDarkMode(bool enabled) {
    setState(() => _darkMode = enabled);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KVB Live Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC8102E),
          primary: const Color(0xFFC8102E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC8102E),
          primary: const Color(0xFFC8102E),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF111827),
      ),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: MonitorHomePage(onDarkModeChanged: _setDarkMode),
    );
  }
}

class MonitorHomePage extends StatefulWidget {
  const MonitorHomePage({super.key, required this.onDarkModeChanged});

  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<MonitorHomePage> createState() => _MonitorHomePageState();
}

class _MonitorHomePageState extends State<MonitorHomePage> {
  static const String _lastStationKey = 'last_station_id';
  static const String _lineFilterEnabledKey = 'line_filter_enabled';
  static const String _autoRefreshEnabledKey = 'auto_refresh_enabled';
  static const String _darkModeEnabledKey = 'dark_mode_enabled';
  static const String _departureTimeDisplayKey = 'departure_time_display';
  static const String _walkingCheckEnabledKey = 'walking_check_enabled';
  static const String _widgetStationIdKey = 'widget_station_id';
  static const String _widgetLinesKey = 'widget_lines';
  static const Duration _autoRefreshInterval = Duration(seconds: 60);

  List<Station> _stations = [];
  Station? _currentStation;
  List<Departure> _departures = [];
  List<Departure> _widgetDepartures = [];
  List<String> _widgetAvailableLines = [];
  String? _widgetStationId;
  final Set<String> _widgetLines = {};
  final Set<String> _hiddenLines = {};
  Timer? _lineTapTimer;
  String? _pendingLineTap;
  bool? _pendingLineSelected;
  Timer? _autoRefreshTimer;
  Timer? _countdownTimer;
  SharedPreferences? _preferences;
  final KvbDepartureService _departureService = KvbDepartureService();
  final WalkingRouteService _walkingRouteService = WalkingRouteService();
  Position? _currentPosition;
  String? _walkingDistanceLabel;
  bool _isCalculatingWalkingDistance = false;
  bool _isFindingNearestStation = false;
  bool _lineFilterEnabled = true;
  bool _autoRefreshEnabled = false;
  bool _darkModeEnabled = false;
  bool _walkingCheckEnabled = true;
  DepartureTimeDisplay _departureTimeDisplay = DepartureTimeDisplay.time;
  int? _walkingMinutes;
  bool _isLoading = true;
  int _departureRequest = 0;
  int _walkingRequest = 0;
  String? _persistenceWarning;
  String _statusMessage = 'Bestimme Standort...';

  @override
  void initState() {
    super.initState();
    _initLocationAndFetch();
  }

  Future<void> _initLocationAndFetch() async {
    try {
      _stations = await StationCatalog.load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Stationskatalog konnte nicht geladen werden: $e';
      });
      return;
    }

    if (!mounted) return;
    try {
      _preferences = await SharedPreferences.getInstance();
    } catch (e) {
      _persistenceWarning = 'Letzte Station konnte nicht geladen werden: $e';
    }
    if (!mounted) return;
    final savedId = _preferences?.getString(_lastStationKey);
    _lineFilterEnabled = _preferences?.getBool(_lineFilterEnabledKey) ?? true;
    _autoRefreshEnabled =
        _preferences?.getBool(_autoRefreshEnabledKey) ?? false;
    _darkModeEnabled = _preferences?.getBool(_darkModeEnabledKey) ?? false;
    _walkingCheckEnabled =
        _preferences?.getBool(_walkingCheckEnabledKey) ?? true;
    _widgetStationId = _preferences?.getString(_widgetStationIdKey);
    _widgetLines.addAll(_preferences?.getStringList(_widgetLinesKey) ?? []);
    final timeDisplayIndex =
        _preferences?.getInt(_departureTimeDisplayKey) ?? 0;
    _departureTimeDisplay = DepartureTimeDisplay.values[
        timeDisplayIndex.clamp(0, DepartureTimeDisplay.values.length - 1)];
    widget.onDarkModeChanged(_darkModeEnabled);
    _configureDisplayTimer();
    final savedStation = _stationById(savedId);

    Position? position;
    String? locationProblem;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        locationProblem = 'Standortdienste sind deaktiviert';
      } else {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          locationProblem = permission == LocationPermission.deniedForever
              ? 'Standortberechtigung dauerhaft verweigert'
              : 'Standortberechtigung verweigert';
        } else {
          position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
            timeLimit: const Duration(seconds: 15),
          );
        }
      }
    } catch (e) {
      locationProblem = 'Standort konnte nicht ermittelt werden: $e';
    }
    if (!mounted) return;

    final station = position == null
        ? savedStation ?? _stationById('900000002') ?? _stations.first
        : _findNearest(position.latitude, position.longitude);
    _currentPosition = position;
    final status = position == null
        ? '$locationProblem. Verwende ${savedStation == null ? 'Neumarkt' : 'zuletzt verwendete Station ${station.name}'}.'
        : 'Lade Live-Daten...';
    setState(() {
      _currentStation = station;
      _walkingDistanceLabel = null;
      _isCalculatingWalkingDistance = position != null;
      _isLoading = true;
      _statusMessage = status;
    });
    if (position != null) {
      _calculateWalkingDistance(station, position);
    }
    await _saveLastStation(station);
    if (_stationById(_widgetStationId) == null) {
      _widgetStationId = station.id;
    }
    await fetchDepartures(station.id);
    await _loadWidgetStationLines(_widgetStationId!);
    _configureAutoRefresh();
    if (_persistenceWarning != null && mounted) {
      setState(() => _statusMessage = _persistenceWarning!);
    }
  }

  Future<void> _findNearestStationAgain() async {
    if (_isFindingNearestStation || _stations.isEmpty) return;
    setState(() => _isFindingNearestStation = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();
        if (!await Geolocator.isLocationServiceEnabled()) {
          throw StateError(
            'Bitte aktiviere die Standortdienste und drücke den Standort-Button erneut.',
          );
        }
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError(
          permission == LocationPermission.deniedForever
              ? 'Standortberechtigung dauerhaft verweigert.'
              : 'Standortberechtigung verweigert.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      if (!mounted) return;

      _currentPosition = position;
      final station = _findNearest(position.latitude, position.longitude);
      await _selectStation(station);
    } catch (e) {
      if (!mounted) return;
      final message = 'Standort konnte nicht neu bestimmt werden: $e';
      setState(() => _statusMessage = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() => _isFindingNearestStation = false);
      }
    }
  }

  Station? _stationById(String? id) {
    if (id == null) return null;
    for (final station in _stations) {
      if (station.id == id) return station;
    }
    return null;
  }

  Future<void> _saveLastStation(Station station) async {
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final saved = await _preferences!.setString(_lastStationKey, station.id);
      if (!saved) {
        throw StateError('Die Station konnte nicht gespeichert werden.');
      }
      _persistenceWarning = null;
    } catch (e) {
      _persistenceWarning =
          'Letzte Station konnte nicht gespeichert werden: $e';
    }
  }

  Future<void> _selectStation(Station station) async {
    if (!mounted) return;
    _departureRequest++;
    _walkingRequest++;
    _lineTapTimer?.cancel();
    _pendingLineTap = null;
    _pendingLineSelected = null;
    setState(() {
      _currentStation = station;
      _departures = [];
      _hiddenLines.clear();
      _walkingDistanceLabel = null;
      _walkingMinutes = null;
      _isCalculatingWalkingDistance = _currentPosition != null;
    });
    _configureAutoRefresh();
    if (_currentPosition case final position?) {
      _calculateWalkingDistance(station, position);
    }
    await _saveLastStation(station);
    await fetchDepartures(station.id);
    if (_persistenceWarning != null && mounted) {
      setState(() => _statusMessage = _persistenceWarning!);
    }
  }

  Future<void> _calculateWalkingDistance(
    Station station,
    Position position,
  ) async {
    final requestId = ++_walkingRequest;
    try {
      final route = await _walkingRouteService.distanceInMeters(
        startLat: position.latitude,
        startLon: position.longitude,
        endLat: station.lat,
        endLon: station.lon,
      );
      if (!mounted ||
          requestId != _walkingRequest ||
          _currentStation?.id != station.id) {
        return;
      }
      final walkingMinutes = (route.distanceInMeters / 5000 * 60).ceil();
      final label =
          'ca. $walkingMinutes ${walkingMinutes == 1 ? 'Minute' : 'Minuten'} Fußweg'
          '${route.isApproximate ? ' (Schätzung)' : ''}';
      setState(() {
        _walkingDistanceLabel = label;
        _walkingMinutes = walkingMinutes;
        _isCalculatingWalkingDistance = false;
      });
    } catch (_) {
      if (!mounted ||
          requestId != _walkingRequest ||
          _currentStation?.id != station.id) {
        return;
      }
      setState(() {
        _walkingDistanceLabel = 'Fußweg nicht verfügbar';
        _walkingMinutes = null;
        _isCalculatingWalkingDistance = false;
      });
    }
  }

  Station _findNearest(double lat, double lon) {
    if (_stations.isEmpty) {
      throw StateError('Der Stationskatalog enthält keine Stationen.');
    }
    Station closest = _stations.first;
    double minDistance = double.infinity;

    for (final station in _stations) {
      final dist = _calculateDistance(lat, lon, station.lat, station.lon);
      if (dist < minDistance) {
        minDistance = dist;
        closest = station;
      }
    }
    return closest;
  }

  double _calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295;
    final c = cos;
    final a = 0.5 -
        c((lat2 - lat1) * p) / 2 +
        c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
    return 12742 * asin(sqrt(a.clamp(0.0, 1.0)));
  }

  Future<void> fetchDepartures(String stationId) async {
    if (!mounted) return;
    final requestId = ++_departureRequest;
    setState(() {
      _isLoading = true;
      _statusMessage = 'Lade Live-Daten...';
    });

    try {
      final fetched = await _departureService.fetch(stationId);
      if (!mounted || requestId != _departureRequest) return;
      setState(() {
        _departures = fetched;
        _isLoading = false;
        _statusMessage = fetched.isEmpty
            ? 'Keine Abfahrten gefunden.'
            : 'Live-Daten geladen.';
      });
      if (_widgetStationId == stationId) {
        _widgetDepartures = fetched;
        _widgetAvailableLines =
            fetched.map((departure) => departure.line).toSet().toList()..sort();
      }
      await _updateNativeWidget();
    } on TimeoutException {
      if (!mounted || requestId != _departureRequest) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Zeitüberschreitung beim Laden der Abfahrten.';
      });
    } catch (e) {
      if (!mounted || requestId != _departureRequest) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Abfahrten konnten nicht geladen werden: $e';
      });
    }
  }

  void _openSearchDialog() {
    showDialog(
      context: context,
      builder: (context) => _StationSearchDialog(
        stations: _stations,
        onSelected: (station) {
          Navigator.pop(context);
          _selectStation(station);
        },
      ),
    );
  }

  Future<void> _setLineFilterEnabled(bool enabled) async {
    setState(() => _lineFilterEnabled = enabled);
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final saved = await _preferences!.setBool(_lineFilterEnabledKey, enabled);
      if (!saved) {
        throw StateError('Die Einstellung konnte nicht gespeichert werden.');
      }
    } catch (e) {
      _showSettingsSaveError(e);
    }
  }

  Future<void> _setAutoRefreshEnabled(bool enabled) async {
    setState(() => _autoRefreshEnabled = enabled);
    _configureAutoRefresh();
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final saved =
          await _preferences!.setBool(_autoRefreshEnabledKey, enabled);
      if (!saved) {
        throw StateError('Die Einstellung konnte nicht gespeichert werden.');
      }
    } catch (e) {
      _showSettingsSaveError(e);
    }
  }

  Future<void> _setDarkModeEnabled(bool enabled) async {
    setState(() => _darkModeEnabled = enabled);
    widget.onDarkModeChanged(enabled);
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final saved = await _preferences!.setBool(_darkModeEnabledKey, enabled);
      if (!saved) {
        throw StateError('Die Einstellung konnte nicht gespeichert werden.');
      }
    } catch (e) {
      _showSettingsSaveError(e);
    }
  }

  Future<void> _setWalkingCheckEnabled(bool enabled) async {
    setState(() => _walkingCheckEnabled = enabled);
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final saved =
          await _preferences!.setBool(_walkingCheckEnabledKey, enabled);
      if (!saved) {
        throw StateError('Die Einstellung konnte nicht gespeichert werden.');
      }
    } catch (e) {
      _showSettingsSaveError(e);
    }
  }

  Future<void> _setDepartureTimeDisplay(
    DepartureTimeDisplay display,
  ) async {
    setState(() => _departureTimeDisplay = display);
    _configureDisplayTimer();
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final saved =
          await _preferences!.setInt(_departureTimeDisplayKey, display.index);
      if (!saved) {
        throw StateError('Die Einstellung konnte nicht gespeichert werden.');
      }
    } catch (e) {
      _showSettingsSaveError(e);
    }
  }

  Future<List<String>> _setWidgetStation(String stationId) async {
    _widgetStationId = stationId;
    _widgetLines.clear();
    _preferences ??= await SharedPreferences.getInstance();
    final saved = await _preferences!.setString(_widgetStationIdKey, stationId);
    if (!saved) {
      throw StateError('Widget-Haltestelle konnte nicht gespeichert werden.');
    }
    return _loadWidgetStationLines(stationId);
  }

  Future<List<String>> _loadWidgetStationLines(String stationId) async {
    final station = _stationById(stationId);
    if (station == null) {
      throw StateError('Die Widget-Haltestelle wurde nicht gefunden.');
    }

    final departures = stationId == _currentStation?.id
        ? _departures
        : await _departureService.fetch(stationId);
    _widgetStationId = stationId;
    _widgetDepartures = departures;
    _widgetAvailableLines =
        departures.map((departure) => departure.line).toSet().toList()..sort();
    if (_widgetLines.isEmpty ||
        _widgetLines.every((line) => !_widgetAvailableLines.contains(line))) {
      _widgetLines
        ..clear()
        ..addAll(_widgetAvailableLines);
    } else {
      _widgetLines.removeWhere(
        (line) => !_widgetAvailableLines.contains(line),
      );
    }
    final stationSaved =
        await _preferences?.setString(_widgetStationIdKey, stationId) ?? false;
    if (!stationSaved) {
      throw StateError('Widget-Haltestelle konnte nicht gespeichert werden.');
    }
    await _saveWidgetLines();
    await _updateNativeWidget();
    return _widgetAvailableLines;
  }

  Future<void> _setWidgetLines(Set<String> selectedLines) async {
    _widgetLines
      ..clear()
      ..addAll(selectedLines);
    try {
      await _saveWidgetLines();
      await _updateNativeWidget();
    } catch (e) {
      _showSettingsSaveError(e);
    }
  }

  Future<void> _saveWidgetLines() async {
    _preferences ??= await SharedPreferences.getInstance();
    final saved = await _preferences!.setStringList(
      _widgetLinesKey,
      _widgetLines.toList(),
    );
    if (!saved) {
      throw StateError('Widget-Linien konnten nicht gespeichert werden.');
    }
  }

  Future<void> _updateNativeWidget() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final station = _stationById(_widgetStationId);
    try {
      await _widgetChannel.invokeMethod<void>('updateWidget', {
        'stationName': station?.name ?? 'KVB Abfahrten',
        'departures': _widgetDepartures
            .where((departure) => _widgetLines.contains(departure.line))
            .take(5)
            .map(
              (departure) => {
                'line': departure.line,
                'destination': departure.destination,
                'time': departure.realTime,
                'status': departure.status,
                'cancelled': departure.isCancelled,
              },
            )
            .toList(),
      });
    } on PlatformException catch (e) {
      _showSettingsSaveError(e);
    }
  }

  void _configureDisplayTimer() {
    _countdownTimer?.cancel();
    if (_departureTimeDisplay != DepartureTimeDisplay.time) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _showSettingsSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Einstellung konnte nicht gespeichert werden: $error')),
    );
  }

  void _configureAutoRefresh() {
    _autoRefreshTimer?.cancel();
    if (!_autoRefreshEnabled || _currentStation == null) return;
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      final station = _currentStation;
      if (mounted && station != null) {
        _refreshDepartures(reportWidgetErrors: false);
      }
    });
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _SettingsDialog(
        lineFilterEnabled: _lineFilterEnabled,
        autoRefreshEnabled: _autoRefreshEnabled,
        darkModeEnabled: _darkModeEnabled,
        departureTimeDisplay: _departureTimeDisplay,
        walkingCheckEnabled: _walkingCheckEnabled,
        onLineFilterChanged: _setLineFilterEnabled,
        onAutoRefreshChanged: _setAutoRefreshEnabled,
        onDarkModeChanged: _setDarkModeEnabled,
        onDepartureTimeDisplayChanged: _setDepartureTimeDisplay,
        onWalkingCheckChanged: _setWalkingCheckEnabled,
        stations: _stations,
        widgetStationId: _widgetStationId ?? _currentStation?.id,
        widgetLines: _widgetLines,
        widgetAvailableLines: _widgetAvailableLines,
        onWidgetStationChanged: _setWidgetStation,
        onWidgetLinesChanged: _setWidgetLines,
      ),
    );
  }

  Future<void> _refreshDepartures({bool reportWidgetErrors = true}) async {
    final station = _currentStation;
    if (station == null) return;
    await fetchDepartures(station.id);
    final widgetStationId = _widgetStationId;
    if (widgetStationId != null && widgetStationId != station.id) {
      try {
        _widgetDepartures = await _departureService.fetch(widgetStationId);
        _widgetAvailableLines = _widgetDepartures
            .map((departure) => departure.line)
            .toSet()
            .toList()
          ..sort();
        _widgetLines
            .removeWhere((line) => !_widgetAvailableLines.contains(line));
        await _updateNativeWidget();
      } catch (e) {
        if (reportWidgetErrors && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text('Widget-Abfahrten konnten nicht geladen werden: $e')),
          );
        } else {
          debugPrint('Widget-Abfahrten konnten nicht geladen werden: $e');
        }
      }
    }
  }

  String _departureTimeLabel(Departure departure) {
    if (_departureTimeDisplay == DepartureTimeDisplay.time) {
      return departure.realTime;
    }
    final departureAt = departure.departureAt;
    if (departureAt == null) return departure.realTime;
    final difference = departureAt.difference(DateTime.now());
    final remainingMinutes = (difference.inSeconds / 60).ceil();
    final countdown =
        remainingMinutes <= 0 ? 'jetzt' : 'in $remainingMinutes Min';
    return _departureTimeDisplay == DepartureTimeDisplay.countdown
        ? countdown
        : '$countdown (${departure.realTime})';
  }

  bool _isTooLateToWalk(Departure departure) {
    final departureAt = departure.departureAt;
    final walkingMinutes = _walkingMinutes;
    if (!_walkingCheckEnabled ||
        _currentPosition == null ||
        departure.isCancelled ||
        departureAt == null ||
        walkingMinutes == null) {
      return false;
    }
    final minutesUntilDeparture =
        departureAt.difference(DateTime.now()).inMinutes;
    return minutesUntilDeparture >= 0 &&
        minutesUntilDeparture <= walkingMinutes + 1;
  }

  void _handleLineTap(String line, bool selected, List<String> lines) {
    if (_pendingLineTap == line && _lineTapTimer?.isActive == true) {
      _lineTapTimer?.cancel();
      _lineTapTimer = null;
      _pendingLineTap = null;
      _pendingLineSelected = null;
      setState(() {
        final visibleLines =
            lines.where((currentLine) => !_hiddenLines.contains(currentLine));
        if (visibleLines.length == 1 && visibleLines.single == line) {
          _hiddenLines.removeAll(lines);
        } else {
          _hiddenLines
            ..clear()
            ..addAll(lines.where((currentLine) => currentLine != line));
        }
      });
      return;
    }

    if (_lineTapTimer?.isActive == true && _pendingLineTap != null) {
      final previousLine = _pendingLineTap!;
      final previousSelection = _pendingLineSelected!;
      setState(() {
        if (previousSelection) {
          _hiddenLines.remove(previousLine);
        } else {
          _hiddenLines.add(previousLine);
        }
      });
    }
    _lineTapTimer?.cancel();
    _pendingLineTap = line;
    _pendingLineSelected = selected;
    _lineTapTimer = Timer(const Duration(milliseconds: 300), () {
      _pendingLineTap = null;
      _pendingLineSelected = null;
      if (!mounted) return;
      setState(() {
        if (selected) {
          _hiddenLines.remove(line);
        } else {
          _hiddenLines.add(line);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lines =
        _departures.map((departure) => departure.line).toSet().toList()..sort();
    final visibleDepartures = _lineFilterEnabled
        ? _departures
            .where((departure) => !_hiddenLines.contains(departure.line))
            .toList()
        : _departures;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('KVB Abfahrtsmonitor',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(
              _currentStation != null
                  ? _currentStation!.name
                  : 'Standort wird gesucht...',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
            if (_currentStation != null &&
                (_isCalculatingWalkingDistance ||
                    _walkingDistanceLabel != null))
              Text(
                _isCalculatingWalkingDistance
                    ? 'Fußweg wird berechnet...'
                    : _walkingDistanceLabel!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Haltestelle suchen',
            onPressed: _openSearchDialog,
          ),
          IconButton(
            icon: _isFindingNearestStation
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.my_location),
            tooltip: 'Nächste Haltestelle am Standort suchen',
            onPressed: _isFindingNearestStation || _stations.isEmpty
                ? null
                : _findNearestStationAgain,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren',
            onPressed: _refreshDepartures,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Einstellungen',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_lineFilterEnabled && lines.isNotEmpty)
            SizedBox(
              height: 58,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(line),
                        selected: !_hiddenLines.contains(line),
                        onSelected: (selected) =>
                            _handleLineTap(line, selected, lines),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => RefreshIndicator(
                onRefresh: _refreshDepartures,
                child: _isLoading && _departures.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: constraints.maxHeight,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const CircularProgressIndicator(
                                      color: Color(0xFFC8102E)),
                                  const SizedBox(height: 16),
                                  Text(
                                    _statusMessage,
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : visibleDepartures.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height: constraints.maxHeight,
                                child: Center(
                                  child: Text(
                                    _departures.isEmpty
                                        ? _statusMessage
                                        : 'Alle Linien sind ausgeblendet.',
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: visibleDepartures.length,
                            separatorBuilder: (context, index) => Divider(
                                height: 1, color: colorScheme.outlineVariant),
                            itemBuilder: (context, index) {
                              final dep = visibleDepartures[index];
                              final tooLate = _isTooLateToWalk(dep);
                              final strikeStyle = TextStyle(
                                decoration: dep.isCancelled
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: dep.isCancelled
                                    ? colorScheme.error
                                    : tooLate
                                        ? colorScheme.onSurfaceVariant
                                        : null,
                              );
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                color: dep.isCancelled
                                    ? colorScheme.errorContainer
                                    : tooLate
                                        ? colorScheme.surfaceContainerHighest
                                        : colorScheme.surface,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 36,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFC8102E),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        dep.line,
                                        style: TextStyle(
                                          color: dep.isCancelled
                                              ? colorScheme.onError
                                              : Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          decoration: dep.isCancelled
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            dep.destination,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 15,
                                            ).merge(strikeStyle),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Soll: ${dep.schedTime}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ).merge(strikeStyle),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          _departureTimeLabel(dep),
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: 'monospace',
                                          ).merge(strikeStyle),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          dep.status,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: dep.isCancelled
                                                ? colorScheme.error
                                                : tooLate
                                                    ? colorScheme
                                                        .onSurfaceVariant
                                                    : dep.status.startsWith('+')
                                                        ? colorScheme.error
                                                        : colorScheme.tertiary,
                                            decoration: dep.isCancelled
                                                ? TextDecoration.lineThrough
                                                : null,
                                          ).merge(strikeStyle),
                                        ),
                                        if (tooLate)
                                          Text(
                                            'Zu knapp',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _countdownTimer?.cancel();
    _lineTapTimer?.cancel();
    _departureService.close();
    _walkingRouteService.close();
    super.dispose();
  }
}

class _StationSearchDialog extends StatefulWidget {
  const _StationSearchDialog({
    required this.stations,
    required this.onSelected,
  });

  final List<Station> stations;
  final ValueChanged<Station> onSelected;

  @override
  State<_StationSearchDialog> createState() => _StationSearchDialogState();
}

class _StationSearchDialogState extends State<_StationSearchDialog> {
  final TextEditingController _controller = TextEditingController();
  Timer? _searchDebounce;
  List<Station> _filteredStations = [];
  List<String> _normalizedNames = [];

  @override
  void initState() {
    super.initState();
    _filteredStations = widget.stations;
    _normalizedNames =
        widget.stations.map((station) => station.name.toLowerCase()).toList();
  }

  void _filterStations(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      final normalizedQuery = query.trim().toLowerCase();
      setState(() {
        _filteredStations = normalizedQuery.isEmpty
            ? widget.stations
            : [
                for (var index = 0; index < widget.stations.length; index++)
                  if (_normalizedNames[index].contains(normalizedQuery) ||
                      widget.stations[index].id.contains(normalizedQuery))
                    widget.stations[index],
              ];
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.bottom - 48;
    return Dialog(
      child: SizedBox(
        width: 520,
        height: availableHeight.clamp(120.0, 600.0).toDouble(),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Text(
                'Alle Haltestellen durchsuchen',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Haltestelle eingeben (z.B. Ehrenfeld)...',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: _filterStations,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('${_filteredStations.length} Haltestellen'),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: _filteredStations.length,
                  itemBuilder: (context, index) {
                    final station = _filteredStations[index];
                    return ListTile(
                      dense: true,
                      title: Text(station.name),
                      subtitle: Text('ID: ${station.id}'),
                      onTap: () => widget.onSelected(station),
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Schließen'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.lineFilterEnabled,
    required this.autoRefreshEnabled,
    required this.darkModeEnabled,
    required this.departureTimeDisplay,
    required this.walkingCheckEnabled,
    required this.onLineFilterChanged,
    required this.onAutoRefreshChanged,
    required this.onDarkModeChanged,
    required this.onDepartureTimeDisplayChanged,
    required this.onWalkingCheckChanged,
    required this.stations,
    required this.widgetStationId,
    required this.widgetLines,
    required this.widgetAvailableLines,
    required this.onWidgetStationChanged,
    required this.onWidgetLinesChanged,
  });

  final bool lineFilterEnabled;
  final bool autoRefreshEnabled;
  final bool darkModeEnabled;
  final DepartureTimeDisplay departureTimeDisplay;
  final bool walkingCheckEnabled;
  final ValueChanged<bool> onLineFilterChanged;
  final ValueChanged<bool> onAutoRefreshChanged;
  final ValueChanged<bool> onDarkModeChanged;
  final ValueChanged<DepartureTimeDisplay> onDepartureTimeDisplayChanged;
  final ValueChanged<bool> onWalkingCheckChanged;
  final List<Station> stations;
  final String? widgetStationId;
  final Set<String> widgetLines;
  final List<String> widgetAvailableLines;
  final Future<List<String>> Function(String stationId) onWidgetStationChanged;
  final ValueChanged<Set<String>> onWidgetLinesChanged;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late bool _lineFilterEnabled = widget.lineFilterEnabled;
  late bool _autoRefreshEnabled = widget.autoRefreshEnabled;
  late bool _darkModeEnabled = widget.darkModeEnabled;
  late bool _walkingCheckEnabled = widget.walkingCheckEnabled;
  late DepartureTimeDisplay _departureTimeDisplay = widget.departureTimeDisplay;
  late String? _widgetStationId = widget.widgetStationId;
  late Set<String> _widgetLines = {...widget.widgetLines};
  late List<String> _widgetAvailableLines = widget.widgetAvailableLines;
  bool _isLoadingWidgetLines = false;
  String? _widgetError;
  LocationPermission? _permission;
  bool? _locationEnabled;

  @override
  void initState() {
    super.initState();
    _loadLocationStatus();
  }

  Future<void> _loadLocationStatus() async {
    final permission = await Geolocator.checkPermission();
    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      _permission = permission;
      _locationEnabled = locationEnabled;
    });
  }

  Future<void> _openPermissionSettings() async {
    final permission = _permission;
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
    } else {
      await Geolocator.requestPermission();
    }
    await _loadLocationStatus();
  }

  Future<void> _openLocationSettings() async {
    await Geolocator.openLocationSettings();
    await _loadLocationStatus();
  }

  Future<void> _selectWidgetStation(String? stationId) async {
    if (stationId == null) return;
    setState(() {
      _widgetStationId = stationId;
      _isLoadingWidgetLines = true;
      _widgetError = null;
      _widgetLines.clear();
    });
    try {
      final lines = await widget.onWidgetStationChanged(stationId);
      if (!mounted) return;
      setState(() {
        _widgetAvailableLines = lines;
        _widgetLines = lines.toSet();
        _isLoadingWidgetLines = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _widgetError = 'Linien konnten nicht geladen werden: $e';
        _isLoadingWidgetLines = false;
      });
    }
  }

  void _toggleWidgetLine(String line, bool enabled) {
    setState(() {
      if (enabled) {
        _widgetLines.add(line);
      } else {
        _widgetLines.remove(line);
      }
    });
    widget.onWidgetLinesChanged(_widgetLines);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Einstellungen'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Linienfilter anzeigen'),
            subtitle: const Text('Linien an der Station ein- und ausblenden'),
            value: _lineFilterEnabled,
            onChanged: (enabled) {
              setState(() => _lineFilterEnabled = enabled);
              widget.onLineFilterChanged(enabled);
            },
          ),
          DropdownButtonFormField<DepartureTimeDisplay>(
            initialValue: _departureTimeDisplay,
            decoration: const InputDecoration(
              labelText: 'Abfahrtszeit anzeigen als',
            ),
            items: const [
              DropdownMenuItem(
                value: DepartureTimeDisplay.time,
                child: Text('Uhrzeit'),
              ),
              DropdownMenuItem(
                value: DepartureTimeDisplay.countdown,
                child: Text('Countdown'),
              ),
              DropdownMenuItem(
                value: DepartureTimeDisplay.both,
                child: Text('Countdown und Uhrzeit'),
              ),
            ],
            onChanged: (display) {
              if (display == null) return;
              setState(() => _departureTimeDisplay = display);
              widget.onDepartureTimeDisplayChanged(display);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Fußweg mit Abfahrten verknüpfen'),
            subtitle: const Text(
              'Markiert Abfahrten als „Zu knapp“, wenn die Gehzeit nicht reicht',
            ),
            value: _walkingCheckEnabled,
            onChanged: (enabled) {
              setState(() => _walkingCheckEnabled = enabled);
              widget.onWalkingCheckChanged(enabled);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Automatisch aktualisieren'),
            subtitle: const Text('Abfahrten alle 60 Sekunden aktualisieren'),
            value: _autoRefreshEnabled,
            onChanged: (enabled) {
              setState(() => _autoRefreshEnabled = enabled);
              widget.onAutoRefreshChanged(enabled);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dark Mode'),
            value: _darkModeEnabled,
            onChanged: (enabled) {
              setState(() => _darkModeEnabled = enabled);
              widget.onDarkModeChanged(enabled);
            },
          ),
          const Divider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Widget',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _widgetStationId,
            decoration: const InputDecoration(labelText: 'Widget-Haltestelle'),
            items: [
              for (final station in widget.stations)
                DropdownMenuItem(
                  value: station.id,
                  child: Text(
                    station.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _selectWidgetStation,
          ),
          if (_isLoadingWidgetLines)
            const Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            )
          else if (_widgetError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _widgetError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            )
          else if (_widgetAvailableLines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Für die Haltestelle sind keine Linien verfügbar.'),
            )
          else
            Column(
              children: [
                for (final line in _widgetAvailableLines)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(line),
                    value: _widgetLines.contains(line),
                    onChanged: (enabled) =>
                        _toggleWidgetLine(line, enabled ?? false),
                  ),
              ],
            ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Standortberechtigung'),
            subtitle: Text(
              _permission == null
                  ? 'Wird geprüft...'
                  : _permissionLabel(_permission!),
            ),
            trailing: const Icon(Icons.my_location),
            onTap: _openPermissionSettings,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Standortdienste'),
            subtitle: Text(
              _locationEnabled == null
                  ? 'Wird geprüft...'
                  : _locationEnabled!
                      ? 'Aktiviert'
                      : 'Deaktiviert',
            ),
            trailing: const Icon(Icons.settings),
            onTap: _openLocationSettings,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Schließen'),
        ),
      ],
    );
  }

  String _permissionLabel(LocationPermission permission) {
    return switch (permission) {
      LocationPermission.always => 'Immer erlaubt',
      LocationPermission.whileInUse => 'Während der Nutzung erlaubt',
      LocationPermission.denied => 'Nicht erteilt',
      LocationPermission.deniedForever => 'Dauerhaft verweigert',
      LocationPermission.unableToDetermine => 'Unbekannt',
    };
  }
}
