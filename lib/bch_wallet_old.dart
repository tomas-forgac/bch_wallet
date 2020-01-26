library bch_wallet;

import 'dart:convert';

import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'account.dart';
import 'src/address.dart';

class BchWalletOld {
  static Database _db;
  static const _db_name = "flutter_bch_wallet";
  
  // Using legacy account path here because it's used by Bitcoin.com wallet.
  // Change to m/44'/145'/0'/0 if you want compatibility with other wallets
  static const _accountsDerivationPath = "m/44'/0'/0'";

  static const _accountsSharedPrefsKey = "accounts";
  static const _accountAddressesKey = "_addresses";
  static const _lastIndexPrefsKey = "last_index";
  static const _spentAddressesKey = "spent_addresses";
  static const _isTestnetKey = "is_testnet";

  static const _mnemonicStorageKey = "mnemonic";
  static const _xPubStorageKey = "master_public_key";

  static String createMnemonic() {
    return Bitbox.Mnemonic.generate();
  }

  /// Creates a new wallet, writes its private and public metadata in the
  /// keystore or shared preferences and returns the mnemonic as a list of words
  /// TODO: add note about password not being saved
  static createWallet(String mnemonic, String password,
      {bool testnet = false, String defaultAccountName, String accountDerivationPath = _accountsDerivationPath}) async {
    // generate a random mnemonic and convert it to seed
    final seed = Bitbox.Mnemonic.toSeed(mnemonic + password);

    // create an account HD Node from the seed and derivation path
    Bitbox.HDNode masterNode = Bitbox.HDNode.fromSeed(seed, testnet);

    // access the keystoire and write account private key and mnemonic to it
    final storage = FlutterSecureStorage();
    storage.write(key: _mnemonicStorageKey, value: mnemonic);
    storage.write(key: _xPubStorageKey, value: mnemonic);

    (await SharedPreferences.getInstance()).setBool(_isTestnetKey, testnet);

    addAccount(defaultAccountName);
  }

  static Future<Account> addAccount([String name]) async {
    final db = await _getDatabase();
    final nameSqlValue = name == null ? "null" : "'$name'";
    db.execute("INSERT INTO Accounts (name) VALUES ($nameSqlValue)");

    final accountNo = Sqflite.firstIntValue(await db.rawQuery('SELECT last_insert_rowid()'));
    
    return Account(accountNo, name);
  }

  /// Returns the current address for receiving payments
  static Future<Address> getAccountAddress(int accountNo) async {
    RangeError.checkNotNegative(accountNo, "accountNo", "accountNo cannot be negative");
    
    final db = await _getDatabase();

    final accountQuery = await db.query("Accounts", where: "id = ?", whereArgs: [accountNo]);
    if (accountQuery.length == 0) {
      throw ArgumentError("account $accountNo doesn't exist");
    }

    final account = Account.fromMap(accountQuery.first);

    final addresses = await db.query("Addresses", where: "account_no = ? AND balance = 0 AND spent = FALSE",
      orderBy: "child_no DESC", whereArgs: [accountNo], limit: 1);

    if ((addresses is List) && addresses.length > 0 ) {
      final address = addresses.first;
      final detail = await Bitbox.Address.details(address["cash_address"]);
      if (detail["totalReceivedSat"] == 0) {
        return Address(address["child_no"], address["cash_address"], 0);
      } else {
        _addUsedAddress(detail);
      }
    }

    Address address;
    int index = 0;

    if (lastAddress != null && lastAddress.childNo > account.lastUsedChildNo) {
      final balance = await getAddressBalance(lastAddress.cashAddr);
      if (balance["unconfirmed"] == 0 && balance["confirmed"] == 0) {
        return lastAddress;
      } else {
        lastAddress.balance = balance["confirmed"] + balance["unconfirmed"];
        addresses[address.childNo] = lastAddress.toString();
      }
      index = lastAddress.childNo;
      address = lastAddress;
    }

    final xPub = await FlutterSecureStorage().read(key: _xPubStorageKey);
    final accountXPub =  _deriveAccountXPub(xPub, accountNo);

    try {
      if (account.lastUsedChildNo != null) {
        index += account.lastUsedChildNo;
      }
    } catch (e) {
      throw ArgumentError("Account no. $accountNo does not exist");
    }

    do {
      final cashAddr = generateAddress(accountXPub, index);
      final balance = await getAddressBalance(cashAddr);

      address = Address(index, cashAddr, balance["confirmed"] + balance["unconfirmed"]);

      _storeAddress(prefs, accountNo, address);

      if (address.balance > 0) {
        index++;
      }
    } while (address.balance > 0);

    return address;
  }

