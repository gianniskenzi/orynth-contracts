# Orynth Robinhood contracts

Solidity source, ABIs, deployment addresses, and original compiler inputs for Orynth's token launch contracts on Robinhood Chain (chain ID **4663**).

## Current deployment

| Contract | Mainnet address |
| --- | --- |
| OrynthRobinhoodLauncher | [0xF67B66751Ef6b0733eeb562c2BC37D856CF00214](https://robinhoodchain.blockscout.com/address/0xF67B66751Ef6b0733eeb562c2BC37D856CF00214?tab=contract) |
| OrynthTokenDeployer | [0xFAA6e7470abDa93496Fca2c49E38CB27F0b51f8F](https://robinhoodchain.blockscout.com/address/0xFAA6e7470abDa93496Fca2c49E38CB27F0b51f8F?tab=contract) |

Each launch creates its own `OrynthLaunchTokenV2` and `OrynthFeeLocker`. The current deployment's recorded token and locker addresses are in [the deployment manifest](deployments/robinhood-mainnet.json). That manifest is a dated snapshot, not a live index or a complete history of all prior launches.

## Verification status

As of September 5, 2026 (UTC), **30 recorded addresses have exact-match source verification on Sourcify**: the 12 current launch tokens, their 12 lockers, and six shared current/historical contracts. [Per-address results](deployments/verification-status.json) include direct source links. For example, [OCR Genius is verified here](https://repo.sourcify.dev/4663/0x99E35ac90a8E583c06d68aE9e894939cdfA15f4C).

The current launcher also displays an exact match on Blockscout. Further Blockscout publication is pending: its API returned HTTP 403, and the browser submission for OCR returned “Something went wrong.” This does not change the successful Sourcify results. Do not interpret these results as confirmation of every historical deployment or of GMGN's cached badge.

The token has a fixed supply of 1,000,000,000 units with 18 decimals. The launcher creates a Uniswap v4 pool with a 2% pool fee and places the liquidity position NFT in a permanent fee locker. The locker splits fees between creator and platform and supports converting accumulated token fees to ETH.

## Source layout

- `contracts/robinhood/`: the current standard-pool deployment's source, copied from its original compiler input.
- `build-inputs/`: original Solidity Standard JSON inputs, including dependency source text and compiler settings.
- `builds.json`: compiler versions, input checksums, settings, and fully qualified contract names.
- `abi/<build-id>/`: contract ABIs for each saved build.
- `archive/<build-id>/`: readable Orynth sources for historical builds, including the older ETH-hook stack.

Use the exact build listed for an address. Identical contract names across historical builds do not imply identical bytecode. An address with `artifactMatch: false` has no matching saved artifact in this release; it must not be submitted using a guessed version.

## Compilation settings

The saved builds use Solidity **0.8.26+commit.8a97fa7a**, the **Cancun** EVM target, optimizer enabled with **10,000 runs**, and **viaIR: true**. All imported source text is embedded in each Standard JSON input, so dependency upgrades do not change these snapshots.

To reproduce the active build with the exact native `solc` version installed:

```sh
solc --standard-json < build-inputs/1beec5358d07f58d3571542c5e2527b5.json > compiler-output.json
```

The manifest records a comparison of deployed runtime bytecode, including its metadata trailer, against saved compiler output. Constructor-populated immutable positions are excluded from that local comparison. Only an explorer's successful verification establishes its own verification status.

## Verify a deployed address

Verification publishes source and matches it against an existing contract. It requires no wallet key, transaction, gas payment, or redeployment.

1. Open [Robinhood Blockscout's verification form](https://robinhoodchain.blockscout.com/contract-verification).
2. Enter the **token, locker, or launcher address** being verified. Verifying a launcher alone does not establish verification for its child tokens.
3. Select the source's MIT license and **Solidity (Standard JSON input)**.
4. Select **v0.8.26+commit.8a97fa7a** and upload the input named in the deployment manifest.
5. Submit, then confirm the contract page reports an exact match.

With Node.js 20 or newer, recorded addresses can also be submitted using:

```sh
node scripts/verify.cjs 0x99e35ac90a8e583c06d68ae9e894939cdfa15f4c --submit
```

Omit `--submit` to inspect the request details without publishing. The script uses Blockscout's documented API. If its web protection rejects API access, use the browser form above. Submission acceptance is not verification success; check the contract page after processing.

GMGN and other security providers may refresh at different times. Public GitHub source and explorer verification do not guarantee an immediate badge update, a security audit, or any token's safety.

## License

Orynth-authored Solidity sources retain their existing **MIT** SPDX license. Dependency files retain their individual SPDX identifiers and upstream terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This repository publishes contract code and build data, not Orynth application code or private deployment credentials.
