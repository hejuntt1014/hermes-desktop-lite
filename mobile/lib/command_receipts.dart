import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'gateway.dart';

final _terminalEscapes = RegExp(
  r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))',
);
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');

class CommandReceipt {
  CommandReceipt(this.command, String output, {this.after})
    : output = _cleanOutput(output);

  final int? after;
  final String command, output;

  static String _cleanOutput(String output) {
    final text = output.replaceAll(_terminalEscapes, '').trim();
    final bytes = utf8.encode(text);
    var end = math.min(bytes.length, 32000);
    if (end == bytes.length) return text;
    while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end));
  }

  static CommandReceipt? fromSystem(String content) {
    const prefix = 'slash:/';
    final newline = content.indexOf('\n');
    if (!content.startsWith(prefix) || newline <= prefix.length) return null;
    final command = content.substring(prefix.length, newline).trim();
    if (command.isEmpty || command.contains(_controlCharacters)) return null;
    return CommandReceipt(command, content.substring(newline + 1));
  }

  static CommandReceipt? fromWire(Json wire) {
    final command = wire['command'];
    final output = wire['output'];
    final after = wire['after'];
    if (command is! String ||
        command.isEmpty ||
        command.contains(_controlCharacters) ||
        output is! String ||
        after != null && (after is! int || after <= 0)) {
      return null;
    }
    return CommandReceipt(command, output, after: after as int?);
  }

  Json toWire() => {'command': command, 'output': output, 'after': ?after};
}

class CommandReceipts {
  CommandReceipts(Gateway gateway, String profile, String session)
    : _key = sha256
          .convert(
            utf8.encode(
              jsonEncode([gateway.base.toString(), profile, session]),
            ),
          )
          .toString();

  final String _key;
  static final _writes = <String, Future<void>>{};

  Future<File> _file() async {
    final data = await getApplicationSupportDirectory();
    return File('${data.path}/command-receipts/$_key.jsonl');
  }

  Future<List<CommandReceipt>> read() async {
    await _writes[_key];
    final file = await _file();
    if (!await file.exists()) return [];
    final receipts = <CommandReceipt>[];
    final lines = file
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) continue;
      try {
        if (jsonDecode(line) case final Json wire) {
          if (CommandReceipt.fromWire(wire) case final receipt?) {
            receipts.add(receipt);
          }
        }
      } on FormatException {
        // A process ending mid-write can leave one incomplete line.
      }
    }
    return receipts;
  }

  Future<void> append(CommandReceipt receipt) => _write((file) async {
    await file.parent.create(recursive: true);
    // Isolate a possibly incomplete last line from the next receipt.
    await file.writeAsString(
      '\n${jsonEncode(receipt.toWire())}\n',
      mode: FileMode.append,
      flush: true,
    );
  });

  Future<void> delete() => _write((file) async {
    if (await file.exists()) await file.delete();
  });

  Future<void> _write(Future<void> Function(File) commit) {
    final next = (_writes[_key] ?? Future<void>.value()).then((_) async {
      await commit(await _file());
    });
    final settled = next.then<void>((_) {}, onError: (Object _) {});
    _writes[_key] = settled;
    settled.whenComplete(() {
      if (identical(_writes[_key], settled)) _writes.remove(_key);
    });
    return next;
  }
}
