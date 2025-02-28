// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import "../script/Deploy.s.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract DeployScriptTest is Test {
    DeployScript public deployScript;

    ISimpleTokenExtended funToken;
    ISimpleTokenExtended funLpToken;
    IStUSFExtended stFunToken;
    IRewardDistributorExtended rewardDistributor;
    IWstUSFExtended wstFunToken;
    IFlpPriceStorageExtended flpPriceStorage;
    IUsfPriceStorageExtended usfPriceStorage;
    IAddressesWhitelistExtended whitelist;
    IExternalRequestsManagerExtended externalRequestsManager;
    IExternalRequestsManagerExtended usfExternalRequestsManager;

    address admin;

    function setUp() public {
        deployScript = new DeployScript();

        string memory configName = "local_config.json";

        deployScript.run(configName);

        funToken = deployScript.funToken();
        funLpToken = deployScript.funLpToken();
        stFunToken = deployScript.stFunToken();
        wstFunToken = deployScript.wstFunToken();
        rewardDistributor = deployScript.rewardDistributor();
        flpPriceStorage = deployScript.flpPriceStorage();
        usfPriceStorage = deployScript.usfPriceStorage();
        externalRequestsManager = deployScript.externalRequestsManager();
        usfExternalRequestsManager = deployScript.usfExternalRequestsManager();
        whitelist = deployScript.whitelist();

        admin = deployScript.admin();
    }

    function test_deployment() public {
        assertEq(usfExternalRequestsManager.isWhitelistEnabled(), false, "test_deployment::1");
        assertEq(externalRequestsManager.isWhitelistEnabled(), false, "test_deployment::2");

        assertEq(gatherTransparentProxyAdminAddress(address(funToken)), admin, "test_deployment::3");
        assertEq(gatherTransparentProxyAdminAddress(address(funLpToken)), admin, "test_deployment::4");
        assertEq(gatherTransparentProxyAdminAddress(address(stFunToken)), admin, "test_deployment::5");
        assertEq(gatherTransparentProxyAdminAddress(address(wstFunToken)), admin, "test_deployment::6");
        assertEq(gatherTransparentProxyAdminAddress(address(flpPriceStorage)), admin, "test_deployment::7");
        assertEq(gatherTransparentProxyAdminAddress(address(usfPriceStorage)), admin, "test_deployment::8");

        assertEq(usfExternalRequestsManager.ISSUE_TOKEN_ADDRESS(), address(funToken), "test_deployment::9");
        assertEq(externalRequestsManager.ISSUE_TOKEN_ADDRESS(), address(funLpToken), "test_deployment::10");

        vm.warp(block.timestamp + 86400 + 1);

        vm.startPrank(admin);

        whitelist.acceptOwnership();

        funToken.acceptDefaultAdminTransfer();
        funLpToken.acceptDefaultAdminTransfer();
        rewardDistributor.acceptDefaultAdminTransfer();
        flpPriceStorage.acceptDefaultAdminTransfer();
        usfPriceStorage.acceptDefaultAdminTransfer();
        externalRequestsManager.acceptDefaultAdminTransfer();
        usfExternalRequestsManager.acceptDefaultAdminTransfer();

        vm.stopPrank();

        assertEq(whitelist.owner(), admin, "test_deployment::11");
        assertEq(funToken.defaultAdmin(), admin, "test_deployment::12");
        assertEq(funLpToken.defaultAdmin(), admin, "test_deployment::13");
        assertEq(rewardDistributor.defaultAdmin(), admin, "test_deployment::14");
        assertEq(flpPriceStorage.defaultAdmin(), admin, "test_deployment::15");
        assertEq(usfPriceStorage.defaultAdmin(), admin, "test_deployment::16");
        assertEq(externalRequestsManager.defaultAdmin(), admin, "test_deployment::17");
        assertEq(usfExternalRequestsManager.defaultAdmin(), admin, "test_deployment::18");
    }

    function gatherTransparentProxyAdminAddress(address proxy) public view returns (address adminAddress) {
        bytes32 adminSlot = ERC1967Utils.ADMIN_SLOT;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        address proxyAdminAddress = address(uint160(uint256(adminValue)));
        adminAddress = IOwnable(proxyAdminAddress).owner();
    }
}
