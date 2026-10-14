import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:torch_light/torch_light.dart';
import 'dart:ui';
import 'dart:io';
import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Chyba inicializace Firebase: $e");
  }

  try {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'jsdh_alarm_channel',
      'Ostré poplachy JSDH',
      description: 'Tento kanál slouží pro okamžité vyhlášení poplachu s maximální prioritou.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  } catch (e) {
    debugPrint("Chyba inicializace notifikací: $e");
  }

  try {
    await initializeBackgroundService();
  } catch (e) {
    debugPrint("Chyba inicializace background service: $e");
  }

  runApp(const HasiciSvolavakApp());
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'jsdh_alarm_channel',
      initialNotificationTitle: 'JSDH Svolávač běží',
      initialNotificationContent: 'Aplikace hlídá poplachy na pozadí 24/7.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onBackgroundServiceStart,
      onBackground: onIosBackground,
    ),
  );

  service.startService();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

Future<void> _blinkTorch() async {
  try {
    bool isTorchAvailable = await TorchLight.isTorchAvailable();
    if (isTorchAvailable) {
      for (int i = 0; i < 6; i++) {
        await TorchLight.enableTorch();
        await Future.delayed(const Duration(milliseconds: 300));
        await TorchLight.disableTorch();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  } catch (e) {
    debugPrint("Blesk není k dispozici nebo chybí oprávnění: $e");
  }
}

@pragma('vm:entry-point')
void onBackgroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Chyba Firebase v pozadí: $e");
  }

  final AudioPlayer backgroundAudioPlayer = AudioPlayer();
  String? lastAlarmId;

  service.on('stopAudio').listen((event) async {
    try {
      await backgroundAudioPlayer.stop();
    } catch (e) {
      debugPrint("Chyba při zastavování zvuku v pozadí: $e");
    }
  });

  Stream.periodic(const Duration(seconds: 5)).listen((_) async {
    try {
      var snapshot = await FirebaseFirestore.instance
          .collection('alarmy')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        var doc = snapshot.docs.first;
        var data = doc.data();
        String rawText = data['text'] ?? '';

        if (lastAlarmId != doc.id) {
          lastAlarmId = doc.id;

          _blinkTorch();

          final prefs = await SharedPreferences.getInstance();
          String? customPath = prefs.getString('saved_alarm_mp3');

          if (customPath != null && customPath.isNotEmpty) {
            File audioFile = File(customPath);
            if (audioFile.existsSync()) {
              try {
                await backgroundAudioPlayer.setReleaseMode(ReleaseMode.loop);
                await backgroundAudioPlayer.setVolume(1.0);
                await backgroundAudioPlayer.play(DeviceFileSource(customPath));
                debugPrint("Přehrávám tón: $customPath");
              } catch (e) {
                debugPrint("Chyba přehrávání zvuku v pozadí: $e");
              }
            } else {
              debugPrint("Soubor neexistuje na ceste: $customPath");
            }
          } else {
            debugPrint("Uživatel dosud nevybral žádný MP3 tón.");
          }

          const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
            'jsdh_alarm_channel',
            'Ostré poplachy JSDH',
            channelDescription: 'Upozornění na vyhlášený poplach',
            importance: Importance.max,
            priority: Priority.high,
            fullScreenIntent: true,
            category: AndroidNotificationCategory.alarm,
            ticker: '🚨 OSTRÝ POPLACH!',
          );

          const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.critical,
          );

          const NotificationDetails details = NotificationDetails(
            android: androidDetails,
            iOS: iosDetails,
          );

          await flutterLocalNotificationsPlugin.show(
            0,
            '🚨 OSTRÝ POPLACH!',
            rawText,
            details,
          );
        }
      }
    } catch (e) {
      debugPrint("Chyba při stahování alarmu na pozadí: $e");
    }
  });

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

class HasiciSvolavakApp extends StatelessWidget {
  const HasiciSvolavakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JSDH Svolávač',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.red,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: ColorScheme.dark(
          primary: Colors.red.shade700,
          secondary: Colors.orange,
        ),
      ),
      home: const OperationalAlarmScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AlarmMessage {
  final String technika;
  final String datum;
  final String cas;
  final String typUdalosti;
  final String mesto;
  final String adresa;
  final String poznamka;

  AlarmMessage({
    required this.technika,
    required this.datum,
    required this.cas,
    required this.typUdalosti,
    required this.mesto,
    required this.adresa,
    required this.poznamka,
  });

  static AlarmMessage? parse(String text) {
    final regExp = RegExp(
      r'VYJEZD PRO:\s*(.*?),\s*(\d{2}\.\d{2}\.\d{4})\s*(\d{2}:\d{2}:\d{2}),\s*(.*?),\s*(.*?),\s*(.*?);\s*(.*)',
      dotAll: true,
    );

    final match = regExp.firstMatch(text.trim());
    if (match != null) {
      return AlarmMessage(
        technika: match.group(1)?.trim() ?? '',
        datum: match.group(2)?.trim() ?? '',
        cas: match.group(3)?.trim() ?? '',
        typUdalosti: match.group(4)?.trim() ?? '',
        mesto: match.group(5)?.trim() ?? '',
        adresa: match.group(6)?.trim() ?? '',
        poznamka: match.group(7)?.trim() ?? '',
      );
    }
    return null;
  }
}

