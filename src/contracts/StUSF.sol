// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20RebasingPermitUpgradeable} from "./ERC20RebasingPermitUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStUSF} from "../interfaces/IStUSF.sol";
import {IDefaultErrors} from "../interfaces/IDefaultErrors.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StUSF is ERC20RebasingPermitUpgradeable, IStUSF, IDefaultErrors {
    using Math for uint256;
    using SafeERC20 for IERC20Metadata;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _usfAddress
    ) public initializer {
        _assertNonZero(_usfAddress);

        __ERC20Rebasing_init(_name, _symbol, _usfAddress);
        __ERC20RebasingPermit_init(_name);
    }

    function deposit(uint256 _usfAmount, address _receiver) public {
        uint256 shares = previewDeposit(_usfAmount);
        //slither-disable-next-line incorrect-equality
        if (shares == 0) revert InvalidDepositAmount(_usfAmount);

        IERC20Metadata usf = super.underlyingToken();
        super._mint(_receiver, shares);
        usf.safeTransferFrom(msg.sender, address(this), _usfAmount);
        emit Deposit(msg.sender, _receiver, _usfAmount, shares);
    }

    function deposit(uint256 _usfAmount) external {
        deposit(_usfAmount, msg.sender);
    }

    function depositWithPermit(
        uint256 _usfAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public {
        IERC20Metadata usf = super.underlyingToken();
        IERC20Permit usfPermit = IERC20Permit(address(usf));
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try usfPermit.permit(msg.sender, address(this), _usfAmount, _deadline, _v, _r, _s) {} catch {}
        deposit(_usfAmount, _receiver);
    }

    function depositWithPermit(
        uint256 _usfAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        depositWithPermit(_usfAmount, msg.sender, _deadline, _v, _r, _s);
    }

    function withdraw(uint256 _usfAmount) external {
        withdraw(_usfAmount, msg.sender);
    }

    function withdrawAll() external {
        withdraw(super.balanceOf(msg.sender), msg.sender);
    }

    function withdraw(uint256 _usfAmount, address _receiver) public {
        uint256 shares = previewWithdraw(_usfAmount);
        super._burn(msg.sender, shares);

        IERC20Metadata usf = super.underlyingToken();
        usf.safeTransfer(_receiver, _usfAmount);
        emit Withdraw(msg.sender, _receiver, _usfAmount, shares);
    }

    function previewDeposit(uint256 _usfAmount) public view returns (uint256 shares) {
        return _convertToShares(_usfAmount, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 _usfAmount) public view returns (uint256 shares) {
        return _convertToShares(_usfAmount, Math.Rounding.Ceil);
    }

    function _assertNonZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }    
}
