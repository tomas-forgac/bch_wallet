import 'dart:convert';

import 'package:bch_wallet/bch_wallet.dart';
import 'utils/database.dart';
import 'package:bch_wallet/src/utils/utils.dart' as utils;
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:crypto/crypto.dart';

import 'account.dart';

/// Stores data about and provides function to work with a wallet. The app can have multiple wallets, each with their
/// own recovery seed phrase, optionally protected by a password.
///
/// Each wallet has at least one account created by default
class Wallet {
  /// wallet mnemonics will be stored referenced with this key + suffix
  static const _mnemonicStorageKey = "mnemonic";

  /// wallet's id - primary key in the internal database
  final int id;

  /// indicates if wallet is used in testnet
  final bool testnet;

  /// optional name of the wallet
  String name;

  /// derivation path from which accounts are directly derived
  final String derivationPath;

  /// flag if the wallet is password protected (password will be checked in the relevant calls)
  final bool passwordProtected;

  /// asynchronous getter for a list of [Account] instances. Calls the db if hasn't been called before
  Future<List<Account>> get accounts async => _accounts ?? await _getAccounts(await Database.database);

  // private storage of account instances
  List<Account> _accounts;

  Wallet(this.id, this.testnet, this.passwordProtected, this.derivationPath, [this.name]);

  /// Retrieve wallet's mnemonic from the secure storage
  Future<String> getMnemonic([String password]) async => _getMnemonic(await Database.database, password);

  /// Create a new account, stores it in the db, adds to the [accounts] list, and returns its [Account] instance
  Future<Account> createAccount(String name, {String password}) async =>
    _createAccount(await Database.database, password, name);

  /// Returns an account.
  /// If you work with just one account for each wallet, simply call this without a parameter to work with the account
  Future<Account> getAccount([int accountNo = 0]) async {
    _accounts ?? await _getAccounts(await Database.database);

    if (accountNo < 0 || accountNo > _accounts.length - 1) {
      throw RangeError("Account $accountNo doesn't exist");
    }

    return _accounts[accountNo];
  }

  /// validates whether the provided password is correct
  Future<bool> validatePassword(String password) async => _validatePassword(await Database.database, password);

//  rename(String newName) async {
    // TODO
//  }

