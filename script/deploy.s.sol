// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

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

interface ISimpleTokenExtended is ISimpleToken, IERC20, IAccessControlDefaultAdminRules {}

interface IStUSFExtended is IStUSF, IERC20Rebasing {}

interface IRewardDistributorExtended is IRewardDistributor, IAccessControlDefaultAdminRules {}

interface IWstUSFExtended is IERC20, IWstUSF {}

interface IFlpPriceStorageExtended is IFlpPriceStorage, IAccessControlDefaultAdminRules {}

interface IUsfPriceStorageExtended is IUsfPriceStorage, IAccessControlDefaultAdminRules {}

interface IUsfRedemptionExtensionExtended is IUsfRedemptionExtension, IAccessControlDefaultAdminRules {
    function paused() external view returns (bool);
}

interface IUsfExternalRequestsManagerExtended is IUsfExternalRequestsManager, IAccessControlDefaultAdminRules {
    function isWhitelistEnabled() external view returns (bool);
    function ISSUE_TOKEN_ADDRESS() external view returns (address);
}

interface IExternalRequestsManagerExtended is IExternalRequestsManager, IAccessControlDefaultAdminRules {
    function isWhitelistEnabled() external view returns (bool);
    function ISSUE_TOKEN_ADDRESS() external view returns (address);
}

