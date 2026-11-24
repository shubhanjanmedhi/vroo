// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_opus/vroo_opus.dart';

import 'ui/home_screen.dart';

void main() {
  // libopus is BSD-3: its notice goes on the licence page.
  LicenseRegistry.addLicense(() => Stream.value(const LicenseEntryWithLineBreaks(['libopus'], libopusLicense)));
  runApp(VrooApp(net: createVrooNet(), audio: createVrooAudio()));
}

class VrooApp extends StatelessWidget {
  const VrooApp({super.key, required this.net, required this.audio});

  final VrooNet net;
  final VrooAudio audio;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vroo',
        theme: ThemeData(colorSchemeSeed: Colors.deepOrange),
        darkTheme: ThemeData(colorSchemeSeed: Colors.deepOrange, brightness: Brightness.dark),
        home: HomeScreen(net: net, audio: audio),
      );
}
