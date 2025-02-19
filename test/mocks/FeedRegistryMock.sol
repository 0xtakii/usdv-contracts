// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract FeedRegistryMock {
    int256 price = 1e8;

    // 8 is the number for almost all chainlink USD price feeds
    function decimals(address tokenAddress, address currencyAddress) public returns (uint8) {
        return 8;
    }

    function setPrice(int256 _price) public {
        price = _price;
    }

    function latestRoundData(address tokenAddress, address currencyAddress)
        public
        returns (uint80 roundId, int256 _price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        _price = price;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }
}