  /// Simple helper to generate a child address address from an extended public key.
  static String generateAddress(String xPub, int childNo) {
    final hdNode = Bitbox.HDNode.fromXPub(xPub).derive(childNo);
    return hdNode.toCashAddress();
  }

  /// Checks address' balance (confirmed + unconfirmed) using Bitbox API and returns the value in satoshis
  static Future<Map<String, int>> getAddressBalance(String address) async {
    final addressInfo = await Bitbox.Address.details(address);

    return {
      "confirmed": addressInfo["balanceSat"],
      "unconfirmed": addressInfo["unconfirmedBalanceSat"]
    };
  }

  // Get details of a single address provided as a String or addresses provided as List of Strings
  static Future<dynamic> getAddressDetails(dynamic addresses) async {
    // check if single address or more addresses were provided
    if (addresses is String) {
      // request the details
      final details = await Bitbox.Address.details(addresses) as Map<String, dynamic>;
      // create a single Address instance to return
      final address = Address(null, addresses, details["balanceSat"] + details["unconfirmedBalanceSat"]);
      // add Map with details to the Address object
      address.detailsJson = details;
      // return the address
      return address;
    } else if (addresses is List<String>) {
      // request the details for list of addresses
      final detailsList = await Bitbox.Address.details(addresses, false) as List<Map<String, dynamic>>;
      // create an empty List of Address as a placeholder for returned list of address details
      final addressList = <Address>[];
      // iterate through the returned list to create list of Address instances
      detailsList.forEach((details) {
        // create new Address with basic details filled in
        final address = Address(null, details["cashAddress"], details["balanceSat"] + details["unconfirmedBalanceSat"]);
        // add details from the API
        address.detailsJson = details;
        // add the Address to the list to be returned
        addressList.add(address);
      });
      // return the list
      return addressList;
    } else {
      // if the provided parameter was neither List nor String, return null (maybe exception would make more sense)
      return null;
    }
  }

  /// Returns balance as stored in shared preferences during a use of the plugin.
  /// To check against potential manipulation with the stored wallet,
  /// do checks against blockchain using [getBlokchainBalance]
  static int getStoredBalance(SharedPreferences prefs) {
    final addresses = _getAddresses(prefs);

    int totalBalance = 0;

    addresses.forEach((address) {
      totalBalance += address.balance;
    });

    return totalBalance;
  }

  static Future<int> getMaxSendable(int account, {includeUnspent = false}) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    final unspentAddresses = _getAddresses(prefs);

    final utxosToFetch = <String>[];
    int inputsCount = 0;
    int utxoAmount = 0;

    unspentAddresses.forEach((address) {
      utxosToFetch.add(address.cashAddr);
    });

    final utxoList = Bitbox.Address.utxo(utxosToFetch, false) as List<Map>;

    for (int i = 0; i < utxoList.length; i++) {
      utxoList[i]["utxos"].forEach((Bitbox.Utxo utxo) {
        if (includeUnspent == true || utxo.confirmations > 0) {
          inputsCount++;
          utxoAmount += utxo.satoshis;
        }
      });
    };

    final fee = Bitbox.BitcoinCash.getByteCount(inputsCount, 1);

