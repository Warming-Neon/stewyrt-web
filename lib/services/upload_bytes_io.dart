import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readPathAsBytes(String path) => File(path).readAsBytes();
