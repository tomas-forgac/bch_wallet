import 'dart:convert';

import 'package:bch_wallet/bch_wallet.dart';
import 'package:bch_wallet/src/database.dart';
import 'package:bch_wallet/src/utils/utils.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:crypto/crypto.dart';

import 'account.dart';

class Wallet {
  static const _mnemonicStorageKey = "mnemonic";

  final int id;
  final bool testnet;
  String name;
  final String derivationPath;
  final bool passwordProtected;

  Future<List<Account>> get accounts async => _accounts ?? await _getAccounts(await Database.database);

  List<Account> _accounts;

  Wallet(this.id, this.testnet, this.passwordProtected, this.derivationPath, [this.name]);

  Wallet.fromRow(Map<String, dynamic> row) :
      id = row["id"],
      testnet = row["testnet"] == 1,
      name = row["name"],
      derivationPath = row["derivation_path"],
      passwordProtected = row["password_hash"] != null;

  /// Retrieve mnemonic from the secure storage.
  Future<String> getMnemonic([String password]) async => _getMnemonic(await Database.database, password);

  Future<Account> createAccount(String name, {String password}) async =>
    _createAccount(await Database.database, password, name);

  Future<bool> validatePassword(String password) async => _validatePassword(await Database.database, password);

  Future<Map<String, int>> getAddressBalance(Address address) async {
    _setRestUrl();

    final balanceMap = await Bitbox.Address.details(address.cashAddr);
    address.confirmedBalance = balanceMap["confirmed"];
    address.unconfirmedBalance = balanceMap["unconfirmed"];

    return balanceMap;
  }

  rebuildHistory(String password) async {
    final db = await Database.database;

    if (!await _validatePassword(db, password)) {
      throw ArgumentError("Invalid password");
    }

    // save accounts to have names stored when re-creating them
    // TODO: test this again
    final savedAccounts = await accounts;

    await deleteWallet(this.id, db, false);

    _accounts = <Account>[];

    int accountNo = 0;
    int lastSavedAccountNo = 0;

    String mnemonic = await getMnemonic(password);
    final masterNode = Bitbox.HDNode.fromSeed(Bitbox.Mnemonic.toSeed(mnemonic + password), testnet);

    await _saveAccount(db, 0, savedAccounts.length > 0 ? savedAccounts[0].name : null,
      masterNode.derivePath("$derivationPath/$accountNo'").toXPub());

    BchWallet.setTestNet(testnet);

    List<Bitbox.HDNode> accountNodes = <Bitbox.HDNode>[];

    final transactionList = <String>[];
    final allAddresses = <String, int>{};
//    List<Map<String, dynamic>> addressTransactions = [];

    do {
      accountNodes.add(masterNode.derivePath("$derivationPath/$accountNo'"));

      for (int change = 0; change <= 1; change++) {
        List<Address> checkedAddresses = <Address>[];
        List<String> addressesToFetch = List<String>(10);

        int lastUsedChildNo;
        int startChildNo = 0;
        bool repeat = true;

        do {
          checkedAddresses.length = startChildNo + 10;
          for (int i = 0; i < 10; i++) {
            final child = accountNodes[accountNo].derive(change).derive(i + startChildNo);

            addressesToFetch[i] = child.toCashAddress();
          }

          final addressDetails = await Bitbox.Address.details(addressesToFetch, false) as List;

          for (int i = 0; i < 10; i++) {
            final childNo = i + startChildNo;

            checkedAddresses[childNo] = Address.fromJson(addressDetails[i], childNo, id, accountNo, change == 1);

            (addressDetails[i]["transactions"] as List).forEach((txid) {
              if (!transactionList.contains(txid)) {
                transactionList.add(txid);
              }
            });

            if (addressDetails[i]["txApperances"] > 0 || addressDetails[i]["unconfirmedBalance"] > 0) {
              lastUsedChildNo = childNo;
            } else if (lastUsedChildNo == null && i < 4) {
              continue;
            } else if ((lastUsedChildNo == null && i == 4) || childNo - lastUsedChildNo == 5) {
              repeat = false;
              break;
            }
          }
          startChildNo += 10;
        } while (repeat);

        if (lastUsedChildNo == null) {
          break;
        } else if (accountNo > 0) {
          for (int accountNoToSave = lastSavedAccountNo + 1; accountNoToSave <= accountNo; accountNoToSave++) {
            //TODO: add old account name instead of wallet name here
            final accountName = savedAccounts.length > accountNoToSave ? savedAccounts[accountNoToSave].name : null;
            await _saveAccount(db, accountNoToSave, accountName, accountNodes[accountNoToSave].toXPub());
          }

          lastSavedAccountNo = accountNo;
        }

        final addresses = await _accounts[accountNo].addresses;

        for (int childNo = 0; childNo <= lastUsedChildNo; childNo++) {
          final address = checkedAddresses[childNo];
          address.id = await db.insert("address", {
            "wallet_id": address.walletId,
            "account_no": address.accountId,
            "change": address.change,
            "child_no": address.childNo,
            "cash_addr": address.cashAddr,
            "balance": address.balance
          });

          addresses.add(address);
          allAddresses[address.cashAddr] = address.id;
        }
      }
      accountNo++;
    } while (accountNo <= lastSavedAccountNo + 2);

    final transactions = [];
    final txToFetch = <String>[];
    for (int i = 0 ; i < transactionList.length; i++) {
      txToFetch.add(transactionList[i]);
      if (txToFetch.length == 10 || i == transactionList.length - 1) {
        transactions.addAll(await Bitbox.Transaction.details(txToFetch));
        txToFetch.clear();
      }
    };

    for (int i = 0; i < transactions.length; i++) {
      final tx = transactions[i];
      int txnId;

      final query = await db.query("txn", columns: ["id"], where: "txid = ? AND wallet_id = ?",
        whereArgs: [tx["txid"], id]);

      if (query.length > 0) {
        txnId = query.first["id"];
      } else {
        txnId = await db.insert("txn", {
          "wallet_id" : id,
          "txid": tx["txid"],
          "time": tx["time"] * 1000
        });
      }

      final addressList = allAddresses.keys;
      for (int j = 0; j < (tx["vin"] as List).length; j++) {
        final cashAddr = tx["vin"][j]["cashAddress"];
        if (addressList.contains(cashAddr)) {
          await db.insert("txn_address", {
            "txn_id": txnId,
            "address_id": allAddresses[cashAddr],
            "value": tx["vin"][j]["value"] * -1,
          });
        }
      }

      for (int j = 0; j < (tx["vout"] as List).length; j++) {
        final cashAddr = tx["vout"][j]["scriptPubKey"]["cashAddrs"].first;
        if (addressList.contains(cashAddr)) {
          await db.insert("txn_address", {
            "txn_id": txnId,
            "address_id": allAddresses[cashAddr],
            "value": BchWallet.toSatoshi(double.parse(tx["vout"][j]["value"])),
          });
        }
      };
    };
  }

