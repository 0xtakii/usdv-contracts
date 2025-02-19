// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IUsfPriceStorage} from "../interfaces/IUsfPriceStorage.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin-upgradeable/contracts/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

contract UsfPriceStorage is IUsfPriceStorage, AccessControlDefaultAdminRulesUpgradeable {
    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");
    uint256 public constant PRICE_SCALING_FACTOR = 1e18;
    uint256 public constant BOUND_PERCENTAGE_DENOMINATOR = 1e18;

    mapping(bytes32 key => Price price) public prices;
    Price public lastPrice;

    uint256 public lowerBoundPercentage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Sets the reserves and supply for a given key and calculates the price according to:
     *         - If reserves >= usfSupply, price = 1e18 (1:1 ratio)
     *         - If reserves < usfSupply,  price = (reserves * 1e18 / usfSupply)
     * @param _key The identifier for this reserves and supply data point.
     * @param usfSupply The supply of USF tokens, 1e18 decimals,
     * @param reserves The amount of reserves in USD, 1e18 decimals.
     */
    function setReserves(bytes32 _key, uint256 usfSupply, uint256 reserves) external onlyRole(SERVICE_ROLE) {
        if (_key == bytes32(0)) revert InvalidKey();
        if (usfSupply == 0) revert InvalidUsfSupply();
        if (reserves == 0) revert InvalidReserves();
        if (prices[_key].timestamp != 0) revert PriceAlreadySet(_key);

        uint256 computedPrice = _calculatePrice(usfSupply, reserves);
        uint256 lastPriceValue = lastPrice.price;
        if (lastPriceValue != 0) {
            // assumes only possible at initialization
            uint256 lowerBound = lastPriceValue - (lastPriceValue * lowerBoundPercentage / BOUND_PERCENTAGE_DENOMINATOR);
            if (computedPrice < lowerBound) {
                revert InvalidPrice(computedPrice, lowerBound);
            }
        }

        uint256 currentTime = block.timestamp;
        Price memory priceData =
            Price({price: computedPrice, usfSupply: usfSupply, reserves: reserves, timestamp: currentTime});

        prices[_key] = priceData;
        lastPrice = priceData;

        emit PriceSet(_key, computedPrice, usfSupply, reserves, currentTime);
    }

    function initialize(uint256 _lowerBoundPercentage) public initializer {
        __AccessControlDefaultAdminRules_init(1 days, msg.sender);
        setLowerBoundPercentage(_lowerBoundPercentage);
    }

    function setLowerBoundPercentage(uint256 _lowerBoundPercentage) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_lowerBoundPercentage == 0 || _lowerBoundPercentage > BOUND_PERCENTAGE_DENOMINATOR) {
            revert InvalidLowerBoundPercentage();
        }

        lowerBoundPercentage = _lowerBoundPercentage;
        emit LowerBoundPercentageSet(_lowerBoundPercentage);
    }

    /**
     * @notice Calculates price based on supply and reserves.
     */
    function _calculatePrice(uint256 usfSupply, uint256 reserves) internal pure returns (uint256 price) {
        if (reserves >= usfSupply) {
            price = PRICE_SCALING_FACTOR;
        } else {
            price = (reserves * PRICE_SCALING_FACTOR) / usfSupply;
        }

        return price;
    }
}
