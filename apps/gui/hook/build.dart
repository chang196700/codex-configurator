// SPDX-License-Identifier: MIT OR Apache-2.0

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await const FlutterRustBridgeNativeAssetsBuilder(
      assetName: 'src/rust/frb_generated.io.dart',
      cratePath: 'rust',
    ).run(input: input, output: output);
  });
}
