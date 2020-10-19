import
  std/[os, strutils, terminal, wordwrap, unicode],
  chronicles, chronos, web3, stint, json_serialization, zxcvbn,
  serialization, blscurve, eth/common/eth_types, eth/keys, confutils, bearssl,
  spec/[datatypes, digest, crypto, keystore],
  stew/[byteutils, io2], libp2p/crypto/crypto as lcrypto,
  nimcrypto/utils as ncrutils,
  conf, ssz/merkleization, network_metadata

export
  keystore

when defined(windows):
  import stew/[windows/acl]

{.push raises: [Defect].}
{.localPassC: "-fno-lto".} # no LTO for crypto

const
  keystoreFileName* = "keystore.json"
  netKeystoreFileName* = "network_keystore.json"

type
  WalletPathPair* = object
    wallet*: Wallet
    path*: string

  CreatedWallet* = object
    walletPath*: WalletPathPair
    mnemonic*: Mnemonic

const
  minPasswordLen = 12
  minPasswordEntropy = 60.0

  mostCommonPasswords = wordListArray(
    currentSourcePath.parentDir /
      "../vendor/nimbus-security-resources/passwords/10-million-password-list-top-100000.txt",
    minWordLen = minPasswordLen)

proc echoP(msg: string) =
  ## Prints a paragraph aligned to 80 columns
  echo ""
  echo wrapWords(msg, 80)

proc checkAndCreateDataDir*(dataDir: string): bool =
  ## Checks `conf.dataDir`.
  ## If folder exists, procedure will check it for access and
  ## permissions `0750 (rwxr-x---)`, if folder do not exists it will be created
  ## with permissions `0750 (rwxr-x---)`.
  let amask = {AccessFlags.Read, AccessFlags.Write, AccessFlags.Execute}
  when defined(posix):
    if fileAccessible(dataDir, amask):
      let gmask = {UserRead, UserWrite, UserExec, GroupRead, GroupExec}
      let pmask = {OtherRead, OtherWrite, OtherExec, GroupWrite}
      let pres = getPermissionsSet(dataDir)
      if pres.isErr():
        fatal "Could not check data folder permissions",
               data_dir = dataDir, errorCode = $pres.error,
               errorMsg = ioErrorMsg(pres.error)
        false
      else:
        let insecurePermissions = pres.get() * pmask
        if insecurePermissions != {}:
          fatal "Data folder has insecure permissions",
                 data_dir = dataDir,
                 insecure_permissions = $insecurePermissions,
                 current_permissions = pres.get().toString(),
                 required_permissions = gmask.toString()
          false
        else:
          true
    else:
      let res = createPath(dataDir, 0o750)
      if res.isErr():
        fatal "Could not create data folder", data_dir = dataDir,
              errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        false
      else:
        true
  elif defined(windows):
    if fileAccessible(dataDir, amask):
      let cres = checkCurrentUserOnlyACL(dataDir)
      if cres.isErr():
        fatal "Could not check data folder's ACL",
               data_dir = dataDir, errorCode = $cres.error,
               errorMsg = ioErrorMsg(cres.error)
        false
      else:
        if cres.get() == false:
          fatal "Data folder has insecure ACL", data_dir = dataDir
          false
        else:
          true
    else:
      let sres = createCurrentUserOnlySecurityDescriptor()
      if sres.isErr():
        fatal "Could not allocate security descriptor", data_dir = dataDir,
              errorMsg = ioErrorMsg(sres.error), errorCode = $sres.error
        false
      else:
        var sd = sres.get()
        let res = createPath(dataDir, 0o750, secDescriptor = sd.getDescriptor())
        if res.isErr():
          fatal "Could not create data folder", data_dir = dataDir,
                errorMsg = ioErrorMsg(res.error), errorCode = $res.error
          false
        else:
          true
  else:
    fatal "Unsupported operation system"
    return false

