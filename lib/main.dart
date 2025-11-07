// هذا ملف واحد يحتوي على كل الكلاسات لسهولة الشرح والتحكم
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

// --- إضافات Firebase الأساسية ---
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'firebase_options.dart';

// --- إضافة حزمة الإشعارات الجديدة ---
import 'package:firebase_messaging/firebase_messaging.dart';

// ==============================================
// === تهيئة الإشعارات ومعالجة الخلفية (Top-Level) ===
// ==============================================

// دالة لمعالجة رسائل الخلفية (يجب أن تكون دالة على مستوى علوي/Top-Level Function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // يجب إعادة تهيئة Firebase إذا كنت تستخدم خدمات أخرى في الخلفية
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print("Handling a background message: ${message.messageId}");
}

// ----------------------------------------------
// 0.0 دالة main
// ----------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // *الإضافة الجديدة لمعالجة رسائل الخلفية*
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // تهيئة اللغة العربية لمكتبة الوقت
  await initializeDateFormatting('ar', null);

  runApp(const AttendanceApp());
}

// ----------------------------------------------
// 0.1 خدمة الإشعارات (NotificationService)
// ----------------------------------------------
class NotificationService {
  final _fcm = FirebaseMessaging.instance;
  final _dbRef = rtdb.FirebaseDatabase.instance.ref('users');

  Future<void> initialize() async {
    // 1. طلب صلاحية الإشعارات
    NotificationSettings settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      // 2. جلب وحفظ الـ Token
      await _getAndSaveToken();

      // 3. معالجة الإشعارات أثناء عمل التطبيق (Foreground)
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // 4. معالجة الإشعارات عند الضغط عليها (App is in background/terminated)
      FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpen);
    }
  }

  Future<void> _getAndSaveToken() async {
    final token = await _fcm.getToken();
    final user = FirebaseAuth.instance.currentUser;

    if (token != null && user != null) {
      // أ. حفظ التوكن في مسار المستخدم
      await _dbRef.child('${user.uid}/fcmToken').set(token);

      // ب. التحكم في اشتراكات الـ Topic (لأغراض الإرسال الجماعي/للمدراء)
      final snapshot = await _dbRef.child('${user.uid}/role').get();
      final userRole = snapshot.exists ? snapshot.value.toString() : 'employee';

      // اشتراك الموظفين في Topic عام (لتلقي رسائل المدير الجماعية)
      _fcm.subscribeToTopic('all_employees');

      // اشتراك المدراء في Topic خاص (لتلقي تنبيهات الحضور)
      if (userRole == 'admin') {
        _fcm.subscribeToTopic('admin_alerts');
      } else {
        _fcm.unsubscribeFromTopic(
          'admin_alerts',
        ); // الموظف لا يستقبل تنبيهات المدراء
      }
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    // يمكن استخدام مكتبة flutter_local_notifications هنا لعرض الإشعار بشكل أفضل
    if (message.notification != null) {
      print('Foreground Message Title: ${message.notification!.title}');
    }
  }

  void _handleMessageOpen(RemoteMessage message) {
    print('App opened from message: ${message.data}');
  }
}

// ==============================================
// === كلاسات الواجهة (Widgets) ===
// ==============================================

// ----------------------------------------------
// 1. الكلاس الأساسي للتطبيق (AttendanceApp)
// ----------------------------------------------
class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Attendance App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          elevation: 4,
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

// ----------------------------------------------
// 2. شاشة التحقق (AuthWrapper)
// ----------------------------------------------
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) {
          // *الإضافة الجديدة: تهيئة خدمة الإشعارات بعد تسجيل الدخول*
          NotificationService().initialize();

          return const RoleBasedRedirector();
        }
        return const LoginScreen();
      },
    );
  }
}

// ----------------------------------------------
// 3. شاشة تسجيل الدخول (LoginScreen)
// ----------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' ||
          e.code == 'wrong-password' ||
          e.code == 'invalid-credential') {
        _errorMessage = 'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
      } else {
        _errorMessage = 'حدث خطأ. يرجى المحاولة مرة أخرى.';
      }
    } catch (e) {
      _errorMessage = 'حدث خطأ غير متوقع.';
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 100),
              Icon(
                Icons.lock_clock,
                size: 80,
                color: Theme.of(context).primaryColor,
              ),
              const SizedBox(height: 10),
              const Text(
                'بصمة الحضور الذكية',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 40),

              Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: 'البريد الإلكتروني',
                          prefixIcon: const Icon(Icons.email),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'يرجى إدخال البريد الإلكتروني';
                          }
                          if (!value.contains('@')) {
                            return 'يرجى إدخال بريد إلكتروني صحيح';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: 'كلمة المرور',
                          prefixIcon: const Icon(Icons.lock),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'يرجى إدخال كلمة المرور';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 30),

              if (_errorMessage != null)
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red, fontSize: 14),
                  textAlign: TextAlign.center,
                ),

              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        'تسجيل الدخول',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: _login,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------
