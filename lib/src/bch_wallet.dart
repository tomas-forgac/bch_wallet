import 'package:bch_wallet/src/database.dart';
import 'package:bch_wallet/src/wallet.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'account.dart';

//final x = _test;

class BchWallet {
  static List<Wallet> _wallets;

  static const _mnemonicStorageKey = "mnemonic";

  static Future<void> init() async {
    final db = await Database.database;
//    await db.delete("address", where: "child_no = 4");
  }

  /// Creates a new wallet, saves it in the phone's secure storage and returns its ID.
  /// Keep track of wallet IDs if you want to use more wallets in one app. If you want to use only one wallet in your
  /// app simply omit wallet id argument in all other functions
  ///
  /// Creates one default account, which can be optionally named using [defaultAccountName]
  ///
  /// If [password] is defined, it is used as a 13th word of the mnemonic phrase. The password is *not* stored.
  /// _Note: this means, that if the user or the app loses the password, the wallet cannot be accessed from the
  /// secure storage only_
  ///
  /// Typically there's no reason to change [derivationPath]. Change it only if you know what you're doing.
  static Future<Wallet> createWallet({String name, String defaultAccountName, String password,
      bool testnet = false, String derivationPath = "m/44'/145'"}) async {
    String passwordHash;

    final bool passwordProtected = password != null && password.length > 0;

    if (password != null && password.length > 0) {
      passwordHash = sha256.convert(utf8.encode(password)).toString();
    }

    final db = await Database.database;
    final walletId = await db.insert('wallet', {
      'testnet' : testnet,
      'name' : name,
      'derivation_path' : derivationPath,
      'password_hash' : passwordHash
    });

    final wallet = Wallet(walletId, testnet, passwordProtected, derivationPath);

    // generate a random mnemonic
    final mnemonic = Bitbox.Mnemonic.generate();

    // convert the mnemonic to seed and add (optional) password
    final seed = Bitbox.Mnemonic.toSeed(mnemonic + password);
    final masterNode = Bitbox.HDNode.fromSeed(seed, testnet);

    // CREATE ONE DEFAULT ACCOUNT

    // derive an account's xpub
    final accountXpub = masterNode.derivePath("${derivationPath}/0'").toXPub();

    // store the account in the db
    await db.insert('account', {
      'wallet_id': walletId,
      'account_no' : 0,
      'name' : name,
      'xpub' : accountXpub
    });

    final account = Account(0, walletId, name);

    (await wallet.accounts).add(account);

    // access the keystore and write the mnemonic (without the password) to it
    final storage = FlutterSecureStorage();
    storage.write(key: "${_mnemonicStorageKey}_$walletId", value: mnemonic);

    _wallets ??= await _getWallets(db);

    return wallet;
  }

  static Future<List<Wallet>> getWalletList() async =>
    _wallets ?? await _getWallets(await Database.database);

  static Future<Wallet> getWallet([walletId = 1]) async {
    _wallets ?? await _getWallets(await Database.database);

    if (_wallets.length < walletId) {
      throw RangeError("Wallet with  id $walletId doesn't exist");
    }

    return _wallets[walletId - 1];
  }


  //TODO: Implement
  static Future<Map<String, int>> getWalletBalance([int walletId]) async {
    return {
      "confirmed" : 100000,
      "unconfirmed" : 500000,
    };
  }

  /// Returns XPub of a BIP44 account. If [accountId] is not provided, returns XPub of the default account
  static Future<String> getXPub([int walletId = 1, int accountId = 0]) async {
    return await Account(accountId, walletId).getXPub();
  }

  static Future<Map<String, List<Map<String, dynamic>>>> getAddressList({accountId = 0, walletId = 0}) async {
    return {
      "main": [{
        "address": "bitcoincash:lakjdfkjgkjfalksjfdlakjdf",
        "balance": 0,
      }],
      "change": []
    };
  }

  static Future<int> getMaxSpendable({int accountId = 0, int walletId = 0}) async {
    return 199000000;
  }

  /// Send [amount] in satoshis to the [address].
  /// Txid is returned.
  ///
  /// If the wallet has been password protected when it was created, the [password] has to be provided.
  static Future<String> send(int amount, String address,
    {String password, int accountId = 0, int walletId = 0}) async {

    return "ksjehr3jh45jh234hoijsadou98324iuhasidh";
  }

  static bool validateAddress(String address) {
    return true;
  }

  static Future<Map<String, dynamic>> getAddressDetails(String address) async {
    return {
      "balance": 0
    };
  }

  static Future<Map<String, dynamic>> getTransactionDetails(String txid) async {
    return {
      "inputs": []
    };
  }

  /// Rescans full transaction history of the wallet and updates the stored data accordingly.
  /// Use this sparingly only if necessary as it calls the API extensively and might take a while to run
  static rescanWallet([int walletId = 0]) async {

  }

  static int toSatoshi(double amount) => (amount * 100000000).toInt();

  static double fromSatoshi(int amount) => amount / 100000000;


  validatePassword(String password) {
    return true;
  }
  /// Deletes all wallet data (keys, history, etc.) from the phone.
  /// _*Note*: This cannot be undone!_
  static Future<bool> deleteWallet([int walletId = 0]) async {
    return true;
  }

  static Future<List<Wallet>> _getWallets(sql.Database db) async {
    List queryResult = await db.query("wallet");

    _wallets = List<Wallet>.generate(queryResult.length, (i) => Wallet.fromRow(queryResult[i]));

    return _wallets;
  }

  _setTestNet(testNet) {
    Bitbox.Bitbox.setRestUrl(restUrl: testNet ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);
  }
}