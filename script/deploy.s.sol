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

interface ISimpleTokenExtended is ISimpleToken, IERC20, IAccessControlDefaultAdminRules {}

interface IStUSFExtended is IStUSF, IERC20Rebasing {}

interface IRewardDistributorExtended is IRewardDistributor, IAccessControlDefaultAdminRules {}

interface IWstUSFExtended is IERC20, IWstUSF {}

interface IFlpPriceStorageExtended is IFlpPriceStorage, IAccessControlDefaultAdminRules {}

interface IUsfPriceStorageExtended is IUsfPriceStorage, IAccessControlDefaultAdminRules {}

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
    IExternalRequestsManagerExtended public usfExternalRequestsManager;

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

    function run(string memory _configName) public {
        configName = _configName;
        path = string.concat(root, "/configs/", configName);
        json = vm.readFile(path);

        service = stdJson.readAddress(json, "$.addresses.service");
        admin = stdJson.readAddress(json, "$.addresses.admin");
        treasury = stdJson.readAddress(json, "$.addresses.treasury");
        usdcAddress = stdJson.readAddress(json, "$.addresses.usdcAddress");

        // caller is the deployer address
        vm.startBroadcast(privateKey);

        // deploy implementation contract for USDV and FunLP tokens
        implementation = new SimpleToken();

        // deploy the USDV token
        string memory name = "USDV";
        string memory symbol = "USDV";

        bytes memory initializeCall = abi.encodeWithSelector(SimpleToken.initialize.selector, name, symbol);

        funToken = ISimpleTokenExtended(
            address(new TransparentUpgradeableProxy(address(implementation), admin, initializeCall))
        );

        // deploy the VLP token
        name = "VLP";
        symbol = "VLP";

        initializeCall = abi.encodeWithSelector(SimpleToken.initialize.selector, name, symbol);

        // deploy the FunLP token
        funLpToken = ISimpleTokenExtended(
            address(new TransparentUpgradeableProxy(address(implementation), admin, initializeCall))
        );

        // deploy the implementation contract for stUSDV token
        stUsfImplementation = new StUSF();

        name = "StUSDV";
        symbol = "StUSDV";

        initializeCall = abi.encodeWithSelector(StUSF.initialize.selector, name, symbol, address(funToken));

        // deploy the stUSDV token
        stFunToken = IStUSFExtended(
            address(new TransparentUpgradeableProxy(address(stUsfImplementation), admin, initializeCall))
        );

        // deploy the RewardsDistributor contract
        rewardDistributor =
            IRewardDistributorExtended(address(new RewardDistributor(address(stFunToken), address(funToken))));

        rewardDistributor.grantRole(SERVICE_ROLE, service); // service account requires ability trigger rewards distribution
        funToken.grantRole(SERVICE_ROLE, address(rewardDistributor)); // reward distributor needs ability to mint USDV tokens

        // deploy the implementation contract for wstUSDV token
        wstUsfImpl = new WstUSF();

        name = "WstUSDV";
        symbol = "WstUSDV";
        initializeCall = abi.encodeWithSelector(WstUSF.initialize.selector, name, symbol, address(stFunToken));

        // deploy the wstUSDV token
        wstFunToken =
            IWstUSFExtended(address(new TransparentUpgradeableProxy(address(wstUsfImpl), admin, initializeCall)));

        // deploying the price storage implementation contract for funLP
        flpPriceStorageImpl = new FlpPriceStorage();

        initializeCall = abi.encodeWithSelector(FlpPriceStorage.initialize.selector, 9e17, 9e17); // lower and upper bounds

        // deploy the price storage contract for funLP
        flpPriceStorage = IFlpPriceStorageExtended(
            address(new TransparentUpgradeableProxy(address(flpPriceStorageImpl), admin, initializeCall))
        );

        flpPriceStorage.grantRole(SERVICE_ROLE, service);

        // deploy the price storage implementation contract for USDV
        usfPriceStorageImpl = new UsfPriceStorage();

        initializeCall = abi.encodeWithSelector(UsfPriceStorage.initialize.selector, 9e17);

        // deploy the price storage contract for USDV
        usfPriceStorage = IUsfPriceStorageExtended(
            address(new TransparentUpgradeableProxy(address(usfPriceStorageImpl), admin, initializeCall))
        );

        usfPriceStorage.grantRole(SERVICE_ROLE, service);

        // deploying the whitelist contract
        whitelist = IAddressesWhitelistExtended(address(new AddressesWhitelist()));

        address[] memory whitelistedTokens = new address[](1);
        whitelistedTokens[0] = usdcAddress;

        // deploying the ExternalRequestsManager contract for FunLP tokens
        externalRequestsManager = IExternalRequestsManagerExtended(
            address(new ExternalRequestsManager(address(funLpToken), treasury, address(whitelist), whitelistedTokens))
        );

        funLpToken.grantRole(SERVICE_ROLE, address(externalRequestsManager));

        externalRequestsManager.grantRole(SERVICE_ROLE, service);

        usfExternalRequestsManager = IExternalRequestsManagerExtended(
            address(new ExternalRequestsManager(address(funToken), treasury, address(whitelist), whitelistedTokens))
        );

        funToken.grantRole(SERVICE_ROLE, address(usfExternalRequestsManager)); // requires for mint and burn functions

        usfExternalRequestsManager.grantRole(SERVICE_ROLE, address(service));

        // transfer the ownership to the multisig for all contracts
        funToken.beginDefaultAdminTransfer(admin);
        funLpToken.beginDefaultAdminTransfer(admin);
        rewardDistributor.beginDefaultAdminTransfer(admin);
        flpPriceStorage.beginDefaultAdminTransfer(admin);
        usfPriceStorage.beginDefaultAdminTransfer(admin);
        usfExternalRequestsManager.beginDefaultAdminTransfer(admin);
        externalRequestsManager.beginDefaultAdminTransfer(admin);

        whitelist.transferOwnership(admin);

        vm.stopBroadcast();
    }
}
