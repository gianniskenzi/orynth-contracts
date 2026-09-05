// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrynthLaunchTokenV2} from "./OrynthLaunchTokenV2.sol";

/// @notice Deploys launch tokens without embedding their creation bytecode in the launcher.
contract OrynthTokenDeployer {
    address public immutable owner;
    address public launcher;

    event LauncherConfigured(address indexed launcher);

    constructor() {
        owner = msg.sender;
    }

    function setLauncher(address launcher_) external {
        require(msg.sender == owner, "only owner");
        require(launcher == address(0), "launcher already set");
        require(launcher_ != address(0), "invalid launcher");
        launcher = launcher_;
        emit LauncherConfigured(launcher_);
    }

    function deployToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        string calldata logo,
        string calldata description,
        string calldata twitter,
        string calldata telegram,
        string calldata website,
        address receiver,
        address tokenDeployer
    ) external returns (address token) {
        require(msg.sender == launcher, "only launcher");
        token = address(
            new OrynthLaunchTokenV2(
                name,
                symbol,
                metadataURI,
                logo,
                description,
                twitter,
                telegram,
                website,
                receiver,
                tokenDeployer,
                launcher
            )
        );
    }
}
