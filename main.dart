import 'dart:async';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

SupabaseClient get db => Supabase.instance.client;

typedef Rows = List<Map<String, dynamic>>;

Rows asRows(dynamic r) => List<Map<String, dynamic>>.from(r as List);

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

    final base = path.contains('.') ? path.substring(0, path.lastIndexOf('.')) : path;
    await Gal.putImageBytes(bytes, album: 'Template Store', name: base);
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
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
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
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final a = widget.isAdmin;
    final pages = <Widget>[
      StorePage(isAdmin: a),
      OrdersPage(isAdmin: a),
      SupportPage(isAdmin: a),
      ProfilePage(isAdmin: a),
    ];
    return Scaffold(
      body: pages[_i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Store',
          ),
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            label: a ? 'Orders' : 'My Purchases',
          ),
          NavigationDestination(
            icon: const Icon(Icons.support_agent_outlined),
            selectedIcon: const Icon(Icons.support_agent),
            label: a ? 'Support Inbox' : 'Support',
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: a ? 'Master' : 'Profile',
          ),
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

  Future<Rows> _load() async {
    final r = await db.from('templates').select().order('created_at', ascending: false);
    return asRows(r);
  }

  void _reload() {
    setState(() {
      _f = _load();
    });
  }

  Rows _filter(Rows all) {
    final q = _q.trim().toLowerCase();
    return all.where((t) {
      final okCat = _cat == 'All' || (t['category'] ?? 'General') == _cat;
      final okQ = q.isEmpty || (t['title'] as String).toLowerCase().contains(q);
      return okCat && okQ;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppLogo(size: 32),
            SizedBox(width: 10),
            Text('Template Store'),
          ],
        ),
        actions: [
          if (!widget.isAdmin)
            AnimatedBuilder(
              animation: cart,
              builder: (c, _) => IconButton(
                tooltip: 'Cart',
                onPressed: () => Navigator.push(
                  c,
                  MaterialPageRoute(builder: (_) => const CartPage()),
                ),
                icon: Badge(
                  isLabelVisible: cart.items.isNotEmpty,
                  label: Text('${cart.items.length}'),
                  child: const Icon(Icons.shopping_cart_outlined),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: widget.isAdmin
          ? FloatingActionButton.extended(
              onPressed: () async {
                final ok = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const AddTemplatePage()),
                );
                if (ok == true) _reload();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add template'),
            )
          : null,
      body: FutureBuilder<Rows>(
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
            ...all.map((t) => (t['category'] ?? 'General') as String),
          }.toList();
          final items = _filter(all);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    hintText: 'Search templates',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _q.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              setState(() => _q = '');
                            },
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: cats
                      .map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(c),
                            selected: _cat == c,
                            onSelected: (_) => setState(() => _cat = c),
                          ),
                        ),
                      )
                      .toList(),
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
                          children: const [
                            Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(child: Text('No templates found')),
                            ),
                          ],
                        )
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.72,
                          ),
                          itemCount: items.length,
                          itemBuilder: (c, i) {
                            final t = items[i];
                            return Card(
                              elevation: 3,
                              shadowColor: Colors.black26,
                              color: Colors.white,
                              surfaceTintColor: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () async {
                                  await Navigator.push(
                                    c,
                                    MaterialPageRoute(
                                      builder: (_) => DetailPage(t: t, isAdmin: widget.isAdmin),
                                    ),
                                  );
                                  _reload();
                                },
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: PreviewImage(path: t['preview_path'] as String)),
                                    Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            t['title'] as String,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                          ),
                                          Text(
                                            money(t['price'] as num),
                                            style: TextStyle(
                                              color: Theme.of(context).colorScheme.primary,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          );
        },
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
          .select('status')
          .eq('user_id', myId!)
          .eq('template_id', _t['id'])
          .order('created_at', ascending: false)
          .limit(1);
      final rows = asRows(r);
      _status = rows.isEmpty ? null : rows.first['status'] as String;
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
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Your last payment was rejected. You can try again.'),
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
      appBar: AppBar(title: Text(t['title'] as String)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 1,
              child: PreviewImage(path: t['preview_path'] as String, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 16),
          Text(t['title'] as String, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                money(price),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Chip(label: Text((t['category'] ?? 'General') as String)),
            ],
          ),
          const SizedBox(height: 8),
          Text((t['description'] ?? '') as String),
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
        Navigator.pop(context, true);
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

  Future<void> _setStatus(Map<String, dynamic> o, String status) async {
    try {
      final g = o['payment_group'];
      if (g != null) {
        await db.from('orders').update({'status': status}).eq('payment_group', g);
      } else {
        await db.from('orders').update({'status': status}).eq('id', o['id']);
      }
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isAdmin ? 'All Orders' : 'My Purchases')),
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
                  child: Padding(
                    padding: const EdgeInsets.all(12),
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
                        const SizedBox(height: 8),
                        if (widget.isAdmin && status == 'pending')
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => _setStatus(o, 'rejected'),
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
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isAdmin ? 'Support Inbox' : 'Support')),
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