interface ITwoStepOwnable {
    function acceptOwnership() external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface IChainlinkOracleExtended is IChainlinkOracle, ITwoStepOwnable {}

interface IAddressesWhitelistExtended is IAddressesWhitelist, ITwoStepOwnable {}

contract DeployScript is Script {
    SimpleToken implementation;
    ISimpleTokenExtended public funToken;
    ISimpleTokenExtended public funLpToken;
    StUSF stUsfImplementation;
    IStUSFExtended public stFunToken;
    WstUSF wstUsfImpl;
    IWstUSFExtended public wstFunToken;
    IRewardDistributorExtended public rewardDistributor;
    FlpPriceStorage flpPriceStorageImpl;
    IFlpPriceStorageExtended public flpPriceStorage;
    UsfPriceStorage usfPriceStorageImpl;
    IUsfPriceStorageExtended public usfPriceStorage;
    IAddressesWhitelistExtended public whitelist;
    IExternalRequestsManagerExtended public externalRequestsManager;
    IChainlinkOracleExtended public chainlinkOracle;
    IUsfRedemptionExtensionExtended public usfRedemptionExtension;
    IUsfExternalRequestsManagerExtended public usfExternalRequestsManager;

    bytes32 SERVICE_ROLE = keccak256("SERVICE_ROLE");
    uint256 privateKey = vm.envUint("PRIVATE_KEY");

    // load values from config file
    string root = vm.projectRoot();
    string configName;
    string path;
    string json;

    address public service;
    address public admin; // multisig, for ownership transfer on deploy
    address public treasury; // fund management address
    address public usdcAddress;
    address public usdtAddress;
    address public chainlinkFeedRegistry; // only exists on eth mainnet
    address public feeCollector; // fee collection will not occur on smart contract level

    function run(string memory _configName) public {
        configName = _configName;
        path = string.concat(root, "/configs/", configName);
        json = vm.readFile(path);

        service = stdJson.readAddress(json, "$.addresses.service");
        admin = stdJson.readAddress(json, "$.addresses.admin");
        feeCollector = admin;
        treasury = stdJson.readAddress(json, "$.addresses.treasury");
        usdcAddress = stdJson.readAddress(json, "$.addresses.usdcAddress");
        usdtAddress = stdJson.readAddress(json, "$.addresses.usdtAddress");
        chainlinkFeedRegistry = stdJson.readAddress(json, "$.addresses.chainlinkFeedRegistry");

        // caller is the deployer address
        vm.startBroadcast(privateKey);

        // deploy implementation contract for USDFun and FunLP tokens
        implementation = new SimpleToken();

        // deploy the USDFun token
        string memory name = "USDFun";
        string memory symbol = "USDFun";

        bytes memory initializeCall = abi.encodeWithSelector(SimpleToken.initialize.selector, name, symbol);

        funToken = ISimpleTokenExtended(
            address(new TransparentUpgradeableProxy(address(implementation), admin, initializeCall))
        );

        initializeCall = abi.encodeWithSelector(SimpleToken.initialize.selector, name, symbol);

        // deploy the FunLP token
        funLpToken = ISimpleTokenExtended(
            address(new TransparentUpgradeableProxy(address(implementation), admin, initializeCall))
        );

        // deploy the implementation contract for stUSDFun token
        stUsfImplementation = new StUSF();

        name = "StUSDFun";
        symbol = "StUSDFun";

        initializeCall = abi.encodeWithSelector(StUSF.initialize.selector, name, symbol, address(funToken));

        // deploy the stUSDFun token
        stFunToken = IStUSFExtended(
            address(new TransparentUpgradeableProxy(address(stUsfImplementation), admin, initializeCall))
        );

        // deploy the RewardsDistributor contract
        rewardDistributor = IRewardDistributorExtended(
            address(new RewardDistributor(address(stFunToken), feeCollector, address(funToken)))
        );

        rewardDistributor.grantRole(SERVICE_ROLE, service); // service account requires ability trigger rewards distribution
        funToken.grantRole(SERVICE_ROLE, address(rewardDistributor)); // reward distributor needs ability to mint USDFun tokens

        // deploy the implementation contract for wstUSDFun token
        wstUsfImpl = new WstUSF();

        name = "WstUSDFun";
        symbol = "WstUSDFun";
        initializeCall = abi.encodeWithSelector(WstUSF.initialize.selector, name, symbol, address(stFunToken));

        // deploy the wstUSDFun token
        wstFunToken =
            IWstUSFExtended(address(new TransparentUpgradeableProxy(address(wstUsfImpl), admin, initializeCall)));

        // deploying the price storage implementation contract for funLP
        flpPriceStorageImpl = new FlpPriceStorage();

        initializeCall = abi.encodeWithSelector(FlpPriceStorage.initialize.selector, 2e17, 2e17); // lower and upper bounds

        // deploy the price storage contract for funLP
        flpPriceStorage = IFlpPriceStorageExtended(
            address(new TransparentUpgradeableProxy(address(flpPriceStorageImpl), admin, initializeCall))
        );

        flpPriceStorage.grantRole(SERVICE_ROLE, service);

        // deploy the price storage implementation contract for USDFun
        usfPriceStorageImpl = new UsfPriceStorage();

        initializeCall = abi.encodeWithSelector(UsfPriceStorage.initialize.selector, 2e17);

        // deploy the price storage contract for USDFun
        usfPriceStorage = IUsfPriceStorageExtended(
            address(new TransparentUpgradeableProxy(address(usfPriceStorageImpl), admin, initializeCall))
        );

        usfPriceStorage.grantRole(SERVICE_ROLE, service);

        // deploying the whitelist contract
        whitelist = IAddressesWhitelistExtended(address(new AddressesWhitelist()));

        address[] memory whitelistedTokens = new address[](2);
        whitelistedTokens[0] = usdcAddress;
        whitelistedTokens[1] = usdtAddress;

        // deploying the ExternalRequestsManager contract for FunLP tokens
        externalRequestsManager = IExternalRequestsManagerExtended(
            address(new ExternalRequestsManager(address(funLpToken), treasury, address(whitelist), whitelistedTokens))
        );

        funLpToken.grantRole(SERVICE_ROLE, address(externalRequestsManager));

        externalRequestsManager.grantRole(SERVICE_ROLE, service);

        uint48[] memory heartbeatIntervals = new uint48[](2);
        heartbeatIntervals[0] = 86400;
        heartbeatIntervals[1] = 86400;

        chainlinkOracle = IChainlinkOracleExtended(
            address(new ChainlinkOracle(chainlinkFeedRegistry, whitelistedTokens, heartbeatIntervals))
        );

        usfRedemptionExtension = IUsfRedemptionExtensionExtended(
            address(
                new UsfRedemptionExtension(
                    address(funToken),
                    whitelistedTokens,
                    treasury,
                    address(chainlinkOracle),
                    address(usfPriceStorage),
                    60 * 60, // USDFun heartbeat interval
                    1e18, // USDFun redemption limit
                    block.timestamp
                )
            )
        );

        usfExternalRequestsManager = IUsfExternalRequestsManagerExtended(
            address(
                new UsfExternalRequestsManager(
                    address(funToken), treasury, address(whitelist), address(usfRedemptionExtension), whitelistedTokens
                )
            )
        );

        funToken.grantRole(SERVICE_ROLE, address(usfExternalRequestsManager)); // requires for mint and burn functions
        funToken.grantRole(SERVICE_ROLE, address(usfRedemptionExtension)); // requires for redeem() function

        usfRedemptionExtension.grantRole(SERVICE_ROLE, address(usfExternalRequestsManager));

        usfExternalRequestsManager.grantRole(SERVICE_ROLE, address(service));

        usfRedemptionExtension.pause(); // disable automatic redemptions

        // the treasury is required to make token approvals to enable to system to function properly

        // transfer the ownership to the multisig for all contracts
        funToken.beginDefaultAdminTransfer(admin);
        funLpToken.beginDefaultAdminTransfer(admin);
        rewardDistributor.beginDefaultAdminTransfer(admin);
        flpPriceStorage.beginDefaultAdminTransfer(admin);
        usfPriceStorage.beginDefaultAdminTransfer(admin);
        usfRedemptionExtension.beginDefaultAdminTransfer(admin);
        usfExternalRequestsManager.beginDefaultAdminTransfer(admin);
        externalRequestsManager.beginDefaultAdminTransfer(admin);

        whitelist.transferOwnership(admin);
        chainlinkOracle.transferOwnership(admin);

        vm.stopBroadcast();
    }
}
