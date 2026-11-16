# ForgeDeck security model

This document states what ForgeDeck protects, what it does not, and where each rule lives in the code.
It ends with a security check report that maps each leak and injection check to the test that covers it.
It describes the code as of 2026-11-15. Weak spots are listed plainly in "Known limits".

## What is protected

| Asset | Where it lives |
| --- | --- |
| Secret values (API keys, tokens, database URLs) | macOS Keychain, or an external reference (1Password CLI, an environment variable) |
| The GitHub token | macOS Keychain |
| SSH private keys | Never touched. They stay with the user's SSH agent and `~/.ssh` |
| Lead contact details | Masked on arrival. The full value is never stored |
| Production systems | Read-only requests only, plus user-written recipes behind confirmation |

## Threats considered

| Threat | Answer in the code |
| --- | --- |
| A secret ends up in a file, an export, a log, or a command line | Secrets are read just before use and exist only in memory. See "What is never stored" and the check report |
| A hostile folder or file name injects a shell command | No shell is used. Programs run with an executable URL and an argument array. The two places that need shell text use single-quote quoting |
| A remote API response becomes part of a command | SSH commands come from a fixed catalog. Revisions passed to git must be hex. Nothing from a response is added to an argument list |
| A production secret leaks into a development session | Each variable lists the tiers it may resolve into. A wrong tier is Blocked, not inherited |
| A CLI caller forges arguments to reach production | A profile is bound to one environment, lists its programs and variables, and production secrets need device-owner authentication |
| A bearer token is sent to the wrong host | HTTPS is required off loopback, credentials in URLs are refused, and redirects must stay on the same host |
| A man in the middle on SSH | `StrictHostKeyChecking=yes`, `BatchMode=yes`. The app never accepts a host key |
| A staging build answers on the production URL | The companion status must declare the expected environment or it is rejected |

## Trust boundaries

1. **The person at the Mac.** Trusted. Device-owner authentication (Touch ID or the account password) is how the app asks "is it you?" for production secrets.
2. **The app binary.** One binary is both the app and the `forgedeck` CLI. They share one code signature.
3. **Other processes running as the same user.** Not trusted, but only partly defended against. See "Known limits".
4. **Child processes started with granted variables.** They receive the values. From that point the values are theirs.
5. **Remote systems** (GitHub, status endpoints, SSH hosts, metric sources). Their answers are data. They are parsed, validated, bounded, and never executed.
6. **Files in project folders.** Read for nonsecret metadata only. Names that usually hold secrets are never opened.

## Keychain storage

Code: `Security/SecretStore.swift`.

- One generic-password item per credential. Service `com.forgedeck.vault`, account = the `CredentialReference` locator (a UUID string).
- Added with `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`, and the label "ForgeDeck credential".
- An update replaces the value in place with `SecItemUpdate`, so rotation keeps the same item.
- `exists` uses an `LAContext` with `interactionNotAllowed`, so checking for an item never raises a prompt.
- Deleting a variable, disconnecting GitHub, or removing a product deletes the matching Keychain items.

What this means in practice:

- The code does not set `kSecUseDataProtectionKeychain` and the app has no keychain access group entitlement. Items therefore go to the user's login keychain, where access is controlled by the item's access list, which names the app that created it.
- Apple documents `kSecAttrAccessible` for data-protection keychain items. Whether the `WhenUnlockedThisDeviceOnly` attribute has any effect on a login-keychain item was not verified. Treat the "only while unlocked, this device only" property as intended, not proven. The login keychain is itself locked when the user is logged out, and these items are not marked synchronizable.
- Because the CLI is the same signed binary, it reads the items without a second trust prompt. This was exercised: the self-test writes real items, runs `forgedeck exec` as a child process, and deletes the items.
- A rebuild signed with a different identity (for example ad hoc, where each build has a new signature) is a different app to the Keychain. macOS then asks whether to allow access. See the User Manual troubleshooting section.

