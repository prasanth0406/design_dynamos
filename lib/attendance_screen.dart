// The readable concatenations here avoid building large dynamic UI strings inline.
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_theme.dart';
import 'attendance_backend.dart';

const String bleServiceUuid = 'bf27730d-860a-4e09-889c-2d8b6a9e0fe7';

String _newSessionCode() =>
    (100000 + Random.secure().nextInt(900000)).toString();

/// 6 random bytes broadcast in the BLE scan response next to the session ID.
/// The server only stores their SHA-256 hash and rotates them with the QR.
Uint8List _newBleToken() {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(6, (_) => random.nextInt(256)));
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _attendanceStartError(Object error) {
  final detail = error.toString();
  if (detail.contains('PGRST202') ||
      (detail.contains('create_attendance_session') &&
          detail.contains('schema cache'))) {
    return 'Supabase is missing the attendance RPC. Run '
        'supabase/attendance_workflow.sql in the Supabase SQL Editor, '
        'then retry.';
  }
  return 'Could not start attendance: $detail';
}

/// Wait until Supabase Realtime confirms the Postgres-change channel is ready.
Future<void> _subscribeAndWait(RealtimeChannel channel) {
  final completer = Completer<void>();
  channel.subscribe((status, error) {
    if (status == RealtimeSubscribeStatus.subscribed) {
      if (!completer.isCompleted) completer.complete();
    } else if (status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.timedOut ||
        status == RealtimeSubscribeStatus.closed) {
      if (!completer.isCompleted) {
        completer.completeError(
          Exception(
            'Supabase Realtime subscription failed: $status${error == null ? "" : " ($error)"}',
          ),
        );
      }
    }
  });
  return completer.future.timeout(const Duration(seconds: 12));
}

class _SessionNameDialog extends StatefulWidget {
  const _SessionNameDialog();

  @override
  State<_SessionNameDialog> createState() => _SessionNameDialogState();
}

class _SessionNameDialogState extends State<_SessionNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create attendance session'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Session name',
          hintText: 'e.g. CS164 - Period 1',
        ),
        onSubmitted: (value) {
          final name = value.trim();
          if (name.isNotEmpty) Navigator.of(context).pop(name);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isNotEmpty) Navigator.of(context).pop(name);
          },
          child: const Text('CREATE'),
        ),
      ],
    );
  }
}

/// Teacher creates a named session and advertises the BLE service.
/// Attendance confirmations are sent over a Supabase Realtime broadcast channel.
class TeacherBleScreen extends StatefulWidget {
  const TeacherBleScreen({super.key});

  @override
  State<TeacherBleScreen> createState() => _TeacherBleScreenState();
}

class _TeacherBleScreenState extends State<TeacherBleScreen> {
  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  final AttendanceBackend _backend = AttendanceBackend(
    Supabase.instance.client,
  );
  final Map<String, DateTime> _presentStudents = <String, DateTime>{};
  final Set<String> _issuedQrCodes = <String>{};

  RealtimeChannel? _attendanceChannel;
  Timer? _qrRotationTimer;
  Timer? _sessionEndTimer;
  bool _isAdvertising = false;
  bool _isLoading = false;
  bool _isRotatingQr = false;
  String _status = 'Create a session to begin attendance.';
  String _sessionName = '';
  String _sessionId = '';
  String _qrCode = '';
  String? _activeSessionUuid;
  int _qrNumber = 0;

  String _generateQrCode() {
    String code;
    do {
      code = _newSessionCode();
    } while (code == _sessionId || !_issuedQrCodes.add(code));
    return code;
  }

  Future<String?> _askSessionName() => showDialog<String>(
    context: context,
    builder: (_) => const _SessionNameDialog(),
  );

