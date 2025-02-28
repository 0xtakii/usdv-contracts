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

contract EndToEndTestLocal is Test {
    bytes32 SERVICE_ROLE = keccak256("SERVICE_ROLE");

    address admin = makeAddr("admin"); // multisig
    address service = makeAddr("service"); // backend
    address feeCollector = makeAddr("feeCollector"); // fee collector
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address treasury = admin;

    ISimpleTokenExtended funToken;
    ISimpleTokenExtended funLpToken;
    IStUSFExtended stFunToken;
    IWstUSFExtended wstFunToken;
    IRewardDistributorExtended rewardDistributor;
    IFlpPriceStorageExtended flpPriceStorage;
    IUsfPriceStorageExtended usfPriceStorage;
    AddressesWhitelist whitelist;
    ExternalRequestsManager externalRequestsManager;
    ExternalRequestsManager usfExternalRequestsManager;

    MintableERC20 usdcToken;
    MintableERC20 usdtToken;

    function setUp() public {
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

        // deploying the mock token(s)
        usdcToken = new MintableERC20("USDC", "USDC");
        usdtToken = new MintableERC20("USDT", "USDT");

        usdcToken.mint(userA, 1_000e18);
        usdtToken.mint(userA, 1_000e18);

        usdcToken.mint(userB, 1_000e18);
        usdtToken.mint(userB, 1_000e18);

        // deploying the requests manager contract
        address[] memory whitelistedTokens = new address[](2);
        whitelistedTokens[0] = address(usdcToken);
        whitelistedTokens[1] = address(usdtToken);

        vm.prank(admin);
        externalRequestsManager =
            new ExternalRequestsManager(address(funLpToken), treasury, address(whitelist), whitelistedTokens);

        vm.prank(admin);
        externalRequestsManager.setWhitelistEnabled(true);

        vm.prank(admin);
        funLpToken.grantRole(SERVICE_ROLE, address(externalRequestsManager));

        vm.prank(admin);
        externalRequestsManager.grantRole(SERVICE_ROLE, service);

        // deploying the USF requests manager contract
        vm.prank(admin);
        usfExternalRequestsManager =
            new ExternalRequestsManager(address(funToken), treasury, address(whitelist), whitelistedTokens);

        vm.prank(admin);
        usfExternalRequestsManager.setWhitelistEnabled(true);

        vm.prank(admin);
        funToken.grantRole(SERVICE_ROLE, address(usfExternalRequestsManager));

        vm.prank(admin);
        usfExternalRequestsManager.grantRole(SERVICE_ROLE, address(service));
    }

    function test_setUp() public {
        assertEq(usfExternalRequestsManager.isWhitelistEnabled(), true, "test_setUp::1");
        assertEq(externalRequestsManager.isWhitelistEnabled(), true, "test_setUp::2");
    }

    function test_usfExternalRequestManagerMint() public {
        vm.prank(userA);
        usdcToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        assertEq(
            usfExternalRequestsManager.allowedTokens(address(usdtToken)), true, "test_externalRequestManagerMint::1"
        );

        vm.expectRevert();
        usfExternalRequestsManager.removeAllowedToken(address(usdtToken));

        vm.prank(admin);
        usfExternalRequestsManager.removeAllowedToken(address(usdtToken));

        assertEq(
            usfExternalRequestsManager.allowedTokens(address(usdtToken)), false, "test_externalRequestManagerMint::2"
        );

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.UnknownProvider.selector, userA));
        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        vm.prank(admin);
        whitelist.addAccount(userA);

        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 0, "test_externalRequestManagerMint::3");

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 0e18, 0e18);

        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 10e18, "test_externalRequestManagerMint::4");

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            usfExternalRequestsManager.mintRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerMint::5");
        assertEq(amount, 10e18, "test_externalRequestManagerMint::6");
        assertEq(token, address(usdcToken), "test_externalRequestManagerMint::7");
        assertEq(minExpectedAmount, 10e18, "test_externalRequestManagerMint::8");

        bytes32 idempotencyKey = keccak256(abi.encode(1));

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 1, 9e18);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.InsufficientMintAmount.selector, 9e18, 10e18));
        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 0, 9e18);

        assertEq(funToken.balanceOf(userA), 0, "test_externalRequestManagerMint::9");

        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funToken.balanceOf(userA), 10e18, "test_externalRequestManagerMint::10");
        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 0, "test_externalRequestManagerMint::11");
        assertEq(usdcToken.balanceOf(address(admin)), 10e18, "test_externalRequestManagerMint::12");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(1);

        vm.expectRevert();
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(0);

        uint256 userAStartUsdc = usdcToken.balanceOf(userA);

        vm.prank(userA);
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc - 10e18, "test_externalRequestManagerMint::13");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(0);

        vm.prank(userA);
        usfExternalRequestsManager.cancelMint(1);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc, "test_externalRequestManagerMint::14");
        assertEq(usdcToken.balanceOf(address(usfExternalRequestsManager)), 0, "test_externalRequestManagerMint::15");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 2));
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
        usfExternalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        vm.prank(admin);
        usfExternalRequestsManager.removeAllowedToken(address(usdtToken));

        bytes32 idempotencyKey = keccak256(abi.encode(1));
        bytes32 nextIdempotencyKey = keccak256(abi.encode(2));

        vm.prank(service);
        usfExternalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funToken.totalSupply(), 10e18, "test_externalRequestManagerBurn::1");
        assertEq(funToken.balanceOf(userA), 10e18, "test_externalRequestManagerBurn::2");

        vm.prank(userA);
        funToken.approve(address(usfExternalRequestsManager), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.TokenNotAllowed.selector, address(usdtToken)));
        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(0e18, address(usdtToken), 0e18);

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(0e18, address(usdcToken), 0e18);

        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(9e18, address(usdcToken), 8e18);

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            usfExternalRequestsManager.burnRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerBurn::3");
        assertEq(amount, 9e18, "test_externalRequestManagerBurn::4");
        assertEq(token, address(usdcToken), "test_externalRequestManagerBurn::5");
        assertEq(minExpectedAmount, 8e18, "test_externalRequestManagerBurn::6");

        assertEq(funToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::7");
        assertEq(funToken.balanceOf(address(usfExternalRequestsManager)), 9e18, "test_externalRequestManagerBurn::8");
        assertEq(usdcToken.balanceOf(admin), 10e18, "test_externalRequestManagerBurn::9");

        vm.expectRevert(
            abi.encodeWithSelector(IExternalRequestsManager.InsufficientWithdrawalAmount.selector, 7e18, 8e18)
        );
        vm.prank(service);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 7e18);

        vm.expectRevert();
        vm.prank(admin);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        vm.prank(service);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        assertEq(usdcToken.balanceOf(admin), 2e18, "test_externalRequestManagerBurn::10");
        assertEq(funToken.totalSupply(), 1e18, "test_externalRequestManagerBurn::11");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(service);
        usfExternalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        vm.prank(admin);
        usfExternalRequestsManager.pause();

        vm.expectRevert();
        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(1e18, address(usdcToken), 1e18);

        vm.prank(admin);
        usfExternalRequestsManager.unpause();

        vm.prank(userA);
        usfExternalRequestsManager.requestBurn(1e18, address(usdcToken), 1e18);

        assertEq(funToken.balanceOf(userA), 0, "test_externalRequestManagerBurn::12");

        vm.prank(userA);
        usfExternalRequestsManager.cancelBurn(1);

        assertEq(funToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::13");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(userA);
        usfExternalRequestsManager.cancelBurn(1);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 2));
        vm.prank(service);
        usfExternalRequestsManager.completeBurn(nextIdempotencyKey, 1, 1e18);
    }

    function test_externalRequestManagerMint() public {
        vm.prank(userA);
        usdcToken.approve(address(externalRequestsManager), type(uint256).max);

        assertEq(externalRequestsManager.allowedTokens(address(usdtToken)), true, "test_externalRequestManagerMint::1");

        vm.expectRevert();
        externalRequestsManager.removeAllowedToken(address(usdtToken));

        vm.prank(admin);
        externalRequestsManager.removeAllowedToken(address(usdtToken));

        assertEq(externalRequestsManager.allowedTokens(address(usdtToken)), false, "test_externalRequestManagerMint::2");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.UnknownProvider.selector, userA));
        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        vm.prank(admin);
        whitelist.addAccount(userA);

        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 0, "test_externalRequestManagerMint::3");

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 0e18, 0e18);

        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 10e18, "test_externalRequestManagerMint::4");

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            externalRequestsManager.mintRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerMint::5");
        assertEq(amount, 10e18, "test_externalRequestManagerMint::6");
        assertEq(token, address(usdcToken), "test_externalRequestManagerMint::7");
        assertEq(minExpectedAmount, 10e18, "test_externalRequestManagerMint::8");

        bytes32 idempotencyKey = keccak256(abi.encode(1));

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 1, 9e18);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.InsufficientMintAmount.selector, 9e18, 10e18));
        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 0, 9e18);

        assertEq(funLpToken.balanceOf(userA), 0, "test_externalRequestManagerMint::9");

        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funLpToken.balanceOf(userA), 10e18, "test_externalRequestManagerMint::10");
        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 0, "test_externalRequestManagerMint::11");
        assertEq(usdcToken.balanceOf(address(admin)), 10e18, "test_externalRequestManagerMint::12");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.MintRequestNotExist.selector, 1));
        vm.prank(userA);
        externalRequestsManager.cancelMint(1);

        vm.expectRevert();
        vm.prank(userA);
        externalRequestsManager.cancelMint(0);

        uint256 userAStartUsdc = usdcToken.balanceOf(userA);

        vm.prank(userA);
        externalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc - 10e18, "test_externalRequestManagerMint::13");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(userA);
        externalRequestsManager.cancelMint(0);

        vm.prank(userA);
        externalRequestsManager.cancelMint(1);

        assertEq(usdcToken.balanceOf(userA), userAStartUsdc, "test_externalRequestManagerMint::14");
        assertEq(usdcToken.balanceOf(address(externalRequestsManager)), 0, "test_externalRequestManagerMint::15");

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
        externalRequestsManager.requestMint(address(usdcToken), 10e18, 10e18);

        vm.prank(admin);
        externalRequestsManager.removeAllowedToken(address(usdtToken));

        bytes32 idempotencyKey = keccak256(abi.encode(1));
        bytes32 nextIdempotencyKey = keccak256(abi.encode(2));

        vm.prank(service);
        externalRequestsManager.completeMint(idempotencyKey, 0, 10e18);

        assertEq(funLpToken.totalSupply(), 10e18, "test_externalRequestManagerBurn::1");
        assertEq(funLpToken.balanceOf(userA), 10e18, "test_externalRequestManagerBurn::2");

        vm.prank(userA);
        funLpToken.approve(address(externalRequestsManager), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.TokenNotAllowed.selector, address(usdtToken)));
        vm.prank(userA);
        externalRequestsManager.requestBurn(0e18, address(usdtToken), 0e18);

        vm.expectRevert(abi.encodeWithSelector(IDefaultErrors.InvalidAmount.selector, 0));
        vm.prank(userA);
        externalRequestsManager.requestBurn(0e18, address(usdcToken), 0e18);

        vm.prank(userA);
        externalRequestsManager.requestBurn(9e18, address(usdcToken), 8e18);

        (, address provider,, uint256 amount, address token, uint256 minExpectedAmount) =
            externalRequestsManager.burnRequests(0);

        assertEq(provider, userA, "test_externalRequestManagerBurn::3");
        assertEq(amount, 9e18, "test_externalRequestManagerBurn::4");
        assertEq(token, address(usdcToken), "test_externalRequestManagerBurn::5");
        assertEq(minExpectedAmount, 8e18, "test_externalRequestManagerBurn::6");

        assertEq(funLpToken.balanceOf(userA), 1e18, "test_externalRequestManagerBurn::7");
        assertEq(funLpToken.balanceOf(address(externalRequestsManager)), 9e18, "test_externalRequestManagerBurn::8");
        assertEq(usdcToken.balanceOf(admin), 10e18, "test_externalRequestManagerBurn::9");

        vm.expectRevert(
            abi.encodeWithSelector(IExternalRequestsManager.InsufficientWithdrawalAmount.selector, 7e18, 8e18)
        );
        vm.prank(service);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 7e18);

        vm.expectRevert();
        vm.prank(admin);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        vm.prank(service);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        assertEq(usdcToken.balanceOf(admin), 2e18, "test_externalRequestManagerBurn::10");
        assertEq(funLpToken.totalSupply(), 1e18, "test_externalRequestManagerBurn::11");

        vm.expectRevert(abi.encodeWithSelector(IExternalRequestsManager.IllegalState.selector, 0, 1));
        vm.prank(service);
        externalRequestsManager.completeBurn(idempotencyKey, 0, 8e18);

        vm.prank(admin);
        externalRequestsManager.pause();

        vm.expectRevert();
        vm.prank(userA);
        externalRequestsManager.requestBurn(1e18, address(usdcToken), 1e18);

        vm.prank(admin);
        externalRequestsManager.unpause();

        vm.prank(userA);
        externalRequestsManager.requestBurn(1e18, address(usdcToken), 1e18);

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
