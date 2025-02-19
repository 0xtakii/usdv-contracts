// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IUsfPriceStorage} from "./IUsfPriceStorage.sol";
import {IChainlinkOracle} from "./oracles/IChainlinkOracle.sol";
import {IDefaultErrors} from "./IDefaultErrors.sol";

interface IUsfRedemptionExtension is IDefaultErrors {
    event TreasurySet(address _treasuryAddress);
    event ChainlinkOracleSet(address _chainlinkOracleAddress);
    event UsfPriceStorageSet(address _usfPriceStorageAddress);
    event UsfPriceStorageHeartbeatIntervalSet(uint256 _interval);
    event RedemptionLimitSet(uint256 _redemptionLimit);
    event AllowedWithdrawalTokenAdded(address _tokenAddress);
    event AllowedWithdrawalTokenRemoved(address _tokenAddres);
    event Redeemed(
        address indexed _sender,
        address indexed _receiver,
        uint256 _amount,
        address _withdrawalToken,
        uint256 _withdrawalTokenAmount
    );
    event RedemptionLimitReset(uint256 _newResetTime);

    error RedemptionLimitExceeded(uint256 _amount, uint256 _limit);
    error InvalidTokenAddress(address _token);
    error TokenAlreadyAllowed(address _token);
    error TokenNotAllowed(address _token);
    error InvalidLastResetTime(uint256 _lastResetTime);
    error UsfPriceHeartbeatIntervalCheckFailed();
    error InvalidUsfPrice(uint256 _price);
    error NotEnoughTokensForRedemption(address _withdrawalToken, uint256 _requested, uint256 _available);

    function setTreasury(address _treasury) external;

    function setChainlinkOracle(address _chainlinkOracle) external;

    function setRedemptionLimit(uint256 _redemptionLimit) external;

    function setUsfPriceStorage(address _usfPriceStorage) external;

    function setUsfPriceStorageHeartbeatInterval(uint256 _usfPriceStorageHeartbeatInterval) external;

    function addAllowedWithdrawalToken(address _allowedWithdrawalTokenAddress) external;

    function removeAllowedWithdrawalToken(address _allowedWithdrawalTokenAddress) external;

    function pause() external;

    function unpause() external;

    function redeem(uint256 _amount, address _receiver, address _withdrawalTokenAddress)
        external
        returns (uint256 withdrawalTokenAmount);

    function redeem(uint256 _amount, address _withdrawalTokenAddress) external;

    function getRedeemPrice(address _withdrawalTokenAddress)
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
