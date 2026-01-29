import 'dart:convert';
import 'dart:io' show SecurityContext;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:math' show cos, sqrt, asin;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

// MQTT imports — use apenas uma versão de cada
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// Estilo e fontes
import 'package:google_fonts/google_fonts.dart';

// GPS
import 'package:geolocator/geolocator.dart';
import 'dart:async';


// Páginas internas
import 'dashboard_page.dart';
import 'parking_entry_page.dart';
import 'package:smart_parking_app/screens/estacionamento_page.dart';



//Fire Base 
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


// 👇 ENUM NO TOPO DO ARQUIVO (FORA DE QUALQUER CLASSE)
enum StatusVaga {
  livre,
  ocupada,
  aguardandoPagamento,
  pagaComJanela,
}




void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const SmartParkingApp());
}


class SmartParkingApp extends StatelessWidget {
  const SmartParkingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Parking',
      debugShowCheckedModeBanner: false,
      //home: const EstacionamentoScreen(), // 👈 aqui
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A237E),
          primary: const Color(0xFF3949AB),
          secondary: const Color(0xFF1A237E),
          surface: Colors.white,
          onPrimary: Colors.white,
        ),
        textTheme: GoogleFonts.poppinsTextTheme(),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A237E),
          foregroundColor: Colors.white,
          elevation: 3,
          centerTitle: true,
        ),
      ),
      home: const ParkingHomePage(),
    );
  }
}

class ParkingHomePage extends StatefulWidget {
  const ParkingHomePage({super.key});

  @override
  State<ParkingHomePage> createState() => _ParkingHomePageState();
}

class _ParkingHomePageState extends State<ParkingHomePage> {
  
  final userCtrl = TextEditingController(text: 'Veículo');
  final vehicleCtrl = TextEditingController(text: 'ABC-1234');
  DateTime scheduledAt = DateTime.now().add(const Duration(minutes: 5));

  late MqttClient client;
  final FirebaseFirestore db = FirebaseFirestore.instance;
  bool connected = false;
  String logs = '';
  late FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;
  Position? _currentPosition;

  // Status das vagas
  final Map<String, bool> vagaStatus = {
    'Vaga 1': false,
    'Vaga 2': false,
    'Vaga 3': false,
    'Vaga 4': false,
  };
  String vagaSelecionada = 'Vaga 1';

  // Localização fixa do estacionamento (troca pelos dados reais)
  static const double espLat = %use your location;
  static const double espLng = %use your location;

  // Raio para considerar "perto do estacionamento"
  static const double detectionRadiusMeters = 20;

  // Controle do modo automático
  bool autoRetiradaAtiva = false;
  bool retiradaJaAgendada = false;
  bool perguntaEmExibicao = false;
  DateTime? retiradaAgendada;   // horário definido pelo usuário
  DateTime? ultimaRetiradaNaFila;    // última retirada da fila
  bool retiradaExecutada = false;
  bool perguntaGpsEmExibicao = false;
  bool gpsAtivo = true; // se quiser toggle depois
  bool modoTesteEmCasa = true; // 🔥 TROQUE PARA false em produção
  double distanciaSimuladaMetros = 100.0;

  StatusVaga statusVaga = StatusVaga.livre;

  DateTime? inicioEstacionamento;
  DateTime? pagamentoConfirmadoEm;

  double valorPorMinuto = 1.0;
  double valorPago = 0.0;

  int janelaSaidaMinutos = 5;

  bool servoBusy = false;

  Timer? _timerChegadaPagamento;
  bool pagamentoChegadaAgendado = false;
  bool _usuarioDentroDoRaio = false;
  bool _bloquearDialogAteSairDoRaio = false;
  bool _perguntaProximidadeAberta = false; // evita spam de dialogs
  DateTime? _ultimaLogDistancia;
  bool _retiradaConfirmadaPorGps = false;