  /// If for some reason the wallet's internal ledger is corrupted (due to some bug perhaps), this should rebuild it
  /// from scratch.
  ///
  /// It will search for used accounts until two in a row are not used. It will search for used primary and change
  /// addresses until 5 in a row are not used.
  rebuildHistory(String password) async {
    final db = await Database.database;

    if (passwordProtected == true && !await _validatePassword(db, password)) {
      throw ArgumentError("Invalid password");
    }

    // save accounts to have names stored when re-creating them
    final savedAccounts = await accounts;

    // first delete all the wallet data except of the wallet table record
    await utils.deleteWallet(this.id, db, false);

    // start a new list of accounts
    _accounts = <Account>[];

    int accountNo = 0;
    int lastSavedAccountNo = 0;

    // create a master node from seed mnemonic in order to re-create all the accounts
    String mnemonic = await getMnemonic(password);
    final masterNode = Bitbox.HDNode.fromSeed(Bitbox.Mnemonic.toSeed(mnemonic + (password ?? "")), testnet);

    // first account is always generated
    await _saveAccount(db, 0, savedAccounts.length > 0 ? savedAccounts[0].name : null,
      masterNode.derivePath("$derivationPath/$accountNo'").toXPub());

    utils.setTestNet(testnet);

    List<Bitbox.HDNode> accountNodes = <Bitbox.HDNode>[];

    // this will store a reference of all used addresses and their transactions to save the transactions more
    // efficiently later
    final transactionList = <String>[];
    final allAddresses = <String, int>{};

    do {
      accountNodes.add(masterNode.derivePath("$derivationPath/$accountNo'"));

      // find all used addresses on both primary and change paths
      for (int change = 0; change <= 1; change++) {
        // placeholder for all addresses with details retrieved from the API
        List<Address> checkedAddresses = <Address>[];

        // list to be provided to the API to retrieve the address details
        List<String> addressesToFetch = List<String>(10);

        // this will keep track of last used address to determine when to stop searching and saving
        int lastUsedChildNo;
        // this will keep track of a position in the account with every cycle of api call and parsing details
        int startChildNo = 0;
        // flag whether to continue generating more addresses
        bool repeat = true;

        do {
          // make room for additional 10 addresses to be stored
          checkedAddresses.length = startChildNo + 10;

          // generate 10 addresses to be checked (maximum the API allows)
          for (int i = 0; i < 10; i++) {
            // generate a child node
            final child = accountNodes[accountNo].derive(change).derive(i + startChildNo);
            // add the address to the list to fetch from Bitbox
            addressesToFetch[i] = child.toCashAddress();
          }

          // get details of the populated addresses from Bitbox
          final addressDetails = await Bitbox.Address.details(addressesToFetch, false) as List;

          // now go through the list of the retrieved address details
          for (int i = 0; i < 10; i++) {
            final childNo = i + startChildNo;

            // create instance of Address and add it to the list of all checked addresses to be used later
            checkedAddresses[childNo] = Address.fromJson(addressDetails[i], childNo, id, accountNo, change == 1);

            // add all the distinct transactions the address was used in to the list, that will be used later
            (addressDetails[i]["transactions"] as List).forEach((txid) {
              if (!transactionList.contains(txid)) {
                transactionList.add(txid);
              }
            });

            // check if the address has bee nused
            if (addressDetails[i]["txApperances"] > 0 || addressDetails[i]["unconfirmedBalance"] > 0) {
              // if yes, update the lastUsedChildNo
              lastUsedChildNo = childNo;
            } else if (lastUsedChildNo == null && i < 4) {
              // if it hasn't, but it's only one of the first four addresses, carry on
              continue;
            } else if ((lastUsedChildNo == null && i == 4) || childNo - lastUsedChildNo == 5) {
              // if five in a row haven't been used, stop generating more addresses in this account and change branch
              repeat = false;
              break;
            }
          }
          // increae a start childno by 10 for the next cycle
          startChildNo += 10;
        } while (repeat);

        if (lastUsedChildNo == null) {
          // if no address has been found as used, go to the next account
          break;
        } else if (accountNo > 0) {
          // if this is not the first account (which was already saved), save this account and also a previous one in
          // case that one was found as unused, but needs to be saved since the next one is used and to be saved
          for (int accountNoToSave = lastSavedAccountNo + 1; accountNoToSave <= accountNo; accountNoToSave++) {
            // get the account name from the previously saved account list
            final accountName = savedAccounts.length > accountNoToSave ? savedAccounts[accountNoToSave].name : null;
            // save account to the db
            await _saveAccount(db, accountNoToSave, accountName, accountNodes[accountNoToSave].toXPub());
          }

          // note the number of this account for later reference
          lastSavedAccountNo = accountNo;
        }

        // this is now an empty list of addressess, which will be filled
        final addresses = await _accounts[accountNo].addresses;

        // go through the list of all checked addresses until the last one that was recorded as used.
        for (int childNo = 0; childNo <= lastUsedChildNo; childNo++) {
          final address = checkedAddresses[childNo];
          // save the address to db and udpate its returned id
          address.id = await db.insert("address", {
            "wallet_id": address.walletId,
            "account_no": address.accountNo,
            "change": address.change,
            "child_no": address.childNo,
            "cash_addr": address.cashAddr,
            "balance": address.balance
          });

          // add the address to the list in the account
          addresses.add(address);
          // note the address to the reference map to use in transaction saving part of the function
          allAddresses[address.cashAddr] = address.id;
        }
      }
      // move on to the next account
      accountNo++;
    } while (accountNo <= lastSavedAccountNo + 2); // if two accounts in the row were not used, stop

    // placeholder for storing the list of transactions
    final transactions = [];
    // placeholder for a list of transactions to fetch
    final txToFetch = <String>[];

    // go through the list of transactions populated from all account's used addresses to get their details
    for (int i = 0 ; i < transactionList.length; i++) {
      // add txid to the list to fetch
      txToFetch.add(transactionList[i]);
      // to maximize efficiency of the API calls, wait until there's 10 of the txids before making the call
      if (txToFetch.length == 10 || i == transactionList.length - 1) {
        // fetch the transactions and add them to the list to be worked with later
        transactions.addAll(await Bitbox.Transaction.details(txToFetch));
        txToFetch.clear();
      }
    }

    // list of addressess to search in during the following loop
    final addressList = allAddresses.keys;

    // go through the list of all the populated transaction details
    for (int i = 0; i < transactions.length; i++) {
      final tx = transactions[i];
      int txnId;

      // check if the transaction exists in the database (it might if was transferring from one account to another)
      final query = await db.query("txn", columns: ["id"], where: "txid = ? AND wallet_id = ?",
        whereArgs: [tx["txid"], id]);

      if (query.length > 0) {
        txnId = query.first["id"];
      } else {
        // save the transaction and retrieve its db id
        txnId = await db.insert("txn", {
          "wallet_id" : id,
          "txid": tx["txid"],
          "time": tx["time"] * 1000
        });
      }

      // go through the list of transaction inputs and try to find if any of them matches one of the account's addresses
      for (int j = 0; j < (tx["vin"] as List).length; j++) {
        final cashAddr = tx["vin"][j]["cashAddress"];
        if (addressList.contains(cashAddr)) {
          // if the matching address was found, save the record of this transaction related to the address and account
          await db.insert("txn_address", {
            "txn_id": txnId,
            "address_id": allAddresses[cashAddr],
            "value": tx["vin"][j]["value"] * -1,
          });
        }
      }

      // now do the same thing with the outputs
      for (int j = 0; j < (tx["vout"] as List).length; j++) {
        if (tx["vout"][j]["scriptPubKey"]["cashAddrs"] is List) {
          final cashAddr = tx["vout"][j]["scriptPubKey"]["cashAddrs"].first;
          if (addressList.contains(cashAddr)) {
            await db.insert("txn_address", {
              "txn_id": txnId,
              "address_id": allAddresses[cashAddr],
              "value": BchWallet.toSatoshi(
                double.parse(tx["vout"][j]["value"])),
            });
          }
        }
      }
    }
  }

