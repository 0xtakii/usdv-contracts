// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IDefaultErrors} from "./IDefaultErrors.sol";

interface IRewardDistributor is IDefaultErrors {
    event RewardDistributed(
        bytes32 indexed idempotencyKey,
        uint256 totalShares,
        uint256 totalUSFBefore,
        uint256 totalUSFAfter,
        uint256 stakingReward
    );

    function distribute(bytes32 idempotencyKey, uint256 _stakingReward) external;

    function pause() external;

    function unpause() external;
}
