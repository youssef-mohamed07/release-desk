import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/asc.dart';
import '../core/asc_key.dart';
import '../core/errors.dart';
import '../core/google.dart';
import '../core/play.dart';
import '../core/shell.dart';
import '../core/workspace.dart';
import 'app_model.dart';
import 'theme.dart';

Future<void> showConnectDialog(BuildContext context, StoreProvider provider) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ConnectDialog(provider: provider),
);

/// Connect a store team: an App Store Connect API key, or a Google account
/// with Play Console access. Checks with the store before anything is saved.
class ConnectDialog extends StatefulWidget {
  const ConnectDialog({super.key, required this.provider});
  final StoreProvider provider;

  @override
  State<ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<ConnectDialog> {
  late StoreProvider provider = widget.provider;

  // App Store Connect
  List<String> found = [];
  String? keyFile;
  String? pem;
  final path = TextEditingController();
  final keyId = TextEditingController();
  final issuerId = TextEditingController();
  String? accountChoice;
  final accountName = TextEditingController();
  final email = TextEditingController();
  final teamName = TextEditingController();
  bool verifying = false;
  ({String? teamId, List<StoreApp> apps})? verified;
  String? error;

  // Google
  OAuthClient? oauthClient;
  List<String> clientFiles = [];
  GoogleUser? googleUser;
  bool signingIn = false;
  List<PlayApp> foundApps = [];
  bool appsUnavailable = false;
  final packages = TextEditingController();

  bool get isApple => provider == StoreProvider.apple;

  @override
  void initState() {
    super.initState();
    _scan();
    ModelScope.read(context).savedOAuthClient().then((c) {
      if (mounted && c != null) setState(() => oauthClient = c);
    });
  }

  @override
  void dispose() {
    for (final c in [path, keyId, issuerId, accountName, email, teamName, packages]) {
      c.dispose();
    }
    super.dispose();
  }

  List<Account> _accounts(AppModel m) => m.workspace.accounts.where((a) => a.provider == provider).toList();

  void _scan() {
    final model = ModelScope.read(context);
    final home = debugHomeOverride ?? Shell.home;
    final accounts = _accounts(model);
    accountChoice = accounts.isEmpty ? null : accounts.first.id;
    if (isApple) {
      final connected = {
        for (final t in model.allTeams)
          if (!t.team.credential.isGoogle) t.team.credential.keyId,
      };
      final seen = <String>{};
      found = [
        for (final d in ['.appstoreconnect/private_keys', 'private_keys', '.private_keys', 'Downloads'])
          ..._list(p.join(home, d)).where((f) {
            final n = p.basename(f);
            if (!n.startsWith('AuthKey_') || !n.endsWith('.p8')) return false;
            final id = _keyIdFrom(f);
            return !connected.contains(id) && seen.add(id);
          }),
      ];
    } else {
      clientFiles = _list(p.join(home, 'Downloads')).where((f) {
        final n = p.basename(f);
        return n.startsWith('client_secret_') && n.endsWith('.json');
      }).toList();
    }
  }

  static List<String> _list(String dir) {
    try {
      return Directory(dir).listSync().whereType<File>().map((f) => f.path).toList()..sort();
    } catch (_) {
      return const [];
    }
  }

  static String _keyIdFrom(String file) {
    final m = RegExp(r'AuthKey_([A-Z0-9]+)').firstMatch(p.basenameWithoutExtension(file));
    return m?.group(1) ?? p.basenameWithoutExtension(file);
  }

  void _switch(StoreProvider to) {
    if (to == provider) return;
    setState(() {
      provider = to;
      keyFile = null;
      pem = null;
      path.clear();
      keyId.clear();
      issuerId.clear();
      verified = null;
      error = null;
      _scan();
    });
  }

  void _loadKey(String file) {
    String text;
    try {
      text = File(file).readAsStringSync();
    } catch (_) {
      setState(() => error = 'Cannot read $file.');
      return;
    }
    // The file decides the store.
    if (text.contains('"client_secret"')) {
      if (provider != StoreProvider.google) _switch(StoreProvider.google);
      unawaited(_importClient(file));
      return;
    }
    if (!text.contains('PRIVATE KEY')) {
      setState(() => error = '${p.basename(file)} is not an App Store Connect key.');
      return;
    }
    try {
      AscKey.parsePrivateKey(text);
    } catch (e) {
      setState(() => error = describeError(e));
      return;
    }
    if (provider != StoreProvider.apple) _switch(StoreProvider.apple);
    setState(() {
      error = null;
      verified = null;
      keyFile = file;
      pem = text;
      path.text = tildePath(file);
      if (p.basename(file).startsWith('AuthKey_')) keyId.text = _keyIdFrom(file);
      if (accountChoice == null && accountName.text.isEmpty) accountName.text = 'App Store Connect';
    });
  }

  Future<void> _chooseKey() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'App Store Connect key', extensions: ['p8']),
      ],
    );
    if (f != null) _loadKey(f.path);
  }

  Future<void> _importClient(String file) async {
    final model = ModelScope.read(context);
    try {
      final c = OAuthClient.fromFile(File(file).readAsStringSync());
      await model.saveOAuthClient(c);
      setState(() {
        oauthClient = c;
        error = null;
      });
    } catch (e) {
      setState(() => error = describeError(e));
    }
  }

  Future<void> _chooseClient() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Google OAuth client', extensions: ['json']),
      ],
    );
    if (f != null) await _importClient(f.path);
  }

  Future<void> _signIn() async {
    final client = oauthClient;
    if (client == null) return;
    setState(() {
      signingIn = true;
      error = null;
    });
    try {
      final user = await GoogleSignIn.signIn(
        client,
        open: (url) async {
          if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
            throw const ReleaseError.precondition('Could not open the browser.');
          }
        },
      );
      googleUser = user;
      if (teamName.text.isEmpty) teamName.text = 'Play Console';
      final play = PlayClient(user);
      try {
        final apps = await play.searchApps();
        foundApps = apps ?? [];
        appsUnavailable = apps == null;
      } catch (_) {
        appsUnavailable = true;
      } finally {
        play.close();
      }
    } catch (e) {
      error = describeError(e);
    }
    if (mounted) setState(() => signingIn = false);
  }

  List<String> get _packageList => packages.text.split(RegExp(r'[,\s]+')).map((s) => s.trim()).where((s) => s.contains('.')).toList();

  Future<void> _verify() async {
    final model = ModelScope.read(context);
    final key = pem;
    if (key == null) return;
    setState(() {
      verifying = true;
      error = null;
    });
    try {
      verified = await model.verifyApple(keyId.text.trim(), issuerId.text.trim(), key);
      if (teamName.text.isEmpty) teamName.text = verified!.teamId == null ? 'My team' : 'Team ${verified!.teamId}';
    } catch (e) {
      final text = describeError(e);
      error = text.contains('401')
          ? 'Apple did not accept this key. Check the Key ID and Issuer ID, and that the key is an App Store Connect API key (not an APNs key).'
          : text;
    }
    if (mounted) setState(() => verifying = false);
  }

  Future<void> _connect() async {
    final model = ModelScope.read(context);
    try {
      if (!isApple) {
        final user = googleUser;
        if (user == null) return;
        final existing = model.workspace.accounts.where((a) => a.provider == StoreProvider.google && a.email == user.email).firstOrNull?.id;
        await model.connectGoogleUser(
          user,
          accountId: existing,
          teamName: teamName.text.trim(),
          packages: ({...foundApps.map((a) => a.packageName), ..._packageList}.toList()..sort()),
        );
      } else {
        final key = pem;
        if (key == null) return;
        await model.connectApple(
          accountId: accountChoice,
          newAccountName: accountName.text.trim(),
          email: email.text.trim().isEmpty ? null : email.text.trim(),
          teamName: teamName.text.trim(),
          teamId: verified?.teamId,
          keyId: keyId.text.trim(),
          issuerId: issuerId.text.trim(),
          pem: key,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final model = ModelScope.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 780),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ProviderMark(provider, size: 26),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Connect a team', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(
                              isApple
                                  ? 'One App Store Connect API key per team: Users and Access → Integrations → App Store Connect API.'
                                  : 'Sign in with the Google account that has Play Console access. Release Desk sees the apps it sees.',
                              style: TextStyle(fontSize: 13.5, color: t.text2),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Segmented<StoreProvider>(
                    items: const [(StoreProvider.apple, 'App Store Connect'), (StoreProvider.google, 'Google Play')],
                    value: provider,
                    expand: true,
                    onChanged: _switch,
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
                children: isApple ? _appleSections(context, model) : _googleSections(context, model),
              ),
            ),
            Divider(height: 1, color: t.hairline),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.lock_rounded, size: 13, color: t.text2),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Keys go to your system keychain, never to a file Release Desk keeps.', style: TextStyle(fontSize: 12, color: t.text2)),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  ..._footerAction(model),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _footerAction(AppModel model) {
    if (!isApple) {
      return [FilledButton(onPressed: googleUser == null || teamName.text.trim().isEmpty ? null : _connect, child: const Text('Connect'))];
    }
    if (verified == null) {
      return [
        FilledButton.tonal(
          onPressed: pem == null || verifying || keyId.text.trim().isEmpty || issuerId.text.trim().isEmpty ? null : _verify,
          child: const Text('Verify'),
        ),
      ];
    }
    return [
      FilledButton(
        onPressed: teamName.text.trim().isEmpty || (accountChoice == null && accountName.text.trim().isEmpty) ? null : _connect,
        child: const Text('Connect'),
      ),
    ];
  }

  Widget _section(String title, List<Widget> rows, {String? footer}) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              title,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
            ),
          ),
          Surface(
            radius: 12,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, r) in rows.indexed) ...[if (i > 0) Divider(height: 18, color: t.hairline), r],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(footer, style: TextStyle(fontSize: 12, color: t.text2)),
            ),
        ],
      ),
    );
  }

  Widget _labeled(String label, Widget field) => Row(
    children: [
      SizedBox(width: 170, child: Text(label, style: const TextStyle(fontSize: 13.5))),
      Expanded(child: field),
    ],
  );

  List<Widget> _appleSections(BuildContext context, AppModel model) {
    final t = context.tokens;
    final accounts = _accounts(model);
    return [
      _section('Private key (.p8)', [
        if (found.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Found on this computer', style: TextStyle(fontSize: 12, color: t.text2)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in found)
                    Sensitive(
                      radius: 5,
                      child: SoftButton(
                        label: p.basename(f),
                        icon: keyFile == f ? Icons.check_circle_rounded : Icons.key_rounded,
                        small: true,
                        onPressed: () => _loadKey(f),
                      ),
                    ),
                ],
              ),
            ],
          ),
        Row(
          children: [
            Icon(pem == null ? Icons.file_download_outlined : Icons.verified_rounded, size: 18, color: pem == null ? t.text2 : Palette.mint),
            const SizedBox(width: 8),
            Expanded(
              child: Sensitive(
                radius: 5,
                child: Field(
                  controller: path,
                  isMono: true,
                  hint: 'Choose or paste the path of AuthKey_….p8',
                  onSubmitted: (s) => _loadKey(s.startsWith('~') ? p.join(Shell.home, s.substring(2)) : s),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SoftButton(label: 'Choose…', small: true, onPressed: _chooseKey),
          ],
        ),
        _labeled(
          'Key ID',
          Sensitive(
            radius: 5,
            child: Field(controller: keyId, isMono: true, hint: 'e.g. 2X9R4HXF34', onChanged: (_) => setState(() => verified = null)),
          ),
        ),
        _labeled(
          'Issuer ID',
          Sensitive(
            radius: 5,
            child: Field(controller: issuerId, isMono: true, hint: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', onChanged: (_) => setState(() => verified = null)),
          ),
        ),
      ]),
      _section('Where it belongs', [
        _labeled(
          'Account',
          Align(
            alignment: Alignment.centerLeft,
            child: DropdownButton<String?>(
              value: accountChoice,
              isDense: true,
              underline: const SizedBox(),
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13.5, color: t.text),
              borderRadius: BorderRadius.circular(10),
              items: [
                for (final a in accounts)
                  DropdownMenuItem(
                    value: a.id,
                    child: Sensitive(radius: 5, child: Text(a.name)),
                  ),
                const DropdownMenuItem(value: null, child: Text('New account…')),
              ],
              onChanged: (v) => setState(() => accountChoice = v),
            ),
          ),
        ),
        if (accountChoice == null) ...[
          _labeled(
            'Account name',
            Sensitive(
              radius: 5,
              child: Field(controller: accountName, hint: 'e.g. My Apple ID', onChanged: (_) => setState(() {})),
            ),
          ),
          _labeled(
            'Apple ID email (optional)',
            Sensitive(
              radius: 5,
              child: Field(controller: email, hint: 'name@example.com'),
            ),
          ),
        ],
        _labeled(
          'Team name',
          Sensitive(
            radius: 5,
            child: Field(controller: teamName, hint: 'e.g. Client team', onChanged: (_) => setState(() {})),
          ),
        ),
      ]),
      if (verifying || verified != null || error != null)
        _section('Check', [
          if (verifying)
            Row(
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
                const SizedBox(width: 10),
                Text('Asking App Store Connect…', style: TextStyle(color: t.text2)),
              ],
            )
          else if (error != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cancel_rounded, size: 18, color: Palette.ember),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(error!, style: TextStyle(color: Palette.ember)),
                ),
              ],
            )
          else if (verified != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.verified_rounded, size: 18, color: Palette.mint),
                    const SizedBox(width: 8),
                    Text(
                      'Key works · ${counted(verified!.apps.length, 'app')}',
                      style: TextStyle(color: Palette.mint, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Sensitive(
                  radius: 4,
                  child: Text(
                    verified!.apps.take(8).map((a) => a.name).join(' · ') + (verified!.apps.length > 8 ? ' …' : ''),
                    style: TextStyle(fontSize: 12, color: t.text2),
                  ),
                ),
              ],
            ),
        ]),
    ];
  }

  List<Widget> _googleSections(BuildContext context, AppModel model) {
    final t = context.tokens;
    final user = googleUser;
    return [
      _section('Your Google account', [
        if (user != null) ...[
          Row(
            children: [
              Icon(Icons.verified_rounded, size: 18, color: Palette.mint),
              const SizedBox(width: 8),
              Expanded(
                child: Sensitive(
                  radius: 5,
                  child: Text(
                    'Signed in as ${user.email}',
                    style: TextStyle(color: Palette.mint, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              SoftButton(label: 'Use another account', small: true, onPressed: signingIn ? null : _signIn),
            ],
          ),
          if (foundApps.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${counted(foundApps.length, 'app')} on Play', style: TextStyle(fontSize: 12, color: t.text2)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [for (final a in foundApps) Tag(a.name, icon: Icons.apps_rounded, sensitive: true)]),
              ],
            )
          else if (appsUnavailable)
            Text(
              'Play did not list your apps yet (the Reporting API can take a few minutes after it is turned on). Name them below, or connect now and refresh later.',
              style: TextStyle(fontSize: 12, color: t.text2),
            ),
        ] else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _GoogleButton(busy: signingIn, onPressed: oauthClient == null || signingIn ? null : _signIn),
              const SizedBox(height: 8),
              Text(
                'Opens your browser. Pick the Google account that has access to Play Console; Release Desk sees the apps that account sees.',
                style: TextStyle(fontSize: 12, color: t.text2),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.cancel_rounded, size: 16, color: Palette.ember),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(error!, style: TextStyle(fontSize: 13, color: Palette.ember)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        if (oauthClient != null)
          Row(
            children: [
              const SizedBox(width: 170, child: Text('Sign-in client', style: TextStyle(fontSize: 13.5))),
              Expanded(
                child: Sensitive(
                  radius: 4,
                  child: Text(
                    oauthClient!.projectId ?? '${oauthClient!.clientId.substring(0, oauthClient!.clientId.length.clamp(0, 12))}…',
                    style: mono(12, color: t.text2),
                  ),
                ),
              ),
              LinkText('Change…', size: 12, onTap: _chooseClient),
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Release Desk needs your Google sign-in client once: the client_secret_….json of a Desktop OAuth client you create in Google Cloud.',
                style: TextStyle(fontSize: 12, color: t.text2),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in clientFiles)
                    Sensitive(
                      radius: 4,
                      child: SoftButton(
                        label: p.basename(f).length > 30 ? '${p.basename(f).substring(0, 28)}…' : p.basename(f),
                        icon: Icons.settings_applications_outlined,
                        small: true,
                        onPressed: () => _importClient(f),
                      ),
                    ),
                  SoftButton(label: 'Choose…', small: true, onPressed: _chooseClient),
                ],
              ),
            ],
          ),
      ]),
      if (user != null)
        _section('Apps', [
          Sensitive(
            radius: 5,
            child: Field(controller: packages, isMono: true, minLines: 1, maxLines: 4, hint: 'com.example.app, com.example.other'),
          ),
        ], footer: appsUnavailable ? 'Name the package names of your apps; you can add more later on the account page.' : 'Optional: apps Play did not list.'),
      _section('Where it belongs', [
        _labeled(
          'Developer account name',
          Sensitive(
            radius: 5,
            child: Field(controller: teamName, hint: 'e.g. Play Console', onChanged: (_) => setState(() {})),
          ),
        ),
      ]),
    ];
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.busy, required this.onPressed});
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Opacity(
          opacity: onPressed == null && !busy ? 0.5 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Palette.googleBlue,
              borderRadius: BorderRadius.circular(99),
              boxShadow: [BoxShadow(color: Palette.googleBlue.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const GoogleG(size: 20),
                const SizedBox(width: 10),
                Text(
                  busy ? 'Waiting for your browser…' : 'Sign in with Google',
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
