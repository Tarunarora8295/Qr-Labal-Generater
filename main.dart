import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

SupabaseClient get db => Supabase.instance.client;

typedef Rows = List<Map<String, dynamic>>;

Rows asRows(dynamic r) => List<Map<String, dynamic>>.from(r as List);

// ---------------------------------------------------------------- UPDATES + TELEGRAM ALERTS

const kRepo = 'Tarunarora8295/Qr-Labal-Generater'; // GitHub repo that holds the APK releases
const kTgBot = 'TamplateStoresupport_bot'; // Telegram bot that sends the user alerts

// Looks on GitHub for a newer release. Tapping "Update" downloads the new APK;
// installing it replaces the old app and keeps all data (needs the fixed signing key).
Future<void> checkForUpdate(BuildContext context, {bool manual = false}) async {
  if (kIsWeb) return;
  try {
    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;
    final res = await http
        .get(
          Uri.parse('https://api.github.com/repos/$kRepo/releases?per_page=10'),
          headers: const {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw Exception('GitHub ${res.statusCode}');
    var best = 0;
    String? apk;
    for (final r in jsonDecode(res.body) as List) {
      if (r['draft'] == true || r['prerelease'] == true) continue;
      final n = int.tryParse('${r['tag_name'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      if (n <= best) continue;
      for (final a in (r['assets'] as List? ?? const [])) {
        if (a['name'] == 'app-release.apk') {
          best = n;
          apk = '${a['browser_download_url']}';
        }
      }
    }
    if (!context.mounted) return;
    if (apk != null && best > current) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Update available'),
          content: Text(
            'A new version (v$best) is ready. You are on v$current.\n\n'
            'Tap Update, then open the downloaded file and tap Install. '
            'Your account and orders stay safe.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Update')),
          ],
        ),
      );
      if (go == true) {
        await launchUrl(Uri.parse(apk), mode: LaunchMode.externalApplication);
      }
    } else if (manual) {
      toast(context, 'You are on the latest version (v$current)');
    }
  } catch (_) {
    if (manual && context.mounted) toast(context, 'Could not check for updates');
  }
}

bool _tgOffered = false;

// Asks (once per app session) whether the user wants Telegram alerts, if not linked yet
Future<void> offerTelegramAlerts(BuildContext context) async {
  if (_tgOffered || kIsWeb) return;
  try {
    final r = await db.from('profiles').select('tg_code, tg_chat_id').eq('id', myId!).maybeSingle();
    final code = r?['tg_code']?.toString();
    if (code == null || code.isEmpty || r?['tg_chat_id'] != null) return;
    _tgOffered = true;
    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Get instant alerts?'),
        content: const Text(
          'Get a Telegram message when your payment is approved, when support replies, '
          'and when new templates arrive.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enable')),
        ],
      ),
    );
    if (go == true) {
      await launchUrl(Uri.parse('https://t.me/$kTgBot?start=$code'), mode: LaunchMode.externalApplication);
    }
  } catch (_) {}
}

// Drawer item: links the user's account to the Telegram bot (hidden if alerts are not set up)
class TelegramTile extends StatefulWidget {
  const TelegramTile({super.key});

  @override
  State<TelegramTile> createState() => _TelegramTileState();
}

class _TelegramTileState extends State<TelegramTile> with WidgetsBindingObserver {
  String? _code;
  bool _linked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final r = await db.from('profiles').select('tg_code, tg_chat_id').eq('id', myId!).maybeSingle();
      if (!mounted) return;
      setState(() {
        _code = r?['tg_code']?.toString();
        _linked = r?['tg_chat_id'] != null;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    if (code == null || code.isEmpty) return const SizedBox.shrink();
    return ListTile(
      leading: Icon(
        _linked ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
        color: kBrandA,
      ),
      title: Text(
        _linked ? 'Telegram alerts: ON' : 'Enable Telegram alerts',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(_linked ? 'Send /stop to the bot to turn off' : 'Payments, support replies, new templates'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
      onTap: _linked
          ? null
          : () => launchUrl(Uri.parse('https://t.me/$kTgBot?start=$code'), mode: LaunchMode.externalApplication),
    );
  }
}

// ---------------------------------------------------------------- CART

class CartModel extends ChangeNotifier {
  final List<Map<String, dynamic>> items = [];

  bool has(dynamic id) => items.any((t) => t['id'] == id);

  num get total => items.fold<num>(0, (a, t) => a + (t['price'] as num));

  void add(Map<String, dynamic> t) {
    if (!has(t['id'])) {
      items.add(t);
      notifyListeners();
    }
  }

  void remove(dynamic id) {
    items.removeWhere((t) => t['id'] == id);
    notifyListeners();
  }

  void clear() {
    if (items.isNotEmpty) {
      items.clear();
      notifyListeners();
    }
  }
}

final cart = CartModel();

// Random UUID v4, used to tie all orders of one payment together
String newGroupId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

String? get myId => db.auth.currentUser?.id;
String get myEmail => db.auth.currentUser?.email ?? '';

void toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
}

final GlobalKey<ScaffoldState> shellKey = GlobalKey<ScaffoldState>();
final ValueNotifier<int> shellTab = ValueNotifier<int>(0);
final ValueNotifier<Set<String>> favs = ValueNotifier<Set<String>>(<String>{});

// Saved (favourite) template ids live in the user's own metadata - no database table needed
void loadFavs() {
  final raw = db.auth.currentUser?.userMetadata?['favs'];
  favs.value = raw is List ? raw.map((e) => e.toString()).toSet() : <String>{};
}

Future<void> toggleFav(dynamic id) async {
  final k = id.toString();
  final next = Set<String>.from(favs.value);
  if (!next.remove(k)) next.add(k);
  favs.value = next;
  try {
    await db.auth.updateUser(UserAttributes(data: {'favs': next.toList()}));
  } catch (_) {}
}

// Menu (drawer) button for the main tabs; null on pushed pages so the normal back arrow shows
Widget? menuButton(BuildContext c) {
  if (Navigator.of(c).canPop()) return null;
  return IconButton(
    icon: const Icon(Icons.menu_rounded),
    onPressed: () => shellKey.currentState?.openDrawer(),
  );
}

String money(num p) => '₹${p % 1 == 0 ? p.toInt().toString() : p.toStringAsFixed(2)}';

Color statusColor(String s) {
  switch (s) {
    case 'approved':
      return Colors.green;
    case 'rejected':
      return Colors.red;
    case 'closed':
      return Colors.grey;
    default:
      return Colors.orange;
  }
}

Widget statusChip(String s) {
  final c = statusColor(s);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: c.withAlpha(40),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      s == 'approved' ? 'COMPLETED' : s.toUpperCase(),
      style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold),
    ),
  );
}