  // retrieve a list of accounts saved in db
  Future<List<Account>> _getAccounts(sql.Database db) async {
    final result = await db.query("account", where: "wallet_id = $id");

    _accounts = List.generate(result.length, (i) {
      return Account(result[i]["account_no"], result[i]["wallet_id"], result[i]["name"]);
    });

    return _accounts;
  }

  // create a new account. Password is necessary because of hardened derivation
  Future<Account> _createAccount(sql.Database db, String password, String name) async {
    if (this.passwordProtected) {
      if (password == null || password.length == 0) {
        throw ArgumentError("Wallet is password protected and the password was not provided. "
            "An account cannot be created without the password");
      } else {
        if (!await _validatePassword(db, password)) {
          throw ArgumentError("Password incorrect");
        }
      }
    }

    // this will update the list of accounts to work with
    await _getAccounts(db);
    // get the account number based on the last saved account
    var accountNo = _accounts.last.number + 1;

    // it is necessary to generate seed with hardened derivation
    String mnemonic = await getMnemonic(password);
    final seed = Bitbox.Mnemonic.toSeed(mnemonic + (password??""));
    final accountNode = Bitbox.HDNode.fromSeed(seed, testnet).derivePath("$derivationPath/$accountNo'");

    // save the account in thd db
    await _saveAccount(db, accountNo, name, accountNode.toXPub());

    // return the account instance
    return _accounts.last;
  }

  // save an account to the database
  _saveAccount(sql.Database db, int accountNo, String name, String xPub) async {
    await db.insert('account', {
      'wallet_id': id,
      'account_no': accountNo,
      'name': name,
      'xpub': xPub
    });

    // add the account to the object's list
    _accounts.add(Account(accountNo, id, name));
  }

  // validate a provided password against a hash stored in the database
  Future<bool> _validatePassword(sql.Database db, password) async {
    if (!passwordProtected) {
      throw Exception("Wallet is not password protected");
    }
    return sha256.convert(utf8.encode(password)).toString() == await _getPasswordHash(db);
  }

  // get wallet's password hash from the database
  Future<String> _getPasswordHash(sql.Database db) async {
    return (await db.query("wallet", columns: ["password_hash"], where: "id = $id")).first["password_hash"];
  }

  // get mnemonic from the secure storage. Password must be provided if the wallet is protected
  Future<String> _getMnemonic(sql.Database db, String password) async {
    if (passwordProtected && (password == null || !await _validatePassword(db, password))) {
      throw Exception("Incorrect password");
    }

    final storage = FlutterSecureStorage();
    final mnemonic = await storage.read(key: "${_mnemonicStorageKey}_$id");
    return mnemonic;
  }
}