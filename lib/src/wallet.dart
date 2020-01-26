import 'package:bch_wallet/bch_wallet.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Wallet {
  static const _mnemonicStorageKey = "mnemonic";

  final int id;
  final bool testnet;
  String name;
  final bool passwordProtected;

  List accounts;

  Wallet(this.id, this.testnet, this.passwordProtected, [this.name]);

  Wallet.fromRow(Map<String, dynamic> row) :
      id = row["id"],
      testnet = row["testnet"] == 1,
      passwordProtected = row["password_protected"] == 1,
      name = row["name"];

  /// Retrieve mnemonic from the secure storage.
  Future<String> getMnemonic() async {
    final storage = FlutterSecureStorage();
    final mnemonic = await storage.read(key: "${_mnemonicStorageKey}_$id");
    return mnemonic;
  }

  Future<String> getXPub([int accountId = 0]) async {
    return BchWallet.getXPub(id, accountId);
  }
}