proc checkSensitiveFilePermissions*(filePath: string): bool =
  ## Check if ``filePath`` has only "(600) rw-------" permissions.
  ## Procedure returns ``false`` if permissions are different
  when defined(windows):
    let cres = checkCurrentUserOnlyACL(filePath)
    if cres.isErr():
      fatal "Could not check file's ACL",
             key_path = filePath, errorCode = $cres.error,
             errorMsg = ioErrorMsg(cres.error)
      false
    else:
      if cres.get() == false:
        fatal "File has insecure permissions", key_path = filePath
        false
      else:
        true
  else:
    let allowedMask = {UserRead, UserWrite}
    let mask = {UserExec,
                GroupRead, GroupWrite, GroupExec,
                OtherRead, OtherWrite, OtherExec}
    let pres = getPermissionsSet(filePath)
    if pres.isErr():
      error "Could not check file permissions",
            key_path = filePath, errorCode = $pres.error,
            errorMsg = ioErrorMsg(pres.error)
      false
    else:
      let insecurePermissions = pres.get() * mask
      if insecurePermissions != {}:
        error "File has insecure permissions",
              key_path = filePath,
              insecure_permissions = $insecurePermissions,
              current_permissions = pres.get().toString(),
              required_permissions = allowedMask.toString()
        false
      else:
        true

proc keyboardCreatePassword(prompt: string, confirm: string): KsResult[string] =
  while true:
    let password =
      try:
        readPasswordFromStdin(prompt)
      except IOError:
        error "Could not read password from stdin"
        return err("Could not read password from stdin")

    # We treat `password` as UTF-8 encoded string.
    if validateUtf8(password) == -1:
      if runeLen(password) < minPasswordLen:
        echoP "The entered password should be at least " & $minPasswordLen &
              " characters."
        echo ""
        continue
      elif passwordEntropy(password) < minPasswordEntropy:
        echoP "The entered password has low entropy and may be easy to " &
              "brute-force with automated tools. Please increase the " &
              "variety of the user characters."
        continue
      elif password in mostCommonPasswords:
        echoP "The entered password is too commonly used and it would be " &
              "easy to brute-force with automated tools."
        echo ""
        continue
    else:
      echoP "Entered password is not valid UTF-8 string"
      echo ""
      continue

    let confirmedPassword =
      try:
        readPasswordFromStdin(confirm)
      except IOError:
        error "Could not read password from stdin"
        return err("Could not read password from stdin")

    if password != confirmedPassword:
      echo "Passwords don't match, please try again\n"
      continue

    return ok(password)

proc keyboardGetPassword[T](prompt: string, attempts: int,
                            pred: proc(p: string): KsResult[T] {.closure.}): KsResult[T] =
  var
    remainingAttempts = attempts
    counter = 1

  while remainingAttempts > 0:
    let passphrase =
      try:
        readPasswordFromStdin(prompt)
      except IOError as exc:
        error "Could not read password from stdin"
        return
    os.sleep(1000 * counter)
    let res = pred(passphrase)
    if res.isOk():
      return res
    else:
      inc(counter)
      dec(remainingAttempts)
  err("Failed to decrypt keystore")

proc loadKeystore(validatorsDir, secretsDir, keyName: string,
                  nonInteractive: bool): Option[ValidatorPrivKey] =
  let
    keystorePath = validatorsDir / keyName / keystoreFileName
    keystore =
      try: Json.loadFile(keystorePath, Keystore)
      except IOError as err:
        error "Failed to read keystore", err = err.msg, path = keystorePath
        return
      except SerializationError as err:
        error "Invalid keystore", err = err.formatMsg(keystorePath)
        return

  let passphrasePath = secretsDir / keyName
  if fileExists(passphrasePath):
    if not(checkSensitiveFilePermissions(passphrasePath)):
      error "Password file has insecure permissions", key_path = keyStorePath
      return

    let passphrase = KeystorePass.init:
      try:
        readFile(passphrasePath)
      except IOError as err:
        error "Failed to read passphrase file", err = err.msg,
              path = passphrasePath
        return

    let res = decryptKeystore(keystore, passphrase)
    if res.isOk:
      return res.get.some
    else:
      error "Failed to decrypt keystore", keystorePath, passphrasePath
      return

  if nonInteractive:
    error "Unable to load validator key store. Please ensure matching passphrase exists in the secrets dir",
      keyName, validatorsDir, secretsDir = secretsDir
    return

  let prompt = "Please enter passphrase for key \"" &
               (validatorsDir / keyName) & "\": "
  let res = keyboardGetPassword[ValidatorPrivKey](prompt, 3,
    proc (password: string): KsResult[ValidatorPrivKey] =
      let decrypted = decryptKeystore(keystore, KeystorePass.init password)
      if decrypted.isErr():
        error "Keystore decryption failed. Please try again", keystorePath
      decrypted
  )

  if res.isOk():
    some(res.get())
  else:
    return