// 4. شاشة التحقق من الدور (RoleBasedRedirector)
// ----------------------------------------------
class RoleBasedRedirector extends StatelessWidget {
  const RoleBasedRedirector({super.key});

  Future<String> _getUserRole(String uid) async {
    try {
      final snapshot = await rtdb.FirebaseDatabase.instance
          .ref('users/$uid/role')
          .get();
      if (snapshot.exists && snapshot.value != null) {
        return snapshot.value.toString();
      } else {
        // إذا لم يجد الدور (ربما في لحظة إنشاء المستخدم)
        // يعيد "employee" افتراضياً ليسمح للقاعدة بالعمل
        // هذا يتم معالجته بقاعدة الأمان التي عدلناها
        return 'employee';
      }
    } catch (e) {
      return 'error_exception';
    }
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const LoginScreen();
    }
    return FutureBuilder<String>(
      future: _getUserRole(user.uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) {
          final role = snapshot.data;
          if (role == 'admin') {
            return const AdminHomeScreen();
          } else if (role == 'employee') {
            return const EmployeeHomeScreen();
          } else {
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('خطأ: حسابك غير مُعد. يرجى مراجعة المدير.'),
                    ElevatedButton(
                      child: const Text('تسجيل الخروج'),
                      onPressed: () async {
                        await FirebaseAuth.instance.signOut();
                      },
                    ),
                  ],
                ),
              ),
            );
          }
        }
        return const Scaffold(
          body: Center(child: Text('حدث خطأ في تحميل بيانات المستخدم')),
        );
      },
    );
  }
}