  Future<List<Account>> _getAccounts(sql.Database db) async {
    final result = await db.query("account", where: "wallet_id = $id");

    _accounts = List.generate(result.length, (i) {
      return Account.fromDbRow(result[i]);
    });

    return _accounts;
  }

  Future<Account> _createAccount(sql.Database db, String password, String name) async {
    if (this.passwordProtected && password == null || password.length == 0) {
      throw ArgumentError("Wallet is password protected and the password was not provided. "
        "An account cannot be created without the password");
    } else {
      if (!await _validatePassword(db, password)) {
        throw ArgumentError("Password incorrect");
      }
    }

    await _getAccounts(db);
    var accountNo = _accounts.last.number + 1;

    String mnemonic = await getMnemonic(password);
    final seed = Bitbox.Mnemonic.toSeed(mnemonic + password);
    final accountNode = Bitbox.HDNode.fromSeed(seed, testnet).derivePath("$derivationPath/$accountNo'");

    await _saveAccount(db, accountNo, name, accountNode.toXPub());

    return _accounts.last;
  }

  _saveAccount(sql.Database db, int accountNo, String name, String xPub) async {
    await db.insert('account', {
      'wallet_id': id,
      'account_no': accountNo,
      'name': name,
      'xpub': xPub
    });

    _accounts.add(Account(accountNo, id, name));
  }

  Future<bool> _validatePassword(sql.Database db, password) async {
    if (!passwordProtected) {
      throw Exception("Wallet is not password protected");
    }
    return sha256.convert(utf8.encode(password)).toString() == await _getPasswordHash(db);
  }

  Future<String> _getPasswordHash(sql.Database db) async {
    return (await db.query("wallet", columns: ["password_hash"], where: "id = $id")).first["password_hash"];
  }

  Future<String> _getMnemonic(sql.Database db, String password) async {
    if (passwordProtected && (password == null || !await _validatePassword(db, password))) {
      throw Exception("Incorrect password");
    }

    final storage = FlutterSecureStorage();
    final mnemonic = await storage.read(key: "${_mnemonicStorageKey}_$id");
    return mnemonic;
  }

  _setRestUrl() {
    Bitbox.Bitbox.setRestUrl(testnet ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);
  }

}