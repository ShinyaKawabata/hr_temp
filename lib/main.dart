import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const int maxHistoryPoints = 8640;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(home: HRTempScreen());
}

class HRTempScreen extends StatefulWidget {
  const HRTempScreen({super.key});
  @override
  State<HRTempScreen> createState() => _HRTempScreenState();
}

Future<void> requestPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
    Permission.storage, // ← ファイル保存にも必要なら追加
  ].request();

  if (statuses.values.any((status) => !status.isGranted)) {
    // 必要ならダイアログなどで警告表示も検討
    debugPrint("Some permissions not granted!");
  }
}

class _HRTempScreenState extends State<HRTempScreen> {
  static const String targetName = "HR_Temp";
  static final Guid charUUID = Guid("13d9f4e0-67a3-4439-a2d1-bc1bb0eebd6d");

  BluetoothDevice? device;
  BluetoothCharacteristic? characteristic;
  List<FlSpot> history = [];
  List<DateTime> timestamps = [];
  List<String> csvLines = ["timestamp,value"];
  String currentValue = "--";
  String lastDate = "----";
  int index = 0;

  String connectionState = "Disconnect.";
  bool _isScanning = false;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    initAsync();
  }

  @override
  void dispose(){
    _connectionSub?.cancel();
    device?.disconnect();
    FlutterBluePlus.stopScan();
    print("*************** DISPOSED ****************");
    super.dispose();
  }

  Future <void> initAsync() async {
    await requestPermissions();
    scanAndConnect();
  }

  void scanAndConnect() async {

    if (_isScanning) return;
    _isScanning = true;
    setState(() => connectionState = "Scanning...");
    
    bool found = false;
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 60));
    print("scan start.");
    FlutterBluePlus.scanResults.listen((results) async {
      for (var r in results) {
        if (r.device.advName == targetName) {
          found = true;
          await FlutterBluePlus.stopScan();
          setState(() => connectionState = "Connecting...");
          await r.device.connect();
          setState(() => device = r.device);

          //切断監視
          _connectionSub?.cancel();  // 前のリスナーを解除
          _connectionSub = device?.connectionState.listen((state) async {
            if (state == BluetoothConnectionState.disconnected) {
              setState(() => connectionState = "Disconnected");
              await Future.delayed(const Duration(seconds: 2));
              scanAndConnect();  // 再接続
            } else if (state == BluetoothConnectionState.connected) {
              setState(() => connectionState = "Connected");
            }
          });

          discoverServices();
          break;
        }
      }
    });

    Future.delayed(const Duration(seconds: 70), (){
      if(!found){
        print("Device not found. Retry Scanning...");
        _isScanning = false;
        scanAndConnect();
      }
    });
  }

  void discoverServices() async {
    if (device == null) return;
    List<BluetoothService> services = await device!.discoverServices();
    for (var service in services) {
      for (var c in service.characteristics) {
        if (c.uuid == charUUID) {
          characteristic = c;
          await c.setNotifyValue(true);
          c.value.listen(onDataReceived);
          setState(() => connectionState = "Connected.");
          return;
        }
      }
    }
  }

  void onDataReceived(List<int> data) async {
    if (data.length < 2) return;

    final value = ByteData.sublistView(Uint8List.fromList(data)).getUint16(0, Endian.little);
    final now = DateTime.now();
    final timestamp = now.toIso8601String().replaceFirst('T', ' ').split('.').first;

    print(timestamp);

    setState(() {
      currentValue = value.toString();
      lastDate = timestamp;
      timestamps.add(now);

      final age = now.difference(timestamps.first).inSeconds.toDouble();
      history.add(FlSpot(age, value.toDouble()));
      if (history.length >= maxHistoryPoints) {
        history.removeAt(0);
        timestamps.removeAt(0);
      }
      csvLines.add("$timestamp,$value");
    });

    final directory = Directory("/storage/emulated/0/Download");
    final dateStr = DateTime.now().toIso8601String().split('T').first;
    print(dateStr);
    final file = File("${directory.path}/${dateStr}_hr_temp_log.csv");

    if (!await file.exists()){
      await file.writeAsString("date,temp\n");
    }
    await file.writeAsString("$timestamp,$value\n", mode: FileMode.append);
  }

  Widget buildChart() {
    if (history.isEmpty) return const SizedBox.shrink();

    final minX = 0.0;
    final maxX = history.map((e) => e.x).reduce((a, b) => a > b ? a : b);
    final interval = (maxX - minX) / 10;
    final safeInterval = interval == 0 ? 1.0 : interval;

    final showInMinutes = maxX.abs() >= 600;
    final showInHours = maxX.abs() >= 36000;

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: 100,
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: safeInterval,
              getTitlesWidget: (value, meta) {
                final secondsN = (maxX - value).round();
                if(showInHours){
                  final hours = secondsN ~/ 3600;
                  return Text("${hours}h", style:  const TextStyle(fontSize: 10),);
                }else if(showInMinutes) {
                  final minutes = secondsN ~/ 60;
                  return Text("${minutes}m", style: const TextStyle(fontSize: 10),);
                }else{
                  return Text("${secondsN}s", style: const TextStyle(fontSize: 10),);
                }
              },
              reservedSize: 30,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 5,
              getTitlesWidget: (value, meta) =>
                  Text("${value.toInt()}", style: const TextStyle(fontSize: 10)),
              reservedSize: 30,
            ),
          ),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          horizontalInterval: 5,
          verticalInterval: safeInterval,
        ),
        lineBarsData: [
          LineChartBarData(
            spots: history,
            isCurved: false,
            color: Colors.blue,
            dotData: FlDotData(show: true),
            barWidth: 0,
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("HR_Temp Viewer")),
    body: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(connectionState, style: const TextStyle(fontSize: 16),),
          const SizedBox(height: 8,),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text("Current Value: ", style: const TextStyle(fontSize: 24)),
              Text(currentValue, style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
              Text(" ℃", style: const TextStyle(fontSize: 24)),
            ],
          ),
          const SizedBox(height: 8,),
          Text("Last Update: $lastDate", style: TextStyle(fontSize: 16),),
          const SizedBox(height: 16),
          Expanded(child: history.isEmpty ? const Text("No data yet") : buildChart()),
        ],
      ),
    ),
  );
}
