import 'package:bch_wallet/src/database.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;

import '../bch_wallet.dart';
import 'package:sqflite/sqflite.dart' as sql;

//TODO: rename account
class Account {
  final int number;
  final int walletId;
  final String name;
  String xPub;

  Future<List<Address>> get addresses async => _addresses ?? await _getAddresses(await Database.database);

  List<Address> _addresses;

  Account(this.number, this.walletId, [this.name]);

  Account.fromDbRow(row) :
    number = row["account_no"],
    walletId = row["wallet_id"],
    name = row["name"];

  Future<String> getXPub() async => _getXPub(await Database.database);

  Future<Address> getReceivingAddress() async => _getReceivingAddress(await Database.database);

  /// Returns account balance (confirmed + unconfirmed) in satoshis as recorded in the last balance update.
  /// In  most cases this should be in sync with the actual balance retrieved from the blockchain.
  /// This is to be able to retrieve the balance immediately upon
  /// user's opening of the app without necessity to wait for the blockchain sync.
  ///
  /// It is recommended to:
  /// 1. Use this function to display balance for the user immediately when they open the app;
  /// 2. Call [getBalanceFromBlockchain] asynchronously to check if some of the balance is still unconfirmed or
  /// if any funds have moved in or out of the previously used addresses
  /// 3. Update user screen for the obtained information
  Future<int> getStoredBalance() async => _getStoredBalance(await Database.database);

  Future<Map<String, int>> getBalanceFromBlockchain({int fetchLast = 10, bool fetchAdditional = true}) async =>
    _getBalanceFromBlockchain(await Database.database, fetchLast, fetchAdditional);

  Future<List<Transaction>> getTransactions() async => _getTransactions(this, await Database.database);

  Future<List<Address>> getUtxos() async {
    final db = await Database.database;
    final result = (await db.rawQuery("SELECT * FROM address WHERE balance > 0"));

    List<Address> addrsUtxo = List<Address>(result.length);

    for (int i = 0; i < result.length; i++) {
      addrsUtxo[i] = Address.fromDb(result[i]);
    }

    List<String> addrToFetch = <String>[];

    int lastAddedAddress = -1;

    for (int i = 0; i < addrsUtxo.length; i++) {
      addrToFetch.add(addrsUtxo[i].cashAddr);

      if (addrToFetch.length == 10 || i == addrsUtxo.length - 1) {
        final fetchedAddrUtxo = await Bitbox.Address.utxo(addrToFetch) as List<Map>;

        fetchedAddrUtxo.forEach((addrUtxo) {
          addrsUtxo[++lastAddedAddress].utxo = addrUtxo["utxos"];
        });

        addrToFetch.clear();
      }
    }

    return addrsUtxo;
  }

  int getMaxSpendable(List<Address> addrsUtxo, int outputs) {
    assert (outputs != null && outputs > 0);
    assert(addrsUtxo != null && addrsUtxo.length > 0);

    int balance = 0;
    int inputs = 0;
    addrsUtxo.forEach((address) {
      inputs += address.utxo.length;
      address.utxo.forEach((Bitbox.Utxo utxo) {
        balance += utxo.satoshis;
      });
    });
    return balance - Bitbox.BitcoinCash.getByteCount(inputs, outputs);
  }

  calculateFee(int amount, int outputsCount, List<Address> addrsUtxo) async {
    int balance = 0;
    int inputsCount = 0;
    int fee = 0;

    for (int i = 0; i < addrsUtxo.length; i++) {
      for (int u = 0; u < addrsUtxo[i].utxo.length; u++) {
        balance += addrsUtxo[i].utxo[u].satoshis;
        inputsCount++;

        fee = Bitbox.BitcoinCash.getByteCount(inputsCount, outputsCount);

        if (balance >= amount + fee) {
          break;
        }
      }

      if (balance >= amount + fee) {
        break;
      }
    }

    return fee;
  }