  Future<Position> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      appendLog('⚠️ GPS desativado no dispositivo.');
      throw Exception('Location services are disabled');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        appendLog('⚠️ Permissão de localização negada.');
        throw Exception('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      appendLog('⚠️ Permissão de localização negada permanentemente.');
      throw Exception('Location permissions are permanently denied.');
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
    _checkLocationPermission();
    _startLocationUpdates(); // ✅ adiciona esta linha
    //_startProximityLoop();
    _listenToVagas();
    _startHorarioLoop();

  }

  void _listenToVagas() {
  db.collection('vagas').snapshots().listen((snapshot) {
    for (var doc in snapshot.docs) {
      final vaga = doc.id;
      final ocupada = doc.data()['ocupada'] ?? false;

      if (vagaStatus.containsKey(vaga)) {
        setState(() {
          vagaStatus[vaga] = ocupada;
        });
      }
    }

    appendLog('♻️ Vagas atualizadas automaticamente pelo Firestore');
  });
}

  void _startProximityLoop() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 20));
      if (!mounted) return false;
      if (!autoRetiradaAtiva) return true;

      await checkProximityAndAsk();
      return true; // continua enquanto a tela existir
    });
  }

  void appendLog(String text) {
    setState(() =>
        logs = '${DateFormat.Hms().format(DateTime.now())}: $text\n$logs');
  }

Future<void> connectMQTT() async {
  appendLog('Tentando conectar ao HiveMQ Cloud via WSS...');

  final broker = 'use your broker';
  final username = 'username';
  final password = 'password';

  client = MqttBrowserClient('your broker', 'smart_parking_web');
  client.port = 8884;
  client.keepAlivePeriod = 30;
  client.setProtocolV311();

  // ⭐ ESSENCIAL no Web em muitos casos:
  client.websocketProtocols = ['mqtt'];

  client.logging(on: true); // ajuda MUITO a enxergar o que está acontecendo

  client.onConnected = () => appendLog('✅ Conectado ao HiveMQ!');
  client.onDisconnected = () => appendLog('❌ Desconectado.');
  client.onSubscribed = (t) => appendLog('✅ Subscribed: $t');

  final connMess = MqttConnectMessage()
      .withClientIdentifier('flutter_web_${DateTime.now().millisecondsSinceEpoch}')
      .authenticateAs(username, password)
      .startClean();

  client.connectionMessage = connMess;

  try {
    await client.connect();
    setState(() => connected = true);
    appendLog('✅ Conexão bem-sucedida!');

    // 1) assina
    client.subscribe('smartparking/vagas/+/status', MqttQos.atLeastOnce);

    // 2) inicia o listener UMA vez aqui (não no onConnected)
    listenToMqtt();
  } catch (e) {
    appendLog('❌ Erro ao conectar: $e');
    client.disconnect();
  }
}




  Future<void> scheduleCar() async {
    if (!connected) return;
    final userId = userCtrl.text.trim();
    final topic = 'app/schedule/$userId';
    final payload = jsonEncode({
      "user_id": userId,
      "vehicle_id": vehicleCtrl.text.trim(),
      "scheduled_at": scheduledAt.toIso8601String(),
    });
    final builder = MqttClientPayloadBuilder()..addString(payload);
    client.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
    appendLog('🚗 Agendamento enviado: $payload');
  }

  Future<void> main() async {
    final client = MqttServerClient.withPort(
      'your broker',
      'id',
      8883,
    );

    client.secure = true;
    client.logging(on: true);
    client.keepAlivePeriod = 20;
    client.securityContext = SecurityContext.defaultContext;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('id')
        .authenticateAs('username', 'password')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    client.connectionMessage = connMessage;

    try {
      await client.connect();
      print('✅ Conectado ao HiveMQ Cloud!');
    } catch (e) {
      print('Erro de conexão: $e');
      client.disconnect();
      return;
    }

    client.subscribe('spotz/teste', MqttQos.atLeastOnce);
    client.updates?.listen((c) {
      final msg = c[0].payload as MqttPublishMessage;
      final text =
          MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      print('📩 Recebido: $text');
    });

    // Publica exemplo
    final builder = MqttClientPayloadBuilder();
    builder.addString('Olá do app Flutter!');
    client.publishMessage('spotz/teste', MqttQos.atLeastOnce, builder.payload!);
  }

  Future<void> checkProximityAndAsk() async {
    // Só roda se:
    if (!connected ||
        !autoRetiradaAtiva ||
        retiradaJaAgendada ||
        perguntaEmExibicao) {
      return;
    }

    try {
      final pos = await _determinePosition();

      final distance = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        espLat,
        espLng,
      );

      appendLog(
        '📍 Distância até o estacionamento: ${distance.toStringAsFixed(1)} m',
      );

      if (distance <= detectionRadiusMeters) {
        // Evita abrir vários diálogos ao mesmo tempo
        perguntaEmExibicao = true;

        if (!mounted) return;

        final confirma = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Retirada do veículo'),
            content: const Text(
              'Parece que você está próximo ao estacionamento.\n'
              'Você está indo retirar o veículo?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Não'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Sim'),
              ),
            ],
          ),
        );

        perguntaEmExibicao = false;

        if (confirma == true) {
          // Define retirada para agora + 5 minutos
          scheduledAt = DateTime.now().add(const Duration(minutes: 5));
          await scheduleCar();

          retiradaJaAgendada = true;
          autoRetiradaAtiva = false;

          appendLog('✅ Retirada agendada após confirmação do usuário.');
          if (mounted) setState(() {});
        } else {
          appendLog('ℹ️ Usuário recusou a retirada automática.');
        }
      }
    } catch (e) {
      appendLog('Erro ao obter localização: $e');
    }
  }

