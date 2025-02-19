// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {SimpleToken, ISimpleToken} from "../src/contracts/SimpleToken.sol";
import {StUSF, IStUSF} from "../src/contracts/StUSF.sol";
import {IERC20Rebasing} from "../src/interfaces/IERC20Rebasing.sol";
import {RewardDistributor, IRewardDistributor} from "../src/contracts/RewardDistributor.sol";
import {WstUSF, IWstUSF} from "../src/contracts/WstUSF.sol";
import {IDefaultErrors} from "../src/interfaces/IDefaultErrors.sol";
import {FlpPriceStorage, IFlpPriceStorage} from "../src/contracts/FlpPriceStorage.sol";
import {UsfPriceStorage, IUsfPriceStorage} from "../src/contracts/UsfPriceStorage.sol";
import {AddressesWhitelist, IAddressesWhitelist} from "../src/contracts/AddressesWhitelist.sol";
import {ExternalRequestsManager, IExternalRequestsManager} from "../src/contracts/ExternalRequestsManager.sol";
import {
    UsfExternalRequestsManager, IUsfExternalRequestsManager
} from "../src/contracts/UsfExternalRequestsManager.sol";
import {UsfRedemptionExtension, IUsfRedemptionExtension} from "../src/contracts/UsfRedemptionExtension.sol";
import {ChainlinkOracle, IChainlinkOracle} from "../src/contracts/oracles/ChainlinkOracle.sol";
import {FeedRegistryMock} from "./mocks/FeedRegistryMock.sol";

interface ISimpleTokenExtended is ISimpleToken, IERC20, IAccessControl {}

interface IStUSFExtended is IStUSF, IERC20Rebasing {}

interface IRewardDistributorExtended is IRewardDistributor, IAccessControl {}

interface IWstUSFExtended is IERC20, IWstUSF {}

interface IFlpPriceStorageExtended is IFlpPriceStorage, IAccessControl {}

interface IUsfPriceStorageExtended is IUsfPriceStorage, IAccessControl {}

