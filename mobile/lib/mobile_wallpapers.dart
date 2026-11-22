import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'gateway.dart';

class MobileWallpaper {
  const MobileWallpaper(this.id, this.name, {this.asset});

  final String id, name;
  final String? asset;

  static const none = MobileWallpaper('none', '无背景');
  static const hermes = MobileWallpaper(
    'hermes',
    'Hermes',
    asset: 'assets/wallpapers/hermes.webp',
  );
  static const blue = MobileWallpaper(
    'blue_hour',
    '蓝调时刻',
    asset: 'assets/wallpapers/blue-hour.webp',
  );
  static const builtIns = [none, hermes, blue];

  static MobileWallpaper? fromWire(Json row) {
    final id = row['id'];
    final name = row['name'];
    return id is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(id) &&
            name is String &&
            name.trim().isNotEmpty
        ? MobileWallpaper(id, name)
        : null;
  }

  Json toWire() => {'id': id, 'name': name};
}

class WallpaperStorage {
  Future<Directory> root() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}wallpapers')
        .create(recursive: true);
  }

  File forId(Directory root, String id) =>
      File('${root.path}${Platform.pathSeparator}$id');

  Future<MobileWallpaper> add(XFile source, Directory folder) async {
    final scratch = forId(folder, '.${const Uuid().v4()}');
    try {
      await source.saveTo(scratch.path);
      final bytes = await ui.ImmutableBuffer.fromFilePath(scratch.path);
      try {
        final description = await ui.ImageDescriptor.encoded(bytes);
        description.dispose();
      } finally {
        bytes.dispose();
      }
      final digest = await sha256.bind(scratch.openRead()).first;
      final id = digest.toString();
      final owned = forId(folder, id);
      if (!await owned.exists()) await scratch.rename(owned.path);
      final name = source.name.trim();
      return MobileWallpaper(id, name.isEmpty ? '自定义图片' : name);
    } finally {
      if (await scratch.exists()) await scratch.delete();
    }
  }
}

class WallpaperCanvas extends StatelessWidget {
  const WallpaperCanvas({
    super.key,
    required this.image,
    required this.color,
    required this.strength,
    required this.child,
  });

  final ImageProvider? image;
  final Color color;
  final double strength;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final wallpaper = image;
    if (wallpaper == null || strength <= 0) {
      return ColoredBox(color: color, child: child);
    }
    return ColoredBox(
      color: color,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: Image(
                image: wallpaper,
                fit: BoxFit.cover,
                opacity: AlwaysStoppedAnimation(strength.clamp(0, 1) * .33),
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