  /// we're simply spending from the oldest to newest
  send(List<Map> outputs, List<Address> addrsUtxo, {bool testnet = false, String password}) async {
    if (outputs == null || outputs.isEmpty) {
      throw ArgumentError("outputs should be non-empty list of Maps");
    } else if (addrsUtxo == null || addrsUtxo.isEmpty) {
      throw ArgumentError("addrsUtxo should be non-empty list of addresses containing utxos");
    }

    int maxSpendable = getMaxSpendable(addrsUtxo, outputs.length);

    int outputAmount = 0;
    
    outputs.forEach((output) {
      outputAmount += output["amount"];
    });

    if (outputAmount > maxSpendable) {
      throw ArgumentError("output is larger than max spendable");
    }

    final wallet = await BchWallet.getWallet(walletId);
    final masterNode = Bitbox.HDNode.fromSeed(Bitbox.Mnemonic.toSeed(await (wallet).getMnemonic(password)));

    final accountNode = masterNode.derivePath("${wallet.derivationPath}/$number");

    final builder = Bitbox.Bitbox.transactionBuilder();

    // placeholder for input signatures
    final signatures = <Map>[];

    int totalBalance = 0;
    int inputs = 0;
    int fee = 0;

    List<Map> addressBalancesToUpdate = <Map>[];

    for (int i = 0; i < addrsUtxo.length; i++) {
      final address = addrsUtxo[i];

      int value = 0;

      for (int j = 0; j < address.utxo.length; j++) {
        final  Bitbox.Utxo utxo = address.utxo[j];

        // add the utxo as an input for the transaction
        builder.addInput(utxo.txid, utxo.vout);

        signatures.add({
          "vin": signatures.length, // this will be the same as the latest input's index
          "key_pair": accountNode.derive(address.change ? 1 : 0).derive(address.childNo).keyPair,
          "original_amount": utxo.satoshis
        });

        totalBalance += utxo.satoshis;

        value -= utxo.satoshis;

        inputs++;

        fee = Bitbox.BitcoinCash.getByteCount(inputs, outputs.length);

        if (totalBalance > outputAmount + fee) {
          break;
        }
      }

      addressBalancesToUpdate.add({"id" : address.id, "address" : address.cashAddr, "value" : value});
    }

    outputs.forEach((output) {
      builder.addOutput(output["address"], output["amount"]);
    });

    final db = await Database.database;

    Address changeAddress;

    if (totalBalance > outputAmount + fee) {
      changeAddress = await _getChangeAddress(db);
      builder.addOutput(changeAddress.cashAddr, totalBalance - outputAmount - fee);
    }

    // sign all inputs
    signatures.forEach((signature) {
      builder.sign(signature["vin"], signature["key_pair"], signature["original_amount"]);
    });

    // build the transaction
    final tx = builder.build();

    //TODO
    final txid = "";

     // TODO: if successful
    if (true) {
      changeAddress ?? _saveAddress(db, changeAddress);

      // TODO: create and save transaction
      final transaction = Transaction(null, txid, DateTime.now());

      final txnId = await db.insert("txn", {
        "txid" : txid,
        "time" : DateTime.now().millisecondsSinceEpoch
      });

      addressBalancesToUpdate.forEach((address) async {
        db.rawUpdate("UPDATE address SET balance = balance + ? WHERE id = ?",
          [address["value"], address["id"]]);
        db.insert("txn_address", {
          "txn_id" :txnId,
          "address_id" : number,
          "value" : address["value"],
        });

        transaction.addresses[address["address"]] = address["value"];
      });

      return transaction;
    } else {
      return null;
    }
  }

  Future<Address> _getChangeAddress(sql.Database db) => _getReceivingAddress(db, true);

  Future<Address> _getReceivingAddress(sql.Database db, [bool change = false]) async {
    final lastChildNo = (await db.rawQuery("SELECT MAX(child_no) as last_child_no FROM address "
      "WHERE wallet_id = ? AND account_no = ? AND change = ?", [walletId, number, change])).first["last_child_no"];

    // TODO: check if this yields the same result as path
    final account = Bitbox.Account(
      Bitbox.HDNode.fromXPub(await _getXPub(db)).derive(change ? 1 : 0),
      lastChildNo == null ? 0 : lastChildNo + 1
    );

    Address address;

    do {
      address = Address(account.currentChild, account.getCurrentAddress(false), walletId, number, change);

      final balance = await address.updateBalanceFromBlockchain();

      if (balance > 0) {
        _saveAddress(db, address);
        account.currentChild++;
      }
    } while (address.balance > 0);

    return address;
  }

  Future<String> _getXPub(sql.Database db) async {
    final result = await db.query("account", columns: ["xpub"], where: "wallet_id = $walletId AND account_no = $number");

    if (result.length > 0) {
      return result.first["xpub"];
    } else {
      return null;
    }
  }

  Future<List<Address>> _getAddresses(sql.Database db, [bool withBalance = false]) async {
    final addressQuery = await db.query("address", where: "wallet_id = $walletId AND account_no = $number"
      + (withBalance ? " AND balance > 0" : ""));

    _addresses = List<Address>.generate(addressQuery.length, (i) {
      return Address.fromDb(addressQuery[i]);
    });

    return _addresses;
  }

  Future<int> _getStoredBalance(sql.Database db) async {
    final result = await db.rawQuery(
      "SELECT SUM(balance) as balance from address WHERE account_no = $number AND wallet_id = $walletId");

    final balance = result.first["balance"] ?? 0;

    return balance;
  }