Future<void> registrarEstacionamento() async {
  if (!connected) {
    appendLog('⚠️ Conecte ao MQTT antes de registrar estacionamento.');
    return;
  }

  final vaga = vagaSelecionada;
  final builder = MqttClientPayloadBuilder()..addString('$vaga:ocupada');
  client.publishMessage('smartparking/status', MqttQos.atLeastOnce, builder.payload!);

  setState(() => vagaStatus[vaga] = true);

  await db.collection('vagas').doc(vaga).set({
    'ocupada': true,
    'ultimaAtualizacao': FieldValue.serverTimestamp(),
  });

  appendLog('🚗 $vaga ocupada (MQTT + Firestore)');
  inicioEstacionamento = DateTime.now();
  valorPago = 0.0;
  pagamentoConfirmadoEm = null;

  statusVaga = StatusVaga.ocupada;
  appendLog('🚗 Estacionamento iniciado');
}


Future<void> liberarVaga(String vaga) async {
  if (!connected) return;

  final builder = MqttClientPayloadBuilder()..addString('$vaga:livre');
  client.publishMessage('smartparking/status', MqttQos.atLeastOnce, builder.payload!);

  setState(() => vagaStatus[vaga] = false);

  await db.collection('vagas').doc(vaga).set({
    'ocupada': false,
    'ultimaAtualizacao': FieldValue.serverTimestamp(),
  });

  appendLog('🅿️ $vaga liberada (MQTT + Firestore)');
}