  Future<void> _startAdvertising() async {
    if (_isLoading || _isAdvertising) return;
    final name = await _askSessionName();
    if (name == null || name.trim().isEmpty || !mounted) return;

    setState(() {
      _isLoading = true;
      _presentStudents.clear();
      _status = 'Checking Bluetooth and permissions...';
    });

    ActiveAttendanceSession? session;
    RealtimeChannel? channel;
    var advertisingStarted = false;
    try {
      if (!await _peripheral.isSupported) {
        throw Exception('This phone does not support BLE advertising.');
      }
      var permission = await _peripheral.hasPermission();
      if (permission != PeripheralBluetoothState.granted &&
          permission != PeripheralBluetoothState.ready) {
        permission = await _peripheral.requestPermission();
      }
      if (permission == PeripheralBluetoothState.turnedOff) {
        if (!await _peripheral.enableBluetooth()) {
          throw Exception('Turn on Bluetooth, then try again.');
        }
        permission = await _peripheral.hasPermission();
      }
      if (permission != PeripheralBluetoothState.granted &&
          permission != PeripheralBluetoothState.ready) {
        throw Exception(
          'Bluetooth permission was not granted (' +
              permission.toString() +
              ').',
        );
      }

      final initialQr = _newSessionCode();
      final initialBle = _newBleToken();
      final activeSession = await _backend.createSession(
        title: name.trim(),
        initialQrCode: initialQr,
        initialBleToken: _hex(initialBle),
      );
      session = activeSession;
      _sessionId = activeSession.sessionCode;
      _issuedQrCodes
        ..clear()
        ..add(initialQr);
      var displayedQr = initialQr;
      if (displayedQr == _sessionId) {
        displayedQr = _generateQrCode();
        await _backend.rotateQr(
          sessionId: activeSession.id,
          qrCode: displayedQr,
          bleToken: _hex(initialBle),
        );
      }

      channel = _backend.watchPresentStudents(
        sessionId: activeSession.id,
        onRecord: (record) {
          if (!mounted) return;
          setState(() {
            _presentStudents.putIfAbsent(record.email, () => record.markedAt);
            _status =
                _presentStudents.length.toString() +
                ' student(s) marked present.';
          });
        },
      );
      await _subscribeAndWait(channel);
      final records = await _backend.loadPresentStudents(activeSession.id);

      final result = await _advertise(activeSession.sessionCode, initialBle);
      if (result != PeripheralBluetoothState.granted &&
          result != PeripheralBluetoothState.ready) {
        throw Exception(
          'BLE advertising could not start (' + result.toString() + ').',
        );
      }
      advertisingStarted = true;

      if (!mounted) {
        await _peripheral.stop();
        await _backend.stopSession(activeSession.id);
        await Supabase.instance.client.removeChannel(channel);
        return;
      }

      _attendanceChannel = channel;
      _activeSessionUuid = activeSession.id;
      setState(() {
        _sessionName = activeSession.title;
        _sessionId = activeSession.sessionCode;
        _qrCode = displayedQr;
        _qrNumber = 1;
        _isAdvertising = true;
        _presentStudents.addEntries(
          records.map((record) => MapEntry(record.email, record.markedAt)),
        );
        _status = 'BLE is advertising. QR 1 of 6 is active for 10 seconds.';
      });
      _startQrTimers(activeSession.endsAt);
    } catch (error) {
      try {
        await _peripheral.stop();
      } catch (_) {}
      if (session != null && !advertisingStarted) {
        try {
          await _backend.stopSession(session.id);
        } catch (_) {}
      }
      if (channel != null) {
        try {
          await Supabase.instance.client.removeChannel(channel);
        } catch (_) {}
      }
      if (mounted) {
        setState(() => _status = _attendanceStartError(error));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Scan-response service data = 6 ASCII session-ID digits + 6 rotating
  /// BLE-token bytes (2 + 16 + 12 = 30 of the 31 available bytes). Students
  /// resolve the ID through Supabase and must present the current token.
  Future<PeripheralBluetoothState> _advertise(
    String sessionCode,
    List<int> bleToken,
  ) => _peripheral.start(
    advertiseData: const AdvertiseDataCore(serviceUuid: bleServiceUuid),
    androidSettings: AndroidAdvertiseSettings(
      advertiseResponseData: AndroidAdvertiseData(
        serviceDataUuid: bleServiceUuid,
        serviceData: Uint8List.fromList([
          ...utf8.encode(sessionCode),
          ...bleToken,
        ]),
      ),
    ),
  );

  void _startQrTimers(DateTime endsAt) {
    _qrRotationTimer?.cancel();
    _sessionEndTimer?.cancel();
    _qrRotationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (timer.tick >= 6 || !mounted || !_isAdvertising) {
        timer.cancel();
        return;
      }
      unawaited(_rotateQr(timer.tick + 1));
    });
    final remaining = endsAt.difference(DateTime.now());
    _sessionEndTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        if (mounted && _isAdvertising) {
          unawaited(_stopAdvertising(sessionExpired: true));
        }
      },
    );
  }

  Future<void> _rotateQr(int number) async {
    final sessionId = _activeSessionUuid;
    if (sessionId == null || !_isAdvertising || _isRotatingQr) return;
    _isRotatingQr = true;
    final nextQr = _generateQrCode();
    final nextBle = _newBleToken();
    try {
      await _backend.rotateQr(
        sessionId: sessionId,
        qrCode: nextQr,
        bleToken: _hex(nextBle),
      );
      if (_isAdvertising) {
        await _peripheral.stop();
        final state = await _advertise(_sessionId, nextBle);
        if (state != PeripheralBluetoothState.granted &&
            state != PeripheralBluetoothState.ready) {
          throw Exception('BLE advertising could not restart ($state).');
        }
      }
      if (mounted && _isAdvertising) {
        setState(() {
          _qrCode = nextQr;
          _qrNumber = number;
          _status =
              'QR ' + number.toString() + ' of 6 is active for 10 seconds.';
        });
      }
    } catch (error) {
      if (mounted && _isAdvertising) {
        setState(
          () => _status =
              'Could not activate the next QR code: ' + error.toString(),
        );
      }
    } finally {
      _isRotatingQr = false;
    }
  }

  Future<void> _stopAdvertising({bool sessionExpired = false}) async {
    if (_isLoading && !_isAdvertising) return;
    _qrRotationTimer?.cancel();
    _sessionEndTimer?.cancel();
    _qrRotationTimer = null;
    _sessionEndTimer = null;

    String? cleanupError;
    final sessionId = _activeSessionUuid;
    try {
      await _peripheral.stop();
    } catch (error) {
      cleanupError = 'BLE stop error: ' + error.toString();
    }
    if (sessionId != null) {
      try {
        await _backend.stopSession(sessionId);
      } catch (error) {
        cleanupError = 'Session stop error: ' + error.toString();
      }
    }
    final channel = _attendanceChannel;
    if (channel != null) {
      try {
        await Supabase.instance.client.removeChannel(channel);
      } catch (error) {
        cleanupError ??= 'Realtime cleanup error: ' + error.toString();
      }
    }
    if (!mounted) return;
    setState(() {
      _attendanceChannel = null;
      _activeSessionUuid = null;
      _isAdvertising = false;
      _qrCode = '';
      _status = cleanupError != null
          ? 'Session stopped locally, but cleanup reported: ' + cleanupError
          : sessionExpired
          ? 'One-minute session expired. ' +
                _presentStudents.length.toString() +
                ' student(s) marked present.'
          : 'Session stopped. ' +
                _presentStudents.length.toString() +
                ' student(s) marked present.';
    });
  }

  @override
  void dispose() {
    _qrRotationTimer?.cancel();
    _sessionEndTimer?.cancel();
    unawaited(_peripheral.stop());
    final sessionId = _activeSessionUuid;
    if (sessionId != null) unawaited(_backend.stopSession(sessionId));
    final channel = _attendanceChannel;
    if (channel != null) {
      unawaited(Supabase.instance.client.removeChannel(channel));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: midnightBlue,
      appBar: AppBar(
        title: const Text('Teacher BLE Attendance'),
        backgroundColor: deepNavy,
        foregroundColor: Colors.white,
      ),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.page),
            children: [
              Icon(
                _isAdvertising ? Icons.bluetooth_connected : Icons.bluetooth,
                size: 82,
                color: _isAdvertising ? Colors.greenAccent : brandOrange,
              ),
              const SizedBox(height: 14),
              Text(
                _isAdvertising
                    ? 'Attendance Session Active'
                    : 'Create Attendance Session',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              if (_isAdvertising) ...[
                const SizedBox(height: 20),
                AppSurfaceCard(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SESSION NAME',
                        style: TextStyle(
                          color: mutedInk,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _sessionName,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '6-DIGIT SESSION ID',
                        style: TextStyle(
                          color: mutedInk,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SelectableText(
                        _sessionId,
                        style: const TextStyle(
                          color: brandOrange,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'ROTATING QR CODE — QR $_qrNumber OF 6',
                        style: const TextStyle(color: mutedInk, fontSize: 12),
                      ),
                      SelectableText(
                        _qrCode,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Each QR code and BLE token is valid for 10 seconds. Students without a camera can type the rotating code.',
                        style: TextStyle(color: mutedInk, fontSize: 12),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'SCAN THE CURRENT QR WITHIN 10 SECONDS',
                        style: TextStyle(
                          color: ink,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                          ),
                          child: QrImageView(
                            data: _qrCode,
                            version: QrVersions.auto,
                            size: 220,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _isLoading
                    ? null
                    : (_isAdvertising ? _stopAdvertising : _startAdvertising),
                icon: Icon(_isAdvertising ? Icons.stop : Icons.play_arrow),
                label: Text(
                  _isLoading
                      ? 'PLEASE WAIT...'
                      : (_isAdvertising
                            ? 'STOP SESSION'
                            : 'CREATE & START SESSION'),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isAdvertising
                      ? const Color(0xFFB3261E)
                      : brandOrange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Students present (' + _presentStudents.length.toString() + ')',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (_presentStudents.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'No students have marked present yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              else
                ..._presentStudents.entries.map(
                  (entry) => Card(
                    color: Colors.white,
                    child: ListTile(
                      leading: const Icon(
                        Icons.check_circle,
                        color: Color(0xFF287A45),
                      ),
                      title: Text(
                        entry.key,
                        style: const TextStyle(
                          color: ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        'Present · ' +
                            TimeOfDay.fromDateTime(entry.value).format(context),
                        style: const TextStyle(color: mutedInk),
                      ),
                      trailing: const Icon(
                        Icons.verified,
                        color: Color(0xFF287A45),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Sessions last one minute. Six unique QR codes rotate every 10 seconds. Supabase records confirmed attendance and updates this list in real time.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A real active session discovered by the student over BLE.
class _DiscoveredSession {
  const _DiscoveredSession(this.session, this.rssi);
  final ActiveAttendanceSession session;
  final int rssi;
}

class StudentBleScreen extends StatefulWidget {
  const StudentBleScreen({super.key});
  @override
  State<StudentBleScreen> createState() => _StudentBleScreenState();
}

class _StudentBleScreenState extends State<StudentBleScreen> {
  final _backend = AttendanceBackend(Supabase.instance.client);
  final Map<String, _DiscoveredSession> _sessions = {};
  final Set<String> _lookedUp = {};
  final Map<String, ({String token, DateTime seenAt})> _bleTokens = {};
  final TextEditingController _idController = TextEditingController();
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanStateSubscription;
  _DiscoveredSession? _selected;
  AttendanceResult? _result;
  bool _scanning = false;
  bool _loading = false;
  bool _scannerOpen = false;
  String? _method;
  String? _qrCode;
  String _status = 'Tap FIND SESSIONS to scan for active teacher sessions.';

  Future<void> _startScan() async {
    if (_scanning || _loading) return;
    setState(() {
      _loading = true;
      _sessions.clear();
      _lookedUp.clear();
      _selected = null;
      _result = null;
      _method = null;
      _qrCode = null;
      _scannerOpen = false;
      _idController.clear();
      _status = 'Requesting Bluetooth permissions...';
    });
    try {
      final permissions = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
      if (permissions.values.any((p) => !p.isGranted)) {
        throw Exception(
          'Bluetooth permissions were denied. Allow them in Settings.',
        );
      }
      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 8));
      if (state != BluetoothAdapterState.on) {
        throw Exception('Turn on Bluetooth, then try again.');
      }
      await _scanSubscription?.cancel();
      await _scanStateSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.onScanResults.listen(_onResults);
      _scanStateSubscription = FlutterBluePlus.isScanning.listen((value) {
        if (mounted) setState(() => _scanning = value);
      });
      await FlutterBluePlus.startScan(
        withServices: [Guid(bleServiceUuid)],
        timeout: const Duration(seconds: 30),
      );
      if (mounted) {
        setState(() {
          _scanning = true;
          _status = 'Searching for active teacher sessions for 30 seconds...';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not scan: ' + error.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onResults(List<ScanResult> results) {
    for (final result in results) {
      final hasService = result.advertisementData.serviceUuids.any(
        (uuid) => uuid.toString().toLowerCase() == bleServiceUuid,
      );
      if (!hasService) continue;
      String? id;
      for (final item in result.advertisementData.serviceData.entries) {
        if (item.key.toString().toLowerCase() != bleServiceUuid) continue;
        final value = item.value;
        if (value.length != 12) continue;
        final candidate = String.fromCharCodes(value.sublist(0, 6));
        if (!RegExp(r'^\d{6}$').hasMatch(candidate)) continue;
        id = candidate;
        _bleTokens[candidate] = (
          token: _hex(value.sublist(6)),
          seenAt: DateTime.now(),
        );
      }
      if (id == null) continue;
      final existing = _sessions[id];
      if (existing != null) {
        _sessions[id] = _DiscoveredSession(existing.session, result.rssi);
      } else if (_lookedUp.add(id)) {
        unawaited(_lookup(id, result.rssi));
      }
    }
    if (mounted) {
      setState(
        () => _status = _sessions.isEmpty
            ? 'Scanning... no active teacher session detected yet.'
            : 'Active sessions found. Select one to continue.',
      );
    }
  }

  Future<void> _lookup(String id, int rssi) async {
    try {
      final session = await _backend.findActiveSession(id);
      if (session != null && mounted) {
        setState(() {
          _sessions[id] = _DiscoveredSession(session, rssi);
          _status = 'Active sessions found. Select one to continue.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = 'Could not load session details: ' + error.toString(),
        );
      }
    }
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _select(_DiscoveredSession session) async {
    await _stopScan();
    if (!mounted) return;
    setState(() {
      _selected = session;
      _method = null;
      _qrCode = null;
      _result = null;
      _scannerOpen = false;
      _idController.clear();
      _status =
          'Selected ' +
          session.session.title +
          '. BLE signal detected; attendance still needs verification.';
    });
  }

  bool get _canSubmit {
    if (_loading || _selected == null || _result?.ok == true) return false;
    if (_method == 'qr') return _qrCode != null;
    return _method == 'code' &&
        RegExp(r'^\d{6}$').hasMatch(_idController.text.trim());
  }

  /// Returns the rotating BLE token most recently heard from [sessionCode],
  /// re-scanning briefly if the last one is older than 3 seconds.
  Future<String?> _freshBleToken(String sessionCode) async {
    bool fresh(DateTime since) {
      final seen = _bleTokens[sessionCode];
      return seen != null && seen.seenAt.isAfter(since);
    }

    final cutoff = DateTime.now().subtract(const Duration(seconds: 3));
    if (fresh(cutoff)) return _bleTokens[sessionCode]!.token;
    final started = DateTime.now();
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(bleServiceUuid)],
        timeout: const Duration(seconds: 8),
      );
      while (!fresh(started) &&
          DateTime.now().difference(started) < const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      await _stopScan();
    }
    return fresh(started) ? _bleTokens[sessionCode]!.token : null;
  }

  Future<void> _markAttendance() async {
    if (!_canSubmit) return;
    final selected = _selected!;
    if (Supabase.instance.client.auth.currentUser == null) {
      setState(
        () => _status = 'Your login session is unavailable. Sign in again.',
      );
      return;
    }
    final qrCode = _method == 'qr' ? _qrCode! : _idController.text.trim();
    setState(() {
      _loading = true;
      _result = null;
      _status = 'Listening for the teacher’s current BLE signal...';
    });
    try {
      final bleToken = await _freshBleToken(selected.session.sessionCode);
      if (bleToken == null) {
        if (mounted) {
          setState(() {
            _result = const AttendanceResult(
              ok: false,
              code: 'invalid_ble',
              message: 'No current BLE signal from the teacher’s phone. Move closer, keep Bluetooth on and retry.',
            );
            _status = _result!.message;
          });
        }
        return;
      }
      if (mounted) {
        setState(
          () => _status =
              'Confirm with your fingerprint or face to sign '
              'this attendance request...',
        );
      }
      final result = await _backend.markPresent(
        sessionId: selected.session.id,
        sessionCode: selected.session.sessionCode,
        qrCode: qrCode,
        bleToken: bleToken,
      );
      if (mounted) {
        setState(() {
          _result = result;
          _status = result.ok
              ? 'Attendance marked successfully.'
              : result.message;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _result = AttendanceResult(
            ok: false,
            code: 'network_error',
            message:
                'Unable to submit attendance. Please try again. (' +
                error.toString() +
                ')',
          );
          _status = _result!.message;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    unawaited(_scanSubscription?.cancel());
    unawaited(_scanStateSubscription?.cancel());
    _idController.dispose();
    unawaited(FlutterBluePlus.stopScan());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final email =
        Supabase.instance.client.auth.currentUser?.email ??
        'No logged-in email';
    return Scaffold(
      backgroundColor: midnightBlue,
      appBar: AppBar(
        title: const Text('Find Teacher'),
        backgroundColor: deepNavy,
        foregroundColor: Colors.white,
      ),
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: AppSurfaceCard(
              padding: const EdgeInsets.all(AppSpacing.page),
              child: Column(
                children: [
                  Icon(
                    _selected == null
                        ? Icons.bluetooth_searching
                        : Icons.bluetooth_connected,
                    size: 72,
                    color: _selected == null ? brandOrange : Colors.green,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Available Attendance Sessions',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ink,
                      fontSize: 23,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    email,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: mutedInk, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: mutedInk, fontSize: 14),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _loading
                          ? null
                          : (_scanning ? _stopScan : _startScan),
                      icon: Icon(_scanning ? Icons.stop : Icons.search),
                      label: Text(
                        _loading
                            ? 'PLEASE WAIT...'
                            : (_scanning ? 'STOP SCANNING' : 'FIND SESSIONS'),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _scanning
                            ? const Color(0xFFB3261E)
                            : brandOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                    ),
                  ),
                  ..._sessions.values.map((session) {
                    final chosen = _selected?.session.id == session.session.id;
                    return Card(
                      color: chosen
                          ? const Color(0xFFE4F4F3)
                          : const Color(0xFFF4F6FA),
                      child: ListTile(
                        onTap: _loading ? null : () => _select(session),
                        leading: const Icon(
                          Icons.bluetooth_searching,
                          color: brandOrange,
                        ),
                        title: Text(
                          session.session.title,
                          style: const TextStyle(
                            color: ink,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          'BLE signal detected · ' +
                              session.rssi.toString() +
                              ' dBm · ID ' +
                              session.session.sessionCode,
                          style: const TextStyle(color: mutedInk),
                        ),
                        trailing: Icon(
                          chosen ? Icons.check_circle : Icons.chevron_right,
                          color: chosen ? Colors.green : mutedInk,
                        ),
                      ),
                    );
                  }),
                  if (_selected != null) ...[
                    Card(
                      color: const Color(0xFFE4F4F3),
                      child: ListTile(
                        leading: const Icon(
                          Icons.event_available,
                          color: Color(0xFF287A45),
                        ),
                        title: Text(
                          'Selected session: ' + _selected!.session.title,
                          style: const TextStyle(
                            color: ink,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          'BLE signal detected · Session ID ' +
                              _selected!.session.sessionCode,
                          style: const TextStyle(color: mutedInk),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => setState(() {
                                    _method = 'qr';
                                    _qrCode = null;
                                    _scannerOpen = true;
                                  }),
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('Scan QR Code'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => setState(() {
                                    _method = 'code';
                                    _scannerOpen = false;
                                    _qrCode = null;
                                  }),
                            icon: const Icon(Icons.pin),
                            label: const Text('Enter Code'),
                          ),
                        ),
                      ],
                    ),
                    if (_method == 'qr') ...[
                      Text(
                        _qrCode == null
                            ? 'Scan the teacher’s current QR code.'
                            : 'QR scanned. Supabase will validate it.',
                        textAlign: TextAlign.center,
                      ),
                      if (_scannerOpen)
                        SizedBox(
                          height: 260,
                          child: MobileScanner(
                            onDetect: (capture) {
                              if (!_scannerOpen || !mounted) return;
                              for (final barcode in capture.barcodes) {
                                final value = barcode.rawValue?.trim();
                                if (value != null &&
                                    RegExp(r'^\d{6}$').hasMatch(value)) {
                                  setState(() {
                                    _qrCode = value;
                                    _scannerOpen = false;
                                  });
                                  break;
                                }
                              }
                            },
                          ),
                        ),
                    ],
                    if (_method == 'code')
                      TextField(
                        controller: _idController,
                        onChanged: (_) => setState(() {}),
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        style: const TextStyle(color: ink),
                        decoration: const InputDecoration(
                          labelText: '6-digit rotating code',
                          hintText: 'Type the code shown under the QR',
                          counterText: '',
                          prefixIcon: Icon(Icons.pin),
                        ),
                      ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _canSubmit ? _markAttendance : null,
                        icon: Icon(
                          _result?.ok == true
                              ? Icons.check_circle
                              : Icons.how_to_reg,
                        ),
                        label: Text(
                          _result?.ok == true
                              ? 'MARKED PRESENT'
                              : (_loading
                                    ? 'VERIFYING...'
                                    : 'VERIFY & MARK PRESENT'),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _result?.ok == true
                              ? const Color(0xFF287A45)
                              : brandOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ),
                    if (_result != null)
                      Card(
                        color: _result!.ok
                            ? const Color(0xFFE6F4EA)
                            : const Color(0xFFFFECEA),
                        child: ListTile(
                          leading: Icon(
                            _result!.ok
                                ? Icons.check_circle
                                : Icons.error_outline,
                            color: _result!.ok
                                ? const Color(0xFF287A45)
                                : const Color(0xFFB3261E),
                          ),
                          title: Text(
                            _result!.ok
                                ? 'Attendance Marked Successfully!'
                                : _result!.message,
                            style: const TextStyle(
                              color: ink,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: _result!.ok
                              ? Text(
                                  'Session: ' +
                                      (_result!.sessionName ??
                                          _selected!.session.title) +
                                      '\nStudent: ' +
                                      (_result!.studentEmail ?? email) +
                                      '\nStatus: ' +
                                      (_result!.status ?? 'Present'),
                                  style: const TextStyle(color: mutedInk),
                                )
                              : null,
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'BLE discovery identifies the nearby session; only Supabase verification of the QR or session ID records attendance.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: mutedInk, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// current Supabase-authenticated email and the teacher's displayed session code.
