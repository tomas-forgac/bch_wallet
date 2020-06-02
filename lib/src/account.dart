import 'package:bch_wallet/src/utils/utils.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;

import '../bch_wallet.dart';
import 'package:sqflite/sqflite.dart' as sql;

import 'utils/database.dart';

/// Information about and functions to work with a BIP32 account
class Account {
  /// account number, which will determine its derivation path
  final int number;
  /// id of the wallet this account belongs to
  final int walletId;
  /// name of the account
  String name;

  /// getter for list of saved addresses. If they've been retrieved before, it'll return them from object more quickly
  Future<List<Address>> get addresses async => _addresses ?? await _getAddresses(await Database.database);

  /// getter for xpub. If it was retrieved before, it will be returned from the object more quickly
  Future<String> get xPub async => _xPub ?? _getXPub(await Database.database);

  // xpub must be explicitely retrieved if needed, it is not automatically populated with the object's instance
  String _xPub;

  // list of addresses must be explicitly retrieved
  List<Address> _addresses;

  Account(this.number, this.walletId, [this.name]);

  /// generates the next unused address for receiving new funds
  Future<Address> getReceivingAddress() async => _getReceivingAddress(await Database.database);

  /// Returns account balance (confirmed + unconfirmed) in satoshis as recorded in the last balance update.
  /// Usually this should be in sync with the actual balance retrieved from the blockchain.
  /// This is to be able to retrieve the balance immediately upon
  /// user's opening of the app without necessity to wait for the blockchain sync.
  ///
  /// It is recommended to:
  /// 1. Use this function to display balance for the user immediately when they open the app;
  /// 2. Call [getBalanceFromBlockchain] asynchronously to check if some of the balance is still unconfirmed or
  /// if any funds have moved in or out of the previously used addresses
  /// 3. Update user screen for the obtained information
  Future<int> getStoredBalance() async => _getStoredBalance(await Database.database);

  /// Checks balance of the account's addresses on the blockchain
  /// and returns it broken down to confirmed and unconfirmed.
  ///
  /// * [fetchLast] - indicates how many of the latest used addresses should be checked for any balance updates
  /// * [fetchAdditional] - how many unused addresses (both primary and change) should be checked for any new balance
  ///
  /// Returns json object in the following format:
  /// ```
  /// {
  ///   "confirmed" : <int>
  ///   "unconfirmed" : <int>
  /// }
  /// ```
  Future<Map<String, int>> getBalanceFromBlockchain({int fetchLast = 6, int fetchAdditional = 2}) async =>
    _getBalanceFromBlockchain(await Database.database, fetchLast, fetchAdditional);

  /// returns a list of all incoming and outgoing transactions of account's addresses
  Future<List<Transaction>> getTransactions([orderFromOldest = false]) async =>
    _getTransactions(this, await Database.database, orderFromOldest);

  /// get all account's utxos. This is necessary to provide to [getMaxSpendable], [calculateFee] and [send] functions
  Future<List<Address>> getUtxos() async {
    final db = await Database.database;
    // get all addresses of this account with some remaining balance
    final result = (await db.rawQuery(
      "SELECT * FROM address WHERE balance > 0 AND account_no = ? AND wallet_id = ?", [number, walletId]));

    // generate a list of address instances from the returned result
    List<Address> addrsUtxo = List<Address>.generate(result.length, (i) => _addressFromDbRow(result[i]));

    // if there's nothing in db, return empty list
    if (addrsUtxo.length == 0) {
      return addrsUtxo;
    }

    // use the first address in the list to determine if this is testnet wallet and set rest api accordingly
    setTestNet(Address.isTestnet(addrsUtxo.first.cashAddr));

    // placeholhder for cashaddresses to fetch from details of
    List<String> addrToFetch = <String>[];

    int lastAddedAddress = -1;

    // go through the list of addresses to fill them with utxos
    for (int i = 0; i < addrsUtxo.length; i++) {
      // add addresses cashaddr to the list to fetch
      addrToFetch.add(addrsUtxo[i].cashAddr);

      // if the list reached a lenght of 10 (maximum the Bitbox API allow), or it's the end of the list, fetch the utxos
      if (addrToFetch.length == 10 || i == addrsUtxo.length - 1) {
        final fetchedAddrUtxo = await Bitbox.Address.utxo(addrToFetch) as List<Map>;

        // go through the fetched address utxo details and add them to the prepared placeholder
        fetchedAddrUtxo.forEach((addrUtxo) {
          addrsUtxo[++lastAddedAddress].utxo = addrUtxo["utxos"];
        });

        // empty the list to fetch for the next cycle run
        addrToFetch.clear();
      }
    }

    return addrsUtxo;
  }