// 🔔 Mostra notificação local e faz agendamento automático
  Future<void> _mostrarNotificacaoRetirada() async {
    if (!autoRetiradaAtiva) return;

    const androidDetails = AndroidNotificationDetails(
      'retirada_channel',
      'Notificações de Retirada',
      importance: Importance.max,
      priority: Priority.high,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    await flutterLocalNotificationsPlugin.show(
      0,
      'Smart Parking 🚗',
      'Você está próximo ao estacionamento. Deseja agendar a retirada?',
      notificationDetails,
    );

    // Aguarda 5 segundos e agenda automaticamente
    await Future.delayed(const Duration(seconds: 5));
    await scheduleCar();
    appendLog(
        '✅ Agendamento automático de retirada enviado (proximidade detectada)');
  }

// 🛰️ Atualiza posição continuamente e checa proximidade
void _startLocationUpdates() {
  const double raio = 20.0;
  const estacionamentoLat = %use your location;
  const estacionamentoLng = %use your location;

  Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
  ).listen((Position position) async {
    _currentPosition = position;

    final distancia = _calcularDistancia(
      estacionamentoLat,
      estacionamentoLng,
      position.latitude,
      position.longitude,
    );

    // ✅ LOG DA DISTÂNCIA (com throttle)
    final agora = DateTime.now();
    final podeLogar = _ultimaLogDistancia == null ||
        agora.difference(_ultimaLogDistancia!) >= const Duration(seconds: 5);

    if (podeLogar) {
      appendLog('📏 Distância até estacionamento: ${distancia.toStringAsFixed(1)} m');
      _ultimaLogDistancia = agora;
    }

    final dentro = distancia <= raio;

    // ✅ Detecta transição: saiu do raio -> libera perguntar de novo
    if (!dentro && _usuarioDentroDoRaio) {
      _bloquearDialogAteSairDoRaio = false;
      _retiradaConfirmadaPorGps = false; // ✅ reset ao sair do raio (opcional)
      pagamentoChegadaAgendado = false;  // ✅ opcional: libera lógica de ETA novamente
      appendLog('↩️ Saiu do raio. Proximidade liberada para perguntar novamente.');
    }

    _usuarioDentroDoRaio = dentro;

    // ✅ Se o switch estiver OFF: NÃO abre box (mas o log já rolou acima)
    if (!autoRetiradaAtiva) {
      return;
    }

    // ✅ Se já confirmou que vai retirar: não mostra mais boxes
    if (_retiradaConfirmadaPorGps) {
      return;
    }

    // ✅ Só pergunta quando:
    // - dentro do raio
    // - não bloqueado por negação anterior
    // - não há dialog aberto
    // - não tem ETA/pagamento já agendado
    if (dentro &&
        !_bloquearDialogAteSairDoRaio &&
        !_perguntaProximidadeAberta &&
        !pagamentoChegadaAgendado) {

      _perguntaProximidadeAberta = true;

      final confirmar = await _confirmarRetiradaPorProximidade(distancia);

      _perguntaProximidadeAberta = false;

      if (confirmar) {
        // ✅ marcou que já confirmou: não aparece mais box nenhum
        _retiradaConfirmadaPorGps = true;

        // ✅ agenda ETA -> abre box pagamento
        _agendarBoxPagamentoAposChegada(raio);

        appendLog('✅ Usuário confirmou retirada. Não exibirei mais boxes de proximidade.');
      } else {
        // ✅ negou: só reaparece depois que sair do raio e voltar
        _bloquearDialogAteSairDoRaio = true;
        appendLog('⛔ Usuário negou retirada. Só perguntarei de novo após sair e retornar ao raio.');
      }
    }
  });
}



// 📐 Calcula distância entre dois pontos (em metros)
  double _calcularDistancia(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const p = 0.017453292519943295; // pi / 180
    final a = 0.5 -
        cos((lat2 - lat1) * p) / 2 +
        cos(lat1 * p) * cos(lat2 * p) * (1 - cos((lon2 - lon1) * p)) / 2;
    return 12742 * 1000 * asin(sqrt(a)); // distância em metros
  }

  void _initializeNotifications() {
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    flutterLocalNotificationsPlugin.initialize(initSettings);
  }

  Future<void> _checkLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }
  }



bool _mqttListening = false;

