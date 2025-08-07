import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
  await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
  ].request();
}

class _HRTempScreenState extends State<HRTempScreen> {
  static const String targetName = "HR_Temp";
  static final Guid charUUID = Guid("13d9f4e0-67a3-4439-a2d1-bc1bb0eebd6d");

  BluetoothDevice? device;
  BluetoothCharacteristic? characteristic;
  List<FlSpot> history = [];
  List<DateTime> timestamps = [];
  List<String> csvLines = ["timestamp,value"];
  int currentValue = 0;
  int index = 0;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    requestPermissions();
    scanAndConnect();
  }

  void scanAndConnect() async {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 60));
    print("scan start.");
    FlutterBluePlus.scanResults.listen((results) async {
      for (var r in results) {
        print(r.device.advName);
        if (r.device.advName == targetName) {
          await FlutterBluePlus.stopScan();
          await r.device.connect();
          setState(() => device = r.device);
          discoverServices();
          break;
        }
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
          return;
        }
      }
    }
  }

  void onDataReceived(List<int> data) async {
    if (data.length < 2) return;

    final value = ByteData.sublistView(Uint8List.fromList(data)).getUint16(0, Endian.little);
    final now = DateTime.now();
    final timestamp = now.toIso8601String();

    setState(() {
      currentValue = value;
      timestamps.add(now);

      final age = now.difference(timestamps.first).inSeconds.toDouble();
      history.add(FlSpot(age, value.toDouble()));
      csvLines.add("$timestamp,$value");
    });
  }

  Future<void> saveToCSV() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File("${directory.path}/hr_temp_log.csv");
    await file.writeAsString(csvLines.join("\n"));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("CSV saved!")));
  }

  Widget buildChart() {
    if (history.isEmpty) return const SizedBox.shrink();

    final minX = 0.0;
    final maxX = history.map((e) => e.x).reduce((a, b) => a > b ? a : b);
    final interval = (maxX - minX) / 10;
    final safeInterval = interval == 0 ? 1.0 : interval;

    final showInMinutes = minX.abs() >= 600;
    final showInHours = minX.abs() >= 36000;

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text("Current Value: ", style: const TextStyle(fontSize: 24)),
              Text("$currentValue", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
              Text(" ℃", style: const TextStyle(fontSize: 24)),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: history.isEmpty ? const Text("No data yet") : buildChart()),
          ElevatedButton(onPressed: saveToCSV, child: const Text("Save CSV")),
        ],
      ),
    ),
  );
}
