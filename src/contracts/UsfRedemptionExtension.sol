// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISimpleToken} from "../interfaces/ISimpleToken.sol";
import {IUsfRedemptionExtension} from "../interfaces/IUsfRedemptionExtension.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlinkOracle} from "../interfaces/oracles/IChainlinkOracle.sol";
import {IUsfPriceStorage} from "../interfaces/IUsfPriceStorage.sol";

import {console2} from "forge-std/Test.sol";

contract UsfRedemptionExtension is IUsfRedemptionExtension, AccessControlDefaultAdminRules, Pausable {

    using SafeERC20 for IERC20;

    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");

    string internal constant IDEMPOTENCY_KEY_PREFIX = "UsfRedemptionExtension";
    uint256 internal immutable USF_DECIMALS;
    address public immutable USF_TOKEN_ADDRESS;

    address public treasury;
    IChainlinkOracle public chainlinkOracle;
    IUsfPriceStorage public usfPriceStorage;
    uint256 public usfPriceStorageHeartbeatInterval;
    uint256 public redemptionLimit;
    uint256 public currentRedemptionUsage;
    uint256 public lastResetTime;
    uint256 public redeemCounter;
    mapping(address token => bool isAllowed) public allowedWithdrawalTokens;

    modifier allowedWithdrawalToken(address _tokenAddress) {
        _assertNonZero(_tokenAddress);
        if (!allowedWithdrawalTokens[_tokenAddress]) {
            revert TokenNotAllowed(_tokenAddress);
        }
        _;
    }

    constructor(
        address _usfTokenAddress,
        address[] memory _allowedWithdrawalTokenAddresses,
        address _treasury,
        address _chainlinkOracle,
        address _usfPriceStorage,
        uint256 _usfPriceStorageHeartbeatInterval,
        uint256 _redemptionLimit,
        uint256 _lastResetTime
    ) AccessControlDefaultAdminRules(1 days, msg.sender) {
        _assertNonZero(_usfTokenAddress);
        USF_TOKEN_ADDRESS = _usfTokenAddress;
        USF_DECIMALS = IERC20Metadata(_usfTokenAddress).decimals();
        setTreasury(_treasury);
        setChainlinkOracle(_chainlinkOracle);
        setUsfPriceStorage(_usfPriceStorage);
        setUsfPriceStorageHeartbeatInterval(_usfPriceStorageHeartbeatInterval);
        setRedemptionLimit(_redemptionLimit);

        for (uint256 i = 0; i < _allowedWithdrawalTokenAddresses.length; i++) {
            addAllowedWithdrawalToken(_allowedWithdrawalTokenAddresses[i]);
        }

        currentRedemptionUsage = 0;
        if (_lastResetTime < block.timestamp ||
            _lastResetTime > block.timestamp + 1 days) revert InvalidLastResetTime(_lastResetTime);
        lastResetTime = _lastResetTime;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._unpause();
    }

    function redeem(uint256 _amount, address _withdrawalTokenAddress) external {
        redeem(_amount, msg.sender, _withdrawalTokenAddress);
    }

    function removeAllowedWithdrawalToken(
        address _allowedWithdrawalTokenAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) allowedWithdrawalToken(_allowedWithdrawalTokenAddress) {
        allowedWithdrawalTokens[_allowedWithdrawalTokenAddress] = false;
        emit AllowedWithdrawalTokenRemoved(_allowedWithdrawalTokenAddress);
    }

    function addAllowedWithdrawalToken(address _allowedWithdrawalTokenAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_allowedWithdrawalTokenAddress);
        if (allowedWithdrawalTokens[_allowedWithdrawalTokenAddress]) revert TokenAlreadyAllowed(_allowedWithdrawalTokenAddress);
        if (_allowedWithdrawalTokenAddress.code.length == 0) revert InvalidTokenAddress(_allowedWithdrawalTokenAddress);
        allowedWithdrawalTokens[_allowedWithdrawalTokenAddress] = true;
        emit AllowedWithdrawalTokenAdded(_allowedWithdrawalTokenAddress);
    }

    function setTreasury(address _treasury) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_treasury);
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setChainlinkOracle(address _chainlinkOracle) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_chainlinkOracle);
        chainlinkOracle = IChainlinkOracle(_chainlinkOracle);
        emit ChainlinkOracleSet(_chainlinkOracle);
    }

    function setUsfPriceStorage(address _usfPriceStorage) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_usfPriceStorage);
        usfPriceStorage = IUsfPriceStorage(_usfPriceStorage);
        emit UsfPriceStorageSet(_usfPriceStorage);
    }

    function setUsfPriceStorageHeartbeatInterval(uint256 _usfPriceStorageHeartbeatInterval) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_usfPriceStorageHeartbeatInterval);
        usfPriceStorageHeartbeatInterval = _usfPriceStorageHeartbeatInterval;
        emit UsfPriceStorageHeartbeatIntervalSet(_usfPriceStorageHeartbeatInterval);
    }

    function setRedemptionLimit(uint256 _redemptionLimit) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_redemptionLimit);
        redemptionLimit = _redemptionLimit;
        emit RedemptionLimitSet(_redemptionLimit);
    }

    // slither-disable-start pess-multiple-storage-read
    function redeem(
        uint256 _amount,
        address _receiver,
        address _withdrawalTokenAddress
    ) public whenNotPaused allowedWithdrawalToken(_withdrawalTokenAddress) onlyRole(SERVICE_ROLE) returns (uint256 withdrawalTokenAmount) {
        _assertNonZero(_amount);
        _assertNonZero(_receiver);

        uint256 currentTime = block.timestamp;
        if (currentTime >= lastResetTime + 1 days) {
            // slither-disable-start divide-before-multiply
            uint256 periodsPassed = (currentTime - lastResetTime) / 1 days;
            lastResetTime += periodsPassed * 1 days;
            // slither-disable-end divide-before-multiply

            currentRedemptionUsage = 0;

            emit RedemptionLimitReset(lastResetTime);
        }

        currentRedemptionUsage += _amount;
        if (currentRedemptionUsage > redemptionLimit) {
            revert RedemptionLimitExceeded(_amount, redemptionLimit);
        }

        bytes32 idempotencyKey = generateIdempotencyKey();
        ISimpleToken(USF_TOKEN_ADDRESS).burn(
            idempotencyKey,
            msg.sender,
            _amount
        );

        uint8 withdrawalTokenDecimals = IERC20Metadata(_withdrawalTokenAddress).decimals();
        // slither-disable-next-line unused-return
        (,int256 redeemPrice,,,) = getRedeemPrice(_withdrawalTokenAddress);
        if (withdrawalTokenDecimals > USF_DECIMALS) {
            // slither-disable-next-line pess-dubious-typecast
            // slither-disable-next-line divide-before-multiply
            withdrawalTokenAmount = (_amount * (10 ** USF_DECIMALS) / uint256(redeemPrice))
                * 10 ** (withdrawalTokenDecimals - USF_DECIMALS);
        } else {
            // slither-disable-next-line pess-dubious-typecast
            withdrawalTokenAmount = (_amount * (10 ** USF_DECIMALS) / uint256(redeemPrice))
                / 10 ** (USF_DECIMALS - withdrawalTokenDecimals);
        }

        IERC20 withdrawalToken = IERC20(_withdrawalTokenAddress);
        uint256 treasuryWithdrawalTokenBalance = withdrawalToken.balanceOf(address(treasury));

        if (treasuryWithdrawalTokenBalance < withdrawalTokenAmount) {
            revert NotEnoughTokensForRedemption(_withdrawalTokenAddress, withdrawalTokenAmount, treasuryWithdrawalTokenBalance);
        }

        // slither-disable-next-line arbitrary-send-erc20
        withdrawalToken.safeTransferFrom(address(treasury), _receiver, withdrawalTokenAmount);

        emit Redeemed(
            msg.sender,
            _receiver,
            _amount,
            _withdrawalTokenAddress,
            withdrawalTokenAmount
        );

        return withdrawalTokenAmount;
    }

    function getRedeemPrice(address _withdrawalTokenAddress) public view returns (
        uint80 roundId,
        int256 price,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        IChainlinkOracle oracle = chainlinkOracle;
        (
            roundId,
            price,
            startedAt,
            updatedAt,
            answeredInRound
        ) = oracle.getLatestRoundData(_withdrawalTokenAddress);
        uint8 priceDecimals = oracle.priceDecimals(_withdrawalTokenAddress);

        if (priceDecimals > USF_DECIMALS) {
            price = SafeCast.toInt256(SafeCast.toUint256(price) / 10 ** (priceDecimals - USF_DECIMALS));
        } else if (priceDecimals < USF_DECIMALS) {
            price = SafeCast.toInt256(SafeCast.toUint256(price) * 10 ** (USF_DECIMALS - priceDecimals));
        }

        price = SafeCast.toInt256(SafeCast.toUint256(price) * usfPriceStorage.PRICE_SCALING_FACTOR() / getUSFPrice());

        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }
    // slither-disable-end pess-multiple-storage-read

    function generateIdempotencyKey() internal returns (bytes32 idempotencyKey) {
        idempotencyKey = keccak256(abi.encodePacked(IDEMPOTENCY_KEY_PREFIX, redeemCounter));
        unchecked {redeemCounter++;}

        return idempotencyKey;
    }

    function getUSFPrice() internal view returns (uint256 usfPrice) {
        // slither-disable-next-line unused-return
        (uint256 price,,,uint256 timestamp) = usfPriceStorage.lastPrice();
        if (timestamp + usfPriceStorageHeartbeatInterval < block.timestamp) {
            revert UsfPriceHeartbeatIntervalCheckFailed();
        }
        if (price < usfPriceStorage.PRICE_SCALING_FACTOR()) {
            revert InvalidUsfPrice(price);
        }

        return usfPrice = price;
    }

    function _assertNonZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function _assertNonZero(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}