void listenToMqtt() {
  if (_mqttListening) return;
  _mqttListening = true;

  if (client.updates == null) {
    appendLog('⚠️ client.updates é NULL (não vai receber mensagens).');
    return;
  }

  appendLog('👂 Escutando MQTT updates...');

  client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) async {
    final topic = c[0].topic;
    final recMess = c[0].payload as MqttPublishMessage;
    final msg = MqttPublishPayload.bytesToStringAsString(recMess.payload.message).trim();

    appendLog('📩 [$topic] $msg');

    if (topic.startsWith('smartparking/vagas/') && topic.endsWith('/status')) {
      final vagaId = topic.split('/')[2]; // vaga1, vaga2

      final vagaDoc = (vagaId == 'vaga1') ? 'Vaga 1'
                   : (vagaId == 'vaga2') ? 'Vaga 2'
                   : null;

      if (vagaDoc == null) return;

      final ocupada = (msg == 'true');

      try {
        await db.collection('vagas').doc(vagaDoc).set({
          'ocupada': ocupada,
          'ultimaAtualizacao': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        appendLog('🔥 Firestore atualizado: $vagaDoc → $ocupada');
      } catch (e) {
        appendLog('❌ ERRO Firestore: $e');
      }
    }
  });
}


Future<void> enviarComandoServo(String comando) async {
  if (!connected) {
    appendLog('⚠️ MQTT não conectado.');
    return;
  }

  final builder = MqttClientPayloadBuilder()..addString(comando);

  client.publishMessage(
    'smartparking/servo/comando',
    MqttQos.atLeastOnce,
    builder.payload!,
  );

  appendLog('🎮 Comando enviado ao servo: $comando');
}



void verificarRetiradaPorHorario() {
  if (retiradaAgendada == null) return;
  if (retiradaExecutada) return;

  final agora = DateTime.now();

  if (agora.isAfter(retiradaAgendada!)) {
    appendLog('⏰ Horário atingido. Executando retirada.');

    tentarRetirada(context);

    retiradaExecutada = true;
  }
}


double calcularDistanciaGps(Position pos) {
  return Geolocator.distanceBetween(
    pos.latitude,
    pos.longitude,
    espLat,
    espLng,
  );
}





void _startHorarioLoop() {
  Future.doWhile(() async {
    await Future.delayed(const Duration(seconds: 10));
    if (!mounted) return false;

    verificarRetiradaPorHorario();

    return true;
  });
}




DateTime calcularHorarioRetiradaPorGps() {
  final agora = DateTime.now();
  final limitePrioridade = agora.add(const Duration(minutes: 2));

  // Se existe retirada iminente (< 2 min), GPS não fura fila
  if (retiradaAgendada != null &&
      retiradaAgendada!.isBefore(limitePrioridade)) {

    final base = ultimaRetiradaNaFila ?? retiradaAgendada!;
    return base.add(const Duration(minutes: 1));
  }

  // Caso contrário, GPS tem prioridade
  return agora.add(const Duration(minutes: 5));
}



Future<void> verificarProximidadeGps() async {
  if (!autoRetiradaAtiva) return;
  if (!gpsAtivo ||
      retiradaExecutada ||
      perguntaGpsEmExibicao) return;

  final pos = await _determinePosition();
  final distancia = calcularDistanciaGps(pos);

  appendLog('📍 Distância GPS: ${distancia.toStringAsFixed(1)} m');

  if (distancia <= detectionRadiusMeters) {
    perguntaGpsEmExibicao = true;

    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirada do veículo'),
        content: Text(
          'Você está a ${distancia.toStringAsFixed(1)} m do estacionamento.\n'
          'Deseja retirar o veículo?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Não'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sim'),
          ),
        ],
      ),
    );

    perguntaGpsEmExibicao = false;

    if (confirma == true) {
      final horario = calcularHorarioRetiradaPorGps();

      setState(() {
        retiradaAgendada = horario;
        ultimaRetiradaNaFila = horario;
        retiradaExecutada = false;
      });

      appendLog(
        '📍 Retirada por GPS agendada para '
        '${DateFormat.Hm().format(horario)}',
      );
    }
  }
}