  Future<Map<String, int>> _getBalanceFromBlockchain(sql.Database db, [int fetchLast = 10, bool fetchAdditional = true]) async {
    final balance = {
      "unconfirmed" : 0,
      "confirmed"   : 0,
    };

    _addresses ?? await _getAddresses(db);

    if (_addresses.length == 0 && !fetchAdditional) {
      return balance;
    }

    List<int> lastChildNo = List<int>(2);
    _addresses.forEach((address) {
      lastChildNo[address.change ? 1 : 0] = address.childNo;
    });

    if (fetchLast == 0 || fetchLast > _addresses.length) {
      fetchLast = _addresses.length;
    }

    final List<List<String>> addressesToFetch = List(((fetchLast + (fetchAdditional ? 10 : 0)) / 10).ceil());

    int n = 0;
    for (int i = _addresses.length - 1; i >= 0 && i >= _addresses.length - fetchLast; i--) {
      addressesToFetch[n] ??= <String>[];
      addressesToFetch[n].add(_addresses[i].cashAddr);

      if (addressesToFetch[n].length == 10) {
        n++;
      }
    }

    xPub ??= await _getXPub(db);

    final List<List<Address>> nextAddresses = [List<Address>(5), List<Address>(5)];

    for (int change = 0; change <= 1; change++) {
      final account = Bitbox.Account(Bitbox.HDNode.fromXPub(xPub).derive(change),
        _addresses.length > 0 ? _addresses.last.childNo + 1 : 0);

      for (int i = 0; i < 5; i++) {
        final currentChildNo = (lastChildNo[change] == null ? 0 : lastChildNo[change] + 1) + i;
        nextAddresses[change][i] = Address(currentChildNo, account.getCurrentAddress(false), walletId, number, false);
        account.currentChild++;

        addressesToFetch[n] ??= <String>[];
        addressesToFetch[n].add(nextAddresses[change][i].cashAddr);

        if (addressesToFetch[n].length == 10) {
          n++;
        }
      }
    }

    final allAddressDetails = <String, Map>{};

    print(addressesToFetch);
    Bitbox.Bitbox.setRestUrl(restUrl: xPub.startsWith("xpub") ? Bitbox.Bitbox.restUrl : Bitbox.Bitbox.trestUrl);

    for (int n = 0; n < addressesToFetch.length; n++) {
      final addressDetails = await Bitbox.Address.details(addressesToFetch[n], true) as Map;
      allAddressDetails.addAll(addressDetails);
    };

    _addresses.forEach((address) {
      if (allAddressDetails.containsKey(address.cashAddr)) {
        final updatedAddress = Address.fromJson(
          allAddressDetails[address.cashAddr], address.childNo, walletId, number, false);

        if (address.balance != updatedAddress.balance) {
          _saveAddress(db, updatedAddress);
        }

        address.unconfirmedBalance = updatedAddress.unconfirmedBalance;
        address.confirmedBalance = updatedAddress.confirmedBalance;
      }

      balance["confirmed"] += address.confirmedBalance;
      balance["unconfirmed"] += address.unconfirmedBalance;
    });

    for (int change = 0; change <= 1; change++) {
      int lastChildWithBalance;

      for (int i = 0; i < 5; i++) {
        final address = nextAddresses[change][i];
        final addressDetails = allAddressDetails[address.cashAddr];

        if (addressDetails["balanceSat"] +
          addressDetails["unconfirmedBalanceSat"] > 0) {
          address.confirmedBalance = addressDetails["balanceSat"];
          address.unconfirmedBalance = addressDetails["unconfirmedBalanceSat"];

          balance["confirmed"] += address.confirmedBalance;
          balance["unconfirmed"] += address.unconfirmedBalance;

          lastChildWithBalance = address.childNo;
        }
      };

      if (lastChildWithBalance != null) {
        for (int i = 0; i < lastChildWithBalance - _addresses.last.childNo; i++) {
          await _saveAddress(db, nextAddresses[change][i]);
        }
      }
    }

    return balance;
  }

  _saveAddress(sql.Database db, Address address) async {
    if (address.id != null) {
      await db.update("address", {"balance": address.balance}, where: "cash_addr = '${address.cashAddr}'");
    } else {
      address.id = await db.insert("address", {
        "wallet_id": walletId,
        "account_no": number,
        "change": address.change,
        "child_no": address.childNo,
        "cash_addr": address.cashAddr,
        "balance": address.balance
      });
      (await addresses).add(address);
    }
  }

  Future<List<Transaction>> _getTransactions(Account account, sql.Database db, [orderFromOldest = false]) async {
//      db.rawQuery("SELECT * FROM txn INNER JOIN txn_address ON txn.id = txn_address.txn_id WHERE ");
    final result = await db.rawQuery(
      "SELECT txn.id, txn.txid, txn.time, ta.address_id, ta.value, a.cash_addr "
        "FROM txn LEFT JOIN txn_address AS ta ON txn.id = ta.txn_id JOIN address AS a ON address_id = a.id "
        "WHERE account_no = ${account.number} ORDER BY time " + (orderFromOldest ? "ASC" : "DESC"));

    final transactions = <Transaction>[];

    Map<int, int> addedTxns = {};
    for (int i = 0; i < result.length; i++) {
      final row = result[i];
      if (!addedTxns.keys.contains(row["id"])) {
        transactions.add(Transaction.fromDb(result[i]));
        addedTxns[row["id"]] = transactions.length - 1;
      } else {
        transactions[addedTxns[row["id"]]].addresses[row["cash_addr"]] = row["value"];
      }
    }

    final x = true;
    return transactions;
  }
}