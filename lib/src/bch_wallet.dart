import 'utils/database.dart';
import 'package:bch_wallet/src/wallet.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'account.dart';
import 'utils/utils.dart' as utils;

/// Top-level entrypoint to working with this library.
///
/// From here it is possible to:
/// * create a new wallet ([createWallet])
/// * retrieve one ([getWallet]) or all ([getWalletList]) saved wallets
/// * delete a wallet ([deleteWallet])
/// * convert amounts to ([toSatoshi]) and from ([fromSatoshi]) satoshis
///   * _note: this library works with satoshis_
///
/// Further functions and methods to work with accounts, to receive and send BCH, and to check balances and transactions
/// can be found in [Wallet], [Account], and [Address] objects, which are accessible in a hierarchical structure
/// from each other
class BchWallet {
  static List<Wallet> _wallets;

  static const _mnemonicStorageKey = "mnemonic";

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
    // flag if the wallet is password protected - it will be used in some functions to determine if password is needed
    final bool passwordProtected = password != null && password.length > 0;

    // password hash will be stored locally to check validity of the provided password when needed
    final passwordHash = passwordProtected ? sha256.convert(utf8.encode(password)).toString() : null;

    // add a wallet record to the db
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
    final seed = Bitbox.Mnemonic.toSeed(mnemonic + (password??""));
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

    // create an Account instance and add it to the (empty) list of wallet's accounts
    final account = Account(0, walletId, name);
    (await wallet.accounts).add(account);

    // access the keystore and write the mnemonic (without the password) to it
    final storage = FlutterSecureStorage();
    storage.write(key: "${_mnemonicStorageKey}_$walletId", value: mnemonic);

    // this will update the latest list of _wallets before leaving the function
    await _getWallets(db);

    return wallet;
  }

  /// Restores a wallet from its mnemonic.
  /// It creates a local db entry for the wallet and all its used accounts, addresses, and transactions, and
  /// stores the mnemonic locally (not the password - same principle as with [createWallet])
  static Future<Wallet> restoreWallet(String mnemonic, {String name, String password,
      bool testnet = false, String derivationPath = "m/44'/145'"}) async {
    // flag if the wallet is password protected - it will be used in some functions to determine if password is needed
    final bool passwordProtected = password != null && password.length > 0;

    // password hash will be stored locally to check validity of the provided password when needed
    final passwordHash = passwordProtected ? sha256.convert(utf8.encode(password)).toString() : null;

    // add a wallet record to the db
    final db = await Database.database;
    final walletId = await db.insert('wallet', {
      'testnet' : testnet,
      'name' : name,
      'derivation_path' : derivationPath,
      'password_hash' : passwordHash
    });

    // access the keystore and write the mnemonic (without the password) to it
    final storage = FlutterSecureStorage();
    await storage.write(key: "${_mnemonicStorageKey}_$walletId", value: mnemonic);

    final wallet = Wallet(walletId, testnet, passwordProtected, derivationPath, name = name);

    await wallet.rebuildHistory(password);

    return wallet;
  }

  /// returns a [List] of [Wallet] instances stored in DB
  static Future<List<Wallet>> getWalletList() async =>
    _wallets ?? await _getWallets(await Database.database);

  /// retrieves a [Wallet] with a provided [walletId].
  /// [walletId] defaults to 1, so if only one wallet is used in the app, it can be ommitted.
  static Future<Wallet> getWallet([walletId = 1]) async {
    _wallets ?? await _getWallets(await Database.database);

    if (_wallets.length < walletId) {
      throw RangeError("Wallet with  id $walletId doesn't exist");
    }

    return _wallets[walletId - 1];
  }

  /// Deletes all wallet data (keys, history, etc.) from the phone.
  /// _Note: *This cannot be undone!*_
  static Future<bool> deleteWallet(int walletId) async =>
    await utils.deleteWallet(walletId, await Database.database, true, _mnemonicStorageKey);

  /// helper method to convert BCH to satoshis
  static int toSatoshi(double amount) => (amount * 100000000).round();

  /// helper method to convert satoshis to BCH units
  static double fromSatoshi(int amount) => amount / 100000000;

  static Future<List<Wallet>> _getWallets(sql.Database db) async {
    List queryResult = await db.query("wallet");

    _wallets = List<Wallet>.generate(queryResult.length, (i) {
      final row = queryResult[i];
      return (Wallet(row["id"], row["testnet"] == 1, row["password_hash"] != null, row["derivation_path"], row["name"]));
     });

    return _wallets;
  }
}