// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal CREATE2 deployer used to mine a Uniswap v4-compatible hook address.
contract OrynthHookDeployer {
    error DeploymentFailed();

    event Deployed(address indexed deployed, bytes32 indexed salt);

    function deploy(bytes32 salt, bytes memory creationCode) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
        emit Deployed(deployed, salt);
    }
}