Future<double> obterDistanciaEstacionamento() async {
  if (modoTesteEmCasa) {
    return distanciaSimuladaMetros;
  }

  final pos = await _determinePosition();
  return Geolocator.distanceBetween(
    pos.latitude,
    pos.longitude,
    espLat,
    espLng,
  );
}







void _mostrarBoxSaidaVeiculo(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Confirmação'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Confirme sua segurança:',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text('Meu veículo está estacionado e \n Estou fora do veículo'),
              onPressed: () {
                abrirServo(); // 🔥 mesma lógica de antes
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      );
    },
  );
}





Future<void> abrirServo() async {
  if (!connected || servoBusy) return;

  servoBusy = true;

  final payload = jsonEncode({
    "acao": "abrir",
    "vaga": vagaSelecionada.toLowerCase().replaceAll(' ', ''),
  });

  final builder = MqttClientPayloadBuilder()..addString(payload);

  client.publishMessage(
    'smartparking/servo/comando',
    MqttQos.atLeastOnce,
    builder.payload!,
  );

  appendLog('🔧 Servo ABRIR enviado');

  Future.delayed(const Duration(seconds: 2), () {
    servoBusy = false;
  });
}





void enviarComandoRetirada() {
  if (!connected) return;

  final payload = jsonEncode({
    "acao": "retirar",
    "vaga": vagaSelecionada.toLowerCase().replaceAll(' ', ''),
  });

  final builder = MqttClientPayloadBuilder()..addString(payload);

  client.publishMessage(
    'smartparking/servo/comando',
    MqttQos.atLeastOnce,
    builder.payload!,
  );

  appendLog('🚗 Retirada enviada para ${vagaSelecionada}');
}



double calcularValorDevido() {
  if (inicioEstacionamento == null) return 0;

  final segundos =
      DateTime.now().difference(inicioEstacionamento!).inSeconds;

  return (segundos / 10) * valorPorMinuto; // cobra a cada 10s
}


double calcularSaldo() {
  return calcularValorDevido() - valorPago;
}



void tentarRetirada(BuildContext context) {
  final saldo = calcularSaldo();

  debugPrint('👉 tentarRetirada chamada');
  debugPrint('👉 Saldo calculado: $saldo');
  debugPrint('👉 Status vaga: $statusVaga');

  if (saldo > 0) {
    _mostrarBoxPagamento(context, saldo);
  } else {
    tentarAbrirServo(context);
  }
}






void confirmarPagamento(double valor) {
  valorPago += valor;
  pagamentoConfirmadoEm = DateTime.now();

  statusVaga = StatusVaga.pagaComJanela;
  appendLog('💰 Pagamento confirmado');
}



bool janelaExpirada() {
  if (pagamentoConfirmadoEm == null) return true;

  final limite =
      pagamentoConfirmadoEm!.add(Duration(minutes: janelaSaidaMinutos));

  return DateTime.now().isAfter(limite);
}



void tentarAbrirServo(BuildContext context) {
  if (statusVaga != StatusVaga.pagaComJanela || janelaExpirada()) {
    tentarRetirada(context);
    return;
  }

  abrirServo(); // sua função existente
  finalizarVaga();
}



void finalizarVaga() {
  statusVaga = StatusVaga.livre;
  inicioEstacionamento = null;
  pagamentoConfirmadoEm = null;
  valorPago = 0;

  appendLog('✅ Vaga liberada');
}


