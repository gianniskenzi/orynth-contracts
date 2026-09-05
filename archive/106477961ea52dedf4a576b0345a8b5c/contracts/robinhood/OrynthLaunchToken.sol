// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Immutable fixed-supply token created by the Orynth Robinhood launcher.
contract OrynthLaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    string public metadataURI;

    constructor(string memory name_, string memory symbol_, string memory metadataURI_, address receiver)
        ERC20(name_, symbol_)
    {
        metadataURI = metadataURI_;
        _mint(receiver, TOTAL_SUPPLY);
    }

    /// @notice ERC-1046 metadata entrypoint used by ERC-20 indexers.
    function tokenURI() external view returns (string memory) {
        return metadataURI;
    }

    /// @notice ERC-7572 contract-level metadata entrypoint.
    function contractURI() external view returns (string memory) {
        return metadataURI;
    }
}