iterator validatorKeysFromDirs*(validatorsDir, secretsDir: string): ValidatorPrivKey =
  try:
    for kind, file in walkDir(validatorsDir):
      if kind == pcDir:
        let keyName = splitFile(file).name
        let key = loadKeystore(validatorsDir, secretsDir, keyName, true)
        if key.isSome:
          yield key.get
        else:
          quit 1
  except OSError:
    quit 1

iterator validatorKeys*(conf: BeaconNodeConf|ValidatorClientConf): ValidatorPrivKey =
  let validatorsDir = conf.validatorsDir
  try:
    for kind, file in walkDir(validatorsDir):
      if kind == pcDir:
        let keyName = splitFile(file).name
        let key = loadKeystore(validatorsDir, conf.secretsDir, keyName, conf.nonInteractive)
        if key.isSome:
          yield key.get
        else:
          quit 1
  except OSError as err:
    error "Validator keystores directory not accessible",
          path = validatorsDir, err = err.msg
    quit 1

type
  KeystoreGenerationError = enum
    RandomSourceDepleted,
    FailedToCreateValidatorDir
    FailedToCreateSecretsDir
    FailedToCreateSecretFile
    FailedToCreateKeystoreFile

proc loadNetKeystore*(keyStorePath: string,
                      insecurePwd: Option[string]): Option[lcrypto.PrivateKey] =

  if not(checkSensitiveFilePermissions(keystorePath)):
    error "Network keystorage file has insecure permissions",
          key_path = keyStorePath
    return

  let keyStore =
    try:
      Json.loadFile(keystorePath, NetKeystore)
    except IOError as err:
      error "Failed to read network keystore", err = err.msg,
            path = keystorePath
      return
    except SerializationError as err:
      error "Invalid network keystore", err = err.formatMsg(keystorePath)
      return

  if insecurePwd.isSome():
    warn "Using insecure password to unlock networking key"
    let decrypted = decryptNetKeystore(keystore, KeystorePass.init insecurePwd.get)
    if decrypted.isOk:
      return some(decrypted.get())
    else:
      error "Network keystore decryption failed", key_store = keyStorePath
      return
  else:
    let prompt = "Please enter passphrase to unlock networking key: "
    let res = keyboardGetPassword[lcrypto.PrivateKey](prompt, 3,
      proc (password: string): KsResult[lcrypto.PrivateKey] =
        let decrypted = decryptNetKeystore(keystore, KeystorePass.init password)
        if decrypted.isErr():
          error "Keystore decryption failed. Please try again", keystorePath
        decrypted
    )
    if res.isOk():
      some(res.get())
    else:
      return

proc saveNetKeystore*(rng: var BrHmacDrbgContext, keyStorePath: string,
                      netKey: lcrypto.PrivateKey, insecurePwd: Option[string]
                     ): Result[void, KeystoreGenerationError] =
  let password =
    if insecurePwd.isSome():
      warn "Using insecure password to lock networking key",
           key_path = keyStorePath
      insecurePwd.get()
    else:
      let prompt = "Please enter NEW password to lock network key storage: "
      let confirm = "Please confirm, network key storage password: "
      let res = keyboardCreatePassword(prompt, confirm)
      if res.isErr():
        return err(FailedToCreateKeystoreFile)
      res.get()

  let keyStore = createNetKeystore(kdfScrypt, rng, netKey,
                                   KeystorePass.init password)
  var encodedStorage: string
  try:
    encodedStorage = Json.encode(keyStore)
  except SerializationError:
    error "Could not serialize network key storage", key_path = keyStorePath
    return err(FailedToCreateKeystoreFile)

  let res =
    when defined(windows):
      let sres = createCurrentUserOnlySecurityDescriptor()
      if sres.isErr():
        error "Could not allocate security descriptor", key_path = keyStorePath
        return err(FailedToCreateKeystoreFile)
      var sd = sres.get()
      writeFile(keyStorePath, encodedStorage, 0o600,
                secDescriptor = sd.getDescriptor())
    else:
      writeFile(keyStorePath, encodedStorage, 0o600)

  if res.isOk():
    ok()
  else:
    error "Could not write to network key storage file",
          key_path = keyStorePath
    err(FailedToCreateKeystoreFile)

