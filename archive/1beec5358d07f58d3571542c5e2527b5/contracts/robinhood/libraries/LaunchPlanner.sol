// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct LaunchPlan {
    bytes actions;
    bytes[] params;
}
using LaunchPlanner for LaunchPlan global;

library LaunchPlanner {
    function init() internal pure returns (LaunchPlan memory plan) {
        plan.actions = bytes("");
        plan.params = new bytes[](0);
    }

    function add(LaunchPlan memory plan, uint256 action, bytes memory param)
        internal
        pure
        returns (LaunchPlan memory)
    {
        bytes memory actions = new bytes(plan.params.length + 1);
        bytes[] memory params = new bytes[](plan.params.length + 1);

        for (uint256 i; i < plan.params.length; ++i) {
            actions[i] = plan.actions[i];
            params[i] = plan.params[i];
        }

        actions[plan.params.length] = bytes1(uint8(action));
        params[plan.params.length] = param;
        plan.actions = actions;
        plan.params = params;
        return plan;
    }

    function encode(LaunchPlan memory plan) internal pure returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }
}