// Creates a small watermarked preview from the original image
Future<Uint8List> makePreview(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 720);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final w = img.width.toDouble();
  final h = img.height.toDouble();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(img, Offset.zero, Paint());

  final tp = TextPainter(
    text: TextSpan(
      text: 'PREVIEW',
      style: TextStyle(
        color: const Color.fromRGBO(255, 255, 255, 0.55),
        fontSize: w / 6,
        fontWeight: FontWeight.w900,
        shadows: const [Shadow(color: Color.fromRGBO(0, 0, 0, 0.5), blurRadius: 6)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  canvas.save();
  canvas.translate(w / 2, h / 2);
  canvas.rotate(-0.5);
  for (final dy in [-h * 0.28, 0.0, h * 0.28]) {
    tp.paint(canvas, Offset(-tp.width / 2, dy - tp.height / 2));
  }
  canvas.restore();

  final pic = recorder.endRecording();
  final out = await pic.toImage(img.width, img.height);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

// Re-encodes the image so the old photo date (EXIF) is dropped.
// The gallery then shows the download at today's date, at the top.
Future<Uint8List> freshImage(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return bytes;
    return data.buffer.asUint8List();
  } catch (_) {
    return bytes;
  }
}

// Downloads the original image and saves it straight into the phone gallery.
// (On web, where a gallery does not exist, it falls back to opening the link.)
Future<void> openOriginal(BuildContext context, String path) async {
  try {
    if (kIsWeb) {
      final url = await db.storage.from('originals').createSignedUrl(path, 3600);
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) toast(context, 'Could not open the link');
      return;
    }

    if (context.mounted) toast(context, 'Downloading...');
    final bytes = await db.storage.from('originals').download(path);

    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        if (context.mounted) toast(context, 'Gallery permission is needed to save the image');
        return;
      }
    }

    final fresh = await freshImage(bytes);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'Template_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    await Gal.putImageBytes(fresh, album: 'Template Store', name: name);
    if (context.mounted) toast(context, 'Saved to your gallery');
  } catch (e) {
    if (context.mounted) toast(context, 'Download error: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Template Store',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const AuthGate(),
    );
  }
}


// ---------------------------------------------------------------- THEME + LOGO

const kBrandA = Color(0xFF4F46E5); // indigo
const kBrandB = Color(0xFF7C3AED); // violet

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kBrandA, brightness: Brightness.light);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF6F6FB),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF6F6FB),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: Color(0xFF1B1B2F),
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kBrandA.withAlpha(30),
    ),
  );
}

// Rounded, filled text-field look used across the app
InputDecoration fieldDeco(String label, IconData icon, {Widget? suffix, String? hint}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: Icon(icon),
    suffixIcon: suffix,
    filled: true,
    fillColor: const Color(0xFFF1F1F9),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: kBrandA, width: 1.6),
    ),
  );
}

// App logo drawn in code (no image asset needed)
class AppLogo extends StatelessWidget {
  final double size;
  final bool inverse; // white tile with coloured icon (for gradient backgrounds)
  const AppLogo({super.key, this.size = 56, this.inverse = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: inverse
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [kBrandA, kBrandB],
              ),
        color: inverse ? Colors.white : null,
        boxShadow: [
          BoxShadow(
            color: (inverse ? Colors.black : kBrandA).withAlpha(70),
            blurRadius: size * 0.25,
            offset: Offset(0, size * 0.1),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (r) => (inverse
                    ? const LinearGradient(colors: [kBrandA, kBrandB])
                    : const LinearGradient(colors: [Colors.white, Colors.white]))
                .createShader(r),
            child: Icon(Icons.dashboard_customize_rounded, size: size * 0.54),
          ),
          Positioned(
            top: size * 0.14,
            right: size * 0.14,
            child: Icon(
              Icons.auto_awesome,
              size: size * 0.2,
              color: inverse ? const Color(0xFFFFB020) : const Color(0xFFFFE08A),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- AUTH

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: db.auth.onAuthStateChange,
      builder: (context, _) {
        final user = db.auth.currentUser;
        if (user == null) return const LoginPage();
        return RoleLoader(key: ValueKey(user.id));
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _signup = false;
  bool _obscure = true;
  bool _busy = false;

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pass = _pass.text;
    if (email.isEmpty || pass.length < 6) {
      toast(context, 'Enter your email and a password of at least 6 characters');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_signup) {
        final res = await db.auth.signUp(email: email, password: pass);
        if (res.session == null && mounted) {
          toast(context, 'A code has been sent to your email');
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => OtpPage(email: email, recovery: false)),
          );
        }
      } else {
        await db.auth.signInWithPassword(email: email, password: pass);
      }
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      toast(context, 'Enter your email above first');
      return;
    }
    setState(() => _busy = true);
    try {
      await db.auth.resetPasswordForEmail(email);
      if (!mounted) return;
      toast(context, 'A code has been sent to your email');
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => OtpPage(email: email, recovery: true)),
      );
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [kBrandA, kBrandB],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLogo(size: 92, inverse: true),
                  const SizedBox(height: 16),
                  const Text(
                    'Template Store',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Premium templates, ready to download',
                    style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 14),
                  ),
                  const SizedBox(height: 28),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 440),
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(26),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(40),
                          blurRadius: 30,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _signup ? 'Create account' : 'Welcome back',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _signup ? 'Sign up to start shopping' : 'Login to continue',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: fieldDeco('Email', Icons.mail_outline_rounded),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _pass,
                          obscureText: _obscure,
                          decoration: fieldDeco(
                            'Password',
                            Icons.lock_outline_rounded,
                            suffix: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        if (!_signup)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _busy ? null : _forgot,
                              child: const Text('Forgot password?'),
                            ),
                          )
                        else
                          const SizedBox(height: 10),
                        const SizedBox(height: 6),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(_signup ? 'Create account' : 'Login'),
                        ),
                        const SizedBox(height: 6),
                        TextButton(
                          onPressed: () => setState(() => _signup = !_signup),
                          child: Text(
                            _signup
                                ? 'Already have an account? Login'
                                : "Don't have an account? Sign up",
                          ),
                        ),
                      ],
                    ),
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

class OtpPage extends StatefulWidget {
  final String email;
  final bool recovery;
  const OtpPage({super.key, required this.email, required this.recovery});

  @override
  State<OtpPage> createState() => _OtpPageState();
}

class _OtpPageState extends State<OtpPage> {
  final _code = TextEditingController();
  final _newPass = TextEditingController();
  bool _busy = false;

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 6) {
      toast(context, 'Enter the code from your email');
      return;
    }
    if (widget.recovery && _newPass.text.length < 6) {
      toast(context, 'New password must be at least 6 characters');
      return;
    }
    setState(() => _busy = true);
    try {
      await db.auth.verifyOTP(
        email: widget.email,
        token: code,
        type: widget.recovery ? OtpType.recovery : OtpType.signup,
      );
      if (widget.recovery) {
        await db.auth.updateUser(UserAttributes(password: _newPass.text));
      }
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.recovery ? 'Reset password' : 'Verify email')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('A code was sent to this email:\n${widget.email}'),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Code from email', border: OutlineInputBorder()),
          ),
          if (widget.recovery) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _newPass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password', border: OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _verify,
            child: Text(_busy ? 'Please wait...' : (widget.recovery ? 'Change password' : 'Verify')),
          ),
        ],
      ),
    );
  }
}

class RoleLoader extends StatefulWidget {
  const RoleLoader({super.key});

  @override
  State<RoleLoader> createState() => _RoleLoaderState();
}

class _RoleLoaderState extends State<RoleLoader> {
  late final Future<bool> _admin = _load();

  Future<bool> _load() async {
    try {
      final r = await db.from('profiles').select('role').eq('id', myId!).maybeSingle();
      return r != null && r['role'] == 'admin';
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _admin,
      builder: (context, s) {
        if (!s.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return HomeShell(isAdmin: s.data!);
      },
    );
  }
}

// ---------------------------------------------------------------- HOME

class HomeShell extends StatefulWidget {
  final bool isAdmin;
  const HomeShell({super.key, required this.isAdmin});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final ValueNotifier<int> _pending = ValueNotifier<int>(0);
  Timer? _timer;
  int? _lastPending;