proc saveKeystore(rng: var BrHmacDrbgContext,
                  validatorsDir, secretsDir: string,
                  signingKey: ValidatorPrivKey, signingPubKey: ValidatorPubKey,
                  signingKeyPath: KeyPath): Result[void, KeystoreGenerationError] =
  let
    keyName = "0x" & $signingPubKey
    validatorDir = validatorsDir / keyName

  if not existsDir(validatorDir):
    var password = KeystorePass.init ncrutils.toHex(getRandomBytes(rng, 32))
    defer: burnMem(password)

    let
      keyStore = createKeystore(kdfPbkdf2, rng, signingKey,
                                password, signingKeyPath)
      keystoreFile = validatorDir / keystoreFileName

    var encodedStorage: string
    try:
      encodedStorage = Json.encode(keyStore)
    except SerializationError:
      error "Could not serialize keystorage", key_path = keystoreFile
      return err(FailedToCreateKeystoreFile)

    when defined(windows):
      let csres = createCurrentUserOnlySecurityDescriptor()
      if csres.isErr():
        error "Could not allocate security descriptor", key_path = keystoreFile
        return err(FailedToCreateKeystoreFile)
      var sd = csres.get()

      let vres = createPath(validatorDir, 0o750,
                            secDescriptor = sd.getDescriptor())
      if vres.isErr():
        return err(FailedToCreateValidatorDir)

      let sres = createPath(secretsDir, 0o750,
                            secDescriptor = sd.getDescriptor())
      if sres.isErr():
        return err(FailedToCreateSecretsDir)

      let swres = writeFile(secretsDir / keyName, password.str, 0o600,
                            secDescriptor = sd.getDescriptor())
      if swres.isErr():
        return err(FailedToCreateSecretFile)

      let kwres = writeFile(keystoreFile, encodedStorage, 0o600,
                            secDescriptor = sd.getDescriptor())
      if kwres.isErr():
        return err(FailedToCreateKeystoreFile)
    else:
      let vres = createPath(validatorDir, 0o750)
      if vres.isErr():
        return err(FailedToCreateValidatorDir)

      let sres = createPath(secretsDir, 0o750)
      if sres.isErr():
        return err(FailedToCreateSecretsDir)

      let swres = writeFile(secretsDir / keyName, password.str, 0o600)
      if swres.isErr():
        return err(FailedToCreateSecretFile)

      let kwres = writeFile(keystoreFile, encodedStorage, 0o600)
      if kwres.isErr():
        return err(FailedToCreateKeystoreFile)
  ok()

proc generateDeposits*(preset: RuntimePreset,
                       rng: var BrHmacDrbgContext,
                       mnemonic: Mnemonic,
                       firstValidatorIdx, totalNewValidators: int,
                       validatorsDir: string,
                       secretsDir: string): Result[seq[DepositData], KeystoreGenerationError] =
  var deposits: seq[DepositData]

  notice "Generating deposits", totalNewValidators, validatorsDir, secretsDir

  let withdrawalKeyPath = makeKeyPath(0, withdrawalKeyKind)
  # TODO: Explain why we are using an empty password
  var withdrawalKey = keyFromPath(mnemonic, KeystorePass.init "", withdrawalKeyPath)
  defer: burnMem(withdrawalKey)
  let withdrawalPubKey = withdrawalKey.toPubKey

  for i in 0 ..< totalNewValidators:
    let keyStoreIdx = firstValidatorIdx + i
    let signingKeyPath = withdrawalKeyPath.append keyStoreIdx
    var signingKey = deriveChildKey(withdrawalKey, keyStoreIdx)
    defer: burnMem(signingKey)
    let signingPubKey = signingKey.toPubKey

    ? saveKeystore(rng, validatorsDir, secretsDir,
                   signingKey, signingPubKey, signingKeyPath)

    deposits.add preset.prepareDeposit(withdrawalPubKey, signingKey, signingPubKey)

  ok deposits