Other origins (`CredentialResolver`):

| Origin | How the value is read | Status |
| --- | --- | --- |
| Keychain | `SecItemCopyMatching` | Exercised |
| 1Password CLI | `op read --no-newline op://...` with a 30 second timeout | Implemented, not exercised (`op` is not installed here) |
| Environment reference | The named variable in ForgeDeck's own environment | Covered by unit tests |
| SSH agent | Never read. Asking for the value is an error | By design |

## The CLI trust model

Code: `CLI/CLI.swift`, `Security/ExecService.swift`.

### What it is

`forgedeck exec --product <slug> --environment <name> --profile <name> -- <program> [args...]` starts one program with only the variables a profile grants. The rules, in the order `ExecService.plan` applies them:

1. The product must exist and must not be archived.
2. The environment must exist in that product.
3. The profile must exist in that product.
4. If the profile is bound to an environment, it must be the one named. A development profile cannot be aimed at production by passing another flag.
5. The program must be a bare name with no `/`, and the profile's `allowedExecutables` must contain it exactly. An empty list allows nothing.
6. The program is located by `ExecutableLocator.find(program, environment: [:])`. The caller's `PATH` is not consulted. The folders searched, in order: `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/bin`.
7. Variables are resolved for the product, environment, and profile, then filtered to the profile's `variableAllowlist`.
8. If any allowlisted variable is Blocked (wrong tier) or Expired, the run is denied. If any is Missing, the run is denied.
9. If the environment is production, at least one granted variable is a secret, and the setting "Ask for Touch ID or password before using production secrets" is on, `DeviceOwnerAuthorizer` must succeed (`LAContext`, policy `deviceOwnerAuthentication`).
10. Only then are secret values read. They are placed in the child's environment in memory, along with `FORGEDECK_PRODUCT` and `FORGEDECK_ENVIRONMENT`.

Every denial throws before any secret is read, writes one `exec.denied` audit event with a short reason code, and exits with code 77. A grant writes `exec.granted` with the profile, program name, and variable names. When the child ends, `exec.finished` records its exit code.

The granted variable names are printed to stderr. Values are never printed.

Read commands (`list`, `status`, `env list`, `actions list`, `context`, `doctor`) read the two JSON files and print names, scopes, and states. `env list` never prints a value, secret or plain. `actions list` prints the program name only, not arguments.

### What it is not

- **It does not authenticate its caller.** Any process running as the user can run `forgedeck`. There is no XPC service, no socket, and no caller code-signature check. The contract's warning that a mode-0600 socket does not authenticate same-user code applies equally here: the same-binary design removes the IPC channel but does not identify who started the CLI.
- **It does not hide a value from the program that receives it.** The child and everything the child starts can read its environment. That is the purpose of the grant. The profile sheet says so, and it warns against listing a shell.
- **It does not sandbox the child.** The child starts from the caller's full environment (`ExecService.baseEnvironment`) plus the granted variables, in the profile's checkout folder.
- **Development secrets have no prompt.** Only production secrets ask for device-owner authentication.

### What a same-user attacker can still do

Stated plainly, because the code allows it:

- If a profile allows `npm`, `node`, `make`, or any program that runs code from the working directory, then anyone who can write to that checkout can make the allowed program run their code with the granted variables. An attacker who can run allowed programs in a writable checkout can abuse them.
- `portfolio.json` is a mode-0600 file owned by the user. A same-user process can edit it: add a program to a profile, add a variable to an allowlist, widen a variable's allowed tiers, or turn off the production authentication setting. The file is not signed or integrity-protected. The rules above therefore stop forged arguments, not a process that can rewrite the registry.
- Three of the eight program search folders are commonly user-writable: `/opt/homebrew/bin`, `~/.local/bin`, `~/bin` (and `/usr/local/bin` on some Macs). A same-user process can place a binary with an allowed name in a later folder if no earlier folder has one.
- The child inherits the caller's `PATH`. A program that itself looks up helpers through `PATH` follows the caller's choice.

