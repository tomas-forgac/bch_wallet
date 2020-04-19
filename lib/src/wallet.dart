import 'dart:convert';

import 'package:bch_wallet/bch_wallet.dart';
import 'package:bch_wallet/src/database.dart';
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

//  Future<String> getXPub() async {
//    return BchWallet.getXPub(id, accountId);
//  }

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
    final savedAccounts = await accounts;

    _delete(this, db, false);
    _accounts = <Account>[];

    int accountNo = 0;
    int lastSavedAccountNo = 0;

    String mnemonic = await getMnemonic(password);
    final masterNode = Bitbox.HDNode.fromSeed(Bitbox.Mnemonic.toSeed(mnemonic + password), testnet);

    _saveAccount(db, 0, savedAccounts.length > 0 ? savedAccounts[0].name : null,
      masterNode.derivePath("$derivationPath/$accountNo'").toXPub());

    List<Bitbox.HDNode> accountNodes = <Bitbox.HDNode>[];
    do {
      accountNodes[accountNo] = masterNode.derivePath("$derivationPath/$accountNo'");

      for (int change = 0; change <= 1; change++) {
        List<Address> checkedAddresses = <Address>[];
        List<String> addressesToFetch = List<String>(10);

        int lastUsedChildNo;
        int startChildNo = 0;
        bool repeat = true;

        do {
          for (int childNo = startChildNo; childNo < startChildNo + 10; childNo++) {
            final child = accountNodes[accountNo].derive(change).derive(childNo);

            checkedAddresses[childNo] = Address(childNo, child.toCashAddress(), id, null, change == 1);

            addressesToFetch[childNo] = child.toCashAddress();
          }

          final addressDetails = await Bitbox.Address.details(
            addressesToFetch, false) as List;

          for (int childNo = startChildNo; childNo <
            startChildNo + 10; childNo++) {
            final details = addressDetails[childNo];
            if (details["txAppearances"] > 0) {
              lastUsedChildNo = childNo;
              checkedAddresses[childNo].unconfirmedBalance = details["unconfirmedBalanceSat"];
              checkedAddresses[childNo].confirmedBalance = details["balanceSat"];
            }

            if (childNo - lastUsedChildNo == 5) {
              repeat = false;
              break;
            }
          }
        } while (repeat);

        if (lastUsedChildNo == null) {
          break;
        } else {
          for (int accountNoToSave = lastSavedAccountNo + 1; accountNoToSave <= accountNo; accountNoToSave++) {
            if (_accounts.length <= accountNoToSave) {
              _saveAccount(db, accountNo, name, accountNodes[accountNoToSave].toXPub());
            }
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
        }
      }
      accountNo++;
    } while (accountNo <= lastSavedAccountNo + 2);

    for (int accountNo = 0; accountNo < _accounts.length; accountNo++) {
      List<String> txnDetailstoFetch = <String>[];
      (await _accounts[accountNo].addresses).forEach((address) {
        txnDetailstoFetch.add(address.cashAddr);

        if (txnDetailstoFetch.length == 10) {
          //TODO: continue here by fetching and populating transaction details
        }
      });

      // go through the populated transaction details and save them

    }
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

    _saveAccount(db, accountNo, name, accountNode.toXPub());

    return _accounts.last;
  }

  _saveAccount(sql.Database db, int accountNo, String name, String xPub) {
    db.insert('account', {
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
    Bitbox.Bitbox.setRestUrl(restUrl: testnet ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);
  }

  static _delete(Wallet wallet, sql.Database db, [bool withRecord = false, String password = null]) {
    db.rawDelete("DELETE FROM txn_address WHERE address_id IN (SELECT id FROM address WHERE wallet_id = ${wallet.id})");
    db.delete("txn", where: "wallet_id = ${wallet.id}");
    db.delete("address", where: "wallet_id = ${wallet.id}");
    db.delete("account", where: "wallet_id = ${wallet.id}");

    if (withRecord) {
      db.delete("wallet", where: "id = ${wallet.id}");
    }
  }
}