void _mostrarBoxPagamento(BuildContext context, double saldo) {
  showDialog(
    context: context,
    barrierDismissible: false, // importante
    builder: (_) {
      return AlertDialog(
        title: const Text('Pagamento para retirada'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Valor a pagar: R\$ ${saldo.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),

            // QR Code fictício
            Container(
              height: 150,
              width: 150,
              color: Colors.grey[300],
              child: const Center(
                child: Text('QR CODE\nPIX',
                    textAlign: TextAlign.center),
              ),
            ),

            const SizedBox(height: 20),
            const Text(
              'Pagamento simulado para apresentação',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // não pagou
            },
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                valorPago += saldo;
                pagamentoConfirmadoEm = DateTime.now();
                statusVaga = StatusVaga.pagaComJanela;
              });

              Navigator.pop(context);

              abrirServo();

              Future.delayed(const Duration(seconds: 5), () {
                fecharServo();
                finalizarVaga();
              });

            },
            child: const Text('Confirmar pagamento'),
          ),
        ],
      );
    },
  );
}




void _liberarCarro() {
  if (statusVaga != StatusVaga.pagaComJanela || janelaExpirada()) {
    return;
  }

  abrirServo();
  finalizarVaga();
}



Future<void> fecharServo() async {
  if (!connected) return;

  final payload = jsonEncode({
    "acao": "fechar",
    "vaga": vagaSelecionada.toLowerCase().replaceAll(' ', ''),
  });

  final builder = MqttClientPayloadBuilder()..addString(payload);

  client.publishMessage(
    'smartparking/servo/comando',
    MqttQos.atLeastOnce,
    builder.payload!,
  );

  appendLog('🔧 Servo FECHAR (JSON) enviado: $payload');
}


Future<bool> _confirmarRetiradaPorProximidade(double distancia) async {
  if (!mounted) return false;
  if (!autoRetiradaAtiva) return false;

  final resp = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Você está perto do estacionamento'),
      content: Text(
        'Detectamos que você está a ${distancia.toStringAsFixed(1)} m.\n\n'
        'Você está indo retirar o veículo agora ou só está passando perto?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Só estou por perto'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Vou retirar agora'),
        ),
      ],
    ),
  );

  return resp ?? false;
}


Duration _calcularTempoAteChegarPeloRaio(double raioMetros) {
  // 5 km/h = 1.388888... m/s
  const double velocidadeMs = 5 * 1000 / 3600;
  final segundos = (raioMetros / velocidadeMs).round();
  return Duration(seconds: segundos);
}

void _agendarBoxPagamentoAposChegada(double raioMetros) {
  if (!mounted) return;
  if (!autoRetiradaAtiva) return;

  // evita duplicar timers
  _timerChegadaPagamento?.cancel();

  final eta = _calcularTempoAteChegarPeloRaio(raioMetros);
  pagamentoChegadaAgendado = true;

  appendLog('⏳ ETA até o estacionamento: ~${eta.inSeconds}s (5 km/h, raio=${raioMetros.toStringAsFixed(0)}m)');

  _timerChegadaPagamento = Timer(eta, () {
    if (!mounted) return;

    appendLog('📌 ETA atingido. Abrindo box de pagamento...');

    final saldo = calcularSaldo();

    // Se tem saldo, abre pagamento; se não tem, segue direto para liberar
    if (saldo > 0) {
      _mostrarBoxPagamento(context, saldo);
    } else {
      tentarAbrirServo(context);
    }

    pagamentoChegadaAgendado = false;
  });
}