proc saveWallet*(wallet: Wallet, outWalletPath: string): Result[void, string] =
  let walletDir = splitFile(outWalletPath).dir
  var encodedWallet: string
  try:
    encodedWallet = Json.encode(wallet, pretty = true)
  except SerializationError:
    return err("Could not serialize wallet")

  when defined(windows):
    let sres = createCurrentUserOnlySecurityDescriptor()
    if sres.isErr():
      error "Could not allocate security descriptor"
      return err("Could not create security descriptor")
    var sd = sres.get()
    let pres = createPath(walletDir, 0o750, secDescriptor = sd.getDescriptor())
    if pres.isErr():
      return err("Could not create wallet directory [" & walletDir & "]")
    let wres = writeFile(outWalletPath, encodedWallet, 0o600,
                         secDescriptor = sd.getDescriptor())
    if wres.isErr():
      return err("Could not write wallet to file [" & outWalletPath & "]")
  else:
    let pres = createPath(walletDir, 0o750)
    if pres.isErr():
      return err("Could not create wallet directory [" & walletDir & "]")
    let wres = writeFile(outWalletPath, encodedWallet, 0o600)
    if wres.isErr():
      return err("Could not write wallet to file [" & outWalletPath & "]")
  ok()

proc saveWallet*(wallet: WalletPathPair): Result[void, string] =
  saveWallet(wallet.wallet, wallet.path)

proc readPasswordInput(prompt: string, password: var TaintedString): bool =
  try:
    when defined(windows):
      # readPasswordFromStdin() on Windows always returns `false`.
      # https://github.com/nim-lang/Nim/issues/15207
      discard readPasswordFromStdin(prompt, password)
      true
    else:
      readPasswordFromStdin(prompt, password)
  except IOError:
    false

proc setStyleNoError(styles: set[Style]) =
  when defined(windows):
    try: stdout.setStyle(styles)
    except: discard
  else:
    try: stdout.setStyle(styles)
    except IOError, ValueError: discard

proc setForegroundColorNoError(color: ForegroundColor) =
  when defined(windows):
    try: stdout.setForegroundColor(color)
    except: discard
  else:
    try: stdout.setForegroundColor(color)
    except IOError, ValueError: discard

proc resetAttributesNoError() =
  when defined(windows):
    try: stdout.resetAttributes()
    except: discard
  else:
    try: stdout.resetAttributes()
    except IOError: discard

proc importKeystoresFromDir*(rng: var BrHmacDrbgContext,
                             importedDir, validatorsDir, secretsDir: string) =
  var password: TaintedString
  defer: burnMem(password)

  try:
    for file in walkDirRec(importedDir):
      let ext = splitFile(file).ext
      if toLowerAscii(ext) != ".json":
        continue

      let keystore =
        try:
          Json.loadFile(file, Keystore)
        except SerializationError as e:
          warn "Invalid keystore", err = e.formatMsg(file)
          continue
        except IOError as e:
          warn "Failed to read keystore file", file, err = e.msg
          continue

      var firstDecryptionAttempt = true

      while true:
        var secret: seq[byte]
        let status = decryptCryptoField(keystore.crypto,
                                        KeystorePass.init password,
                                        secret)
        case status
        of Success:
          let privKey = ValidatorPrivKey.fromRaw(secret)
          if privKey.isOk:
            let pubKey = privKey.value.toPubKey
            let status = saveKeystore(rng, validatorsDir, secretsDir,
                                      privKey.value, pubKey,
                                      keystore.path)
            if status.isOk:
              notice "Keystore imported", file
            else:
              error "Failed to import keystore", file, err = status.error
          else:
            error "Imported keystore holds invalid key", file, err = privKey.error
          break
        of InvalidKeystore:
          warn "Invalid keystore", file
          break
        of InvalidPassword:
          if firstDecryptionAttempt:
            try:
              const msg = "Please enter the password for decrypting '$1' " &
                          "or press ENTER to skip importing this keystore"
              echo msg % [file]
            except ValueError:
              raiseAssert "The format string above is correct"
          else:
            echo "The entered password was incorrect. Please try again."
          firstDecryptionAttempt = false

          if not readPasswordInput("Password: ", password):
            echo "System error while entering password. Please try again."

          if password.len == 0:
            break
  except OSError:
    fatal "Failed to access the imported deposits directory"
    quit 1

template ask(prompt: string): string =
  try:
    stdout.write prompt, ": "
    stdin.readLine()
  except IOError:
    return err "failure to read data from stdin"

