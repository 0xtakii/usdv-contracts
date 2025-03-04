// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ISimpleToken} from "../interfaces/ISimpleToken.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";
import {IERC20Rebasing} from "../interfaces/IERC20Rebasing.sol";

contract RewardDistributor is IRewardDistributor, AccessControlDefaultAdminRules, Pausable {
    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");

    address public immutable ST_USF_ADDRESS;
    address public immutable TOKEN_ADDRESS;

    mapping(bytes32 => bool) private distributeIds;

    modifier idempotent(bytes32 idempotencyKey) {
        if (distributeIds[idempotencyKey]) {
            revert IdempotencyKeyAlreadyExist(idempotencyKey);
        }
        _;
        distributeIds[idempotencyKey] = true;
    }

    constructor(address _stUSFAddress, address _tokenAddress) AccessControlDefaultAdminRules(1 days, msg.sender) {
        ST_USF_ADDRESS = _assertNonZero(_stUSFAddress);
        TOKEN_ADDRESS = _assertNonZero(_tokenAddress);
    }

    function distribute(bytes32 _idempotencyKey, uint256 _stakingReward)
        external
        onlyRole(SERVICE_ROLE)
        idempotent(_idempotencyKey)
        whenNotPaused
    {
        if (_stakingReward == 0) revert InvalidAmount(_stakingReward);

        IERC20Rebasing stUSF = IERC20Rebasing(ST_USF_ADDRESS);
        uint256 totalShares = stUSF.totalShares();
        uint256 totalUSFBefore = stUSF.totalSupply();

        ISimpleToken token = ISimpleToken(TOKEN_ADDRESS);
        token.mint(ST_USF_ADDRESS, _stakingReward);

        uint256 totalUSFAfter = totalUSFBefore + _stakingReward;

        emit RewardDistributed(_idempotencyKey, totalShares, totalUSFBefore, totalUSFAfter, _stakingReward);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._unpause();
    }

    function _assertNonZero(address _address) internal pure returns (address nonZeroAddress) {
        if (_address == address(0)) revert ZeroAddress();
        return _address;
    }
}