contract MintableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EndToEndTestFork is Test {
    string ETHEREUM_RPC_URL = vm.envString("ETHEREUM_RPC");
    uint256 ethereumFork;
    uint256 blockNumber = 21877494;

    address usdcWhale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    address usdcAddress = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address chainlinkFeedRegistry = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    bytes32 SERVICE_ROLE = keccak256("SERVICE_ROLE");

    address admin = makeAddr("admin"); // multisig
    address treasury = admin;

    address service = makeAddr("service"); // backend
    address feeCollector = makeAddr("feeCollector"); // fee collector
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");

    ISimpleTokenExtended funToken;
    ISimpleTokenExtended funLpToken;
    IStUSFExtended stFunToken;
    IWstUSFExtended wstFunToken;
    IRewardDistributorExtended rewardDistributor;
    IFlpPriceStorageExtended flpPriceStorage;
    IUsfPriceStorageExtended usfPriceStorage;
    AddressesWhitelist whitelist;
    ExternalRequestsManager externalRequestsManager;
    ChainlinkOracle chainlinkOracle;
    UsfRedemptionExtension usfRedemptionExtension;
    UsfExternalRequestsManager usfExternalRequestsManager;

    IERC20 usdcToken;

    function setUp() public {
        ethereumFork = vm.createFork(ETHEREUM_RPC_URL, blockNumber);
        vm.selectFork(ethereumFork);

        SimpleToken implementation = new SimpleToken();

        // deploying USDFun token
        string memory name = "USDFun";
        string memory symbol = "USDFun";

        bytes memory initializeCall = abi.encodeWithSelector(SimpleToken.initialize.selector, name, symbol);

        vm.prank(admin);
        funToken = ISimpleTokenExtended(
            address(new TransparentUpgradeableProxy(address(implementation), admin, initializeCall))
        );

        // deploying the FunLP token
        name = "FunLP";
        symbol = "FunLP";

        initializeCall = abi.encodeWithSelector(SimpleToken.initialize.selector, name, symbol);

        vm.prank(admin);
        funLpToken = ISimpleTokenExtended(
            address(new TransparentUpgradeableProxy(address(implementation), admin, initializeCall))
        );

        // deploy the staked stUSDFun token
        StUSF stUsfImplementation = new StUSF();

        name = "StUSDFun";
        symbol = "StUSDFun";
        initializeCall = abi.encodeWithSelector(StUSF.initialize.selector, name, symbol, address(funToken));

        vm.prank(admin);
        stFunToken = IStUSFExtended(
            address(new TransparentUpgradeableProxy(address(stUsfImplementation), admin, initializeCall))
        );

        // deploy the rewards distributor contract and set up the service account flow
        vm.prank(admin);
        rewardDistributor = IRewardDistributorExtended(
            address(new RewardDistributor(address(stFunToken), feeCollector, address(funToken)))
        );

        vm.startPrank(admin);
        rewardDistributor.grantRole(SERVICE_ROLE, service);
        funToken.grantRole(SERVICE_ROLE, admin); // this wont happen in proper flow
        funToken.grantRole(SERVICE_ROLE, address(rewardDistributor));
        vm.stopPrank();

        // deploying the wrapped USF token
        WstUSF wstUsfImpl = new WstUSF();

        name = "WstUSDFun";
        symbol = "WstUSDFun";
        initializeCall = abi.encodeWithSelector(WstUSF.initialize.selector, name, symbol, address(stFunToken));

        wstFunToken =
            IWstUSFExtended(address(new TransparentUpgradeableProxy(address(wstUsfImpl), admin, initializeCall)));

        // deploying the price storage contract for funLP
        FlpPriceStorage flpPriceStorageImpl = new FlpPriceStorage();

        initializeCall = abi.encodeWithSelector(FlpPriceStorage.initialize.selector, 1e17, 1e17); // lower and upper bounds

        vm.prank(admin);
        flpPriceStorage = IFlpPriceStorageExtended(
            address(new TransparentUpgradeableProxy(address(flpPriceStorageImpl), admin, initializeCall))
        );

        vm.prank(admin);
        flpPriceStorage.grantRole(SERVICE_ROLE, service);

        // deploying the price storage contract for USF
        UsfPriceStorage usfPriceStorageImpl = new UsfPriceStorage();

        initializeCall = abi.encodeWithSelector(UsfPriceStorage.initialize.selector, 1e17);

        vm.prank(admin);
        usfPriceStorage = IUsfPriceStorageExtended(
            address(new TransparentUpgradeableProxy(address(usfPriceStorageImpl), admin, initializeCall))
        );

        vm.prank(admin);
        usfPriceStorage.grantRole(SERVICE_ROLE, service);

        // deploying the whitelist contract
        vm.prank(admin);
        whitelist = new AddressesWhitelist();

        // initializing mock tokens and transfering tokens
        usdcToken = IERC20(usdcAddress);

        vm.prank(usdcWhale);
        usdcToken.transfer(userA, 1_000e6);

        vm.prank(usdcWhale);
        usdcToken.transfer(userB, 1_000e6);

        // deploying the requests manager contract
        address[] memory whitelistedTokens = new address[](1);
        whitelistedTokens[0] = address(usdcToken);

        vm.prank(admin);
        externalRequestsManager =
            new ExternalRequestsManager(address(funLpToken), treasury, address(whitelist), whitelistedTokens);

        vm.prank(admin);
        externalRequestsManager.setWhitelistEnabled(true);

        vm.prank(admin);
        funLpToken.grantRole(SERVICE_ROLE, address(externalRequestsManager));

        vm.prank(admin);
        externalRequestsManager.grantRole(SERVICE_ROLE, service);

        // deploying the chainlink oracle feed contract
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(usdcToken);

        uint48[] memory heartbeatIntervals = new uint48[](1);
        heartbeatIntervals[0] = 86400;

        vm.prank(admin);
        chainlinkOracle = new ChainlinkOracle(chainlinkFeedRegistry, tokenAddresses, heartbeatIntervals);

        // deploying the redemption extension contract
        uint256 usfPriceStorageHeartbeatInterval = 60 * 60;
        uint256 usfRedemptionLimit = 100e18; // redemption limit denominated in USF token

        vm.prank(admin);
        usfRedemptionExtension = new UsfRedemptionExtension(
            address(funToken),
            whitelistedTokens,
            treasury,
            address(chainlinkOracle),
            address(usfPriceStorage),
            usfPriceStorageHeartbeatInterval,
            usfRedemptionLimit,
            block.timestamp
        );

        // deploying the USF requests manager contract
        vm.prank(admin);
        usfExternalRequestsManager = new UsfExternalRequestsManager(
            address(funToken), treasury, address(whitelist), address(usfRedemptionExtension), whitelistedTokens
        );

        vm.prank(admin);
        usfExternalRequestsManager.setWhitelistEnabled(true);

        vm.prank(admin);
        funToken.grantRole(SERVICE_ROLE, address(usfExternalRequestsManager));

        vm.prank(admin);
        funToken.grantRole(SERVICE_ROLE, address(usfRedemptionExtension));

        vm.prank(admin);
        usfRedemptionExtension.grantRole(SERVICE_ROLE, address(usfExternalRequestsManager));

        vm.prank(admin);
        usfExternalRequestsManager.grantRole(SERVICE_ROLE, address(service));

        vm.prank(treasury);
        usdcToken.approve(address(usfRedemptionExtension), type(uint256).max);
    }

    function test_redemptionExtensionAndChainlinkOracle() public {
        bytes32 key = keccak256(abi.encode(1));
        uint256 usfSupply = 1_000e18;
        uint256 reserves = 1_100e18;

        vm.prank(service);
        usfPriceStorage.setReserves(key, usfSupply, reserves);

        (uint256 setPrice,,,) = usfPriceStorage.lastPrice();

        assertEq(setPrice, 1e18, "test_redemptionExtensionAndChainlinkOracle::1"); // capped price

        uint256 usdcPrice = chainlinkOracle.getPrice(address(usdcToken));

        assertApproxEqAbs(usdcPrice, 1e8, 1e6, "test_redemptionExtensionAndChainlinkOracle::2");
        assertEq(chainlinkOracle.priceDecimals(address(usdcToken)), 8, "test_redemptionExtensionAndChainlinkOracle::3");
        assertEq(
            chainlinkOracle.tokenHeartbeatIntervals(address(usdcToken)),
            86400,
            "test_redemptionExtensionAndChainlinkOracle::4"
        );

        (, int256 setUsdcPrice2,,,) = chainlinkOracle.getLatestRoundData(address(usdcToken));
        assertEq(usdcPrice, uint256(setUsdcPrice2), "test_redemptionExtensionAndChainlinkOracle::5");

        (, int256 price,,,) = usfRedemptionExtension.getRedeemPrice(address(usdcToken));

        assertApproxEqAbs(price, 1e18, 1e16, "test_redemptionExtensionAndChainlinkOracle::6");

        vm.prank(admin);
        usfPriceStorage.setLowerBoundPercentage(1e18);

        vm.prank(service);
        usfPriceStorage.setReserves(keccak256(abi.encode(2)), usfSupply, 500e18); // half

        (setPrice,,,) = usfPriceStorage.lastPrice();

        assertEq(setPrice, 5e17, "test_redemptionExtensionAndChainlinkOracle::7");

        vm.expectRevert(abi.encodeWithSelector(IUsfRedemptionExtension.InvalidUsfPrice.selector, 5e17));
        (, price,,,) = usfRedemptionExtension.getRedeemPrice(address(usdcToken));
    }

    function test_usfExternalRequestManagerRedeem() public {
        uint256 mintAmount = 200e18;
        uint256 mintAmountUsdc = 200e6; // tokens paid in
        bytes32 mintIdempotencyKeyA = keccak256(abi.encode(1));
        bytes32 mintIdempotencyKeyB = keccak256(abi.encode(2));

        vm.prank(userA);
        usdcToken.approve(address(usfExternalRequestsManager), type(uint256).max);
        vm.prank(userA);
        funToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.prank(userB);
        usdcToken.approve(address(usfExternalRequestsManager), type(uint256).max);
        vm.prank(userB);
        funToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.prank(admin);
        usfExternalRequestsManager.setWhitelistEnabled(false);

        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), mintAmountUsdc, mintAmount);
        vm.prank(service);
        usfExternalRequestsManager.completeMint(mintIdempotencyKeyA, 0, mintAmount);

        vm.prank(userB);
        usfExternalRequestsManager.requestMint(address(usdcToken), mintAmountUsdc, mintAmount);
        vm.prank(service);
        usfExternalRequestsManager.completeMint(mintIdempotencyKeyB, 1, mintAmount);

        assertEq(funToken.balanceOf(userA), mintAmount, "test_usfExternalRequestManagerRedeem::1");
        assertEq(funToken.balanceOf(userB), mintAmount, "test_usfExternalRequestManagerRedeem::2");

        bytes32 setReservesKey = keccak256(abi.encode(1));
        vm.prank(service);
        usfPriceStorage.setReserves(setReservesKey, 1000e18, 1100e18);

        assertEq(usfRedemptionExtension.redemptionLimit(), 100e18, "test_usfExternalRequestManagerRedeem::3");

        uint256 redeemAmountA = 90e18;
        uint256 minExpectedAmountAUsdc = 89e6;

        assertEq(
            usfRedemptionExtension.allowedWithdrawalTokens(address(usdcToken)),
            true,
            "test_usfExternalRequestManagerRedeem::4"
        );
        assertEq(
            usfRedemptionExtension.allowedWithdrawalTokens(address(1)), false, "test_usfExternalRequestManagerRedeem::5"
        );

        assertEq(usfRedemptionExtension.currentRedemptionUsage(), 0, "test_usfExternalRequestManagerRedeem::6");

        uint256 initialUsdcBalanceTreasury = usdcToken.balanceOf(treasury);
        uint256 initialUsdcBalanceUserA = usdcToken.balanceOf(userA);
        vm.prank(userA);
        usfExternalRequestsManager.redeem(redeemAmountA, address(usdcToken), minExpectedAmountAUsdc);

        // Assuming ~1:1 price
        assertApproxEqAbs(
            usdcToken.balanceOf(userA), initialUsdcBalanceUserA + 90e6, 1e5, "test_usfExternalRequestManagerRedeem::7"
        );
        assertEq(funToken.balanceOf(userA), mintAmount - redeemAmountA, "test_usfExternalRequestManagerRedeem::8");
        assertApproxEqAbs(
            usdcToken.balanceOf(treasury),
            initialUsdcBalanceTreasury - 90e6,
            1e5,
            "test_usfExternalRequestManagerRedeem::9"
        );

        assertEq(usfRedemptionExtension.currentRedemptionUsage(), 90e18, "test_usfExternalRequestManagerRedeem::10");

        vm.expectRevert(abi.encodeWithSelector(IUsfRedemptionExtension.RedemptionLimitExceeded.selector, 20e18, 100e18));
        vm.prank(userB);
        usfExternalRequestsManager.redeem(20e18, address(usdcToken), 19e6);

        uint256 redeemAmountB = 10e18;
        uint256 minExpectedAmountBUsdc = 9e6;

        uint256 initialUsdcBalanceUserB = usdcToken.balanceOf(userB);

        setReservesKey = keccak256(abi.encode(2));
        vm.prank(service);
        usfPriceStorage.setReserves(setReservesKey, 1000e18, 1200e18);

        vm.prank(userB);
        usfExternalRequestsManager.redeem(redeemAmountB, address(usdcToken), minExpectedAmountBUsdc);

        // Assuming ~1:1 price
        assertApproxEqAbs(
            usdcToken.balanceOf(userB), initialUsdcBalanceUserB + 10e6, 1e5, "test_usfExternalRequestManagerRedeem::11"
        );
        assertEq(funToken.balanceOf(userB), mintAmount - redeemAmountB, "test_usfExternalRequestManagerRedeem::12");
    }

    function test_usfExternalRequestManagerMint() public {
        vm.prank(userA);
        usdcToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.UnknownProvider.selector, userA));
        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        vm.prank(admin);
        whitelist.addAccount(userA);

        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 0, "test_externalRequestManagerMint::1");

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 0e6, 0e18);

        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 10e6, "test_externalRequestManagerMint::2");

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            usfExternalRequestsManager.mintRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerMint::3");
        assertEq(amount, 10e6, "test_externalRequestManagerMint::4");
        assertEq(token, address(usdcToken), "test_externalRequestManagerMint::5");
        assertEq(minExpectedAmount, 10e18, "test_externalRequestManagerMint::6");

        bytes32 idempotencyKey = keccak256(abi.encode(1));

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 1, 9e18);

        vm.expectRevert(
            abi.encodeWithSelector(IUsfExternalRequestsManager.InsufficientMintAmount.selector, 9e18, 10e18)
        );
        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 0, 9e18);

        assertEq(funToken.balanceOf(userA), 0, "test_externalRequestManagerMint::7");

        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funToken.balanceOf(userA), 10e18, "test_externalRequestManagerMint::8");
        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 0, "test_externalRequestManagerMint::9");
        assertEq(usdcToken.balanceOf(address(admin)), 10e6, "test_externalRequestManagerMint::10");

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(1);

        vm.expectRevert();
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(0);

        uint256 userAStartUsdc = usdcToken.balanceOf(userA);

        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc - 10e6, "test_externalRequestManagerMint::11");

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(0);

        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(1);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc, "test_externalRequestManagerMint::12");
        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 0, "test_externalRequestManagerMint::13");

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(1);
    }

    function test_usfExternalRequestManagerBurn() public {
        vm.prank(admin);
        usdcToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.prank(userA);
        usdcToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.prank(admin);
        whitelist.addAccount(userA);

        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        bytes32 idempotencyKey = keccak256(abi.encode(1));
        bytes32 nextIdempotencyKey = keccak256(abi.encode(2));

        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funToken.totalSupply(), 10e18, "test_externalRequestManagerBurn::1");
        assertEq(funToken.balanceOf(userA), 10e18, "test_externalRequestManagerBurn::2");

        vm.prank(userA);
        funToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(0e18, address(usdcToken), 0e6);

        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(9e18, address(usdcToken), 8e6);

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            usfExternalRequestsManager.burnRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerBurn::3");
        assertEq(amount, 9e18, "test_externalRequestManagerBurn::4");
        assertEq(token, address(usdcToken), "test_externalRequestManagerBurn::5");
        assertEq(minExpectedAmount, 8e6, "test_externalRequestManagerBurn::6");

        assertEq(funToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::7");
        assertEq(funToken.balanceOf(address(usfExternalRequestsManager)), 9e18, "test_externalRequestManagerBurn::8");
        assertEq(usdcToken.balanceOf(admin), 10e6, "test_externalRequestManagerBurn::9");

        vm.expectRevert(
            abi.encodeWithSelector(IUsfExternalRequestsManager.InsufficientWithdrawalAmount.selector, 7e6, 8e6)
        );
        vm.prank(service);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 7e6);

        vm.expectRevert();
        vm.prank(admin);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 8e6);

        vm.prank(service);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 8e6);

        assertEq(usdcToken.balanceOf(admin), 2e6, "test_externalRequestManagerBurn::10");
        assertEq(funToken.totalSupply(), 1e18, "test_externalRequestManagerBurn::11");

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(service);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        vm.prank(admin);
        usfExternalRequestsManager.pause();

        vm.expectRevert();
        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(1e18, address(usdcToken), 1e6);

        vm.prank(admin);
        usfExternalRequestsManager.unpause();

        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(1e18, address(usdcToken), 1e6);

        assertEq(funToken.balanceOf(userA), 0, "test_externalRequestManagerBurn::12");

        vm.prank(userA);
        usfExternalRequestsManager.cancelBurn(1);

        assertEq(funToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::13");

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(userA);
        usfExternalRequestsManager.cancelBurn(1);

        vm.expectRevert(abi.encodeWithSelector(IUsfExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(service);
        usfExternalRequestsManager.completeBurn(nextIdempotencyKey, 1, 1e18);
    }

    function test_externalRequestManagerMint() public {
        vm.prank(userA);
        usdcToken.approve(address(externalRequestsManager), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.UnknownProvider.selector, userA));
        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        vm.prank(admin);
        whitelist.addAccount(userA);

        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 0, "test_externalRequestManagerMint::1");

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 0e6, 0e18);

        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 10e6, "test_externalRequestManagerMint::2");

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            externalRequestsManager.mintRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerMint::3");
        assertEq(amount, 10e6, "test_externalRequestManagerMint::4");
        assertEq(token, address(usdcToken), "test_externalRequestManagerMint::5");
        assertEq(minExpectedAmount, 10e18, "test_externalRequestManagerMint::6");

        bytes32 idempotencyKey = keccak256(abi.encode(1));

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 1, 9e18);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.InsufficientMintAmount.selector, 9e18, 10e18));
        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 0, 9e18);

        assertEq(funLpToken.balanceOf(userA), 0, "test_externalRequestManagerMint::7");

        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funLpToken.balanceOf(userA), 10e18, "test_externalRequestManagerMint::8");
        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 0, "test_externalRequestManagerMint::9");
        assertEq(usdcToken.balanceOf(address(admin)), 10e6, "test_externalRequestManagerMint::10");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(userA);
        externalRequestsManager.cancelMint(1);

        vm.expectRevert();
        vm.prank(userA);
        externalRequestsManager.cancelMint(0);

        uint256 userAStartUsdc = usdcToken.balanceOf(userA);

        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc - 10e6, "test_externalRequestManagerMint::11");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(userA);
        externalRequestsManager.cancelMint(0);

        vm.prank(userA);
        externalRequestsManager.cancelMint(1);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc, "test_externalRequestManagerMint::12");
        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 0, "test_externalRequestManagerMint::13");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(userA);
        externalRequestsManager.cancelMint(1);
    }

    function test_externalRequestManagerBurn() public {
        vm.prank(admin);
        usdcToken.approve(address(externalRequestsManager), type(uint256).max);

        vm.prank(userA);
        usdcToken.approve(address(externalRequestsManager), type(uint256).max);

        vm.prank(admin);
        whitelist.addAccount(userA);

        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e6, 10e18);

        bytes32 idempotencyKey = keccak256(abi.encode(1));
        bytes32 nextIdempotencyKey = keccak256(abi.encode(2));

        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funLpToken.totalSupply(), 10e18, "test_externalRequestManagerBurn::1");
        assertEq(funLpToken.balanceOf(userA), 10e18, "test_externalRequestManagerBurn::2");

        vm.prank(userA);
        funLpToken.approve(address(externalRequestsManager), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        externalRequestsManager.requestBurn(0e18, address(usdcToken), 0e6);

        vm.prank(userA);
        externalRequestsManager.requestBurn(9e18, address(usdcToken), 8e6);

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            externalRequestsManager.burnRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerBurn::3");
        assertEq(amount, 9e18, "test_externalRequestManagerBurn::4");
        assertEq(token, address(usdcToken), "test_externalRequestManagerBurn::5");
        assertEq(minExpectedAmount, 8e6, "test_externalRequestManagerBurn::6");

        assertEq(funLpToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::7");
        assertEq(funLpToken.balanceOf(address(externalRequestsManager)), 9e18, "test_externalRequestManagerBurn::8");
        assertEq(usdcToken.balanceOf(admin), 10e6, "test_externalRequestManagerBurn::9");

        vm.expectRevert(
            abi.encodeWithSelector(IExternalRequestsManager.InsufficientWithdrawalAmount.selector, 7e6, 8e6)
        );
        vm.prank(service);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 7e6);

        vm.expectRevert();
        vm.prank(admin);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 8e6);

        vm.prank(service);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 8e6);

        assertEq(usdcToken.balanceOf(admin), 2e6, "test_externalRequestManagerBurn::10");
        assertEq(funLpToken.totalSupply(), 1e18, "test_externalRequestManagerBurn::11");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(service);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        vm.prank(admin);
        externalRequestsManager.pause();

        vm.expectRevert();
        vm.prank(userA);
        externalRequestsManager.requestBurn(1e18, address(usdcToken), 1e6);

        vm.prank(admin);
        externalRequestsManager.unpause();

        vm.prank(userA);
        externalRequestsManager.requestBurn(1e18, address(usdcToken), 1e6);

        assertEq(funLpToken.balanceOf(userA), 0, "test_externalRequestManagerBurn::12");

        vm.prank(userA);
        externalRequestsManager.cancelBurn(1);

        assertEq(funLpToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::13");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(userA);
        externalRequestsManager.cancelBurn(1);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(service);
        externalRequestsManager.completeBurn(nextIdempotencyKey, 1, 1e18);
    }

    function test_usfPriceStorage() public {
        bytes32 key = keccak256(abi.encode(1));
        bytes32 nextKey = keccak256(abi.encode(2));
        uint256 usfSupply = 1_000e18;
        uint256 reserves = 1_200e18;
        uint256 newReserves = 800e18;

        vm.expectRevert();
        vm.prank(admin);
        usfPriceStorage.setReserves(key, usfSupply, reserves);

        vm.prank(service);
        usfPriceStorage.setReserves(key, usfSupply, reserves);

        (uint256 setPrice, uint256 setUsfSupply, uint256 setReserves, uint256 timestamp) = usfPriceStorage.lastPrice();

        assertEq(setPrice, 1e18, "test_usfPriceStorage::1"); // capped price
        assertEq(setUsfSupply, usfSupply, "test_usfPriceStorage::2");
        assertEq(setReserves, reserves, "test_usfPriceStorage::3");
        assertEq(timestamp, block.timestamp, "test_usfPriceStorage::4");

        vm.expectRevert(abi.encodeWithSelector(IUsfPriceStorage.PriceAlreadySet.selector, key));
        vm.prank(service);
        usfPriceStorage.setReserves(key, usfSupply, newReserves);

        vm.expectRevert();
        vm.prank(service);
        usfPriceStorage.setReserves(nextKey, usfSupply, newReserves);

        vm.expectRevert();
        vm.prank(service);
        usfPriceStorage.setLowerBoundPercentage(2e17);

        vm.prank(admin);
        usfPriceStorage.setLowerBoundPercentage(2e17);

        vm.prank(service);
        usfPriceStorage.setReserves(nextKey, usfSupply, newReserves);

        (setPrice, setUsfSupply, setReserves,) = usfPriceStorage.lastPrice();

        assertEq(setUsfSupply, usfSupply, "test_usfPriceStorage::5");
        assertEq(setReserves, newReserves, "test_usfPriceStorage::6");
        assertEq(setPrice, newReserves * 1e18 / usfSupply, "test_usfPriceStorage::7");
    }

    function test_flpPriceStorage() public {
        bytes32 key = keccak256(abi.encode(1));
        bytes32 nextKey = keccak256(abi.encode(2));
        uint256 startPrice = 1e18;
        uint256 newPrice = 9e17;

        vm.expectRevert();
        vm.prank(admin);
        flpPriceStorage.setPrice(key, startPrice);

        vm.prank(service);
        flpPriceStorage.setPrice(key, startPrice);

        (uint256 setPrice, uint256 timestamp) = flpPriceStorage.lastPrice();

        assertEq(setPrice, startPrice, "test_flpPriceStorage::1");
        assertEq(timestamp, block.timestamp, "test_flpPriceStorage::2");

        vm.expectRevert(abi.encodeWithSelector(IFlpPriceStorage.PriceAlreadySet.selector, key));
        vm.prank(service);
        flpPriceStorage.setPrice(key, newPrice);

        vm.expectRevert();
        vm.prank(service);
        flpPriceStorage.setPrice(nextKey, newPrice - 1); // just outside default range

        vm.expectRevert(abi.encodeWithSelector(IFlpPriceStorage.InvalidPrice.selector));
        vm.prank(service);
        flpPriceStorage.setPrice(nextKey, 0);

        vm.prank(service);
        flpPriceStorage.setPrice(nextKey, newPrice);

        (setPrice,) = flpPriceStorage.lastPrice();
        assertEq(setPrice, newPrice, "test_flpPriceStorage::3");
    }

    function test_rebasingAndWrappedRebasingTokens() public {
        vm.startPrank(admin);
        funToken.mint(userA, 100e18);
        funToken.mint(userB, 100e18);
        vm.stopPrank();

        vm.prank(userA);
        funToken.approve(address(stFunToken), type(uint256).max);
        vm.prank(userB);
        funToken.approve(address(stFunToken), type(uint256).max);

        vm.prank(userA);
        stFunToken.deposit(1e18, userA);

        assertEq(stFunToken.balanceOf(userA), 1e18, "test_rebasingTokens::1");
        assertEq(funToken.balanceOf(address(stFunToken)), 1e18, "test_rebasingTokens::2");
        assertEq(stFunToken.sharesOf(userA), 1e18 * 1000, "test_rebasingTokens::3");

        bytes32 idempotencyKey = keccak256(abi.encode(1));

        vm.prank(service);
        rewardDistributor.distribute(idempotencyKey, 1e18, 0); // mints 1e18 USF as reward

        assertEq(stFunToken.balanceOf(userA), 2e18 - 1, "test_rebasingTokens::4"); // round down
        assertEq(funToken.balanceOf(address(stFunToken)), 2e18, "test_rebasingTokens::5");

        vm.prank(userB);
        stFunToken.deposit(1e18, userB);

        assertEq(stFunToken.balanceOf(userB), 1e18 - 1, "test_rebasingTokens::6"); // round down

        assertEq(stFunToken.balanceOf(userB), 1e18 - 1, "test_rebasingTokens::7");

        assertApproxEqAbs(stFunToken.sharesOf(userB), 1e18 * 1000 / 2, 1000, "test_rebasingTokens::8");

        vm.prank(userA);
        stFunToken.withdrawAll();
        assertApproxEqAbs(funToken.balanceOf(userA), 100e18 + 1e18, 1000, "test_rebasingTokens::9");

        vm.prank(userB);
        stFunToken.withdrawAll();
        assertApproxEqAbs(funToken.balanceOf(address(stFunToken)), 1, 1, "test_rebasingTokens::10");

        vm.prank(userA);
        stFunToken.deposit(1e18, userA);
        uint256 userAStartShares = stFunToken.sharesOf(userA);

        vm.prank(userA);
        stFunToken.approve(address(wstFunToken), type(uint256).max);

        vm.prank(userA);
        wstFunToken.wrap(1e18);

        assertEq(wstFunToken.balanceOf(userA), userAStartShares / 1000, "test_rebasingTokens::11");
        assertEq(stFunToken.balanceOf(userA), 0, "test_rebasingTokens::12");

        vm.expectRevert();
        vm.prank(admin);
        rewardDistributor.distribute(idempotencyKey, 1e18, 1e18); // mints 1e18 USF as reward

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.IdempotencyKeyAlreadyExist.selector, idempotencyKey));
        vm.prank(service);
        rewardDistributor.distribute(idempotencyKey, 1e18, 1e18); // mints 1e18 USF as reward

        idempotencyKey = keccak256(abi.encode(2));
        vm.prank(service);
        rewardDistributor.distribute(idempotencyKey, 1e18, 1e18);

        assertEq(funToken.balanceOf(feeCollector), 1e18, "test_rebasingTokens::13");
        assertApproxEqAbs(funToken.balanceOf(address(stFunToken)), 2e18, 1, "test_rebasingTokens::14");
        assertEq(stFunToken.totalSupply(), funToken.balanceOf(address(stFunToken)), "test_rebasingTokens::15");

        assertEq(wstFunToken.balanceOf(userA), userAStartShares / 1000, "test_rebasingTokens::16");

        uint256 maxAmount = wstFunToken.maxRedeem(userA);

        vm.prank(userA);
        wstFunToken.redeem(maxAmount);

        assertEq(stFunToken.balanceOf(address(wstFunToken)), 0, "test_rebasingTokens::17");

        vm.prank(userA);
        stFunToken.withdrawAll();

        assertEq(stFunToken.balanceOf(userA), 0, "test_rebasingTokens::18");
    }
}