@override
void dispose() {
  _timerChegadaPagamento?.cancel();
  super.dispose();
}






























  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Parking - TESTE'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Text(
              'Dados do Veículo',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(
                labelText: 'Modelo do veículo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: vehicleCtrl,
              decoration: const InputDecoration(
                labelText: 'Placa do veículo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            // ---- BOTÃO DE CONEXÃO ----
            ElevatedButton.icon(
              onPressed: connected ? null : connectMQTT,
              icon: Icon(connected ? Icons.check_circle : Icons.wifi),
              label: Text(connected ? 'Conectado' : 'Entrar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: connected ? Colors.green : Colors.indigo,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
              ),
            ),
            const SizedBox(height: 20),





            // ---- SEÇÃO DE ESTACIONAMENTO ----
            const Text(
              'Registro de Estacionamento',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            DropdownButtonFormField<String>(
              value: vagaSelecionada,
              items: vagaStatus.keys
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: connected
                  ? (v) {
                      if (v != null) setState(() => vagaSelecionada = v);
                    }
                  : null,
              decoration: const InputDecoration(
                labelText: 'Selecione a vaga',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 15),

            const Text(
              'Consulte os status das vagas abaixo',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),

            ElevatedButton.icon(
              onPressed: connected
                  ? () async {
                      await registrarEstacionamento();
                      _mostrarBoxSaidaVeiculo(context); // ✅ novo passo
                    }
                  : null,
              icon: const Icon(Icons.local_parking),
              label: const Text('Registrar Estacionamento'),
            ),










            // ---- AGENDAMENTO ----
            const Text(
              'Agende sua retirada',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),

            // Seletor de horário
            const Text(
              'Selecione o horário',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Horário: ${DateFormat('HH:mm').format(scheduledAt)}',
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(scheduledAt),
                    );
                    if (time != null) {
                      setState(() {
                        scheduledAt = DateTime(
                          DateTime.now().year,
                          DateTime.now().month,
                          DateTime.now().day,
                          time.hour,
                          time.minute,
                        );
                      });
                    }
                  },
                  child: const Text('Escolher horário'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            ElevatedButton.icon(
               onPressed: connected
                  ? () {
                    // 🔹 mantém o que você já fazia
                    scheduleCar();

                    // 🔹 PASSO 2 — salva horário para retirada automática
                    setState(() {
                      retiradaAgendada = scheduledAt;
                      retiradaExecutada = false;
                    });

                    appendLog(
                      '⏰ Retirada agendada para ${DateFormat.Hm().format(scheduledAt)}',
                    );
                  }
                : null,
              icon: const Icon(Icons.timer),
              label: const Text('Agendar Retirada'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 45),
              ),
            ),

            // ---- BOTÃO DE retirada ----
            ElevatedButton(
              onPressed: () => tentarAbrirServo(context),
              child: const Text('Retirar veículo agora'),
            ),


            

            SwitchListTile.adaptive(
              title: const Text('Ativar retirada automática por GPS'),
              subtitle: Text(
                'Quando estiver a menos de ${detectionRadiusMeters.toInt()} m, o app pergunta se você quer agendar a retirada.',
                style: const TextStyle(fontSize: 12),
              ),
              value: autoRetiradaAtiva,
              onChanged: connected
                  ? (v) {
                      setState(() {
                        autoRetiradaAtiva = v;
                        retiradaJaAgendada = false;

                        if (!v) {
                          _usuarioDentroDoRaio = false;
                          _bloquearDialogAteSairDoRaio = false;
                          _perguntaProximidadeAberta = false;

                          _retiradaConfirmadaPorGps = false;       // ✅ importante
                          _timerChegadaPagamento?.cancel();         // ✅ importante
                          pagamentoChegadaAgendado = false;         // ✅ importante
                        }

                      });

                      appendLog(v
                          ? '🛰️ Retirada automática ativada.'
                          : '🛰️ Retirada automática desativada.');
                    }
                  : null,

            ),
            const SizedBox(height: 10),

            const SizedBox(height: 30),

            // ---- STATUS DAS VAGAS ----
            const Text(
              'Status das Vagas',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              children: vagaStatus.entries.map((entry) {
                final vaga = entry.key;
                final ocupada = entry.value;
                return GestureDetector(
                  onLongPress: connected ? () => liberarVaga(vaga) : null,
                  child: Card(
                    color: ocupada ? Colors.red : Colors.green,
                    child: Center(
                      child: Text(
                        vaga,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 30),

            // ---- LOGS ----
            const Text(
              'Logs do Sistema',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Container(
              height: 180,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
                color: Colors.black12,
              ),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  logs,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
