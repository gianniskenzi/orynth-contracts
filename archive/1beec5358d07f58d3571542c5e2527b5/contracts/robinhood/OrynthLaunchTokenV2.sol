// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrynthLaunchToken} from "./OrynthLaunchToken.sol";

/// @notice Self-describing Orynth launch token for broad indexer compatibility.
contract OrynthLaunchTokenV2 is OrynthLaunchToken {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    address public immutable deployer;
    address public immutable launcher;
    string public logo;
    string public description;
    bytes32 public canonicalPoolId;
    address public poolManager;
    address public pairedToken;
    uint24 public poolFee;

    Socials private _socials;
    bool private _canonicalPoolSet;

    event CanonicalPoolSet(bytes32 indexed poolId, address indexed poolManager, address pairedToken, uint24 poolFee);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        string memory logo_,
        string memory description_,
        string memory twitter_,
        string memory telegram_,
        string memory website_,
        address receiver_,
        address deployer_,
        address launcher_
    ) OrynthLaunchToken(name_, symbol_, metadataURI_, receiver_) {
        require(deployer_ != address(0) && launcher_ != address(0), "invalid token config");
        logo = logo_;
        description = description_;
        _socials = Socials({
            twitter: twitter_,
            telegram: telegram_,
            discord: "",
            website: website_,
            farcaster: ""
        });
        deployer = deployer_;
        launcher = launcher_;
    }

    function socials()
        external
        view
        returns (string memory twitter, string memory telegram, string memory discord, string memory website, string memory farcaster)
    {
        Socials storage values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    function getTokenInfo()
        external
        view
        returns (address tokenDeployer, string memory tokenLogo, string memory tokenDescription, Socials memory tokenSocials)
    {
        return (deployer, logo, description, _socials);
    }

    function setCanonicalPool(bytes32 poolId_, address poolManager_, address pairedToken_, uint24 poolFee_) external {
        require(msg.sender == launcher, "only launcher");
        require(!_canonicalPoolSet, "pool already set");
        require(poolManager_ != address(0), "invalid pool manager");
        _canonicalPoolSet = true;
        canonicalPoolId = poolId_;
        poolManager = poolManager_;
        pairedToken = pairedToken_;
        poolFee = poolFee_;
        emit CanonicalPoolSet(poolId_, poolManager_, pairedToken_, poolFee_);
    }
}
