library bch_wallet;

import 'package:bch_wallet/src/address.dart';
import 'package:bch_wallet/src/transaction.dart';
import 'package:bch_wallet/src/wallet.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:path/path.dart';

import 'account.dart';

class BchWallet {
  static const _mnemonicStorageKey = "mnemonic";

  static final Future<sql.Database> database = connect();

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
  static Future<int> createWallet({String name, String defaultAccountName, String password,
      bool testnet = false, String derivationPath = "m/44'/145'/0'"}) async {
    // generate a random mnemonic
    final mnemonic = Bitbox.Mnemonic.generate();

    password ??= "";

    final db = await database;
    final walletId = await db.insert('wallet', {
      'testnet' : testnet,
      'name' : name,
      'password_protected' : password.length > 0
    });

    // convert the mnemonic to seed and add (optional) password
    final seed = Bitbox.Mnemonic.toSeed(mnemonic + password);

    // create an account HD Node from the seed and the derivation path
    Bitbox.HDNode accountNode = Bitbox.HDNode.fromSeed(seed, testnet).derivePath("$derivationPath/0");

    await db.insert('account', {
      'wallet_id': walletId,
      'account_id' : 0,
      'name' : name,
      'xpub' : accountNode.toXPub()
    });

    // access the keystore and write the mnemonic (without the password) to it
    final storage = FlutterSecureStorage();
    storage.write(key: "${_mnemonicStorageKey}_$walletId", value: mnemonic);
    return walletId;
  }

  static Future<Wallet> getWallet([walletId = 1])async {
    final db = await database;
    List queryResult = await db.query("wallet", where: "id = $walletId");

    if (queryResult.length == 0) {
      return null;
    }
    final Map row = queryResult.first;
    final wallet = Wallet.fromRow(row);

    queryResult = await db.query("account", where: "wallet_id = $walletId");
    wallet.accounts = List.generate(queryResult.length, (i) {
      return Account.fromDbRow(queryResult[i]);
    });

    return wallet;
  }

  static Future<List<Wallet>> getWalletList() async {
    final db = await database;
//    final walletList = await db.query("wallet");
    final queryResult = await db.query("wallet");

    final walletList = List.generate(queryResult.length, (i) {
      final Map<String, dynamic> row = queryResult[i];
      return Wallet.fromRow(row);
    });

    return walletList;
  }

  static Future<Map<String, int>> getWalletBalance([int walletId]) async {
    return {
      "confirmed" : 100000,
      "unconfirmed" : 500000,
    };
  }

  /// Create a new account and returns its id (the last digit of its derivation path)
  static Future<int> createAccount({String name = null, int walletId = 0}) async {
    return 0;
  }

  /// Returns list of stored accounts. The key of the account in the list represents its number used as an argument in
  /// other functions
  static Future<List<Map<String, int>>> getAccountList([walletId = 0]) async {
    return [{
      "id" : 0,
      "balance" : 1000000
    }];
  }

  /// Returns XPub of a BIP44 account. If [accountId] is not provided, returns XPub of the default account
  static Future<String> getXPub([int walletId = 0, int accountId = 0]) async {
    final db = await database;
    final result = await db.query("account", columns: ["xpub"], where: "wallet_id = $walletId AND account_id = $accountId");

    if (result.length > 0) {
      return result.first["xpub"];
    } else {
      return null;
    }
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
  /// Returns an unused address to receive new funds.
  ///
  /// [accountNo] is the account number represented by a key in the list of accounts,
  /// which can be retrieved using [listAccounts].
  /// Omit [walletId] if you use only one wallet in your app
  static Future<Address> getReceivingAddress({int accountNo = 0, int walletId = 0}) async {
    return Address(0, "bitcoincash:lakjdfkjgkjfalksjfdlakjdf", 0);
  }

  /// Returns [address]' confirmed and unconfirmed balance in the following format:
  /// ```
  /// {
  ///     "confirmed": 0,
  ///     "unconfirmed": 0,
  /// }
  /// ````
  static Future<Map<String, int>> getAddressBalance(String address) async {
    return {
      "confirmed" : 0,
      "unconfirmed" : 10000000,
    };
  }

  /// Returns account balance (confirmed + unconfirmed) in satoshis as recorded in the last balance update.
  /// In  most cases this should be in sync with the actual balance retrieved from the blockchain.
  /// This is to be able to retrieve the balance immediately upon
  /// user's opening of the app without necessity to wait for the blockchain sync.
  ///
  /// It is recommended to:
  /// 1. Use this function to display balance for the user immediately when they open the app
  /// 2. Call [getAccountBalanceFromBlockchain] asynchronously to check if some of the balance is still unconfirmed or
  /// if any funds have moved in or out of the previously used addresses
  /// 3. Update user screen for the obtained information
  static Future<int> getAccountBalance([int accountId = 0, int walletId = 0]) async {
    return 100000000;
  }

  /// Returns account confirmed and unconfirmed balance in the following format:
  /// ```
  /// {
  ///     "confirmed": 0,
  ///     "unconfirmed": 0,
  /// }
  /// ````
  ///
  /// If there have been any changes from the latest stored state, they will be updated in [SharedPreferences]
  /// automatically so next time [getAccountBalance] is called it has the latest state.
  static Future<Map<String, int>> getAccountBalanceFromBlockchain({int accountId = 0, int walletId = 0}) async {
    return {"confirmed" : 100000000,"unconfirmed" : 100000000,};
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

  /// Get list of all transactions in the selected account or default account if no [accoundId] is provided.
  static Future<List<Transaction>> getTransactions({int accountId = 0, int walletId = 0}) async {
    return [
      Transaction()
    ];
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

  /// Deletes all wallet data (keys, history, etc.) from the phone.
  /// _*Note*: This cannot be undone!_
  static Future<bool> deleteWallet([int walletId = 0]) async {
    return true;
  }

  static Future<sql.Database> connect() async {
    return sql.openDatabase(
      join(await sql.getDatabasesPath(), 'bch_wallet.db'),
      onCreate: (db, version) {
        db.execute("CREATE TABLE wallet (id INTEGER PRIMARY KEY, testnet BOOL NOT NULL DEFAULT false, name TEXT, "
            "password_protected BOOL NOT NULL DEFAULT false);");
        db.execute("CREATE TABLE account (wallet_id INTEGER NOT NULL, account_id INTEGER NOT NULL, name TEXT, xpub TEXT, "
            "PRIMARY KEY (wallet_id, account_id))");
      },
      version: 1
    );
  }
}