What still holds against that attacker: production secrets need Touch ID or the password as long as the setting is on, and secret values are not in any file the attacker can read without going through the Keychain's access list.

### Output redaction

`ChildProcess.run` passes the child's stdout and stderr through `Redactor` when stdout is not a terminal, or when the undocumented `--redact` switch is given before `--`. The redactor knows the exact granted values and the token patterns below. Lines are buffered so a value split across two reads is still matched. When stdout is a terminal, the child owns it and nothing is redacted.

## Variable scopes and tier blocking

Code: `Security/VariableResolver.swift`.

Precedence, lowest to highest: Global, Organization, Product, Component, Environment, Profile.

For each key in scope:

1. Keep the definitions whose `allowedTiers` contain the target environment's tier.
2. The winner is the highest-precedence one that remains.
3. If none remains, the key is **Blocked** with a note naming the tiers it is allowed in. It is not inherited from a wider scope.
4. If the winner's credential is past `expiresAt`, the key is **Expired**.
5. If a profile allowlist is in effect and does not contain the key, it is **Not granted**.
6. A key the allowlist names that nothing defines is **Missing**.

States that deliver a value: Inherited, Overridden, Direct.

A new variable defaults to `allowedTiers = [.development]`. Choosing Environment scope in the sheet sets the tiers to that environment's tier and locks the checkboxes. The vault page warns when a secret is allowed in Production and in another tier, and when a key is defined twice at one scope.

The same resolver decides which bearer token a probe or metrics source may use (`RefreshEngine.bearer`): a token that is not allowed in the environment's tier is not sent.

## In-app actions

Code: `AppModel+Actions.swift` (`run`, `execute`).

- Only approved recipes run. Detected commands start as unapproved suggestions. Saving a recipe you wrote approves it.
- A recipe's program and arguments are an array. The recipe sheet refuses `|`, `&&`, `||`, `;`, `>`, `<`, `>>` as words.
- Safety classes: Read-only, Local write, Remote write, Production critical. A local recipe aimed at a production environment is raised to at least Remote write when saved.
- Remote write, Production critical, and any recipe in a production environment open the confirmation sheet first. It shows the target, the command, and the variable names, and needs a one-second press and hold. VoiceOver users get a "Confirm" action instead of the hold.
- A captured run resolves the recipe's variable keys for its environment. A key that does not deliver a value stops the run with exit code 77. Output is redacted with the known values and shown in a sheet. It is not saved.
- A recipe run "in a terminal" receives no variables. It runs through a `.command` launch script.
- SSH recipes can only name a probe from the fixed catalog and are forced to Read-only.
- Archived and demo products cannot run actions.
- Each run writes a `recipe.run` audit event.

Two differences from `forgedeck exec` to know about:

- In-app recipe runs that receive a production secret ask for Touch ID or the password after the hold-to-confirm sheet, when the setting is on. This path needs a person and was not exercised by automation.
- The recipe's program is located with the app's own `PATH` as a fallback after the fixed folders.

## Revealing and copying secrets

- Values are masked by default. Reveal shows the value for the reveal timeout (15, 30, or 60 seconds), then hides it.
- Copy puts the value on the clipboard and clears the clipboard after the same timeout if nothing else was copied in between.
- A variable allowed in production asks for device-owner authentication before reveal or copy when the setting is on.
- Reveal and copy write `secret.reveal` or `secret.copy` audit events, with outcome `denied` when authentication fails.
- The command palette lists names and places only. `CopyableValue` is never used for secrets.

## Redaction limits

Code: `Security/Redactor.swift`.

The redactor replaces, with `••••••`:

