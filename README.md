# Bitcoin Cash Wallet for Flutter

A wallet management library, that does all the basic necessary stuff:
* generates one or multiple wallets (optionally password protected)
* creates one or more account in each wallet
* receive and send transactions
* imports wallet from a backup
* works with testnet and mainnet

Built on [Bitbox for Flutter](https://pub.dev/packages/bitbox), which is built on Bitcoin.com's
[Bitbox API](https://rest.bitcoin.com/v2).

## Getting Started

### 1) Depend on it

If you just want to get this from Dart's public package directory:

```
dependencies:
  bch_wallet: ^0.0.1
```

If you checked this out from Github, add a local dependency into the pubspec.yaml of your testing or development projet:

```
dependencies:
  bch_wallet:
    path: <path to the directory>/
```

### 2) Import it

```
import 'package:bch_wallet/bch_wallet.dart';
```

### 3) Use it
```
await BchWallet.createWallet(
  defaultAccountName: "wallet's first account",
  name: "new wallet",
  password: "q7PWSLDQduXEvBE"
);

// get list of all locally stored wallets
List<Wallet> wallets = await BchWallet.getWalletList();

// when using only one wallet in the app, this method will suffice
Wallet newWallet = await BchWallet.getWallet();

// get all wallet's accounts
List<Account> accounts = await newWallet.accounts;

// one account is always created by default for each wallet.
// When using only one account per wallet, this method will suffice
Account firstAccount = await newWallet.getAccount();

// create a second account - password is necessary for password-protected wallets because accounts are hardened
newWallet.createAccount("second account", password: "q7PWSLDQduXEvBE");

// the newly created account will be added to the end of the list
Account secondAccount = await newWallet.getAccount(1);

// generate an empty address - if the address was used before (e.g. when the wallet is used in some other app,
// it will be saved with its balance and transactions and another one will be generated until an empty one is found)
Address address = await firstAccount.getReceivingAddress();

// Wait until a desired amount is received to the address.
// All functions in this library work with satoshi amounts
List<Transaction> transaction = await address.receive(BchWallet.toSatoshi(0.1));

// This is a getter for overall (balanced + unconfirmed) balance.
int addressBalance = address.balance;

// The library's local storage doesn't distinguish confirmed and unconfirmed balance. When you restart the app or
// retrieve this address in a new state even before the receiving tansaction is confirmed,
// the returned value will look as follows:
int confirmedBalance = address.confirmedBalance;     // 10000000
int unconfirmedBalance = address.unconfirmedBalance; // 0

// To get confirmed and unconfirmed balance state from the blockchain, do this:
address.updateBalanceFromBlockchain();

// address (and thus account's) balance is always maintained locally for fast retrieval
int accountbalance = await firstAccount.getStoredBalance();

// however, to get account's confirmed and unconfirmed balance, or to check if the addresses have not been used
// in some other app, do this
Map updatedBalance = await firstAccount.getBalanceFromBlockchain();

// to send an amount from the account, first retrieve its utxos. Please store the utxo list in your state so it
// doesn't need to be retrieved repeatedly to lower the Bitbox API load
this.addrsUtxo = await firstAccount.getUtxos();

int amount = firstAccount.getMaxSpendable(this.addrsUtxo);

// when storing the utxos in the state, it is possible to synchronously calculate fee after every user's input.
double fee = BchWallet.fromSatoshi(firstAccount.calculateFee(amount, 1, addrsUtxo));

// ready to send
Transaction sendingTx = await firstAccount.send(
  [{"bitcoincash:qqy3au5nur3tn0n4v69xqxa3m72e5ve9rqht7pp0ee" : amount}], addrsUtxo);

// list of transactions (by default ordered from the newest)
List<Transaction> transactions = await firstAccount.getTransactions();
```