proc pickPasswordAndSaveWallet(rng: var BrHmacDrbgContext,
                               config: BeaconNodeConf,
                               mnemonic: Mnemonic): Result[WalletPathPair, string] =
  echoP "When you perform operations with your wallet such as withdrawals " &
        "and additional deposits, you'll be asked to enter a password. " &
        "Please note that this password is local to the current machine " &
        "and you can change it at any time."
  echo ""

  var password =
    block:
      let prompt = "Please enter a password: "
      let confirm = "Please repeat the password: "
      let res = keyboardCreatePassword(prompt, confirm)
      if res.isErr():
        return err($res.error)
      res.get()
  defer: burnMem(password)

  var name: WalletName
  let outWalletName = config.outWalletName
  if outWalletName.isSome:
    name = outWalletName.get
  else:
    echoP "For your convenience, the wallet can be identified with a name " &
          "of your choice. Please enter a wallet name below or press ENTER " &
          "to continue with a machine-generated name."
    echo ""

    while true:
      var enteredName = ask "Wallet name"
      if enteredName.len > 0:
        name =
          try:
            WalletName.parseCmdArg(enteredName)
          except CatchableError as err:
            echo err.msg & ". Please try again."
            continue
      break

  let nextAccount =
    if config.cmd == wallets and config.walletsCmd == WalletsCmd.restore:
      config.restoredDepositsCount
    else:
      none Natural

  let wallet = createWallet(kdfPbkdf2, rng, mnemonic,
                            name = name,
                            nextAccount = nextAccount,
                            password = KeystorePass.init password)

  let outWalletFileFlag = config.outWalletFile
  let outWalletFile =
    if outWalletFileFlag.isSome:
      string outWalletFileFlag.get
    else:
      config.walletsDir / addFileExt(string wallet.name, "json")

  let status = saveWallet(wallet, outWalletFile)
  if status.isErr:
    return err("failure to create wallet file due to " & status.error)

  echo "\nWallet file successfully written to \"", outWalletFile, "\""
  return ok WalletPathPair(wallet: wallet, path: outWalletFile)

when defined(windows):
  proc clearScreen =
    discard execShellCmd("cls")
else:
  template clearScreen =
    echo "\e[1;1H\e[2J\e[3J"

proc createWalletInteractively*(
    rng: var BrHmacDrbgContext,
    config: BeaconNodeConf): Result[CreatedWallet, string] =

  if config.nonInteractive:
    return err "not running in interactive mode"

  echoP "The generated wallet is uniquely identified by a seed phrase " &
        "consisting of 24 words. In case you lose your wallet and you " &
        "need to restore it on a different machine, you can use the " &
        "seed phrase to re-generate your signing and withdrawal keys."
  echoP "The seed phrase should be kept secret in a safe location as if " &
        "you are protecting a sensitive password. It can be used to withdraw " &
        "funds from your wallet."
  echoP "We will display the seed phrase on the next screen. Please make sure " &
        "you are in a safe environment and there are no cameras or potentially " &
        "unwanted eye witnesses around you. Please prepare everything necessary " &
        "to copy the seed phrase to a safe location and type 'continue' in " &
        "the prompt below to proceed to the next screen or 'q' to exit now."
  echo ""

  while true:
    let answer = ask "Action"
    if answer.len > 0 and answer[0] == 'q': quit 1
    if answer == "continue": break
    echoP "To proceed to your seed phrase, please type 'continue' (without the quotes). " &
          "Type 'q' to exit now."
    echo ""

  var mnemonic = generateMnemonic(rng)
  defer: burnMem(mnemonic)

  try:
    echoP "Your seed phrase is:"
    setStyleNoError({styleBright})
    setForegroundColorNoError fgCyan
    echoP $mnemonic
    resetAttributesNoError()
  except IOError, ValueError:
    return err "failure to write to the standard output"

  echoP "Press any key to continue."
  try:
    discard getch()
  except IOError as err:
    fatal "Failed to read a key from stdin", err = err.msg
    quit 1

  clearScreen()

  echoP "To confirm that you've saved the seed phrase, please enter the " &
        "first and the last three words of it. In case you've saved the " &
        "seek phrase in your clipboard, we strongly advice clearing the " &
        "clipboard now."
  echo ""

  for i in countdown(2, 0):
    let answer = ask "Answer"
    let parts = answer.split(' ', maxsplit = 1)
    if parts.len == 2:
      if count(parts[1], ' ') == 2 and
         mnemonic.string.startsWith(parts[0]) and
         mnemonic.string.endsWith(parts[1]):
        break
    else:
      doAssert parts.len == 1

    if i > 0:
      echo "\nYour answer was not correct. You have ", i, " more attempts"
      echoP "Please enter 4 words separated with a single space " &
            "(the first word from the seed phrase, followed by the last 3)"
      echo ""
    else:
      quit 1

  clearScreen()

  let walletPath = ? pickPasswordAndSaveWallet(rng, config, mnemonic)
  return ok CreatedWallet(walletPath: walletPath, mnemonic: mnemonic)

