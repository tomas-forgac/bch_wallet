import 'package:bch_wallet/src/database.dart';
import 'package:bch_wallet/src/wallet.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'account.dart';
import 'utils/utils.dart' as utils;

class BchWallet {
  static List<Wallet> _wallets;

  static const _mnemonicStorageKey = "mnemonic";

  static Future<void> init() async {
    final db = await Database.database;
  }

  /// Creates a new wallet, saves it in the phone's secure storage and returns its [Wallet] instance.
  ///
  /// Creates one default account, which can be optionally named using [defaultAccountName]
  ///
  /// If [password] is defined, it is used as a 13th word of the mnemonic phrase. The password is *not* stored and will
  /// be required for operations like sending, creating a new account, or retreving mnemonic
  /// _Note: this means, that if the user or the app loses the password, the wallet cannot be accessed from the
  /// secure storage only_
  ///
  /// Typically there's no reason to change [derivationPath]. Change it only if you know what you're doing.
  static Future<Wallet> createWallet({String name, String defaultAccountName, String password,
      bool testnet = false, String derivationPath = "m/44'/145'"}) async {
    // password hash will be stored locally to check validity of the provided password when needed
    String passwordHash;

    // flag if the wallet is password protected - it will be used in some functions to determine if password is needed
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

  static int toSatoshi(double amount) => (amount * 100000000).round();

  static double fromSatoshi(int amount) => amount / 100000000;

  /// Deletes all wallet data (keys, history, etc.) from the phone.
  /// _*Note*: This cannot be undone!_
  static Future<bool> deleteWallet([int walletId = 0]) async => utils.deleteWallet(walletId, await Database.database, true);

   static Future<List<Wallet>> _getWallets(sql.Database db) async {
    List queryResult = await db.query("wallet");

    _wallets = List<Wallet>.generate(queryResult.length, (i) => Wallet.fromRow(queryResult[i]));

    return _wallets;
  }

  static setTestNet(testnet) {
     //TODO: check where this can be applied
    Bitbox.Bitbox.setRestUrl(testnet ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);
  }

}