  @override
  void initState() {
    super.initState();
    shellTab.value = 0;
    loadFavs();
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) checkForUpdate(context);
      });
    }
    if (widget.isAdmin) {
      _poll();
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pending.dispose();
    super.dispose();
  }

  // Admin: count pending orders, show a badge and alert when a new one arrives
  Future<void> _poll() async {
    try {
      final r = asRows(await db.from('orders').select('id, payment_group').eq('status', 'pending'));
      final n = r.map((o) => (o['payment_group'] ?? o['id']).toString()).toSet().length;
      if (_lastPending != null && n > _lastPending! && mounted) {
        toast(context, 'New order received');
      }
      _lastPending = n;
      _pending.value = n;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.isAdmin;
    final pages = <Widget>[
      StorePage(isAdmin: a),
      OrdersPage(isAdmin: a),
      SupportPage(isAdmin: a),
    ];
    Widget ordersIcon(IconData ic) => ValueListenableBuilder<int>(
          valueListenable: _pending,
          builder: (c, n, _) => Badge(
            isLabelVisible: a && n > 0,
            label: Text('$n'),
            child: Icon(ic),
          ),
        );
    return ValueListenableBuilder<int>(
      valueListenable: shellTab,
      builder: (context, i, _) => Scaffold(
        key: shellKey,
        drawer: AppDrawer(isAdmin: a),
        body: pages[i],
        bottomNavigationBar: NavigationBar(
          elevation: 12,
          shadowColor: Colors.black,
          height: 68,
          selectedIndex: i,
          onDestinationSelected: (v) {
            shellTab.value = v;
            if (a) _poll();
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.storefront_outlined),
              selectedIcon: Icon(Icons.storefront),
              label: 'Shop',
            ),
            NavigationDestination(
              icon: ordersIcon(Icons.receipt_long_outlined),
              selectedIcon: ordersIcon(Icons.receipt_long),
              label: a ? 'Orders' : 'My Orders',
            ),
            const NavigationDestination(
              icon: Icon(Icons.support_agent_outlined),
              selectedIcon: Icon(Icons.support_agent),
              label: 'Support',
            ),
          ],
        ),
      ),
    );
  }
}

// Slide-out side menu: profile, terms and logout
class AppDrawer extends StatelessWidget {
  final bool isAdmin;
  const AppDrawer({super.key, required this.isAdmin});

