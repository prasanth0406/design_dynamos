import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const String bleServiceUuid = 'bf27730d-860a-4e09-889c-2d8b6a9e0fe7';
// Both phones use this shared topic so the teacher can validate the submitted code.
const String attendanceTopic = 'oceanic-attendance-v1';
const Color bleNavy = Color(0xFF081328);
const Color bleBlue = Color(0xFF102C51);
const Color bleCyan = Color(0xFF13C8D2);

String _newSessionCode() => (100000 + Random.secure().nextInt(900000)).toString();

/// Wait until Supabase Realtime confirms the channel is subscribed before
/// sending broadcasts. Calling subscribe() alone does not guarantee readiness.
Future<void> _subscribeAndWait(RealtimeChannel channel) {
  final completer = Completer<void>();
  channel.subscribe((status, error) {
    if (status == RealtimeSubscribeStatus.subscribed) {
      if (!completer.isCompleted) completer.complete();
    } else if (status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.timedOut ||
        status == RealtimeSubscribeStatus.closed) {
      if (!completer.isCompleted) {
        completer.completeError(Exception(
          'Supabase Realtime subscription failed: $status${error == null ? "" : " ($error)"}',
        ));
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
  final Map<String, DateTime> _presentStudents = {};
  RealtimeChannel? _attendanceChannel;
  bool _isAdvertising = false;
  bool _isLoading = false;
  String _status = 'Create a session to begin attendance.';
  String _sessionName = '';
  String _sessionCode = '';
  final Set<String> _issuedSessionCodes = <String>{};
  Timer? _qrRotationTimer;
  Timer? _sessionEndTimer;
  int _qrNumber = 0;
  DateTime? _sessionEndsAt;

  String _generateSessionCode() {
    String code;
    do {
      code = _newSessionCode();
    } while (!_issuedSessionCodes.add(code));
    return code;
  }

  Future<String?> _askSessionName() {
    // The dialog owns its controller and disposes it only when its own State
    // is removed, avoiding use-after-dispose during the route's exit animation.
    return showDialog<String>(
      context: context,
      builder: (_) => const _SessionNameDialog(),
    );
  }

  Future<void> _startAdvertising() async {
    if (_isLoading || _isAdvertising) return;
    final name = await _askSessionName();
    if (name == null || name.trim().isEmpty || !mounted) return;

    setState(() {
      _isLoading = true;
      _status = 'Checking Bluetooth and permissions...';
    });

    try {
      if (!await _peripheral.isSupported) {
        throw Exception('This phone does not support BLE advertising.');
      }
      var permissionState = await _peripheral.hasPermission();
      if (permissionState != PeripheralBluetoothState.granted &&
          permissionState != PeripheralBluetoothState.ready) {
        permissionState = await _peripheral.requestPermission();
      }
      if (permissionState == PeripheralBluetoothState.turnedOff) {
        final enabled = await _peripheral.enableBluetooth();
        if (!enabled) throw Exception('Turn on Bluetooth, then try again.');
        permissionState = await _peripheral.hasPermission();
      }
      if (permissionState != PeripheralBluetoothState.granted &&
          permissionState != PeripheralBluetoothState.ready) {
        throw Exception('Bluetooth permission was not granted ($permissionState).');
      }

      _issuedSessionCodes.clear();
      final code = _generateSessionCode();
      final channel = Supabase.instance.client.channel(
        attendanceTopic,
        opts: const RealtimeChannelConfig(self: false),
      );
      channel.onBroadcast(event: 'attendance_request', callback: (payload) {
        final email = payload['email']?.toString().trim().toLowerCase() ?? '';
        final submittedCode = payload['code']?.toString().trim() ?? '';
        final requestId = payload['request_id']?.toString() ?? '';
        if (email.isEmpty || !email.endsWith('@iiitdwd.ac.in') || requestId.isEmpty) return;

        final isValid = _isAdvertising && submittedCode == _sessionCode &&
            _sessionEndsAt != null && DateTime.now().isBefore(_sessionEndsAt!);
        if (isValid && mounted) {
          setState(() {
            _presentStudents.putIfAbsent(email, () => DateTime.now());
            _status = '${_presentStudents.length} student(s) marked present.';
          });
        }
        // Reply to the student regardless of whether the code was correct.
        unawaited(channel.sendBroadcastMessage(event: 'attendance_result', payload: {
          'request_id': requestId,
          'valid': isValid,
          'message': isValid ? 'Attendance confirmed.' : 'This QR code is incorrect or expired. Scan the current code and try again.',
        }));
      });
      await _subscribeAndWait(channel);

      final result = await _peripheral.start(
        advertiseData: const AdvertiseDataCore(serviceUuid: bleServiceUuid),
      );
      if (result != PeripheralBluetoothState.granted &&
          result != PeripheralBluetoothState.ready) {
        await Supabase.instance.client.removeChannel(channel);
        throw Exception('Advertising could not start ($result).');
      }

      if (!mounted) return;
      _attendanceChannel = channel;
      setState(() {
        _sessionName = name.trim();
        _sessionCode = code;
        _qrNumber = 1;
        _sessionEndsAt = DateTime.now().add(const Duration(minutes: 1));
        _isAdvertising = true;
        _presentStudents.clear();
        _status = 'QR 1 of 6 is active for 10 seconds. BLE must also be detected.';
      });
      _startQrTimers();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not start attendance: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _startQrTimers() {
    _qrRotationTimer?.cancel();
    _sessionEndTimer?.cancel();

    _qrRotationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (timer.tick >= 6) {
        timer.cancel();
        return;
      }
      if (!mounted || !_isAdvertising) {
        timer.cancel();
        return;
      }
      setState(() {
        _sessionCode = _generateSessionCode();
        _qrNumber = timer.tick + 1;
        _status = 'QR $_qrNumber of 6 is active for 10 seconds.';
      });
    });

    _sessionEndTimer = Timer(const Duration(minutes: 1), () {
      if (mounted && _isAdvertising) {
        unawaited(_stopAdvertising(sessionExpired: true));
      }
    });
  }

  Future<void> _stopAdvertising({bool sessionExpired = false}) async {
    _qrRotationTimer?.cancel();
    _sessionEndTimer?.cancel();
    _qrRotationTimer = null;
    _sessionEndTimer = null;
    try {
      await _peripheral.stop();
      final channel = _attendanceChannel;
      if (channel != null) await Supabase.instance.client.removeChannel(channel);
      if (!mounted) return;
      setState(() {
        _attendanceChannel = null;
        _isAdvertising = false;
        _sessionEndsAt = null;
        _status = sessionExpired
            ? 'One-minute session expired. ${_presentStudents.length} student(s) marked present.'
            : 'Session stopped. ${_presentStudents.length} student(s) marked present.';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not stop session: $error');
    }
  }

  @override
  void dispose() {
    _qrRotationTimer?.cancel();
    _sessionEndTimer?.cancel();
    unawaited(_peripheral.stop());
    final channel = _attendanceChannel;
    if (channel != null) unawaited(Supabase.instance.client.removeChannel(channel));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bleNavy,
      appBar: AppBar(title: const Text('Teacher BLE Attendance'), backgroundColor: bleBlue, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(_isAdvertising ? Icons.bluetooth_connected : Icons.bluetooth, size: 82,
              color: _isAdvertising ? Colors.greenAccent : bleCyan),
          const SizedBox(height: 14),
          Text(_isAdvertising ? 'Attendance Session Active' : 'Create Attendance Session',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          if (_isAdvertising) ...[
            const SizedBox(height: 20),
            Card(color: bleBlue, child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('SESSION NAME', style: TextStyle(color: bleCyan, fontSize: 11, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(_sessionName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                Text('ROTATING QR CODE — QR $_qrNumber OF 6', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                SelectableText(_sessionCode, style: const TextStyle(color: bleCyan, fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 5)),
                const SizedBox(height: 4),
                const Text('Each QR is valid for 10 seconds', style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 20),
                const Text(
                  'SCAN THE CURRENT QR WITHIN 10 SECONDS',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: QrImageView(
                      data: _sessionCode,
                      version: QrVersions.auto,
                      size: 220,
                    ),
                  ),
                ),
              ]),
            )),
          ],
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isLoading ? null : (_isAdvertising ? _stopAdvertising : _startAdvertising),
            icon: Icon(_isAdvertising ? Icons.stop : Icons.play_arrow),
            label: Text(_isLoading ? 'PLEASE WAIT...' : (_isAdvertising ? 'STOP SESSION' : 'CREATE & START SESSION')),
            style: ElevatedButton.styleFrom(backgroundColor: _isAdvertising ? Colors.redAccent : bleCyan,
                foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
          ),
          const SizedBox(height: 22),
          Text('Students present (${_presentStudents.length})',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_presentStudents.isEmpty)
            const Padding(padding: EdgeInsets.all(18), child: Text('No students have marked present yet.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)))
          else
            ..._presentStudents.entries.map((entry) => Card(
              color: bleBlue,
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.greenAccent),
                title: Text(entry.key, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text('Present · ${TimeOfDay.fromDateTime(entry.value).format(context)}',
                    style: const TextStyle(color: Colors.white70)),
                trailing: const Icon(Icons.verified, color: Colors.greenAccent),
              ),
            )),
          const SizedBox(height: 12),
          const Text('The session lasts 1 minute. Six unique QR codes rotate every 10 seconds. Attendance is not yet saved to a permanent database.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Student scans for the teacher BLE signal, then confirms attendance using the
/// current Supabase-authenticated email and the teacher's displayed session code.
class StudentBleScreen extends StatefulWidget {
  const StudentBleScreen({super.key});

  @override
  State<StudentBleScreen> createState() => _StudentBleScreenState();
}

class _StudentBleScreenState extends State<StudentBleScreen> {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanStateSubscription;
  final Map<String, ScanResult> _detectedTeachers = {};
  final TextEditingController _sessionCodeController = TextEditingController();
  bool _isScanning = false;
  bool _isLoading = false;
  bool _isPresent = false;
  bool _qrScanned = false;
  String _status = 'Tap FIND TEACHER to scan for a teacher signal.';

  Future<void> _startScanning() async {
    if (_isLoading || _isScanning) return;
    setState(() {
      _isLoading = true;
      _detectedTeachers.clear();
      _isPresent = false;
      _qrScanned = false;
      _sessionCodeController.clear();
      _status = 'Requesting Bluetooth permissions...';
    });
    try {
      final permissions = await <Permission>[Permission.bluetoothScan, Permission.bluetoothConnect].request();
      if (permissions.values.any((status) => !status.isGranted)) {
        throw Exception('Bluetooth permissions were denied. Allow them in Settings.');
      }
      final adapterState = await FlutterBluePlus.adapterState
          .where((state) => state != BluetoothAdapterState.unknown)
          .first.timeout(const Duration(seconds: 8));
      if (adapterState != BluetoothAdapterState.on) throw Exception('Turn on Bluetooth, then try again.');

      await _scanSubscription?.cancel();
      await _scanStateSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          for (final result in results) {
            final foundService = result.advertisementData.serviceUuids.any(
                  (uuid) => uuid.toString().toLowerCase() == bleServiceUuid,
            );
            if (foundService) _detectedTeachers[result.device.remoteId.toString()] = result;
          }
          _status = _detectedTeachers.isEmpty
              ? 'Scanning... no teacher signal detected yet.'
              : 'Teacher detected! Enter the session code and mark present.';
        });
      }, onError: (Object error) {
        if (mounted) setState(() => _status = 'Scan error: $error');
      });
      _scanStateSubscription = FlutterBluePlus.isScanning.listen((scanning) {
        if (mounted) setState(() => _isScanning = scanning);
      });
      await FlutterBluePlus.startScan(withServices: [Guid(bleServiceUuid)], timeout: const Duration(seconds: 30));
      if (mounted) setState(() { _isScanning = true; _status = 'Searching for the teacher for up to 30 seconds...'; });
    } catch (error) {
      if (mounted) setState(() { _isScanning = false; _status = 'Could not scan: $error'; });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stopScanning() async {
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    if (mounted) {
      setState(() {
        _isScanning = false;
        _status = _detectedTeachers.isEmpty
            ? 'Scanning stopped. No teacher found.'
            : 'Teacher detected.';
      });
    }
  }

  Future<void> _markPresent() async {
    if (_isLoading || _isPresent) return;
    if (_detectedTeachers.isEmpty) {
      setState(() => _status = 'Find the teacher via BLE before marking attendance.');
      return;
    }
    if (!_qrScanned) {
      setState(() => _status = 'Scan the teacher QR code after detecting the BLE signal.');
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email?.trim().toLowerCase();
    if (email == null || email.isEmpty) {
      setState(() => _status = 'You are not logged in. Sign in again and retry.');
      return;
    }
    final code = _sessionCodeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _status = 'Enter the six-digit session code shown on the teacher phone.');
      return;
    }

    setState(() { _isLoading = true; _status = 'Checking code with the teacher...'; });
    RealtimeChannel? channel;
    try {
      final requestId = '${DateTime.now().microsecondsSinceEpoch}-${email.hashCode}';
      final response = Completer<Map<String, dynamic>>();
      channel = Supabase.instance.client.channel(
        attendanceTopic,
        opts: const RealtimeChannelConfig(self: false),
      );
      channel.onBroadcast(event: 'attendance_result', callback: (payload) {
        if (payload['request_id']?.toString() == requestId && !response.isCompleted) {
          response.complete(Map<String, dynamic>.from(payload));
        }
      });
      await _subscribeAndWait(channel);
      await channel.sendBroadcastMessage(event: 'attendance_request', payload: {
        'request_id': requestId,
        'email': email,
        'code': code,
        'marked_at': DateTime.now().toUtc().toIso8601String(),
      });

      final result = await response.future.timeout(const Duration(seconds: 8));
      final valid = result['valid'] == true;
      final message = result['message']?.toString() ?? 'No response from teacher.';
      if (!mounted) return;
      setState(() {
        _isPresent = valid;
        _status = valid ? '$email marked present.' : message;
      });
    } on TimeoutException {
      if (mounted) setState(() => _status = 'No response from teacher. Keep the teacher screen open, check internet on both phones, and try again.');
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not validate attendance: $error');
    } finally {
      if (channel != null) await Supabase.instance.client.removeChannel(channel);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _scanStateSubscription?.cancel();
    _sessionCodeController.dispose();
    unawaited(FlutterBluePlus.stopScan());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final email = Supabase.instance.client.auth.currentUser?.email ?? 'No logged-in email';
    return Scaffold(
      backgroundColor: bleNavy,
      appBar: AppBar(title: const Text('Find Teacher'), backgroundColor: bleBlue, foregroundColor: Colors.white),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_detectedTeachers.isEmpty ? Icons.bluetooth_searching : Icons.bluetooth_connected,
                  size: 82, color: _detectedTeachers.isEmpty ? bleCyan : Colors.greenAccent),
              const SizedBox(height: 14),
              const Text('Teacher Signal Scanner', style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(email, textAlign: TextAlign.center, style: const TextStyle(color: bleCyan, fontSize: 13)),
              const SizedBox(height: 12),
              Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 18),
              SizedBox(width: double.infinity, child: ElevatedButton.icon(
                onPressed: _isLoading ? null : (_isScanning ? _stopScanning : _startScanning),
                icon: Icon(_isScanning ? Icons.stop : Icons.search),
                label: Text(_isLoading ? 'PLEASE WAIT...' : (_isScanning ? 'STOP SCANNING' : 'FIND TEACHER')),
                style: ElevatedButton.styleFrom(backgroundColor: _isScanning ? Colors.redAccent : bleCyan,
                    foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
              )),
              if (_detectedTeachers.isNotEmpty) ...[
                const SizedBox(height: 14),
                Card(color: bleBlue, child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.greenAccent),
                  title: const Text('Teacher BLE signal detected', style: TextStyle(color: Colors.white)),
                  subtitle: Text('Signal: ${_detectedTeachers.values.first.rssi} dBm', style: const TextStyle(color: Colors.white70)),
                )),
                const SizedBox(height: 10),
                const SizedBox(height: 12),
                Text(
                  _qrScanned ? 'QR code scanned successfully' : 'Scan the QR code displayed on the teacher phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _qrScanned ? Colors.greenAccent : Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 260,
                    width: double.infinity,
                    child: MobileScanner(
                      onDetect: (capture) {
                        if (!mounted) return;
                        for (final barcode in capture.barcodes) {
                          final value = barcode.rawValue?.trim();
                          if (value != null &&
                              value != _sessionCodeController.text &&
                              RegExp(r'^\d{6}$').hasMatch(value)) {
                            setState(() {
                              _sessionCodeController.text = value;
                              _qrScanned = true;
                              _status = 'Current QR scanned. BLE and QR requirements are satisfied; you can mark attendance.';
                            });
                            break;
                          }
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(width: double.infinity, child: ElevatedButton.icon(
                  onPressed: _isLoading || _isPresent || !_qrScanned || _detectedTeachers.isEmpty ? null : _markPresent,
                  icon: Icon(_isPresent ? Icons.check_circle : Icons.how_to_reg),
                  label: Text(_isPresent ? 'MARKED PRESENT' : 'ALLOW / MARK PRESENT'),
                  style: ElevatedButton.styleFrom(backgroundColor: _isPresent ? Colors.green : bleCyan,
                      foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
                )),
              ],
              const SizedBox(height: 20),
              const Text('Attendance requires both a detected teacher BLE signal and a scanned session QR code. Both phones must be online and use the same Supabase project.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
