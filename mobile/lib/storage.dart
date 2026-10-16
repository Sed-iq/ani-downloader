/// Storage access and the download folder: `<storage root>/Anikoto Downloader/<Anime>/`.
library;

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'native.dart';
import 'site.dart';

const folderName = 'Anikoto Downloader';

/// Android 11+ only lets an app write a folder of its own at the storage root with
/// "All files access"; older versions use the classic storage permission.
Future<Permission> _permission() async => await sdkInt() >= 30 ? Permission.manageExternalStorage : Permission.storage;

Future<bool> hasAccess() async => (await _permission()).isGranted;

/// Ask for access. "All files access" is granted on a system settings page, so this
/// returns once the user comes back from it.
Future<PermissionStatus> requestAccess() async => (await _permission()).request();

/// The root download folder, created if missing.
Future<Directory> rootFolder() async {
  final dir = Directory('${await storageRoot()}/$folderName');
  await dir.create(recursive: true);
  return dir;
}

/// The folder for one anime's episodes.
Future<Directory> animeFolder(String title) async {
  final dir = Directory('${(await rootFolder()).path}/${cleanName(title)}');
  await dir.create(recursive: true);
  return dir;
}