  @override
  Widget build(BuildContext context) {
    final meta = db.auth.currentUser?.userMetadata ?? {};
    final name = (meta['full_name'] ?? '').toString().trim();
    final initial = name.isNotEmpty
        ? name[0].toUpperCase()
        : (myEmail.isNotEmpty ? myEmail[0].toUpperCase() : '?');

    Widget item(IconData ic, String t, VoidCallback onTap, {Color? color}) => ListTile(
          leading: Icon(ic, color: color ?? kBrandA),
          title: Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
          onTap: onTap,
        );

    return Drawer(
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(22, MediaQuery.of(context).padding.top + 26, 22, 22),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [kBrandA, kBrandB],
              ),
              borderRadius: BorderRadius.only(topRight: Radius.circular(28)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Colors.white,
                  child: Text(
                    initial,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: kBrandA),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  name.isEmpty ? 'Welcome' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  myEmail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withAlpha(215), fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          item(
            isAdmin ? Icons.dashboard_outlined : Icons.person_outline_rounded,
            isAdmin ? 'Master Dashboard' : 'My Profile',
            () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute(builder: (_) => ProfilePage(isAdmin: isAdmin)));
            },
          ),
          if (!isAdmin)
            item(Icons.description_outlined, 'Terms & Privacy', () {
              Navigator.of(context).pop();
              showDialog<void>(
                context: shellKey.currentContext ?? context,
                builder: (c) => AlertDialog(
                  title: const Text('Terms & Privacy'),
                  content: const Text(
                    'Payments are verified manually, so approval can take some time.\n\n'
                    'Templates unlock for download only after your payment is approved.\n\n'
                    'Your name, phone number and email are used only to process your orders '
                    'and support requests.',
                  ),
                  actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
                ),
              );
            }),
          if (!isAdmin) const TelegramTile(),
          item(Icons.system_update_rounded, 'Check for updates', () {
            final ctx = shellKey.currentContext ?? context;
            Navigator.of(context).pop();
            checkForUpdate(ctx, manual: true);
          }),
          const Spacer(),
          const Divider(height: 1),
          item(
            Icons.logout_rounded,
            'Logout',
            () {
              cart.clear();
              db.auth.signOut();
            },
            color: const Color(0xFFD92D20),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- STORE

class PreviewImage extends StatelessWidget {
  final String path;
  final BoxFit fit;
  const PreviewImage({super.key, required this.path, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final url = db.storage.from('previews').getPublicUrl(path);
    return Image.network(
      url,
      fit: fit,
      width: double.infinity,
      errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}

class StorePage extends StatefulWidget {
  final bool isAdmin;
  const StorePage({super.key, required this.isAdmin});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  late Future<Rows> _f = _load();
  final _search = TextEditingController();
  String _q = '';
  String _cat = 'All';
  String _sort = 'new'; // new | low | high
  late Future<Map<String, int>> _bf = _loadBanner();

  @override
  void initState() {
    super.initState();
    favs.addListener(_onFav);
  }

  @override
  void dispose() {
    favs.removeListener(_onFav);
    _search.dispose();
    super.dispose();
  }

  void _onFav() {
    if (mounted) setState(() {});
  }

  Future<Map<String, int>> _loadBanner() async {
    try {
      final r = asRows(
        await db.from('orders').select('id, status, created_at, payment_group').eq('user_id', myId!),
      );
      final pend = <String>{};
      final done = <String>{};
      final cutoff = DateTime.now().subtract(const Duration(days: 3));
      for (final o in r) {
        final k = (o['payment_group'] ?? o['id']).toString();
        if (o['status'] == 'pending') {
          pend.add(k);
        } else if (o['status'] == 'approved') {
          final d = DateTime.tryParse('${o['created_at']}');
          if (d != null && d.isAfter(cutoff)) done.add(k);
        }
      }
      return {'pending': pend.length, 'done': done.length};
    } catch (_) {
      return {'pending': 0, 'done': 0};
    }
  }

  Widget _banner() {
    return FutureBuilder<Map<String, int>>(
      future: _bf,
      builder: (c, s) {
        final p = s.data?['pending'] ?? 0;
        final d = s.data?['done'] ?? 0;
        if (p == 0 && d == 0) return const SizedBox.shrink();
        final pend = p > 0;
        final color = pend ? Colors.orange : Colors.green;
        final n = pend ? p : d;
        return GestureDetector(
          onTap: () => shellTab.value = 1,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: color.withAlpha(28),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withAlpha(120)),
            ),
            child: Row(
              children: [
                Icon(pend ? Icons.hourglass_top_rounded : Icons.check_circle_rounded, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    pend
                        ? 'Your payment is being verified ($n order${n > 1 ? 's' : ''})'
                        : '$n order${n > 1 ? 's' : ''} completed - tap to download',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<Rows> _load() async {
    final r = await db.from('templates').select().order('created_at', ascending: false);
    return asRows(r);
  }

  void _reload() {
    setState(() {
      _f = _load();
      _bf = _loadBanner();
    });
  }

  Rows _filter(Rows all) {
    final q = _q.trim().toLowerCase();
    final out = all.where((t) {
      final okCat = _cat == 'All' ||
          (_cat == 'Saved'
              ? favs.value.contains(t['id'].toString())
              : (t['category'] ?? 'General') == _cat);
      final okQ = q.isEmpty || (t['title'] as String).toLowerCase().contains(q);
      return okCat && okQ;
    }).toList();
    if (_sort == 'low') {
      out.sort((a, b) => (a['price'] as num).compareTo(b['price'] as num));
    } else if (_sort == 'high') {
      out.sort((a, b) => (b['price'] as num).compareTo(a['price'] as num));
    }
    return out;
  }

  Widget _header(BuildContext context) {
    final name = (db.auth.currentUser?.userMetadata?['full_name'] ?? '').toString().trim();
    final first = name.isEmpty ? 'there' : name.split(' ').first;
    return Container(
      padding: EdgeInsets.fromLTRB(18, MediaQuery.of(context).padding.top + 14, 18, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kBrandA, kBrandB],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(40),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: IconButton(
                  tooltip: 'Menu',
                  color: Colors.white,
                  onPressed: () => shellKey.currentState?.openDrawer(),
                  icon: const Icon(Icons.menu_rounded, color: Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.isAdmin ? 'Master panel' : 'Hi, $first 👋',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.isAdmin ? 'Manage your templates' : 'Find your perfect template',
                      style: TextStyle(color: Colors.white.withAlpha(215), fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (!widget.isAdmin)
                AnimatedBuilder(
                  animation: cart,
                  builder: (c, _) => Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(40),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      tooltip: 'Cart',
                      color: Colors.white,
                      onPressed: () => Navigator.push(
                        c,
                        MaterialPageRoute(builder: (_) => const CartPage()),
                      ),
                      icon: Badge(
                        isLabelVisible: cart.items.isNotEmpty,
                        label: Text('${cart.items.length}'),
                        child: const Icon(Icons.shopping_cart_outlined, color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _search,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search templates',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _search.clear();
                        setState(() => _q = '');
                      },
                    ),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, {required Color bg, required Color fg, double size = 11}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: size, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _card(BuildContext c, Map<String, dynamic> t) {
    final created = DateTime.tryParse('${t['created_at']}');
    final isNew = created != null && DateTime.now().difference(created).inDays < 7;
    final fav = favs.value.contains(t['id'].toString());
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            await Navigator.push(
              c,
              MaterialPageRoute(builder: (_) => DetailPage(t: t, isAdmin: widget.isAdmin)),
            );
            _reload();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PreviewImage(path: t['preview_path'] as String),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _pill(
                        (t['category'] ?? 'General') as String,
                        bg: Colors.black.withAlpha(110),
                        fg: Colors.white,
                        size: 10,
                      ),
                    ),
                    if (!widget.isAdmin)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: GestureDetector(
                          onTap: () => toggleFav(t['id']),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(235),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              size: 18,
                              color: fav ? Colors.red : Colors.black54,
                            ),
                          ),
                        ),
                      ),
                    if (isNew)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: _pill('NEW', bg: const Color(0xFFFF8A00), fg: Colors.white, size: 10),
                      ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: _pill(
                        money(t['price'] as num),
                        bg: kBrandA,
                        fg: Colors.white,
                        size: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t['title'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                    ),
                    if (!widget.isAdmin)
                      AnimatedBuilder(
                        animation: cart,
                        builder: (cc, _) {
                          final inCart = cart.has(t['id']);
                          return GestureDetector(
                            onTap: inCart
                                ? null
                                : () {
                                    cart.add(t);
                                    toast(cc, 'Added to cart');
                                  },
                            child: Container(
                              margin: const EdgeInsets.only(left: 4),
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: kBrandA.withAlpha(inCart ? 40 : 25),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                inCart ? Icons.check_rounded : Icons.add_shopping_cart_rounded,
                                size: 18,
                                color: kBrandA,
                              ),
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
      ),
    );
  }

  Widget _chip(String c) {
    final sel = _cat == c;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _cat = c),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: sel ? const LinearGradient(colors: [kBrandA, kBrandB]) : null,
            color: sel ? null : Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(sel ? 40 : 14),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Text(
            c,
            style: TextStyle(
              color: sel ? Colors.white : const Color(0xFF3A3A55),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.isAdmin
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ok = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const AddTemplatePage()),
                );
                if (ok == true) _reload();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add template'),
            )
          : null,
      body: Column(
        children: [
          _header(context),
          if (!widget.isAdmin) _banner(),
          Expanded(
            child: FutureBuilder<Rows>(
              future: _f,
              builder: (context, s) {
                if (s.hasError) {
                  return ListView(children: [
                    Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: ${s.error}')),
                  ]);
                }
                if (!s.hasData) return const Center(child: CircularProgressIndicator());
                final all = s.data!;
                final cats = <String>{
                  'All',
                  if (!widget.isAdmin) 'Saved',
                  ...all.map((t) => (t['category'] ?? 'General') as String),
                }.toList();
                final items = _filter(all);

                return Column(
                  children: [
                    SizedBox(
                      height: 56,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        children: cats.map(_chip).toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
                      child: Row(
                        children: [
                          Text(
                            _cat == 'All' ? 'All templates' : _cat,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                          const Spacer(),
                          Text(
                            '${items.length} found',
                            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Sort',
                            icon: Icon(
                              Icons.sort_rounded,
                              color: _sort == 'new' ? Colors.grey.shade700 : kBrandA,
                            ),
                            onSelected: (v) => setState(() => _sort = v),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'new', child: Text('Newest first')),
                              PopupMenuItem(value: 'low', child: Text('Price: low to high')),
                              PopupMenuItem(value: 'high', child: Text('Price: high to low')),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () async {
                          _reload();
                          await _f;
                        },
                        child: items.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(48),
                                    child: Column(
                                      children: [
                                        Icon(Icons.search_off_rounded, size: 56, color: Colors.grey.shade400),
                                        const SizedBox(height: 10),
                                        Text(_cat == 'Saved' ? 'No saved templates yet' : 'No templates found'),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : GridView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 14,
                                  crossAxisSpacing: 14,
                                  childAspectRatio: 0.74,
                                ),
                                itemCount: items.length,
                                itemBuilder: (c, i) => _card(c, items[i]),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class DetailPage extends StatefulWidget {
  final Map<String, dynamic> t;
  final bool isAdmin;
  const DetailPage({super.key, required this.t, required this.isAdmin});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Map<String, dynamic> _t = widget.t;
  String? _status;
  String? _remarks;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final r = await db
          .from('orders')
          .select('status, remarks')
          .eq('user_id', myId!)
          .eq('template_id', _t['id'])
          .order('created_at', ascending: false)
          .limit(1);
      final rows = asRows(r);
      _status = rows.isEmpty ? null : rows.first['status'] as String;
      _remarks = rows.isEmpty ? null : rows.first['remarks']?.toString();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit() async {
    final updated = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(builder: (_) => AddTemplatePage(existing: _t)),
    );
    if (updated is Map<String, dynamic> && mounted) {
      setState(() => _t = updated);
      toast(context, 'Template updated');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this template?'),
        content: const Text('This template will be removed permanently.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await db.storage.from('originals').remove([_t['file_path'] as String]);
      await db.storage.from('previews').remove([_t['preview_path'] as String]);
      await db.from('templates').delete().eq('id', _t['id']);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final price = t['price'] as num;
    Widget action;

    if (_loading) {
      action = const Center(child: CircularProgressIndicator());
    } else if (widget.isAdmin) {
      action = Column(children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => openOriginal(context, t['file_path'] as String),
            icon: const Icon(Icons.download),
            label: const Text('Download original'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit template'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete template'),
          ),
        ),
      ]);
    } else if (_status == 'approved') {
      action = SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => openOriginal(context, t['file_path'] as String),
          icon: const Icon(Icons.download),
          label: const Text('Download'),
        ),
      );
    } else if (_status == 'pending') {
      action = const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('Your payment is being verified. Once the master approves it, the download will unlock here.'),
        ),
      );
    } else {
      action = Column(children: [
        if (_status == 'rejected')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              (_remarks ?? '').trim().isEmpty
                  ? 'Your last payment was rejected. You can try again.'
                  : 'Your last payment was rejected.\nReason: ${_remarks!.trim()}\nYou can try again.',
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () async {
              final ok = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => BuyPage(items: [t])),
              );
              if (ok == true) {
                setState(() => _loading = true);
                _loadStatus();
              }
            },
            child: Text('Buy now  ${money(price)}'),
          ),
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: cart,
          builder: (c, _) {
            final inCart = cart.has(t['id']);
            return SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: inCart
                    ? () => Navigator.push(
                          c,
                          MaterialPageRoute(builder: (_) => const CartPage()),
                        )
                    : () {
                        cart.add(t);
                        toast(c, 'Added to cart');
                      },
                icon: Icon(inCart ? Icons.shopping_cart : Icons.add_shopping_cart),
                label: Text(inCart ? 'In cart - view cart' : 'Add to cart'),
              ),
            );
          },
        ),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t['title'] as String),
        actions: [
          if (!widget.isAdmin)
            ValueListenableBuilder<Set<String>>(
              valueListenable: favs,
              builder: (c, f, _) {
                final on = f.contains(t['id'].toString());
                return IconButton(
                  tooltip: 'Save',
                  onPressed: () => toggleFav(t['id']),
                  icon: Icon(
                    on ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    color: on ? Colors.red : null,
                  ),
                );
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(24),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 1,
              child: PreviewImage(path: t['preview_path'] as String, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            t['title'] as String,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                money(price),
                style: const TextStyle(
                  color: kBrandA,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 12),
              Chip(label: Text((t['category'] ?? 'General') as String)),
            ],
          ),
          const SizedBox(height: 8),
          if (((t['description'] ?? '') as String).trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                (t['description'] ?? '') as String,
                style: const TextStyle(height: 1.4),
              ),
            ),
          const SizedBox(height: 20),
          action,
        ],
      ),
    );
  }
}

class BuyPage extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  const BuyPage({super.key, required this.items});

  @override
  State<BuyPage> createState() => _BuyPageState();
}

class _BuyPageState extends State<BuyPage> {
  final _utr = TextEditingController();
  bool _busy = false;

  num get _total => widget.items.fold<num>(0, (a, t) => a + (t['price'] as num));

  String get _note => widget.items.length == 1
      ? widget.items.first['title'] as String
      : '${widget.items.length} templates';

  String get _upiLink {
    return 'upi://pay?pa=$upiId&pn=${Uri.encodeComponent(payeeName)}'
        '&am=${_total.toStringAsFixed(2)}&cu=INR'
        '&tn=${Uri.encodeComponent(_note)}';
  }

  Future<void> _pay() async {
    final uri = Uri.parse(_upiLink);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) toast(context, 'UPI app not found. Please pay manually to the UPI ID.');
    } catch (_) {
      if (mounted) toast(context, 'UPI app not found. Please pay manually to the UPI ID.');
    }
  }

  Future<void> _submit() async {
    final utr = _utr.text.trim();
    if (utr.length < 6) {
      toast(context, 'Enter the payment UTR / Transaction ID');
      return;
    }
    final meta = db.auth.currentUser?.userMetadata ?? {};
    final cname = (meta['full_name'] ?? '').toString().trim();
    final cphone = (meta['phone'] ?? '').toString().trim();
    if (cname.isEmpty || cphone.isEmpty) {
      toast(context, 'Please add your name and phone number in Profile first');
      return;
    }
    setState(() => _busy = true);
    try {
      // One payment = one UTR. All templates of this payment share a group id;
      // only the first row is "primary" (the unique-UTR rule applies to it).
      final group = newGroupId();
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < widget.items.length; i++) {
        rows.add({
          'user_id': myId,
          'user_email': myEmail,
          'template_id': widget.items[i]['id'],
          'utr': utr,
          'status': 'pending',
          'payment_group': group,
          'is_primary': i == 0,
          'customer_name': cname,
          'customer_phone': cphone,
        });
      }
      await db.from('orders').insert(rows);
      for (final t in widget.items) {
        cart.remove(t['id']);
      }
      if (mounted) {
        toast(context, 'Request sent. Download unlocks after the master approves.');
        await offerTelegramAlerts(context);
        if (mounted) Navigator.pop(context, true);
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        toast(
          context,
          e.code == '23505' ? 'This transaction ID has already been used' : 'Error: ${e.message}',
        );
        setState(() => _busy = false);
      }
    } catch (e) {
      if (mounted) {
        toast(context, 'Error: $e');
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.items.length == 1)
            Text(widget.items.first['title'] as String, style: Theme.of(context).textTheme.titleLarge)
          else
            for (final t in widget.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(t['title'] as String)),
                    Text(money(t['price'] as num)),
                  ],
                ),
              ),
          const SizedBox(height: 4),
          Text('Amount: ${money(_total)}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 20),
          const Text('Step 1: Pay with UPI'),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: SelectableText(upiId),
              subtitle: Text(payeeName),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: upiId));
                  toast(context, 'UPI ID copied');
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: _upiLink,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Or scan this QR with any UPI app',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _pay,
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Open UPI app'),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Step 2: Enter your payment UTR / Transaction ID'),
          const SizedBox(height: 8),
          TextField(
            controller: _utr,
            decoration: const InputDecoration(labelText: 'UTR / Transaction ID', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Please wait...' : 'I have paid, send request'),
            ),
          ),
        ],
      ),
    );
  }
}

class CartPage extends StatelessWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: cart,
      builder: (context, _) {
        final items = cart.items;
        return Scaffold(
          appBar: AppBar(
            title: const Text('My Cart'),
            actions: [
              if (items.isNotEmpty)
                TextButton(onPressed: cart.clear, child: const Text('Clear')),
            ],
          ),
          body: items.isEmpty
              ? const Center(child: Text('Your cart is empty'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final t = items[i];
                    return ListTile(
                      leading: SizedBox(
                        width: 56,
                        height: 56,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: PreviewImage(path: t['preview_path'] as String),
                        ),
                      ),
                      title: Text(t['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(money(t['price'] as num)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => cart.remove(t['id']),
                      ),
                    );
                  },
                ),
          bottomNavigationBar: items.isEmpty
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Total: ${money(cart.total)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        FilledButton(
                          onPressed: () async {
                            final ok = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BuyPage(items: List.of(cart.items)),
                              ),
                            );
                            if (ok == true && context.mounted) Navigator.pop(context);
                          },
                          child: const Text('Checkout'),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class AddTemplatePage extends StatefulWidget {
  final Map<String, dynamic>? existing; // when set, the page edits this template
  const AddTemplatePage({super.key, this.existing});

  @override
  State<AddTemplatePage> createState() => _AddTemplatePageState();
}

class _AddTemplatePageState extends State<AddTemplatePage> {
  final _title = TextEditingController();
  final _price = TextEditingController();
  final _desc = TextEditingController();
  final _cat = TextEditingController(text: 'General');
  List<String> _existing = [];
  XFile? _file;
  Uint8List? _bytes;
  bool _busy = false;

  bool get _edit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _title.text = (e['title'] ?? '').toString();
      final pr = e['price'];
      _price.text = pr is num && pr == pr.truncate() ? pr.toInt().toString() : '${pr ?? ''}';
      _cat.text = (e['category'] ?? 'General').toString();
      _desc.text = (e['description'] ?? '').toString();
    }
    _loadCats();
  }

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    _desc.dispose();
    _cat.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    try {
      final r = await db.from('templates').select('category');
      final s = <String>{};
      for (final m in asRows(r)) {
        final c = m['category'];
        if (c is String && c.isNotEmpty) s.add(c);
      }
      if (mounted) setState(() => _existing = s.toList());
    } catch (_) {}
  }

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final b = await x.readAsBytes();
    setState(() {
      _file = x;
      _bytes = b;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final price = num.tryParse(_price.text.trim());
    final needImage = !_edit;
    if ((needImage && _bytes == null) || title.isEmpty || price == null || price < 0) {
      toast(
        context,
        _edit ? 'Please enter a title and a valid price' : 'Please choose an image, title and a valid price',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final cat = _cat.text.trim().isEmpty ? 'General' : _cat.text.trim();
      final data = <String, dynamic>{
        'title': title,
        'description': _desc.text.trim(),
        'price': price,
        'category': cat,
      };

      // upload new image only when one was chosen
      if (_bytes != null) {
        final name = _file!.name;
        final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpg';
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final filePath = 'orig_$stamp.$ext';
        final previewPath = 'prev_$stamp.png';
        final ct = ext == 'png'
            ? 'image/png'
            : ext == 'webp'
                ? 'image/webp'
                : 'image/jpeg';

        final preview = await makePreview(_bytes!);
        await db.storage
            .from('originals')
            .uploadBinary(filePath, _bytes!, fileOptions: FileOptions(contentType: ct));
        await db.storage
            .from('previews')
            .uploadBinary(previewPath, preview, fileOptions: const FileOptions(contentType: 'image/png'));
        data['file_path'] = filePath;
        data['preview_path'] = previewPath;
      }

      if (_edit) {
        final old = widget.existing!;
        final row = await db.from('templates').update(data).eq('id', old['id']).select().single();
        if (_bytes != null) {
          // remove the old image files; ignore errors, the update already succeeded
          try {
            await db.storage.from('originals').remove([old['file_path'] as String]);
            await db.storage.from('previews').remove([old['preview_path'] as String]);
          } catch (_) {}
        }
        if (mounted) Navigator.pop(context, Map<String, dynamic>.from(row));
      } else {
        await db.from('templates').insert(data);
        if (mounted) {
          toast(context, 'Template added');
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) {
        toast(context, 'Error: $e');
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final old = widget.existing;
    return Scaffold(
      appBar: AppBar(title: Text(_edit ? 'Edit template' : 'New template')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _bytes != null
                ? Image.memory(_bytes!, height: 220, fit: BoxFit.contain)
                : (old != null
                    ? SizedBox(
                        height: 220,
                        child: PreviewImage(path: old['preview_path'] as String, fit: BoxFit.contain),
                      )
                    : const SizedBox.shrink()),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.image_outlined),
            label: Text(
              _edit
                  ? (_bytes == null ? 'Replace image (optional)' : 'Choose a different image')
                  : (_bytes == null ? 'Choose edited image' : 'Change image'),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _edit
                ? 'Leave the image as it is to keep the current one. A new image gets a fresh watermarked preview.'
                : 'A watermark is added to the preview automatically. The original is shared only after payment approval.',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: fieldDeco('Title', Icons.title_rounded),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            keyboardType: TextInputType.number,
            decoration: fieldDeco('Price (Rs)', Icons.currency_rupee_rounded),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cat,
            decoration: fieldDeco('Category', Icons.category_outlined),
          ),
          if (_existing.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _existing
                  .map((c) => ActionChip(label: Text(c), onPressed: () => setState(() => _cat.text = c)))
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLines: 3,
            decoration: fieldDeco('Description', Icons.notes_rounded),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Saving...' : (_edit ? 'Save changes' : 'Save')),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- ORDERS

class OrdersPage extends StatefulWidget {
  final bool isAdmin;
  const OrdersPage({super.key, required this.isAdmin});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  late Future<Rows> _f = _load();
  String _filter = 'all'; // all | pending | approved | rejected

  Future<Rows> _load() async {
    final r = await db
        .from('orders')
        .select('*, templates(title, price, file_path)')
        .order('created_at', ascending: false);
    return asRows(r);
  }

  void _reload() {
    setState(() {
      _f = _load();
    });
  }

  // 3-step progress: Payment sent -> Verifying -> Completed / Rejected
  Widget _tracker(String status) {
    final rejected = status == 'rejected';
    final done = status == 'approved' ? 3 : (rejected ? 2 : 1);
    final labels = ['Payment sent', 'Verifying', rejected ? 'Rejected' : 'Completed'];
    Color colFor(int i) {
      if (rejected && i == 2) return Colors.red;
      if (i < done) return Colors.green;
      if (i == done) return Colors.orange;
      return Colors.grey.shade400;
    }

    IconData iconFor(int i) {
      if (rejected && i == 2) return Icons.close_rounded;
      if (i < done) return Icons.check_rounded;
      if (i == done) return Icons.hourglass_top_rounded;
      return Icons.circle_outlined;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < 3; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(top: 11),
                height: 2,
                color: (i < done || (rejected && i == 2)) ? colFor(i) : Colors.grey.shade300,
              ),
            ),
          SizedBox(
            width: 70,
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(color: colFor(i), shape: BoxShape.circle),
                  child: Icon(iconFor(i), size: 15, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: colFor(i)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(String label, String key, int n, Color color) {
    final sel = _filter == key;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _filter = sel ? 'all' : key),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withAlpha(sel ? 55 : 28),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: sel ? color : Colors.transparent, width: 1.6),
          ),
          child: Column(
            children: [
              Text(
                '$n',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: color),
              ),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  String _when(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}  ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _infoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Expanded(child: SelectableText(text)),
        ],
      ),
    );
  }

  Future<void> _reject(Map<String, dynamic> o) async {
    final c = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Reject payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Remarks (the customer will see this reason)'),
              const SizedBox(height: 8),
              TextField(
                controller: c,
                maxLines: 3,
                autofocus: true,
                onChanged: (_) => setD(() {}),
                decoration: const InputDecoration(
                  hintText: 'Why is this payment rejected?',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 0,
                children: [
                  for (final q in const ['Wrong UTR', 'Amount mismatch', 'Payment not received'])
                    ActionChip(
                      label: Text(q, style: const TextStyle(fontSize: 12)),
                      onPressed: () {
                        c.text = q;
                        c.selection = TextSelection.collapsed(offset: q.length);
                        setD(() {});
                      },
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: c.text.trim().isEmpty ? null : () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Reject'),
            ),
          ],
        ),
      ),
    );
    if (reason == null || reason.isEmpty) return;
    await _setStatus(o, 'rejected', remarks: reason);
  }

  Future<void> _setStatus(Map<String, dynamic> o, String status, {String? remarks}) async {
    try {
      final g = o['payment_group'];
      final patch = <String, dynamic>{'status': status, 'remarks': status == 'rejected' ? remarks : null};
      if (g != null) {
        await db.from('orders').update(patch).eq('payment_group', g);
      } else {
        await db.from('orders').update(patch).eq('id', o['id']);
      }
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: menuButton(context),
        title: Text(widget.isAdmin ? 'All Orders' : 'My Orders'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _reload();
          await _f;
        },
        child: FutureBuilder<Rows>(
          future: _f,
          builder: (context, s) {
            if (s.hasError) {
              return ListView(children: [
                Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: ${s.error}')),
              ]);
            }
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final groups = <String, Rows>{};
            for (final o in s.data!) {
              final key = (o['payment_group'] ?? o['id']).toString();
              groups.putIfAbsent(key, () => []).add(o);
            }
            final all = groups.values.toList();
            int count(String st) => all.where((g) => g.first['status'] == st).length;
            num revenue = 0;
            for (final g in all) {
              if (g.first['status'] != 'approved') continue;
              for (final r in g) {
                final tt = r['templates'] as Map<String, dynamic>?;
                if (tt != null) revenue += tt['price'] as num;
              }
            }
            final items = (widget.isAdmin && _filter != 'all')
                ? all.where((g) => g.first['status'] == _filter).toList()
                : all;

            return Column(
              children: [
                if (widget.isAdmin)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            _tile('Pending', 'pending', count('pending'), Colors.orange),
                            const SizedBox(width: 10),
                            _tile('Completed', 'approved', count('approved'), Colors.green),
                            const SizedBox(width: 10),
                            _tile('Rejected', 'rejected', count('rejected'), Colors.red),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              _filter == 'all'
                                  ? 'All orders (${all.length})'
                                  : 'Showing ${_filter == 'approved' ? 'completed' : _filter} (${items.length})',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            Text(
                              'Earned: ${money(revenue)}',
                              style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(child: Text('No orders found')),
                            ),
                          ],
                        )
                      : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (c, i) {
                final g = items[i];
                final o = g.first;
                final status = o['status'] as String;
                final multi = g.length > 1;
                final t0 = o['templates'] as Map<String, dynamic>?;
                num total = 0;
                for (final r in g) {
                  final tt = r['templates'] as Map<String, dynamic>?;
                  if (tt != null) total += tt['price'] as num;
                }
                return Card(
                  elevation: 2,
                  shadowColor: Colors.black26,
                  color: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                multi
                                    ? 'Cart order (${g.length} templates)'
                                    : (t0?['title'] ?? 'Deleted template') as String,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                              ),
                            ),
                            statusChip(status),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 6),
                          child: _tracker(status),
                        ),
                        if (multi)
                          for (final r in g)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      ((r['templates'] as Map<String, dynamic>?)?['title'] ?? 'Deleted template')
                                          as String,
                                    ),
                                  ),
                                  if (r['templates'] != null)
                                    Text(money((r['templates'] as Map<String, dynamic>)['price'] as num)),
                                  if (!widget.isAdmin && status == 'approved' && r['templates'] != null)
                                    IconButton(
                                      tooltip: 'Download',
                                      icon: const Icon(Icons.download),
                                      onPressed: () => openOriginal(
                                        context,
                                        (r['templates'] as Map<String, dynamic>)['file_path'] as String,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        if (multi) Text('Total: ${money(total)}'),
                        if (!multi && t0 != null) Text(money(t0['price'] as num)),
                        if (widget.isAdmin) ...[
                          const Divider(height: 18),
                          _infoRow(
                            Icons.person_outline_rounded,
                            (o['customer_name'] ?? '').toString().isEmpty
                                ? 'Name not provided'
                                : o['customer_name'].toString(),
                          ),
                          _infoRow(
                            Icons.phone_outlined,
                            (o['customer_phone'] ?? '').toString().isEmpty
                                ? 'Phone not provided'
                                : o['customer_phone'].toString(),
                          ),
                          _infoRow(Icons.mail_outline_rounded, '${o['user_email'] ?? ''}'),
                        ],
                        if (_when(o['created_at']).isNotEmpty)
                          _infoRow(Icons.schedule_rounded, _when(o['created_at'])),
                        Text('UTR: ${o['utr'] ?? ''}'),
                        if (status == 'rejected' && (o['remarks'] ?? '').toString().trim().isNotEmpty)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Reason: ${o['remarks'].toString().trim()}',
                              style: TextStyle(color: Colors.red.shade800),
                            ),
                          ),
                        const SizedBox(height: 8),
                        if (widget.isAdmin && status == 'pending')
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => _reject(o),
                                child: const Text('Reject'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () => _setStatus(o, 'approved'),
                                child: const Text('Approve'),
                              ),
                            ],
                          ),
                        if (!multi && !widget.isAdmin && status == 'approved' && t0 != null)
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.tonalIcon(
                              onPressed: () => openOriginal(context, t0['file_path'] as String),
                              icon: const Icon(Icons.download),
                              label: const Text('Download'),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- SUPPORT

class SupportPage extends StatefulWidget {
  final bool isAdmin;
  const SupportPage({super.key, required this.isAdmin});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  late Future<Rows> _f = _load();

  Future<Rows> _load() async {
    final r = await db.from('tickets').select().order('created_at', ascending: false);
    return asRows(r);
  }

  void _reload() {
    setState(() {
      _f = _load();
    });
  }

  Future<void> _newTicket() async {
    final subj = TextEditingController();
    final msg = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New support request'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: subj, decoration: const InputDecoration(labelText: 'Subject')),
              const SizedBox(height: 8),
              TextField(
                controller: msg,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Describe your problem'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    final s = subj.text.trim();
    final m = msg.text.trim();
    if (s.isEmpty || m.isEmpty) {
      if (mounted) toast(context, 'Please fill in both subject and message');
      return;
    }
    try {
      final t = await db
          .from('tickets')
          .insert({'user_id': myId, 'user_email': myEmail, 'subject': s})
          .select()
          .single();
      await db.from('ticket_messages').insert({
        'ticket_id': t['id'],
        'sender_id': myId,
        'is_admin': false,
        'body': m,
      });
      _reload();
      if (mounted) await offerTelegramAlerts(context);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: menuButton(context),
        title: Text(widget.isAdmin ? 'Support Inbox' : 'Support'),
      ),
      floatingActionButton: widget.isAdmin
          ? null
          : FloatingActionButton.extended(
              onPressed: _newTicket,
              icon: const Icon(Icons.add),
              label: const Text('New request'),
            ),
      body: RefreshIndicator(
        onRefresh: () async {
          _reload();
          await _f;
        },
        child: FutureBuilder<Rows>(
          future: _f,
          builder: (context, s) {
            if (s.hasError) {
              return ListView(children: [
                Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: ${s.error}')),
              ]);
            }
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final items = s.data!;
            if (items.isEmpty) {
              return ListView(children: const [
                Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No support requests'))),
              ]);
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (c, i) {
                final t = items[i];
                return ListTile(
                  title: Text(t['subject'] as String),
                  subtitle: widget.isAdmin ? Text('${t['user_email'] ?? ''}') : null,
                  trailing: statusChip(t['status'] as String),
                  onTap: () async {
                    await Navigator.push(
                      c,
                      MaterialPageRoute(builder: (_) => TicketPage(ticket: t, isAdmin: widget.isAdmin)),
                    );
                    _reload();
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class TicketPage extends StatefulWidget {
  final Map<String, dynamic> ticket;
  final bool isAdmin;
  const TicketPage({super.key, required this.ticket, required this.isAdmin});

  @override
  State<TicketPage> createState() => _TicketPageState();
}

class _TicketPageState extends State<TicketPage> {
  Rows _msgs = [];
  late String _status = widget.ticket['status'] as String;
  final _c = TextEditingController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await db
          .from('ticket_messages')
          .select()
          .eq('ticket_id', widget.ticket['id'])
          .order('created_at');
      final rows = asRows(r);
      if (mounted) setState(() => _msgs = rows);
    } catch (_) {}
  }

  Future<void> _send() async {
    final b = _c.text.trim();
    if (b.isEmpty) return;
    _c.clear();
    try {
      await db.from('ticket_messages').insert({
        'ticket_id': widget.ticket['id'],
        'sender_id': myId,
        'is_admin': widget.isAdmin,
        'body': b,
      });
      await _load();
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  Future<void> _toggle() async {
    final ns = _status == 'open' ? 'closed' : 'open';
    try {
      await db.from('tickets').update({'status': ns}).eq('id', widget.ticket['id']);
      if (mounted) setState(() => _status = ns);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ticket['subject'] as String),
        actions: [
          if (widget.isAdmin)
            TextButton(
              onPressed: _toggle,
              child: Text(_status == 'open' ? 'Close' : 'Reopen'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (widget.isAdmin)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('User: ${widget.ticket['user_email'] ?? ''}'),
            ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: _msgs.length,
              itemBuilder: (c, i) {
                final m = _msgs[_msgs.length - 1 - i];
                final fromAdmin = m['is_admin'] == true;
                final mine = widget.isAdmin ? fromAdmin : !fromAdmin;
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: mine ? Theme.of(context).colorScheme.primaryContainer : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (fromAdmin && !widget.isAdmin)
                          const Text('Master', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        Text(m['body'] as String),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _c,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- PROFILE

class ProfilePage extends StatefulWidget {
  final bool isAdmin;
  const ProfilePage({super.key, required this.isAdmin});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _saving = false;

  Map<String, dynamic> get _meta => db.auth.currentUser?.userMetadata ?? {};

  @override
  void initState() {
    super.initState();
    _name.text = (_meta['full_name'] ?? '').toString();
    _phone.text = (_meta['phone'] ?? '').toString();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<Map<String, int>> _stats() async {
    final u = asRows(await db.from('profiles').select('id'));
    final t = asRows(await db.from('templates').select('id'));
    final o = asRows(await db.from('orders').select('id').eq('status', 'pending'));
    final k = asRows(await db.from('tickets').select('id').eq('status', 'open'));
    return {
      'Users': u.length,
      'Templates': t.length,
      'Pending orders': o.length,
      'Open tickets': k.length,
    };
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.replaceAll(' ', '').trim();
    if (name.isEmpty) {
      toast(context, 'Please enter your name');
      return;
    }
    if (phone.isNotEmpty && !RegExp(r'^\+?\d{10,13}$').hasMatch(phone)) {
      toast(context, 'Enter a valid phone number (10 digits)');
      return;
    }
    setState(() => _saving = true);
    try {
      await db.auth.updateUser(UserAttributes(data: {'full_name': name, 'phone': phone}));
      if (mounted) {
        FocusScope.of(context).unfocus();
        toast(context, 'Profile saved');
      }
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.isAdmin;
    final savedName = (_meta['full_name'] ?? '').toString().trim();
    final initial = savedName.isNotEmpty
        ? savedName[0].toUpperCase()
        : (myEmail.isNotEmpty ? myEmail[0].toUpperCase() : '?');

    return Scaffold(
      appBar: AppBar(title: Text(isAdmin ? 'Master Dashboard' : 'My Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          // ---- header card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [kBrandA, kBrandB],
              ),
              boxShadow: [
                BoxShadow(
                  color: kBrandA.withAlpha(70),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 34,
                  backgroundColor: Colors.white,
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: kBrandA,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        savedName.isEmpty ? 'Add your name' : savedName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        myEmail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withAlpha(220)),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(45),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          isAdmin ? 'MASTER' : 'USER',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ---- edit details card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(14),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Personal details',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: fieldDeco('Full name', Icons.person_outline_rounded),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]'))],
                  decoration: fieldDeco('Phone number', Icons.phone_outlined, hint: '98765 43210'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: myEmail,
                  enabled: false,
                  decoration: fieldDeco('Email', Icons.mail_outline_rounded),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_saving ? 'Saving...' : 'Save changes'),
                ),
              ],
            ),
          ),

          if (isAdmin) ...[
            const SizedBox(height: 18),
            const EarningsChart(),
          ],
          if (isAdmin) ...[
            const SizedBox(height: 18),
            FutureBuilder<Map<String, int>>(
              future: _stats(),
              builder: (context, s) {
                if (!s.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.8,
                  children: s.data!.entries
                      .map(
                        (e) => Card(
                          elevation: 2,
                          color: Colors.white,
                          surfaceTintColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${e.value}',
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                    color: kBrandA,
                                  ),
                                ),
                                Text(e.key),
                              ],
                            ),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
          ],
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: () {
              cart.clear();
              db.auth.signOut();
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}


// Admin: earnings from completed orders over the last 7 days (by order date)
class EarningsChart extends StatelessWidget {
  const EarningsChart({super.key});

  Future<List<num>> _load() async {
    final r = asRows(
      await db.from('orders').select('created_at, status, templates(price)').eq('status', 'approved'),
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sums = List<num>.filled(7, 0);
    for (final o in r) {
      final d = DateTime.tryParse('${o['created_at']}')?.toLocal();
      final t = o['templates'] as Map<String, dynamic>?;
      if (d == null || t == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      final diff = today.difference(day).inDays;
      if (diff >= 0 && diff < 7) sums[6 - diff] += t['price'] as num;
    }
    return sums;
  }

  @override
  Widget build(BuildContext context) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(14), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: FutureBuilder<List<num>>(
        future: _load(),
        builder: (c, s) {
          if (s.hasError) return const Text('Could not load earnings');
          if (!s.hasData) {
            return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
          }
          final v = s.data!;
          num total = 0;
          num maxV = 0;
          for (final x in v) {
            total += x;
            if (x > maxV) maxV = x;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Earnings - last 7 days',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    money(total),
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Completed orders, by order date',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 130,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (int i = 0; i < 7; i++)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (v[i] > 0)
                              Text(
                                money(v[i]),
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                              ),
                            const SizedBox(height: 3),
                            Container(
                              height: maxV == 0 ? 4 : (v[i] / maxV * 80).clamp(4.0, 80.0).toDouble(),
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: v[i] > 0
                                      ? const [kBrandB, kBrandA]
                                      : [Colors.grey.shade300, Colors.grey.shade300],
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              names[today.subtract(Duration(days: 6 - i)).weekday - 1],
                              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
