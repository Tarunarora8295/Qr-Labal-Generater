import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

SupabaseClient get db => Supabase.instance.client;

typedef Rows = List<Map<String, dynamic>>;

Rows asRows(dynamic r) => List<Map<String, dynamic>>.from(r as List);

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
      s.toUpperCase(),
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

Future<void> openOriginal(BuildContext context, String path) async {
  try {
    final url = await db.storage.from('originals').createSignedUrl(path, 3600);
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) toast(context, 'Could not open the link');
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
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const AuthGate(),
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
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.collections, size: 72, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text('Template Store', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 28),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? 'Please wait...' : (_signup ? 'Create account' : 'Login')),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _signup = !_signup),
                child: Text(_signup ? 'Already have an account? Login' : 'Create a new account'),
              ),
              if (!_signup)
                TextButton(
                  onPressed: _busy ? null : _forgot,
                  child: const Text('Forgot password?'),
                ),
            ],
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
      appBar: AppBar(title: const Text('Template Store')),
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
                    border: const OutlineInputBorder(),
                    isDense: true,
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
                                            style: TextStyle(color: Theme.of(context).colorScheme.primary),
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
          .eq('template_id', widget.t['id'])
          .order('created_at', ascending: false)
          .limit(1);
      final rows = asRows(r);
      _status = rows.isEmpty ? null : rows.first['status'] as String;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
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
      await db.storage.from('originals').remove([widget.t['file_path'] as String]);
      await db.storage.from('previews').remove([widget.t['preview_path'] as String]);
      await db.from('templates').delete().eq('id', widget.t['id']);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
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
                MaterialPageRoute(builder: (_) => BuyPage(t: t)),
              );
              if (ok == true) {
                setState(() => _loading = true);
                _loadStatus();
              }
            },
            child: Text('Buy  ${money(price)}'),
          ),
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
  final Map<String, dynamic> t;
  const BuyPage({super.key, required this.t});

  @override
  State<BuyPage> createState() => _BuyPageState();
}

class _BuyPageState extends State<BuyPage> {
  final _utr = TextEditingController();
  bool _busy = false;

  String get _upiLink {
    final price = widget.t['price'] as num;
    return 'upi://pay?pa=$upiId&pn=${Uri.encodeComponent(payeeName)}'
        '&am=${price.toStringAsFixed(2)}&cu=INR'
        '&tn=${Uri.encodeComponent(widget.t['title'] as String)}';
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
    setState(() => _busy = true);
    try {
      await db.from('orders').insert({
        'user_id': myId,
        'user_email': myEmail,
        'template_id': widget.t['id'],
        'utr': utr,
        'status': 'pending',
      });
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
    final price = widget.t['price'] as num;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.t['title'] as String, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Amount: ${money(price)}', style: Theme.of(context).textTheme.titleMedium),
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

class AddTemplatePage extends StatefulWidget {
  const AddTemplatePage({super.key});

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

  @override
  void initState() {
    super.initState();
    _loadCats();
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
    if (_bytes == null || title.isEmpty || price == null || price < 0) {
      toast(context, 'Please choose an image, title and a valid price');
      return;
    }
    setState(() => _busy = true);
    try {
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
      final cat = _cat.text.trim().isEmpty ? 'General' : _cat.text.trim();
      await db.from('templates').insert({
        'title': title,
        'description': _desc.text.trim(),
        'price': price,
        'category': cat,
        'file_path': filePath,
        'preview_path': previewPath,
      });
      if (mounted) {
        toast(context, 'Template added');
        Navigator.pop(context, true);
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
      appBar: AppBar(title: const Text('New template')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_bytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_bytes!, height: 220, fit: BoxFit.contain),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.image_outlined),
            label: Text(_bytes == null ? 'Choose edited image' : 'Change image'),
          ),
          const SizedBox(height: 4),
          const Text(
            'A watermark is added to the preview automatically. The original is shared only after payment approval.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Price (Rs)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cat,
            decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
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
            decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Uploading...' : 'Save'),
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

  Future<void> _setStatus(String id, String status) async {
    try {
      await db.from('orders').update({'status': status}).eq('id', id);
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
            final items = s.data!;
            if (items.isEmpty) {
              return ListView(children: const [
                Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No orders yet'))),
              ]);
            }
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (c, i) {
                final o = items[i];
                final t = o['templates'] as Map<String, dynamic>?;
                final status = o['status'] as String;
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
                                (t?['title'] ?? 'Deleted template') as String,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                              ),
                            ),
                            statusChip(status),
                          ],
                        ),
                        if (t != null) Text(money(t['price'] as num)),
                        if (widget.isAdmin) Text('User: ${o['user_email'] ?? ''}'),
                        Text('UTR: ${o['utr'] ?? ''}'),
                        const SizedBox(height: 8),
                        if (widget.isAdmin && status == 'pending')
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => _setStatus(o['id'] as String, 'rejected'),
                                child: const Text('Reject'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () => _setStatus(o['id'] as String, 'approved'),
                                child: const Text('Approve'),
                              ),
                            ],
                          ),
                        if (!widget.isAdmin && status == 'approved' && t != null)
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.tonalIcon(
                              onPressed: () => openOriginal(context, t['file_path'] as String),
                              icon: const Icon(Icons.download),
                              label: const Text('Download'),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
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

class ProfilePage extends StatelessWidget {
  final bool isAdmin;
  const ProfilePage({super.key, required this.isAdmin});

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isAdmin ? 'Master Dashboard' : 'Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle, size: 40),
            title: Text(myEmail),
            subtitle: Text(isAdmin ? 'Master account' : 'User account'),
          ),
          if (isAdmin)
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
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('${e.value}', style: Theme.of(context).textTheme.headlineMedium),
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
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => db.auth.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}