// ----------------------------------------------
// 5. شاشة المدير الرئيسية (AdminHomeScreen)
// ----------------------------------------------
class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  Widget _buildDashboardCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required VoidCallback onPressed,
    Color color = Colors.indigo,
  }) {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(15),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(15.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 40, color: color),
                const SizedBox(height: 10),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('لوحة تحكم المدير'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 15, top: 5, right: 8),
              child: Text(
                'المهام والإدارة',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),

            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.2,
                children: [
                  _buildDashboardCard(
                    context: context,
                    icon: Icons.access_time_filled,
                    title: 'حالة الحضور اليوم',
                    color: Colors.green.shade700,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const EmployeeStatusScreen(),
                        ),
                      );
                    },
                  ),
                  _buildDashboardCard(
                    context: context,
                    icon: Icons.group_add,
                    title: 'إدارة الموظفين',
                    color: Colors.indigo.shade600,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ManageEmployeesScreen(),
                        ),
                      );
                    },
                  ),
                  _buildDashboardCard(
                    context: context,
                    icon: Icons.qr_code_scanner,
                    title: 'إنشاء باركود',
                    color: Colors.orange.shade700,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const QRGeneratorScreen(),
                        ),
                      );
                    },
                  ),
                  _buildDashboardCard(
                    context: context,
                    icon: Icons.campaign,
                    title: 'إرسال إشعار جماعي',
                    color: Colors.red.shade600,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SendNotificationScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------
// 6. شاشة الموظف الرئيسية (EmployeeHomeScreen)
// ----------------------------------------------
class EmployeeHomeScreen extends StatelessWidget {
  const EmployeeHomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('صفحة الموظف'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'مرحباً بك في بصمة الحضور!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 50),

              // الزر الأول: تسجيل الحضور
              ElevatedButton.icon(
                icon: const Icon(Icons.login, size: 28), // أيقونة الدخول
                label: const Text('تسجيل الحضور (Check-in)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 20,
                  ),
                  backgroundColor: Colors.green, // لون الحضور
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      // نرسل "نوع" المسح إلى الشاشة التالية
                      builder: (context) =>
                          const QRScannerScreen(scanMode: ScanMode.checkIn),
                    ),
                  );
                },
              ),
              const SizedBox(height: 25),

              // الزر الثاني: تسجيل الانصراف
              ElevatedButton.icon(
                icon: const Icon(Icons.logout, size: 28), // أيقونة الخروج
                label: const Text('تسجيل الانصراف (Check-out)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 20,
                  ),
                  backgroundColor: Colors.blue, // لون الانصراف
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      // نرسل "نوع" المسح إلى الشاشة التالية
                      builder: (context) =>
                          const QRScannerScreen(scanMode: ScanMode.checkOut),
                    ),
                  );
                },
              ),
              const SizedBox(height: 30),
              const Text(
                'يرجى اختيار العملية الصحيحة قبل مسح الكود.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------
// 7. شاشة إنشاء الكود (تابعة للمدير)
// ----------------------------------------------
class QRGeneratorScreen extends StatefulWidget {
  const QRGeneratorScreen({super.key});
  @override
  State<QRGeneratorScreen> createState() => _QRGeneratorScreenState();
}

class _QRGeneratorScreenState extends State<QRGeneratorScreen> {
  final TextEditingController _textController = TextEditingController();
  String _qrData = "SCAN_ME";
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إنشاء رمز QR')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '1. معاينة الرمز',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 15),
              Center(
                child: Card(
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: QrImageView(
                      data: _qrData,
                      version: QrVersions.auto,
                      size: 220.0,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),

              const Text(
                '2. تحديد معرّف الكود',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _textController,
                decoration: InputDecoration(
                  labelText: 'المعرّف الخاص بالكود',
                  hintText: 'مثال: MAIN_DOOR_FEB25',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => _textController.clear(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('توليد وتحديث الرمز'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(15),
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  setState(() {
                    _qrData = _textController.text.isNotEmpty
                        ? _textController.text
                        : "SCAN_ME";
                  });
                  FocusScope.of(context).unfocus();
                },
              ),
              const SizedBox(height: 40),
              const Text(
                'ملاحظة: هذا الرمز هو الذي سيمسحه الموظفون. يجب طباعته وتعليقه في مكان ثابت.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// إضافة نوع المسح (حضور أو انصراف)
enum ScanMode { checkIn, checkOut }

// ----------------------------------------------
// 8. شاشة مسح الكود (تابعة للموظف)
// ----------------------------------------------
class QRScannerScreen extends StatefulWidget {
  // استقبال نوع المسح المطلوب
  final ScanMode scanMode;

  const QRScannerScreen({super.key, required this.scanMode});
  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _isScanProcessing = false;

  // --- دالة تسجيل الحضور والانصراف الجديدة (معدلة بالكامل) ---
  Future<void> _recordAttendance(String qrCodeData, ScanMode mode) async {
    // 1. تأكد أننا لم نعالج هذا المسح من قبل
    if (_isScanProcessing) return;
    setState(() {
      _isScanProcessing = true;
    });

    String message = 'حدث خطأ غير معروف';
    Color messageColor = Colors.red;

    try {
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception("المستخدم غير مسجل دخوله");
      }
      final String uid = user.uid;
      final String today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final String now = DateTime.now().toIso8601String();
      final logRef = rtdb.FirebaseDatabase.instance.ref(
        'attendance_logs/$today/$uid',
      );

      final snapshot = await logRef.get();
      final String userName =
          (await rtdb.FirebaseDatabase.instance.ref('users/$uid/name').get())
              .value
              .toString();

      if (mode == ScanMode.checkIn) {
        // --- السيناريو 1: المستخدم يريد "تسجيل الحضور" ---
        if (snapshot.exists) {
          message = 'لقد سجلت حضورك لهذا اليوم بالفعل.';
          messageColor = Colors.orange;
        } else {
          final Map<String, dynamic> attendanceData = {
            'name': userName,
            'checkInTime': now,
            'qrCode': qrCodeData,
            'status': 'present',
          };

          await logRef.set(attendanceData);
          message = 'تم تسجيل حضورك بنجاح، $userName';
          messageColor = Colors.green;

          // إرسال تنبيه للمدير
          await rtdb.FirebaseDatabase.instance
              .ref('admin_alerts_queue')
              .push()
              .set({'type': 'check_in', 'employeeName': userName, 'time': now});
        }
      } else if (mode == ScanMode.checkOut) {
        // --- السيناريو 2: المستخدم يريد "تسجيل الانصراف" ---
        if (!snapshot.exists) {
          message = 'خطأ: يجب عليك تسجيل الحضور أولاً قبل الانصراف.';
          messageColor = Colors.red;
        } else {
          final logData = Map<String, dynamic>.from(snapshot.value as Map);
          if (logData.containsKey('checkOutTime')) {
            message = 'لقد سجلت انصرافك لهذا اليوم بالفعل.';
            messageColor = Colors.orange;
          } else {
            await logRef.update({'checkOutTime': now, 'status': 'completed'});

            message = 'تم تسجيل انصرافك. يومك سعيد!';
            messageColor = Colors.blue;

            // إرسال تنبيه للمدير
            await rtdb.FirebaseDatabase.instance
                .ref('admin_alerts_queue')
                .push()
                .set({
                  'type': 'check_out',
                  'employeeName': userName,
                  'time': now,
                });
          }
        }
      }
    } catch (e) {
      message = 'خطأ في تسجيل الحضور: ${e.toString()}';
      messageColor = Colors.red;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: messageColor),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // تغيير لون الشاشة والعنوان بناءً على نوع المسح
    final bool isCheckingIn = widget.scanMode == ScanMode.checkIn;
    final Color appBarColor = isCheckingIn ? Colors.green : Colors.blue;
    final String title = isCheckingIn
        ? 'مسح (تسجيل الحضور)'
        : 'مسح (تسجيل الانصراف)';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: appBarColor,
        elevation: 0,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: (capture) {
              if (_isScanProcessing) return;

              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                // نمرر نوع المسح المطلوب إلى الدالة
                _recordAttendance(barcodes.first.rawValue!, widget.scanMode);
              }
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(20),
              child: Text(
                'قم بتوجيه الكاميرا نحو الـ QR كود لـ $title',
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------
// 9. شاشة عرض حالة الموظفين (ذكية)
// ----------------------------------------------
class EmployeeStatusScreen extends StatelessWidget {
  const EmployeeStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final String todayDate = DateFormat('yyyy-MM-dd').format(now);
    final String todayKey = DateFormat('EEE').format(now).toLowerCase();

    final usersRef = rtdb.FirebaseDatabase.instance.ref('users');
    final logsRef = rtdb.FirebaseDatabase.instance.ref(
      'attendance_logs/$todayDate',
    );

    return Scaffold(
      appBar: AppBar(title: const Text('حالة الموظفين اليوم')),
      body: FutureBuilder(
        future: usersRef.get(),
        builder: (context, usersSnapshot) {
          if (!usersSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (usersSnapshot.hasError) {
            return const Center(child: Text('خطأ في جلب قائمة الموظفين'));
          }
          if (usersSnapshot.data?.value == null) {
            return const Center(child: Text('لا يوجد موظفون معرفون.'));
          }

          final usersMap = Map<dynamic, dynamic>.from(
            usersSnapshot.data!.value as Map,
          );
          final usersList = usersMap.entries.toList();

          return StreamBuilder(
            stream: logsRef.onValue,
            builder: (context, logsSnapshot) {
              final logsMap =
                  (logsSnapshot.hasData &&
                      logsSnapshot.data!.snapshot.value != null)
                  ? Map<dynamic, dynamic>.from(
                      logsSnapshot.data!.snapshot.value as Map,
                    )
                  : <dynamic, dynamic>{};

              return ListView.builder(
                itemCount: usersList.length,
                itemBuilder: (context, index) {
                  final userEntry = usersList[index];
                  final userUid = userEntry.key;

                  final userData = Map<dynamic, dynamic>.from(
                    userEntry.value as Map,
                  );
                  final name = userData['name'] ?? 'موظف غير معروف';
                  final role = userData['role'] ?? 'employee';

                  if (role == 'admin') {
                    return Container();
                  }

                  final schedule = Map<dynamic, dynamic>.from(
                    userData['workSchedule'] as Map? ?? {},
                  );
                  final bool isWorkDay = schedule[todayKey] ?? false;

                  final bool isPresent = logsMap.containsKey(userUid);

                  String statusText;
                  IconData statusIcon;
                  Color statusColor;
                  String subtitleText;

                  if (!isWorkDay) {
                    statusText = 'عطلة';
                    statusIcon = Icons.nightlight_round;
                    statusColor = Colors.grey.shade600;
                    subtitleText = 'يوم عطلة حسب الجدول';
                  } else if (isPresent) {
                    final logData = Map<dynamic, dynamic>.from(
                      logsMap[userUid] as Map,
                    );
                    String timeIn = '--:--';

                    try {
                      final String? checkInTimeRaw = logData['checkInTime'];
                      if (checkInTimeRaw != null) {
                        final dt = DateTime.parse(checkInTimeRaw);
                        timeIn = DateFormat('hh:mm a', 'ar').format(dt);
                      }
                    } catch (e) {
                      timeIn = 'خطأ';
                    }

                    if (logData.containsKey('checkOutTime')) {
                      statusText = 'أكمل الدوام';
                      statusIcon = Icons.task_alt;
                      statusColor = Colors.indigo.shade600;

                      String timeOut = '--:--';
                      try {
                        final String? checkOutTimeRaw = logData['checkOutTime'];
                        if (checkOutTimeRaw != null) {
                          final dt = DateTime.parse(checkOutTimeRaw);
                          timeOut = DateFormat('hh:mm a', 'ar').format(dt);
                        }
                      } catch (e) {
                        timeOut = 'خطأ';
                      }
                      subtitleText = 'دخول: $timeIn | خروج: $timeOut';
                    } else {
                      statusText = 'حاضر';
                      statusIcon = Icons.check_circle;
                      statusColor = Colors.green.shade700;
                      subtitleText = 'الحضور: $timeIn';
                    }
                  } else {
                    statusText = 'غائب';
                    statusIcon = Icons.cancel;
                    statusColor = Colors.red.shade700;
                    subtitleText = 'لم يسجل حضور';
                  }

                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    elevation: 3,
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: statusColor.withOpacity(0.15),
                        child: Icon(statusIcon, color: statusColor),
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      subtitle: Text(
                        subtitleText,
                        style: const TextStyle(color: Colors.black54),
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ----------------------------------------------
// 10. شاشة إدارة الموظفين - **-- [تمت إضافة زر الحذف] --**
// ----------------------------------------------
class ManageEmployeesScreen extends StatelessWidget {
  const ManageEmployeesScreen({super.key});

  // --- [إضافة جديدة] ---
  // دالة إظهار رسالة تأكيد الحذف
  void _showDeleteDialog(
    BuildContext context,
    String employeeUid,
    String employeeName,
  ) {
    // التأكد من أن المدير لا يحاول حذف نفسه
    if (employeeUid == FirebaseAuth.instance.currentUser?.uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا يمكنك حذف حسابك (المدير).'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: Text(
          'هل أنت متأكد أنك تريد حذف الموظف "$employeeName"؟'
          '\n\nسيتم حذف حسابه (Authentication) وبياناته (Database) بشكل نهائي.',
        ),
        actions: [
          TextButton(
            child: const Text('إلغاء'),
            onPressed: () {
              Navigator.of(ctx).pop();
            },
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('حذف نهائي'),
            onPressed: () {
              // --- [إضافة جديدة] ---
              // إرسال طلب الحذف إلى الـ Cloud Function
              _requestDeleteEmployee(employeeUid);
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('تم إرسال طلب الحذف...'),
                  backgroundColor: Colors.blue,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // --- [إضافة جديدة] ---
  // دالة إرسال الطلب إلى قاعدة البيانات
  Future<void> _requestDeleteEmployee(String uidToDelete) async {
    try {
      final adminUid = FirebaseAuth.instance.currentUser!.uid;
      await rtdb.FirebaseDatabase.instance.ref('delete_requests').push().set({
        'uidToDelete': uidToDelete,
        'requestedByAdmin': adminUid,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print("خطأ في إرسال طلب الحذف: $e");
    }
  }
  // --- [نهاية الإضافات] ---

  @override
  Widget build(BuildContext context) {
    final dbRef = rtdb.FirebaseDatabase.instance.ref('users');

    return Scaffold(
      appBar: AppBar(title: const Text('إدارة الموظفين')),
      body: StreamBuilder(
        stream: dbRef.onValue,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('حدث خطأ: ${snapshot.error}'));
          }
          if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
            return const Center(child: Text('لا يوجد موظفون حتى الآن.'));
          }

          final usersMap = Map<dynamic, dynamic>.from(
            snapshot.data!.snapshot.value as Map,
          );
          final usersList = usersMap.entries.toList();

          return ListView.builder(
            itemCount: usersList.length,
            itemBuilder: (context, index) {
              final userEntry = usersList[index];
              final employeeUid = userEntry.key;

              final userData = Map<dynamic, dynamic>.from(
                userEntry.value as Map,
              );

              final String name = userData['name'] ?? 'حساب (لا يوجد اسم)';
              final String role = userData['role'] ?? 'غير معروف';

              IconData roleIcon = Icons.person;
              Color roleColor = Colors.blue;
              if (role == 'admin') {
                roleIcon = Icons.admin_panel_settings;
                roleColor = Colors.teal;
              }

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: roleColor.withOpacity(0.1),
                    child: Icon(roleIcon, color: roleColor),
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('الدور: $role'),
                  trailing: Wrap(
                    spacing: -16, // تقليل المسافة
                    children: [
                      IconButton(
                        icon: const Icon(Icons.calendar_month_outlined),
                        tooltip: 'تعديل جدول الدوام',
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => EmployeeScheduleScreen(
                                employeeUid: employeeUid,
                                employeeName: name,
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.bar_chart, color: Colors.indigo),
                        tooltip: 'عرض تقرير الموظف',
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => EmployeeReportScreen(
                                employeeUid: employeeUid,
                                employeeName: name,
                              ),
                            ),
                          );
                        },
                      ),
                      // --- [إضافة جديدة] ---
                      // زر الحذف
                      IconButton(
                        icon: Icon(
                          Icons.delete_forever,
                          color: Colors.red[700],
                        ),
                        tooltip: 'حذف الموظف',
                        onPressed: () {
                          // استدعاء دالة التأكيد
                          _showDeleteDialog(context, employeeUid, name);
                        },
                      ),
                      // --- [نهاية الإضافة] ---
                    ],
                  ),
                  onTap: () {
                    // يمكن إبقاء الضغط على البطاقة لفتح التقرير
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => EmployeeReportScreen(
                          employeeUid: employeeUid,
                          employeeName: name,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const AddEmployeeScreen()),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ----------------------------------------------
// 11. شاشة إضافة موظف
// ----------------------------------------------
class AddEmployeeScreen extends StatefulWidget {
  const AddEmployeeScreen({super.key});
  @override
  State<AddEmployeeScreen> createState() => _AddEmployeeScreenState();
}

class _AddEmployeeScreenState extends State<AddEmployeeScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _saveEmployee() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    FirebaseApp? tempApp;
    try {
      try {
        tempApp = await Firebase.initializeApp(
          name: 'tempAdminSDK',
          options: DefaultFirebaseOptions.currentPlatform,
        );
      } catch (e) {
        tempApp = Firebase.app('tempAdminSDK');
      }

      final FirebaseAuth authForTempApp = FirebaseAuth.instanceFor(
        app: tempApp,
      );

      final UserCredential userCredential = await authForTempApp
          .createUserWithEmailAndPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text.trim(),
          );

      final String? uid = userCredential.user?.uid;

      if (uid != null) {
        await rtdb.FirebaseDatabase.instance.ref('users/$uid').set({
          'name': _nameController.text.trim(),
          'role': 'employee',
          'workSchedule': {
            'sat': false,
            'sun': true,
            'mon': true,
            'tue': true,
            'wed': true,
            'thu': true,
            'fri': false,
          },
        });

        await authForTempApp.signOut();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('تمت إضافة الموظف بنجاح'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') {
        _errorMessage =
            'كلمة المرور ضعيفة جداً (يجب أن تكون 6 أحرف على الأقل).';
      } else if (e.code == 'email-already-in-use') {
        _errorMessage = 'هذا البريد الإلكتروني مستخدم بالفعل.';
      } else {
        _errorMessage = 'حدث خطأ: ${e.message}';
      }
    } catch (e) {
      _errorMessage = 'حدث خطأ غير متوقع. يرجى المحاولة مرة أخرى: $e';
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إضافة موظف جديد')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم الموظف الكامل',
                  prefixIcon: Icon(Icons.person),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'يرجى إدخال اسم الموظف';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني (للموظف)',
                  prefixIcon: Icon(Icons.email),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'يرجى إدخال البريد الإلكتروني';
                  }
                  if (!value.contains('@')) {
                    return 'بريد إلكتروني غير صالح';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة مرور (مؤقتة للموظف)',
                  prefixIcon: Icon(Icons.lock),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'يرجى إدخال كلمة مرور';
                  }
                  if (value.length < 6) {
                    return 'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              if (_errorMessage != null)
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 10),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _saveEmployee,
                      child: const Text(
                        'حفظ الموظف',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------
// 12. شاشة تقرير الموظف
// ----------------------------------------------
class EmployeeReportScreen extends StatefulWidget {
  final String employeeUid;
  final String employeeName;

  const EmployeeReportScreen({
    super.key,
    required this.employeeUid,
    required this.employeeName,
  });

  @override
  State<EmployeeReportScreen> createState() => _EmployeeReportScreenState();
}

class _EmployeeReportScreenState extends State<EmployeeReportScreen> {
  late Future<List<Map<String, dynamic>>> _attendanceHistory;

  @override
  void initState() {
    super.initState();
    _attendanceHistory = _fetchAttendanceHistory();
  }

  Future<List<Map<String, dynamic>>> _fetchAttendanceHistory() async {
    final List<Map<String, dynamic>> userHistory = [];

    try {
      final ref = rtdb.FirebaseDatabase.instance.ref('attendance_logs');
      final snapshot = await ref.get();

      if (!snapshot.exists || snapshot.value == null) {
        return [];
      }

      final allLogs = Map<dynamic, dynamic>.from(snapshot.value as Map);

      for (final dayEntry in allLogs.entries) {
        final dailyLogs = Map<dynamic, dynamic>.from(dayEntry.value as Map);

        if (dailyLogs.containsKey(widget.employeeUid)) {
          final logData = Map<dynamic, dynamic>.from(
            dailyLogs[widget.employeeUid] as Map,
          );
          userHistory.add({
            'date': dayEntry.key,
            'checkInTime': logData['checkInTime'],
            'checkOutTime': logData['checkOutTime'],
            'qrCode': logData['qrCode'] ?? 'N/A',
          });
        }
      }

      userHistory.sort((a, b) {
        return b['date'].compareTo(a['date']);
      });
    } catch (e) {
      print("خطأ في جلب تقرير الموظف: $e");
    }

    return userHistory;
  }

  String _calculateDuration(String? checkIn, String? checkOut) {
    if (checkIn == null || checkOut == null) {
      return '(لم يكتمل)'; // نص أوضح
    }
    try {
      final dtIn = DateTime.parse(checkIn);
      final dtOut = DateTime.parse(checkOut);
      final duration = dtOut.difference(dtIn);

      final hours = duration.inHours;
      final minutes = duration.inMinutes.remainder(60);

      if (hours == 0 && minutes < 1) {
        return '(أقل من دقيقة)';
      }

      return '(إجمالي: $hours س و $minutes د)';
    } catch (e) {
      return '(خطأ)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('تقرير: ${widget.employeeName}')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _attendanceHistory,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('حدث خطأ أثناء تحميل التقرير.'));
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('لا توجد سجلات حضور لهذا الموظف.'));
          }

          final history = snapshot.data!;

          return ListView.builder(
            itemCount: history.length,
            itemBuilder: (context, index) {
              final log = history[index];
              final String? checkInTimeRaw = log['checkInTime'];
              String formattedDate = log['date'];
              String formattedTime = "لم يسجل دخول";

              if (checkInTimeRaw != null) {
                try {
                  final DateTime checkInTime = DateTime.parse(checkInTimeRaw);
                  formattedDate = DateFormat(
                    'EEEE, yyyy-MM-dd',
                    'ar',
                  ).format(checkInTime);
                  formattedTime = DateFormat(
                    'hh:mm a',
                    'ar',
                  ).format(checkInTime);
                } catch (e) {
                  formattedTime = "وقت بصيغة خاطئة";
                }
              }

              final String? checkOutTimeRaw = log['checkOutTime'];
              final String formattedCheckOut = (checkOutTimeRaw == null)
                  ? 'لم يسجل انصراف'
                  : DateFormat(
                      'hh:mm a',
                      'ar',
                    ).format(DateTime.parse(checkOutTimeRaw));

              final String duration = _calculateDuration(
                checkInTimeRaw,
                checkOutTimeRaw,
              );

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: checkOutTimeRaw == null
                        ? Colors.orange.withOpacity(0.5)
                        : Colors.green.withOpacity(0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: ListTile(
                    leading: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          checkOutTimeRaw == null
                              ? Icons.hourglass_top
                              : Icons.task_alt,
                          color: checkOutTimeRaw == null
                              ? Colors.orange
                              : Colors.green,
                        ),
                      ],
                    ),
                    title: Text(
                      formattedDate,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 5),
                        Text('دخول: $formattedTime | خروج: $formattedCheckOut'),
                        const SizedBox(height: 4),
                        Text(
                          duration,
                          style: TextStyle(
                            color: Colors.indigo,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ----------------------------------------------
// 13. شاشة تعديل جدول الدوام
// ----------------------------------------------
class EmployeeScheduleScreen extends StatefulWidget {
  final String employeeUid;
  final String employeeName;

  const EmployeeScheduleScreen({
    super.key,
    required this.employeeUid,
    required this.employeeName,
  });

  @override
  State<EmployeeScheduleScreen> createState() => _EmployeeScheduleScreenState();
}

class _EmployeeScheduleScreenState extends State<EmployeeScheduleScreen> {
  bool _isLoading = true;

  // جدول الدوام الافتراضي
  Map<String, bool> _schedule = {
    'sat': false,
    'sun': true,
    'mon': true,
    'tue': true,
    'wed': true,
    'thu': true,
    'fri': false,
  };

  final Map<String, String> _dayNames = {
    'sat': 'السبت',
    'sun': 'الأحد',
    'mon': 'الاثنين',
    'tue': 'الثلاثاء',
    'wed': 'الأربعاء',
    'thu': 'الخميس',
    'fri': 'الجمعة',
  };

  final List<String> _dayOrder = [
    'sat',
    'sun',
    'mon',
    'tue',
    'wed',
    'thu',
    'fri',
  ];

  @override
  void initState() {
    super.initState();
    _loadSchedule();
  }

  Future<void> _loadSchedule() async {
    try {
      final ref = rtdb.FirebaseDatabase.instance.ref(
        'users/${widget.employeeUid}/workSchedule',
      );
      final snapshot = await ref.get();

      if (snapshot.exists && snapshot.value != null) {
        final scheduleData = Map<String, dynamic>.from(snapshot.value as Map);
        setState(() {
          _schedule = {
            'sat': scheduleData['sat'] ?? false,
            'sun': scheduleData['sun'] ?? false,
            'mon': scheduleData['mon'] ?? false,
            'tue': scheduleData['tue'] ?? false,
            'wed': scheduleData['wed'] ?? false,
            'thu': scheduleData['thu'] ?? false,
            'fri': scheduleData['fri'] ?? false,
          };
        });
      }
    } catch (e) {
      print("خطأ في جلب الجدول: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveSchedule() async {
    setState(() {
      _isLoading = true;
    });

    try {
      await rtdb.FirebaseDatabase.instance
          .ref('users/${widget.employeeUid}/workSchedule')
          .set(_schedule);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم حفظ الجدول بنجاح'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('حدث خطأ أثناء الحفظ: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('جدول دوام: ${widget.employeeName}')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    children: _dayOrder.map((dayKey) {
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: CheckboxListTile(
                          title: Text(
                            _dayNames[dayKey]!,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          value: _schedule[dayKey],
                          activeColor: Colors.teal,
                          subtitle: Text(
                            _schedule[dayKey]! ? 'يوم دوام' : 'يوم عطلة',
                          ),
                          onChanged: (bool? newValue) {
                            setState(() {
                              _schedule[dayKey] = newValue ?? false;
                            });
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      padding: const EdgeInsets.all(16),
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _saveSchedule,
                    child: const Text(
                      'حفظ التعديلات',
                      style: TextStyle(fontSize: 18),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ----------------------------------------------
// 14. شاشة إرسال إشعار جماعي (SendNotificationScreen)
// ----------------------------------------------
class SendNotificationScreen extends StatefulWidget {
  const SendNotificationScreen({super.key});

  @override
  State<SendNotificationScreen> createState() => _SendNotificationScreenState();
}

class _SendNotificationScreenState extends State<SendNotificationScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _sendNotification() async {
    if (_titleController.text.isEmpty || _bodyController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء إدخال العنوان والمحتوى')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // **العملية: إنشاء سجل مؤقت في قاعدة البيانات لتلتقطه Cloud Function وترسل الإشعار**
      await rtdb.FirebaseDatabase.instance
          .ref('notifications_queue')
          .push()
          .set({
            'title': _titleController.text.trim(),
            'body': _bodyController.text.trim(),
            'timestamp': DateTime.now().toIso8601String(),
            'targetTopic': 'all_employees', // الموضوع المستهدف
            'senderName': FirebaseAuth.instance.currentUser?.email ?? 'المدير',
          });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم إرسال الرسالة بنجاح (سيتم النشر كإشعار)'),
            backgroundColor: Colors.blue,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في الإرسال: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إرسال إشعار جماعي')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'ستظهر هذه الرسالة كإشعار لجميع الموظفين المسجلين في التطبيق.',
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'عنوان الإشعار',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.title),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _bodyController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'محتوى الرسالة',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.message),
              ),
            ),
            const SizedBox(height: 30),
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton.icon(
                    onPressed: _sendNotification,
                    icon: const Icon(Icons.send, size: 24),
                    label: const Text(
                      'إرسال الإشعار للجميع',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(15),
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}
