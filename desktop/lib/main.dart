import 'package:material_ui/material_ui.dart';

import 'src/core/workspace.dart';
import 'src/ui/app_model.dart';
import 'src/ui/root.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await WorkspaceStore.standard();
  final model = AppModel(store: store, secrets: OsSecretStore());
  runApp(ReleaseDeskApp(model: model));
}