class OperationalAlarmScreen extends StatefulWidget {
  const OperationalAlarmScreen({super.key});

  @override
  State<OperationalAlarmScreen> createState() => _OperationalAlarmScreenState();
}

class _OperationalAlarmScreenState extends State<OperationalAlarmScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  AlarmMessage? _currentAlarm;
  String _myStatus = "Zatím nerozhodnuto";
  Color _statusColor = Colors.grey;
  String? _lastProcessedAlarmId;
  String? _customAudioPath;
  String _firefighterName = "";

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _requestNotificationPermission();
    _checkActiveAlarmOnOpen();
  }

  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _customAudioPath = prefs.getString('saved_alarm_mp3');
      _firefighterName = prefs.getString('firefighter_name') ?? "";
    });

    if (_firefighterName.isEmpty && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNameInputDialog();
      });
    }
  }

  void _showNameInputDialog() {
    TextEditingController controller = TextEditingController(text: _firefighterName);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("👤 Zadejte své jméno"),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: "Např. Jan Novák",
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: () async {
                String name = controller.text.trim();
                if (name.isNotEmpty) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('firefighter_name', name);
                  setState(() {
                    _firefighterName = name;
                  });
                  Navigator.of(context).pop();
                }
              },
              child: const Text("Uložit", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _pickCustomRingtone() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result != null && result.files.single.path != null) {
        String path = result.files.single.path!;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('saved_alarm_mp3', path);

        setState(() {
          _customAudioPath = path;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("✅ Vlastní MP3 vyzvánění úspěšně nastaveno!")),
          );
        }
      }
    } catch (e) {
      debugPrint("Chyba při výběru souboru: $e");
    }
  }

  void _requestNotificationPermission() async {
    try {
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );

      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint("Chyba žádosti o práva na notifikace: $e");
    }
  }

  void _checkActiveAlarmOnOpen() async {
    try {
      var snapshot = await FirebaseFirestore.instance
          .collection('alarmy')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        var doc = snapshot.docs.first;
        _lastProcessedAlarmId = doc.id;
        String rawText = doc.data()['text'] ?? '';
        AlarmMessage? parsed = AlarmMessage.parse(rawText);
        
        setState(() {
          _currentAlarm = parsed ?? AlarmMessage(
            technika: "Neznámá", datum: "", cas: "", typUdalosti: "Mimořádná událost", mesto: "", adresa: rawText, poznamka: ""
          );
        });
      }
    } catch (e) {
      debugPrint("Chyba načítání aktivity při otevření: $e");
    }
  }

  void _stopAlarmSound() async {
    try {
      await _audioPlayer.stop();
      final service = FlutterBackgroundService();
      service.invoke('stopAudio');
    } catch (e) {
      debugPrint("Chyba zastavení zvuku: $e");
    }
  }

  void _sendResponse(String alarmId, String status, Color color) async {
    if (_firefighterName.isEmpty) {
      _showNameInputDialog();
      return;
    }

    _stopAlarmSound();
    setState(() {
      _myStatus = status;
      _statusColor = color;
    });

    try {
      await FirebaseFirestore.instance
          .collection('alarmy')
          .doc(alarmId)
          .collection('odpovědi')
          .doc(_firefighterName)
          .set({
        'status': status,
        'time': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("Chyba při odesílání odpovědi: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_firefighterName.isEmpty ? 'JSDH Svolávač' : 'JSDH: $_firefighterName'),
        backgroundColor: Colors.red.shade900,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Změnit jméno',
            onPressed: _showNameInputDialog,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Nastavit vlastní MP3 vyzvánění',
            onPressed: _pickCustomRingtone,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700, width: 2),
              ),
              child: Column(
                children: [
                  const Text(
                    "🟢 Služba na pozadí aktivní (24/7)",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.greenAccent,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Přihlášen: ${_firefighterName.isEmpty ? 'Neznámý hasič' : _firefighterName}",
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Moje odpověď: $_myStatus",
                    style: TextStyle(color: _statusColor, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "Detaily posledního poplachu:",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            if (_currentAlarm == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40.0),
                child: Center(
                  child: Text(
                    "Aplikace úspěšně hlídá pozadí.\nČeká se na vyhlášení poplachu z velení...",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 15),
                  ),
                ),
              )
            else ...[
              _buildInfoTile("Typ události", _currentAlarm!.typUdalosti, Colors.redAccent),
              _buildInfoTile("Město", _currentAlarm!.mesto, Colors.white),
              _buildInfoTile("Adresa", _currentAlarm!.adresa, Colors.white),
              _buildInfoTile("Datum a čas", "${_currentAlarm!.datum} ${_currentAlarm!.cas}", Colors.orangeAccent),
              _buildInfoTile("Technika", _currentAlarm!.technika, Colors.lightBlueAccent),
              _buildInfoTile("Poznámka", _currentAlarm!.poznamka, Colors.yellowAccent),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: () {
                        _sendResponse(_lastProcessedAlarmId ?? "posledni_alarm", "JEDU NA ZÁSAH", Colors.green);
                      },
                      child: const Text("JEDU", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black54,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: () {
                        _sendResponse(_lastProcessedAlarmId ?? "posledni_alarm", "NEMŮŽU", Colors.red);
                      },
                      child: const Text("NEMŮŽU", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              "$label:",
              style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}