    return utxoAmount - fee;
  }

  static Future<int> calculateFee(int account, {int amountToSend, outputsNo = 1, includeUnspent = false}) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    final unspentAddresses = _getAddresses(prefs);

    final utxosToFetch = <String>[];
    unspentAddresses.forEach((address) {
      utxosToFetch.add(address.cashAddr);
    });

    int inputsCount = 0;
    int utxoAmount = 0;

    final utxoList = Bitbox.Address.utxo(utxosToFetch, false) as List<Map>;

    for (int i = 0; i < utxoList.length; i++) {
      utxoList[i]["utxos"].forEach((Bitbox.Utxo utxo) {
        if ((amountToSend == null || utxoAmount < amountToSend)
          && (includeUnspent == true || utxo.confirmations > 0)) {
          inputsCount++;
          utxoAmount += utxo.satoshis;
        }
      });

      if (amountToSend != null && utxoAmount >= amountToSend) {
        break;
      }
    };

    final fee = Bitbox.BitcoinCash.getByteCount(inputsCount, outputsNo);

    return fee;
  }

  /// Sends balance from wallet to the provided outputs and returns txid.
  ///
  /// If you want to send arbitrary amount from the [account] to one or multiple addresses,
  /// define them in [outputs] as [List] of [Map], e.g.:
  /// ...
  /// [
  ///    {
  ///      "address": "bitcoincash:qrfw0q8smpc6z4mqyvhs6nuwn9xzmpljygqse3nw0h",
  ///      "amount": 10000000
  ///    },
  ///    {
  ///      "address": "bitcoincash:qrz2tg3fewquc5kasw62akfc2tn420lr7sufm9wy9p",
  ///      "amount": 5000000
  ///    }
  /// ]
  /// ...
  /// If you want to send whole balance of the [account] to one address, provide it in [sendAllToAddress].
  ///
  /// If neither [outputs] nor [sendAllToAddress] is defined, throws [ArgumentError]
  /// If both [outputs] and [sendAllToAddress] is defined, throws [ArgumentError]
  /// If any of the provided addresses is of different network, throws [ArgumentError]
  static Future<String>  send(int account, {List<Map<String, dynamic>> outputs, String sendAllToAddress, String password, double feePerByte = 1.0}) async
  {
    if (!(outputs is List && outputs.length > 0) && !(sendAllToAddress is String)) {
      throw ArgumentError("List of outputs or a single address to withdraw whole balance must be provided");
    } else if (outputs != null && sendAllToAddress != null) {
      throw ArgumentError("Provide either list of outputs or address to send the whole balance, not both");
    }
    // app's shared preferences
    final prefs = await SharedPreferences.getInstance();

    int totalOutput = 0;
    bool sendMax = false;

    if (outputs is List && outputs.length > 0) {
      outputs.forEach((output) {
        if (!_checkNetwork(output["address"], prefs)) {
          throw ArgumentError("trying to send balance to the wrong network");
        }
        totalOutput += output["amount"];
      });
    } else if (sendAllToAddress is String) {
      sendMax = true;
    } else if (outputs != null && sendAllToAddress != null) {
      throw ArgumentError("Provide either list of outputs or address to send the whole balance, not both");
    } else if (outputs != null && sendAllToAddress != null) {
      throw ArgumentError("List of outputs or a single address to withdraw whole balance must be provided");
    }

    final builder = Bitbox.Bitbox.transactionBuilder(testnet: prefs.getBool(_isTestnetKey));

    final storage = FlutterSecureStorage();

    if (password != await storage.read(key: _passwordStorageKey)) {
      throw("Invalid password");
    }

    // get balance data
//    final balance = getStoredBalance(prefs);

    // list of wallet's un-withdrawn addresses
    final addressList = _getAddresses(prefs);

    // accumulate list of addresses for the bitbox plugin
    Map<int, String> inputAddresses = {};

    // store balance in these addresses here to check against required amount
    int cumulativeBalance = 0;

    // go through the list of address data to store the addresses and to check when the balance is sufficient
    for (int i = 0; i < addressList.length; i++) {
      // add the cash address to the list of addresses to get utxos for
      inputAddresses[addressList[i].childNo] = addressList[i].cashAddr;

      // add addresses balance to the cumulative balance available
      cumulativeBalance += addressList[i].balance;
      // when the amount in the addresses has reached the amount needed, stop
      if (!sendMax && cumulativeBalance >= totalOutput) {
        break;
      }
    }

    // get account extended private key from the device's keystore
    final xPriv = await storage.read(key: _xprivStorageKey);
    // create account HD node
    final node = Bitbox.HDNode.fromXPriv(xPriv);

    // get utxos for the addresses selected for withdrawal request
    final utxo = await Bitbox.Address.utxo(inputAddresses.values.toList(), true);

    // accumulate input and signature data in these
    List<Map> signatures = <Map>[];
    int vin = 0;
    int totalInput = 0;

    // iterate through the list of input addresses to provide utxos and signatures
    inputAddresses.forEach((childNo, address) {
      final childNode = node.derive(childNo);
      final keyPair = childNode.keyPair;

      // Get utxo details
      final txs = utxo[address] as List<Bitbox.Utxo>;
      // go through the utxo list
      txs.forEach((Bitbox.Utxo utxo) {
        // add all addresses utxos as inputs to the transaction
        if (utxo.confirmations > 0) {
          builder.addInput(utxo.txid, utxo.vout);
          // add signature data
          signatures.add({
            "vin"     : vin++,
            "keyPair" : keyPair,
            "value"   : utxo.satoshis
          });

          totalInput += utxo.satoshis;
        }
      });
    });

    int changeAmount = 0;

    if (sendAllToAddress != null) {
      final feeWithoutChange = Bitbox.BitcoinCash.getByteCount(vin, outputs.length);

      // if total input from utxos is larger than balance to withdraw, throw an error;
      // this should never happen, but just in case
      if (totalInput < totalOutput + feeWithoutChange) {
        throw("Insufficient balance");
      }

      final feeWithChange = Bitbox.BitcoinCash.getByteCount(
        vin, outputs.length + 1);

      if (totalInput > totalOutput + feeWithChange) {
        changeAmount = totalInput - totalOutput - feeWithChange;
      }
    } else {
      final feeWithoutChange = (Bitbox.BitcoinCash.getByteCount(vin, 1) * feePerByte).ceil();
      outputs = [{
        "address" : sendAllToAddress,
        "amount" : totalInput - feeWithoutChange
      }];
    }

    // add all outputs to the txn builder
    outputs.forEach((output) {
      builder.addOutput(output["address"], output["amount"]);
    });

    Address changeAddress;

    if (changeAmount > 0) {
      changeAddress = getAccountAddress(prefs);
      builder.addOutput(changeAddress.cashAddr, changeAmount);
    }

    signatures.forEach((signature) {
      builder.sign(signature["vin"], signature["keyPair"], signature["value"]);
    });

    final tx = builder.build();

    String txid = await Bitbox.RawTransactions.sendRawTransaction(tx.toHex());

    if (txid is String) {
      if (changeAmount > 0) {
        changeAddress.unconfirmedBalance = changeAmount;

        prefs.setInt(_lastIndexPrefsKey, changeAddress.childNo);
      }

      _moveSpentAddresses(inputAddresses.values.toList(), changeAddress, prefs);
    }

    return txid;
  }

  static deleteWallet() async {
    final storage = FlutterSecureStorage();
    storage.delete(key: _mnemonicStorageKey);
    storage.delete(key: _xprivStorageKey);
    storage.delete(key: _passwordStorageKey);

    final prefs = await SharedPreferences.getInstance();
    prefs.remove(_addressesKey);
    prefs.remove(_xpubSharedPrefsKey);
    prefs.remove(_lastIndexPrefsKey);
    prefs.remove(_spentAddressesKey);
  }

  static Future<Database> _getDatabase() async {
    if (!(_db is Database)) {
      _db = await openDatabase(_db_name, onCreate: _createDatabase);
    }

    return _db;
  }

  static _createDatabase(Database db, int version) async {
    await db.execute("CREATE TABLE Accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, last_child_no INTEGER)");
    await db.execute("CREATE TABLE Addresses (account_no INTEGER NOT NULL, child_no INTEGER NOT NULL, cash_addr TEXT NOT NULL, "
      + "balance INTEGER not NULL, spent BOOLEAN DEFAULT FALSE NOT NULL, PRIMARY KEY(account_no, child_no))");
  }

  static List<Address> _getAddresses(SharedPreferences prefs) {
    final addressJsonList = prefs.getStringList(_addressesKey);

    final addressList = <Address>[];
    addressJsonList.forEach((addressJson) {
      addressList.add(Address.fromMap(jsonDecode(addressJson)));
    });

    return addressList;
  }

  static String _deriveAccountXPub(String xPub, int accountNo) {
    return Bitbox.HDNode.fromXPub(xPub).derivePath("$_accountsDerivationPath/$accountNo").toXPub();
  }

  static _storeAddress(SharedPreferences prefs, int accountNo, Address address) {
    final addresses = prefs.getStringList("$accountNo$_accountAddressesKey");
    addresses[address.childNo] = address.toString();

    prefs.setStringList("$accountNo$_accountAddressesKey", addresses);
  }

  static _updateLastUsedChildNo(SharedPreferences prefs, int accountNo, int childNo) {
    final accounts = prefs.getStringList(_accountsSharedPrefsKey);
    final account = Account.fromMap(jsonDecode(accounts[accountNo]));
    account.lastUsedChildNo = childNo;
    accounts[childNo] = account.toString();
    prefs.setStringList(_accountsSharedPrefsKey, accounts);
  }

  /// Move all withdrawn addresses to a separate string list.
  /// This is to organize spent and unspent addresses and to make the blockchain balance checking faster.
  static _moveSpentAddresses(List<String> spentAddresses, Address changeAddress, SharedPreferences prefs) {
    // get the existing list of addresses
    final addressList = _getAddresses(prefs);

    // placeholders for lists of unspent and spent addresses
    final unspentList = <String>[];
    List<String> spentList = prefs.getStringList(_spentAddressesKey);

    if (spentList == null) {
      spentList = <String>[];
    }


    // compare the full list of addresses with the provided list of withdrawn addresses
    addressList.forEach((address) {
      // check if the address was spent by comparing it with the list of withdrawn addressess
      if (spentAddresses.contains(address.cashAddr)) {
        // add the empty address to the list of spent addresses
        spentList.add(jsonEncode({"child_no" : address.childNo, "address" : address.cashAddr}));
      } else {
        // if this address wasn't spent, create its copy, but move all its balance to either tips or sales
        final newAddress = Address(address.childNo, address.cashAddr, address.balance);

        // add it to the respective list
        unspentList.add(newAddress.toString());
      }
    });

    // if the change address has been defined, add it
    if (changeAddress is Address) {
      unspentList.add(changeAddress.toString());
    }

    // rewrite both unspent and spent address lists in the shared preferences data
    prefs.setStringList(_addressesKey, unspentList);
    prefs.setStringList(_spentAddressesKey, spentList);
  }

  static Future<Map> _getUnspentDataFromBlockchain() async {
    final prefs = await SharedPreferences.getInstance();
    final addressStringList = prefs.getStringList(_addressesKey);

    final addresses = <String>[];
    final addressList = <Address>[];

    if (addressStringList != null) {
      addressStringList.forEach((addressJson) {
        final address = Address.fromMap(jsonDecode(addressJson));

        addresses.add(address.cashAddr);
        addressList.add(address);
      });
    }

    final addressUtxos = await Bitbox.Address.utxo(addresses);

    Map balance = {"confirmed" : 0, "unconfirmed" : 0};

    bool updateAddressList = false;
    for (int i = 0; i < addressList.length; i++) {
      if (addressUtxos[i]["cashAddress"] == addressList[i].cashAddr) {
        int confirmedBalance = 0;
        int unconfirmedBalance = 0;
        addressUtxos[i]["utxos"].forEach((Bitbox.Utxo utxo) {
          if (utxo.confirmations > 0) {
            confirmedBalance += utxo.satoshis;
          } else {
            unconfirmedBalance += utxo.satoshis;
          }
        });

        if (confirmedBalance + unconfirmedBalance != addressList[i].balance) {
          final updatedAddress = Address(
            addressList[i].childNo,
            addressList[i].cashAddr,
            confirmedBalance + unconfirmedBalance,
            confirmedBalance,
            unconfirmedBalance
          );

          addressList[i] = updatedAddress;

          updateAddressList = true;
        }

        balance["confirmed"] += confirmedBalance;
        balance["unconfirmed"] += unconfirmedBalance;
      }
    }

    // if it's necessary to update the stored addresses list due to a different balance at some address
    if (updateAddressList) {
      // create an empty string list
      final updatedAddressList = <String>[];
      final spentAddressList = <String>[];
      // generate a json from each address including the updated ones
      addressList.forEach((address) {
        final addressJson = jsonEncode(address.toJson());
        if (address.balance > 0) {
          updatedAddressList.add(addressJson);
        } else {
          spentAddressList.add(jsonEncode({"child_no" : address.childNo, "address" : address.cashAddr}));
        }
      });

      // store the json string list to the shared preferences
      prefs.setStringList(_addressesKey, updatedAddressList);

      if (spentAddressList.length > 0) {
        final currentSpentList = prefs.getStringList(_spentAddressesKey) ?? <String>[];

        spentAddressList.forEach((spentAddress) {
          currentSpentList.add(spentAddress);
        });

        prefs.setStringList(_spentAddressesKey, currentSpentList);
      }
    }

    return {
      "address_utxos" : addressUtxos,
      "balance" : balance
    };
  }

  // checks if the provided address matches the stored wallet's network (testnet vs. mainnet)
  static _checkNetwork(String address, SharedPreferences prefs) {
    final walletIsTestnet = prefs.getBool(_isTestnetKey);

    bool addressIsTestnet;
    if (address.startsWith(RegExp("(1|3|bitcoincash\:)"))) {
      addressIsTestnet = false;
    } else if (address.startsWith(RegExp("(m|n|2|bchtest\:)"))) {
      addressIsTestnet = true;
    } else {
      throw FormatException("Unkwnown format: $address");
    }

    if (walletIsTestnet == addressIsTestnet) {
      return true;
    } else {
      return false;
    }
  }
}