  /// calculate how much can be spent from this account. Output of [getUtxos] function must be provided.
  /// Specify [outputsCount] if it is assumed the amount will be spent to more than one address
  int getMaxSpendable(List<Address> addrsUtxo, {int outputsCount = 1}) {
    if (outputsCount == null || outputsCount < 1) {
      throw ArgumentError("outputsCount must be larger than 0");
    } else if (addrsUtxo == null) {
      throw ArgumentError("provide addrsUtxo from getUtxo function");
    }

    if (addrsUtxo.length == 0) return 0;

    // find out how much confirmed balance is available in all addresses and in how many utxos
    int balance = 0;
    int inputs = 0;
    addrsUtxo.forEach((address) {
      address.utxo.forEach((Bitbox.Utxo utxo) {
        if (utxo.confirmations > 0) {
          inputs++;
          balance += utxo.satoshis;
        }
      });
    });

    // calculate the fee based on number of inputs and outputs and return the difference from the balance
    return balance == 0 ? 0 : balance - Bitbox.BitcoinCash.getByteCount(inputs, outputsCount);
  }

  /// Calculate a fee to be paid when sending an [amount] of satoshis to the number of outputs ([outputsCount]).
  /// Value of [getUtxos] function must be provided in [addrsUtxo]
  calculateFee(int amount, int outputsCount, List<Address> addrsUtxo) {
    int balance = 0;
    int inputsCount = 0;
    int fee = 0;

    // find out how many utxos will be necessary to spend from for the defined output amount
    for (int i = 0; i < addrsUtxo.length; i++) {
      for (int u = 0; u < addrsUtxo[i].utxo.length; u++) {
        balance += addrsUtxo[i].utxo[u].satoshis;
        inputsCount++;

        // calculate the fee every time to reflect current number of input
        fee = Bitbox.BitcoinCash.getByteCount(inputsCount, outputsCount);

        // when the balance reaches the needed amount incl. the fee, stop counting
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

  /// Send from this account to the specified outputs. The outputs must be in the following format:
  /// ```
  /// {
  ///   [
  ///     {
  ///       "address" : <address1>
  ///       "amount" : <satoshiAmount1>
  ///     },
  ///     {
  ///       "address" : <address2>
  ///       "amount" : <satoshiAmount2>
  ///     },
  ///     ...
  ///   ]
  /// }
  /// ```
  Future<Transaction> send(List<Map> outputs, List<Address> addrsUtxo, {String password}) async {
    if (outputs == null || outputs.isEmpty) {
      throw ArgumentError("outputs should be non-empty list of Maps");
    } else if (addrsUtxo == null || addrsUtxo.isEmpty) {
      throw ArgumentError("addrsUtxo should be non-empty list of addresses containing utxos");
    }

    final db = await Database.database;

    // check if there is sufficient spendable balance for the specified amount
    int maxSpendable = getMaxSpendable(addrsUtxo, outputsCount: outputs.length);

    int outputAmount = 0;
    
    outputs.forEach((output) {
      outputAmount += output["amount"];
    });

    if (outputAmount > maxSpendable) {
      throw ArgumentError("output is larger than max spendable");
    }

    // retrieve wallet data
    final wallet = await BchWallet.getWallet(walletId);

    if (password != null && password.length > 0 && !wallet.passwordProtected) {
      throw ArgumentError("wallet is not password protected");
    }

    // generate an account node to derive private keys from
    final seed = Bitbox.Mnemonic.toSeed(await wallet.getMnemonic(password) + (password??""));
    final accountNode = Bitbox.HDNode.fromSeed(seed, wallet.testnet).derivePath("${wallet.derivationPath}/$number'");
    // start a blank transaction builder
    final builder = Bitbox.Bitbox.transactionBuilder(testnet: wallet.testnet);

    // placeholder for input signatures
    final signatures = <Map>[];

    // placeholders for transaction values
    int totalBalance = 0;
    int inputs = 0;
    int fee = 0;

    // placeholder to store the list of addresses which will need to be updated when the transaction is broadcasted
    List<Map> addressBalancesToUpdate = <Map>[];

    // go through a list of provided address utxos until a sufficient amount is found
    for (int i = 0; i < addrsUtxo.length; i++) {
      final address = addrsUtxo[i];

      // placeholder for value for which the address balance will need to be udpated
      int value = 0;

      // go through the list of all utxos for this address until until a sufficient amount is found
      for (int j = 0; j < address.utxo.length; j++) {
        final  Bitbox.Utxo utxo = address.utxo[j];

        // only include confirmed utxos
        if (utxo.confirmations > 0) {
          // add the utxo as an input for the transaction
          builder.addInput(utxo.txid, utxo.vout);

          // derive keypair with the private key for signature
          final changeNode = accountNode.derive(address.change ? 1 : 0);
          final keyPair = changeNode.derive(address.childNo).keyPair as Bitbox.ECPair;

          // populate the signature data for later
          signatures.add({
            "vin": signatures.length, // this will be the same as the latest input's index
            "key_pair": keyPair,
            "original_amount": utxo.satoshis
          });

          // add utxo's confirmed balance to the so far populated balance
          totalBalance += utxo.satoshis;

          // update how much will need to be this address' balance need to change
          value -= utxo.satoshis;

          // increment a number of input for fee calculation purposes
          inputs++;

          // calculate necessary fee to broadcast the transaction with current number of inputs and outputs
          fee = Bitbox.BitcoinCash.getByteCount(inputs, outputs.length);

          // find out if there's sufficient amount populated yet and if yes, stop going through the utxos
          if (totalBalance > outputAmount + fee) {
            break;
          }
        }
      }

      // if this address had utxos to be included in the transactions, add it to the list of addresses to be updated
      if (value != 0) {
        addressBalancesToUpdate.add({"id": address.id, "address": address.cashAddr, "value": value});
      }

      // if a sufficient amount was found, stop going through the address utxos
      if (totalBalance > outputAmount + fee) {
        break;
      }
    }

    // add all outputs to the builder
    outputs.forEach((output) {
      builder.addOutput(output["address"], output["amount"]);
    });

    // placeholder for a possible change address
    Address changeAddress;

    // find out if there will be a change amount left after spending the populated utxos.
    // assume there will be a change left and calculate the fee accordingly
    final feeWithChange = Bitbox.BitcoinCash.getByteCount(inputs, outputs.length + 1);
    // calculate if there will be a change including a (larger) fee with the additional change output
    if (totalBalance > outputAmount + feeWithChange) {
      // generate a change address
      changeAddress = await _getChangeAddress(db);
      // set unconfirmed balance of the address now
      // (so it can be used in the code below instead of storing it separately)
      changeAddress.unconfirmedBalance = totalBalance - outputAmount - feeWithChange;
      //add the change address to the list of outputs
      builder.addOutput(changeAddress.cashAddr, changeAddress.unconfirmedBalance);
    }

    // sign all the inputs
    signatures.forEach((signature) {
      builder.sign(signature["vin"], signature["key_pair"], signature["original_amount"]);
    });

    // prepare the transaction for broadcasting
    final rawTx = builder.build().toHex();

    // make sure to broadcast to the right network
    setTestNet(wallet.testnet);

    // broadcast the transaction and retrieve its id
    final returnedTxIds = await Bitbox.RawTransactions.sendRawTransaction([rawTx]);

    if (returnedTxIds != null) {
      final txid = returnedTxIds.first;
      if (changeAddress != null) {
        // if there's a change, save the address
        await _saveAddress(db, changeAddress);
      }

      // save the transaction to the database and update its internal id
      final txnId = await db.insert("txn", {
        "wallet_id" : walletId,
        "txid" : txid,
        "time" : DateTime.now().millisecondsSinceEpoch
      });

      // create a transaction instance to return
      final transaction = Transaction(txnId, txid, DateTime.now());
      transaction.confirmations = 0;

      // update balances of all the addresses, that the transaction spent from
      for (int i = 0; i < addressBalancesToUpdate.length; i++) {
        final address = addressBalancesToUpdate[i];
        await db.rawUpdate("UPDATE address SET balance = balance + ? WHERE id = ?", [address["value"], address["id"]]);

        // also insert a address-transaction reference
        await db.insert("txn_address", {
          "txn_id" :txnId,
          "address_id" : address["id"],
          "value" : address["value"],
        });

        transaction.addresses[address["address"]] = address["value"];
      }

      return transaction;
    } else {
      return null;
    }
  }

  /// rename account in the database
  Future<bool> rename(String newName) async {
    final db = await Database.database;
    final updated = await db.update("account", {"name" : newName}, where: "wallet_id = ? AND account_no = ?",
      whereArgs: [this.walletId, this.number]);

    if (updated == 1) {
      this.name = newName;
      return true;
    }

    return false;
  }

  // get a new unused change address
  Future<Address> _getChangeAddress(sql.Database db) => _getReceivingAddress(db, true);

  // get a new unused address
  Future<Address> _getReceivingAddress(sql.Database db, [bool change = false]) async {
    // get the last saved address (change or primary) for this account
    final lastChildNo = (await db.rawQuery("SELECT MAX(child_no) as last_child_no FROM address "
      "WHERE wallet_id = ? AND account_no = ? AND change = ?", [walletId, number, change ? 1 : 0])).first["last_child_no"];

    final xPub = await _getXPub(db);
    // generate a new account node from xpub to derive from
    final account = Bitbox.Account(
      Bitbox.HDNode.fromXPub(xPub).derive(change ? 1 : 0),
      lastChildNo == null ? 0 : lastChildNo + 1
    );

    Address address;

    setTestNet(xPub.startsWith("t"));

    bool stop = false;

    while (!stop) {
      // generate Address instance from the next unused child node
      address = Address(account.currentChild, account.getCurrentAddress(false), walletId, number, change);

      // retrieve address details from the API
      final details = await Bitbox.Address.details(address.cashAddr);

      // check if the address has been used before
      if (details["txApperances"] > 0 || details["unconfirmedBalance"] > 0) {
        // if it's been used, update iss current balance
        address.confirmedBalance = details["balanceSat"];
        address.unconfirmedBalance = details["unconfirmedBalanceSat"];

        // save the address and its transactions to the db
        await _saveAddress(db, address);
        await saveTransactions(address, db, details["transactions"]);

        // increase the latest account's child
        account.currentChild++;
      } else {
        stop = true;
      }
    }

    return address;
  }

  // get account's xpub from the databases
  Future<String> _getXPub(sql.Database db) async {
    final result = await db.query("account", columns: ["xpub"], where: "wallet_id = $walletId AND account_no = $number");

    if (result.length > 0) {
      _xPub = result.first["xpub"];
      return _xPub;
    } else {
      return null;
    }
  }

  // get account addresses from the database
  Future<List<Address>> _getAddresses(sql.Database db, [bool withBalance = false]) async {
    final addressQuery = await db.query("address", where: "wallet_id = $walletId AND account_no = $number"
      + (withBalance ? " AND balance > 0" : ""));

    _addresses = List<Address>.generate(addressQuery.length, (i) => _addressFromDbRow(addressQuery[i]));

    return _addresses;
  }

  // get account balance as it is stored in the database
  Future<int> _getStoredBalance(sql.Database db) async {
    final result = await db.rawQuery(
      "SELECT SUM(balance) as balance from address WHERE account_no = $number AND wallet_id = $walletId");

    final balance = result.first["balance"] ?? 0;

    return balance;
  }

  // get account balance from the blockchain
  Future<Map<String, int>> _getBalanceFromBlockchain(sql.Database db, [int fetchLast = 6, int fetchAdditional = 2]) async {
    final balance = {
      "unconfirmed" : 0,
      "confirmed"   : 0,
    };

    // get account addresses from the database
    _addresses ?? await _getAddresses(db);

    // if there are no addresses saved and none unused are supposed to be checked, return zero balance
    if (_addresses.length == 0 && fetchAdditional == 0) {
      return balance;
    }

    // find the last used child number for both primary and change address
    // TODO: rewrite this to go form the end
    List<int> lastChildNo = [-1, -1];
    _addresses.forEach((address) {
      lastChildNo[address.change ? 1 : 0] = address.childNo;
    });

    // if the number of addresses to check is larger than the number of the addresses saved, or if it was requested to
    // check all past addresses, set number of the addresses to check to all
    if (fetchLast == 0 || fetchLast > _addresses.length) {
      fetchLast = _addresses.length;
    }

    // generate separate empty lists for addresses to fetch with length of 10 (max the API allows)
    final List<List<String>> addressesToFetch = List(((fetchLast + (fetchAdditional*2)) / 10).ceil());

    // go through the list of addresses from the latest to older and add them to the list to be fetched until the
    // desired number is reached
    int n = 0;
    for (int i = _addresses.length - 1; i >= 0 && i >= _addresses.length - fetchLast; i--) {
      addressesToFetch[n] ??= <String>[];
      addressesToFetch[n].add(_addresses[i].cashAddr);

      if (addressesToFetch[n].length == 10) {
        n++;
      }
    }

    // placeholder for additional addresses to check for a new balance
    final List<List<Address>> nextAddresses = [
      List<Address>(fetchAdditional),
      List<Address>(fetchAdditional)
    ];

    // if it was requested to check additional addresses in the account for new balance, prepare their list
    if (fetchAdditional > 0) {
      _xPub ??= await _getXPub(db);

      // generate both additional primary andchange addresses
      for (int change = 0; change <= 1; change++) {
        final accountNode = Bitbox.HDNode.fromXPub(_xPub).derive(change);

        // add the required additional addresses to the list to fetch
        for (int i = 0; i < fetchAdditional; i++) {
          final currentChildNo = lastChildNo[change] + 1 + i;
          nextAddresses[change][i] =
            Address(currentChildNo, accountNode.derive(currentChildNo).toCashAddress(), walletId, number, false);

          addressesToFetch[n] ??= <String>[];
          addressesToFetch[n].add(nextAddresses[change][i].cashAddr);

          if (addressesToFetch[n].length == 10) {
            n++;
          }
        }
      }
    }

    // placeholder for the fetched address details
    final allAddressDetails = <String, Map>{};

    setTestNet(_xPub.startsWith("tpub"));

    // go through the two-dimensional list of addresses and fetch their details
    for (int n = 0; n < addressesToFetch.length; n++) {
      // request map to be returned to make it easier to work with it below
      final addressDetails = await Bitbox.Address.details(addressesToFetch[n], true) as Map;
      allAddressDetails.addAll(addressDetails);
    }

    // TODO: go through the list in reverse order and only the required number of times so it doesn't get too slow with too many saved addresses
    _addresses.forEach((address) {
      if (allAddressDetails.containsKey(address.cashAddr)) {
        final updatedAddress = Address.fromJson(
          allAddressDetails[address.cashAddr], address.childNo, walletId, number, false, id: address.id);

        if (address.balance != updatedAddress.balance) {
          _saveAddress(db, updatedAddress);
          saveTransactions(address, db, allAddressDetails[address.cashAddr]["transactions"]);
        }

        address.unconfirmedBalance = updatedAddress.unconfirmedBalance;
        address.confirmedBalance = updatedAddress.confirmedBalance;
      }

      balance["confirmed"] += address.confirmedBalance;
      balance["unconfirmed"] += address.unconfirmedBalance;
    });

    // if it was requested to fetch additional addresses, check those too
    if (fetchAdditional > 0) {
      // check both primary and change addresses
      for (int change = 0; change <= 1; change++) {
        // in case a new address with balance will be found, save its number here
        int lastChildWithBalance;

        for (int i = 0; i < fetchAdditional; i++) {
          // original address list
          final address = nextAddresses[change][i];
          // fetched information
          final addressDetails = allAddressDetails[address.cashAddr];

          // if there is a balance on this new address, update the address and returned balance data
          if (addressDetails["balanceSat"] + addressDetails["unconfirmedBalanceSat"] > 0) {
            address.confirmedBalance = addressDetails["balanceSat"];
            address.unconfirmedBalance = addressDetails["unconfirmedBalanceSat"];

            balance["confirmed"] += address.confirmedBalance;
            balance["unconfirmed"] += address.unconfirmedBalance;

            lastChildWithBalance = address.childNo;
          }
        }

        // if a new address was discovered, save all new addresses up to that point
        if (lastChildWithBalance != null) {
          for (int i = 0; i < lastChildWithBalance - lastChildNo[change]; i++) {
            final address = nextAddresses[change][i];
            await _saveAddress(db, address);
            await saveTransactions(address, db, allAddressDetails[address.cashAddr]["transactions"]);
          }
        }
      }
    }

    return balance;
  }

  // save the address to the database. If address exists, it'll be updated.
  // Otherwise a new record will be created and the addresses id will be updated
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

  // get list of transactions of an account. Sorted from the newest by default
  static Future<List<Transaction>> _getTransactions(Account account, sql.Database db, [orderFromOldest = false]) async {
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

    return transactions;
  }

  // create an address instance from the database table row
  _addressFromDbRow(Map<String, dynamic> addressRow) =>
    Address(addressRow["child_no"], addressRow["cash_addr"], addressRow["wallet_id"], addressRow["account_no"],
      addressRow["change"] == 1, confirmedBalance : addressRow["balance"], id: addressRow["id"]);
}