// Prints the download URL of the AOSP arm64-v8a system image of an Android
// API level, from Google's SDK repository.
//
// usage: dart system_image.dart <api-level>
import 'dart:io';

const _repository = 'https://dl.google.com/android/repository/sys-img/android/';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart system_image.dart <api-level>');
    exit(64);
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('${_repository}sys-img2-3.xml'),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('sys-img2-3.xml: HTTP ${response.statusCode}');
      exit(1);
    }
    final xml = await response.transform(systemEncoding.decoder).join();
    final url = imageUrl(xml, args.single);
    if (url == null) {
      stderr.writeln('No arm64-v8a system image for API ${args.single}.');
      exit(1);
    }
    stdout.writeln('$_repository$url');
  } finally {
    client.close();
  }
}

/// The archive file name of the arm64-v8a image of [apiLevel] in [xml], or
/// null.
String? imageUrl(String xml, String apiLevel) {
  final path = 'system-images;android-$apiLevel;default;arm64-v8a';
  final start = xml.indexOf('<remotePackage path="$path">');
  if (start < 0) return null;
  final end = xml.indexOf('</remotePackage>', start);
  final package = xml.substring(start, end);
  return RegExp(r'<url>([^<]+\.zip)</url>').firstMatch(package)?[1];
}