- exact known values of four or more characters, longest first;
- GitHub tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`);
- Stripe-style keys (`sk_`, `rk_`, `pk_` with `live` or `test`), `whsec_`;
- Slack tokens (`xox?-`), AWS access key ids (`AKIA...`);
- JWT-shaped text;
- PEM private key blocks;
- the token after `Bearer `;
- `user:password` in a URL;
- the value after `password`, `passwd`, `secret`, `token`, `api_key`, `api-key` followed by `=` or `:`.

It is applied to audit details, SSH probe output, Docker output, clone and fetch errors, remote URLs found during discovery, recipe output, and the agent context file.

It cannot recognize a secret that has no known shape and was not granted in this run, a value shorter than four characters, or a value a program transforms (base64, hex, split across lines). It can also mask ordinary text that happens to match a pattern. Program output cannot be guaranteed free of sensitive data.

## SSH rules

Code: `Connectors/SSHInspector.swift`.

- The system client `/usr/bin/ssh` is used with the user's own config and agent. ForgeDeck never reads, copies, or stores a private key.
- Every probe passes: `BatchMode=yes`, `StrictHostKeyChecking=yes`, `ConnectTimeout=8`, `NumberOfPasswordPrompts=0`, `ForwardAgent=no`, `ClearAllForwardings=yes`, `-T`, then `--`, the alias, and the command.
- An alias must start with something other than `-`, be at most 255 characters, and contain only ASCII letters, digits, and `. _ - @`.
- Remote commands come from a fixed catalog of five: `uptime`, `df -h /`, `free -m 2>/dev/null || vm_stat`, `docker ps --format ...`, `uname -srm`.
- One command has a user-supplied part: `cat -- <path>` for a release file. The path must be absolute, contain no `..`, be at most 300 characters, and use only ASCII letters, digits, and `/ . _ -`. It is single-quoted.
- A changed host key is classified `hostKeyChanged`, an unknown one `hostKeyUnknown`. Neither is ever OK, and the Doctor stops before authentication when the host is not in `known_hosts`.
- Output is capped at 64,000 bytes and redacted.

Two things outside those rules:

- "Connect" opens an interactive `ssh -- <alias>` in the user's terminal. That session uses the user's ssh configuration, not the options above. If the host is unknown, ssh asks the person in the terminal, as it always does.
- `SSHHostConfig.allowedProbeIDs` is stored and displayed but not enforced. The Infrastructure > SSH tab offers every catalog probe for every host in `~/.ssh/config`. All five are read-only.

## URL policy and redirects

Code: `Connectors/ConnectorCore.swift`.

- `URLPolicy.validate` accepts `https` to any host and `http` only to loopback: `localhost`, `*.localhost`, `::1`, or a literal `127.x.y.z`. A host name such as `127.evil.example` is not loopback.
- URLs with a user or password are refused.
- Other schemes are refused.
- Probe and metrics URLs are validated when added and again before every request. A URL that breaks the policy is never requested.
- The HTTP client refuses a redirect to another host and a redirect from `https` to `http`. Otherwise the `Authorization` header would travel to a host the user never configured.
- The session is ephemeral: no cookies, no cache.
- Requests are `GET` only. The app never follows a URL taken from a remote response. It does not read the companion `manifest`.

Limit: the policy does not block private network addresses. A user can point a probe at any HTTPS host they type. Since URLs come only from the user, this was judged acceptable.

## Discovery

Code: `Services/ProjectDiscovery.swift`.

- `isSecretBearing` refuses `.env`, `.env.*`, `*.env`, `.npmrc`, `.netrc`, `.pypirc`, `credentials`, `credentials.json`, `secrets.json`, `secrets.yml`, `secrets.yaml`, SSH key names, `.htpasswd`, `wp-config.php`, and the extensions `.pem`, `.key`, `.p12`, `.pfx`, `.keystore`, `.jks`, `.mobileprovision`.
- Files read: `package.json`, `composer.json`, `pyproject.toml`, `requirements.txt`, Compose files, top-level `.php` headers (first 8 KB), a README (first 4 KB), and `.git/config` for remotes.
- A credential embedded in a remote URL is redacted before the URL is stored.
- Symlinks are not followed. Hidden folders and dependency folders are skipped. Limits: depth 4, 20,000 directories, 500 results.

## What is never stored

- A secret value, in `portfolio.json`, `cache.json`, `audit.jsonl`, an export, a launch script, or an argument list.
- A full lead contact. `CompanionMetricsConnector` masks contact text on arrival.
- A terminal transcript or recipe output. Session records hold the app, product, checkout, environment, time, a safe command name, and an exit status.
- SSH private keys or passphrases.
- A plain variable whose value looks like a token: the sheet refuses it and asks for it to be marked secret.

What is stored in plain text: product names, paths, URLs, variable names and scopes, plain (nonsecret) variable values, the GitHub account login, and observations.

## Audit log

`audit.jsonl` in the data folder, one JSON object per line, opened with `O_APPEND` and mode 0600.

| Actor | Actions |
| --- | --- |
| `app` | `open.terminal`, `open.ssh`, `product.add`, `product.remove`, `repository.clone`, `variable.add`, `variable.edit`, `variable.rotate`, `variable.delete`, `secret.reveal`, `secret.copy`, `connection.connect`, `connection.disconnect`, `profile.save`, `recipe.run`, `data.export`, `data.import`, `data.clear-cache` |
| `cli` | `open`, `exec.granted`, `exec.denied`, `exec.finished` |

Details hold names and counts and pass through the redactor before writing. Denial events carry a reason code, not command-line text. The vault page shows the newest events.

Limits: the log is a plain file the user can edit or delete. It has no tamper evidence, rotation, or size cap. Opening an editor is not audited. Test, snapshot, and self-test runs of the app do not write app events.

## Sandbox and entitlements

The app is **not sandboxed** and ships no entitlements file. The reasons:

- It must read Git state in arbitrary user-chosen folders, including ones chosen by the CLI's working context.
- It runs `git`, `ssh`, `ssh-keygen`, `docker`, `op`, `gh`, and user-approved programs as child processes.
- It reads `~/.ssh/config` and relies on the user's SSH agent.
- The CLI is the same binary started from a shell, where a sandbox container would cut it off from the folders it is asked to work in.

What is lost: the system does not limit the app's file or network reach, and there is no App Store distribution path. What is kept: no privileged helper, no listener port, no Automation, Accessibility, or Full Disk Access request. Folders open through Launch Services, so no Apple Events are sent.

Hardened runtime: `scripts/package.sh` signs with `--options runtime` for any real identity. `./build.sh` does not. The app loads no plugins and needs no runtime exceptions.

## Known limits

1. The CLI does not authenticate its caller (see above).
2. `portfolio.json` is not integrity-protected, so a same-user process can change allowlists and the production authentication setting.
3. The program search list for `exec` includes user-writable folders.
4. The effect of the Keychain accessibility attribute on login-keychain items is unverified.
5. In-app production recipe runs ask for device-owner authentication, but that prompt has not been exercised end to end.
6. Touch ID confirmation was not exercised by automation; it needs a person. Tests use a fixed authorizer.
7. Redaction is best effort.
8. `ExecDenial.productionNeedsConfirmation` is defined but nothing throws it.
9. Companion request signing (HMAC) is in the companion packages but the app does not sign requests. A companion configured to require signing will reject the app.
10. No notarization: the build is signed with an Apple Development identity.

## Security check report

Run on 2026-11-15. All listed tests pass. Test names are functions in `Tests/ForgeDeckKitTests`. "Self-test" means a named check printed by `tools/selftest.sh`, which uses the real Keychain and a real `forgedeck exec` child process.

### Secrets are never persisted

| Check | Covered by |
| --- | --- |
| Saved `portfolio.json` holds no secret value | `SecurityTests`: `savedPortfolioHoldsNoSecretValue`. Self-test: "no secret value is in the saved files", "the saved files hold no secret value" |
| `cache.json` after an authenticated refresh holds no secret value | `SecurityTests`: `cacheWrittenAfterAnAuthenticatedRefreshHoldsNoSecretValue` |
| Export holds no secret value | `SecurityTests`: `exportHoldsNoSecretValue`, `exportDropsBookmarksAndTokenLookingValuesAndListsPlaceholders`. Self-test: "the export holds no secret value" |
| Audit file holds no secret value after grants and denials | `SecurityTests`: `auditFileHoldsNoSecretValueAfterGrantsAndDenials`, `everyDenialWritesOneAuditEventWithNoCommandLineText`. `PersistenceTests`: `tokenShapedTextInDetailIsRedactedBeforeItIsWritten`. Self-test: "the audit log holds no secret value" |
| Process arguments and launch script text hold no secret value | `SecurityTests`: `planArgumentsAndLaunchTextHoldNoSecretValue`. `LauncherTests`: `runWritesAPrivateScriptThatHoldsNoSecrets` |
| Agent context file holds no secret or plain value | `SecurityTests`: `agentContextHoldsNoSecretOrPlainValue`. `CLITests`: `contextDescribesTheProductWithoutValues` |
| CLI help and read commands print no secret value | `CLITests`: `noReadCommandPrintsASecretValue`, `envListShowsStatesAndNeverValues`, `actionsListShowsProgramNamesNotArguments`. Self-test: "env list shows names without values", "exec names what it granted, not the value" |
| The command palette lists no secret | Self-test: "the palette never lists a secret" |
| Data files are private to the user | `PersistenceTests`: `filesArePrivateToTheUser` |
| Keychain items are written, read, replaced, and deleted | `SecurityTests`: `keychainRoundTrip`. Self-test: "each secret is a Keychain item", "the next run receives the rotated value", "deleting the variables removes their Keychain items" |
| Lead contacts are masked on arrival | `MetricsTests`: `contactsAreMaskedOnArrival`. `SecurityTests`: `maskingContacts` |

### Scopes and grants

| Check | Covered by |
| --- | --- |
| A development profile receives only its development token | `SecurityTests`: `developmentProfileReceivesOnlyItsDevelopmentToken`, `aRealChildSeesTheDevelopmentVariableAndNotTheProductionOne`. Self-test: "forgedeck exec gives the child the development token" |
| A production-only secret is blocked in development | `SecurityTests`: `aProductionOnlySecretIsBlockedInDevelopment`. `DomainTests`: `productionSecretIsBlockedInDevelopment`. Self-test: "a production secret is denied in development" |
| A development profile cannot be aimed at production | `SecurityTests`: `aDevelopmentProfileCannotBePointedAtProduction`. `CLITests`: `aDevelopmentProfileForgedOntoProductionIsDenied`. Self-test: "a development profile cannot be pointed at production" |
| A profile of another product is denied | `CLITests`: `aProfileOfAnotherProductIsDenied` |
| Forged or repeated flags do not escalate | `CLITests`: the parameterized denial test at `CLITests.swift:426` (nine argument sets) and the usage test at `CLITests.swift:454`; `flagsAfterTheSeparatorBelongToTheProgram` |
| Production without authentication reads no secret | `SecurityTests`: `productionWithoutAuthenticationReadsNoSecret` |
| Production with authentication is granted and audited by name only | `SecurityTests`: `productionWithAuthenticationIsGrantedAndAuditedByNameOnly`. `CLITests`: `productionExecWithAuthenticationIsGranted` |
| Authentication is not asked when no secret is granted; the setting can turn it off | `SecurityTests`: `authenticationIsNotAskedWhenNoSecretIsGranted`, `theSettingCanTurnProductionAuthenticationOff` |
| Archived, unknown, expired, missing, and unavailable cases are denied | `SecurityTests`: `anArchivedProductIsDenied`, `unknownProductEnvironmentAndProfileAreDenied`, `anExpiredCredentialIsDenied`, `anAllowlistedVariableThatNothingDefinesIsDenied`, `aSecretMissingFromTheStoreIsDeniedWithoutLeakingOthers`, `aProgramThatIsNotInstalledIsDenied` |
| Precedence, shadowing, and tier rules | `DomainTests`: `precedenceRunsFromGlobalToProfile`, `overrideReportsWhatItShadows`, `aWiderAllowedDefinitionWinsWhenTheNarrowerIsForAnotherTier`, `allowlistGivesNotGrantedAndMissing`, `warningsFlagDuplicatesAndCrossTierSecrets` |

### Program allowlist

| Check | Covered by |
| --- | --- |
| Programs outside the allowlist are denied, including paths, shells, option-like names, and names with shell syntax | `SecurityTests`: `programsOutsideTheAllowlistAreDenied` (15 cases, among them `/bin/sh`, `npm; rm -rf`, `$(env)`, `` `env` ``, `-env`, `/usr/bin/sudo`). Self-test: "a program the profile does not list is denied" |
| A look-alike binary at another path is denied | `SecurityTests`: `aLookalikeProgramAtAnotherPathIsDenied` |
| The caller's `PATH` does not choose the binary | `SecurityTests`: `theCallersPathDoesNotChooseTheBinary` |
| An empty command or an empty allowlist runs nothing | `SecurityTests`: `anEmptyCommandIsDenied`, `aProfileWithNoAllowedProgramsRunsNothing` |
| Only the exact CLI name or a CLI command triggers CLI mode | `CLITests`: `invocationDetection`, `launchingTheAppBinaryIsNotACLICall` |

### Injection

| Check | Covered by |
| --- | --- |
| Hostile names (quotes, semicolons, backticks, `$()`, newlines, Unicode) survive quoting unchanged | `LauncherTests`: the two parameterized tests over `hostileNames` in `ShellQuoteTests`, `plainWordsStayReadable` |
| A generated launch script passes every argument literally and runs in the requested folder | `LauncherTests`: `aGeneratedScriptPassesEveryArgumentLiterally`, `aGeneratedScriptRunsInTheRequestedDirectory`, `aMissingDirectoryStopsTheScriptBeforeTheCommand`, `scriptTextHasAQuotedCdAndExec`. Self-test: "the launch script quotes the apostrophe" |
| Hostile path characters are just a path to git | `GitServiceTests`: `hostilePathCharactersAreJustAPath` |
| Option-looking revisions and URLs never reach git | `GitServiceTests`: `optionLookingRevisionsNeverReachGit`, `invalidOrOptionLookingURLsAreRejectedBeforeGitRuns`, `cloneArgumentsEndOptionParsingBeforeTheURL`, `optionLookingInputIsRejected`, `aLeadingDashIsNeverAnOwner` |
| No shell invocation in the sources | `scripts/lint.sh`: "shell invocations (must be empty)" |
| "Opened" is reported only when the app accepted the request | `LauncherTests`: `openFolderReportsOpenedOnlyWhenTheOpenerSucceeded`, `anOpenerThatThrowsIsNeverReportedAsOpened`, `anAppThatIsNotInstalledFailsWithAUsableCopyCommand`. `CLITests`: `aFailedOpenPrintsTheCommandToRunInstead` |
| Only web links are opened | `LauncherTests`: `onlyWebLinksAreOpened` |

### SSH

| Check | Covered by |
| --- | --- |
| Every probe checks host keys and never prompts | `ConnectorTests`: `argumentsAlwaysCheckHostKeysAndNeverPrompt` |
| `StrictHostKeyChecking=no` appears nowhere | `scripts/lint.sh` |
| A changed host key is never OK and never Verified | `ConnectorTests`: `aChangedHostKeyIsNeverOKAndNeverVerified`, `stderrClassification` |
| An invalid alias never reaches ssh | `ConnectorTests`: `anInvalidAliasNeverReachesSSH`, `aliasValidation` |
| The probe catalog is fixed; release paths are limited | `ConnectorTests`: `theProbeCatalogIsFixed`, `releasePathsAreLimitedToPlainAbsolutePaths` |
| Probe output is redacted | `ConnectorTests`: `aSuccessfulProbeReturnsRedactedOutput` |
| Unknown host stops the Doctor | Manual: `forgedeck doctor --ssh localhost` reported the missing host key and did not continue |

### Network

| Check | Covered by |
| --- | --- |
| HTTPS required off loopback; credentials in URLs refused; other schemes refused | `ConnectorTests`: `plainHTTPOnAPublicHostIsRejected`, `plainHTTPOnLoopbackIsAccepted`, `embeddedCredentialsAreRejected`, `otherSchemesAreRejected`, `thingsThatAreNotURLsAreInvalid` |
| A host name that starts with `127.` is not loopback | `ConnectorTests`: `aHostNameThatStartsWith127IsNotLoopback` |
| A URL that breaks the policy is never requested | `ConnectorTests`: `aURLThatBreaksThePolicyIsNeverRequested` |
| No token means no Authorization header | `ConnectorTests`: `noTokenMeansNoAuthorizationHeader` |
| A staging build on the production URL, or another product, is rejected | `ConnectorTests`: `aStagingBuildAnsweringOnTheProductionURLIsRejected`, `anotherProductAnsweringIsRejected`. `AcceptanceTests`: `aStagingBuildIsNotRecordedAsProduction` |
| Expired or revoked companion token | `ConnectorTests`: `unauthorizedWithAToken`. `EvidenceTests`: `aRevokedTokenAfterAGoodAnswerIsStaleWithTheReason`. `AcceptanceTests`: `rotatingATokenChangesTheConnection` |
| Redirect to another host is refused | Not covered by an automated test. The rule is in `URLSessionHTTPClient.urlSession(_:task:willPerformHTTPRedirection:newRequest:)` |
| TLS failure is reported as such | `ConnectorTests`: the parameterized transport-error tests in `GitHubConnectorTests` and `HTTPProbeTests`, `errorMapping`. No test against a live expired certificate |

### Discovery and redaction

| Check | Covered by |
| --- | --- |
| Secret-bearing files in a project are never read | `DiscoveryTests`: `secretBearingNamesAreRecognised`, `secretFilesInAProjectAreNeverRead` |
| A token or password in a remote URL is redacted | `DiscoveryTests`: `aTokenEmbeddedInTheRemoteURLIsRedacted`, `aPasswordInAnyRemoteURLIsRedacted`. `GitServiceTests`: `credentialsInTheURLDoNotBecomeTheHost`, `aFailedCloneReportsARedactedReason` |
| Each token pattern | `SecurityTests`: `everyPatternCompiles`, `gitHubTokens`, `stripeAndOtherProviderKeys`, `jwtShapedText`, `bearerHeaders`, `urlCredentials`, `privateKeyBlocks`, `assignmentsOfPasswordsAndKeys`, `knownValuesAreMaskedLongestFirst`, `ordinaryTextIsUntouched` |
| A secret split across two reads is still redacted | `SecurityTests`: `lineBufferKeepsASplitSecretOnOneLine` |
| Docker logs are bounded and redacted; container names are validated | `ConnectorTests`: `logsAreBoundedAndRedacted`, `containerNameValidation`, `containersUsesAFixedArgumentList` |

### Not covered by an automated check

- Secrets in screenshots. Snapshot runs use an in-memory store with the placeholder `demo-value-not-a-real-secret`, and values are masked unless revealed. No test scans the PNGs.
- Crash reports. The app writes no crash diagnostics of its own.
- macOS notifications. None are posted.
- The real Touch ID prompt.
- The redirect rule and a live TLS failure, as noted above.