proc restoreWalletInteractively*(rng: var BrHmacDrbgContext,
                                 config: BeaconNodeConf) =
  var
    enteredMnemonic: TaintedString
    validatedMnemonic: Mnemonic

  defer:
    burnMem enteredMnemonic
    burnMem validatedMnemonic

  echo "To restore your wallet, please enter your backed-up seed phrase."
  while true:
    if not readPasswordInput("Seedphrase: ", enteredMnemonic):
      fatal "failure to read password from stdin"
      quit 1

    if validateMnemonic(enteredMnemonic, validatedMnemonic):
      break
    else:
      echo "The entered mnemonic was not valid. Please try again."

  discard pickPasswordAndSaveWallet(rng, config, validatedMnemonic)

proc unlockWalletInteractively*(wallet: Wallet): Result[Mnemonic, string] =
  let prompt = "Please enter the password for unlocking the wallet: "
  echo "Please enter the password for unlocking the wallet"

  let res = keyboardGetPassword[Mnemonic](prompt, 3,
    proc (password: string): KsResult[Mnemonic] =
      var secret: seq[byte]
      defer: burnMem(secret)
      let status = decryptCryptoField(wallet.crypto, KeystorePass.init password, secret)
      case status
      of Success:
        let mnemonic = Mnemonic(string.fromBytes(secret))
        ok(mnemonic)
      else:
        # TODO Handle InvalidKeystore in a special way here
        let failed = "Unlocking of the wallet failed. Please try again"
        echo failed
        err(failed)
  )

  if res.isOk():
    ok(res.get())
  else:
    err "Unlocking of the wallet failed."

proc loadWallet*(fileName: string): Result[Wallet, string] =
  try:
    ok Json.loadFile(fileName, Wallet)
  except SerializationError as err:
    err "Invalid wallet syntax: " & err.formatMsg(fileName)
  except IOError as err:
    err "Error accessing wallet file \"" & fileName & "\": " & err.msg

proc findWallet*(config: BeaconNodeConf,
                 name: WalletName): Result[Option[WalletPathPair], string] =
  var walletFiles = newSeq[string]()
  try:
    for kind, walletFile in walkDir(config.walletsDir):
      if kind != pcFile: continue
      let walletId = splitFile(walletFile).name
      if cmpIgnoreCase(walletId, name.string) == 0:
        let wallet = ? loadWallet(walletFile)
        return ok some WalletPathPair(wallet: wallet, path: walletFile)
      walletFiles.add walletFile
  except OSError as err:
    return err("Error accessing the wallets directory \"" &
                config.walletsDir & "\": " & err.msg)

  for walletFile in walletFiles:
    let wallet = ? loadWallet(walletFile)
    if cmpIgnoreCase(wallet.name.string, name.string) == 0 or
       cmpIgnoreCase(wallet.uuid.string, name.string) == 0:
      return ok some WalletPathPair(wallet: wallet, path: walletFile)

  return ok none(WalletPathPair)

type
  # This is not particularly well-standardized yet.
  # Some relevant code for generating (1) and validating (2) the data can be found below:
  # 1) https://github.com/ethereum/eth2.0-deposit-cli/blob/dev/eth2deposit/credentials.py
  # 2) https://github.com/ethereum/eth2.0-deposit/blob/dev/src/pages/UploadValidator/validateDepositKey.ts
  LaunchPadDeposit* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    amount*: Gwei
    signature*: ValidatorSig
    deposit_message_root*: Eth2Digest
    deposit_data_root*: Eth2Digest
    fork_version*: Version

func init*(T: type LaunchPadDeposit,
           preset: RuntimePreset, d: DepositData): T =
  T(pubkey: d.pubkey,
    withdrawal_credentials: d.withdrawal_credentials,
    amount: d.amount,
    signature: d.signature,
    deposit_message_root: hash_tree_root(d as DepositMessage),
    deposit_data_root: hash_tree_root(d),
    fork_version: preset.GENESIS_FORK_VERSION)

func `as`*(copied: LaunchPadDeposit, T: type DepositData): T =
  T(pubkey: copied.pubkey,
    withdrawal_credentials: copied.withdrawal_credentials,
    amount: copied.amount,
    signature: copied.signature)
