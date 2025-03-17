// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IStUSF} from "../interfaces/IStUSF.sol";
import {IDefaultErrors} from "../interfaces/IDefaultErrors.sol";
import {IERC20Rebasing} from "../interfaces/IERC20Rebasing.sol";
import {IWstUSF} from "../interfaces/IWstUSF.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract WstUSF is IWstUSF, ERC20PermitUpgradeable, IDefaultErrors {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant ST_USF_SHARES_OFFSET = 1000;

    address public stUSFAddress;
    address public usfAddress;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory _name, string memory _symbol, address _stUSFAddress) public initializer {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);

        _assertNonZero(_stUSFAddress);
        stUSFAddress = _stUSFAddress;

        usfAddress = address(IERC20Rebasing(_stUSFAddress).underlyingToken());
        _assertNonZero(usfAddress);
        IERC20(usfAddress).safeIncreaseAllowance(stUSFAddress, type(uint256).max);
    }

    function asset() external view returns (address usfTokenAddress) {
        return usfAddress;
    }

    function totalAssets() external view returns (uint256 totalManagedusfAmount) {
        return IERC20Rebasing(stUSFAddress).convertToUnderlyingToken(totalSupply() * ST_USF_SHARES_OFFSET);
    }

    function convertToShares(uint256 _usfAmount) public view returns (uint256 wstUSFAmount) {
        return IERC20Rebasing(stUSFAddress).convertToShares(_usfAmount) / ST_USF_SHARES_OFFSET;
    }

    function convertToAssets(uint256 _wstUSFAmount) public view returns (uint256 usfAmount) {
        return IERC20Rebasing(stUSFAddress).convertToUnderlyingToken(_wstUSFAmount * ST_USF_SHARES_OFFSET);
    }

    function maxDeposit(address) external pure returns (uint256 maxusfAmount) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256 maxWstUSFAmount) {
        return type(uint256).max;
    }

    function maxWithdraw(address _owner) public view returns (uint256 maxusfAmount) {
        return convertToAssets(balanceOf(_owner));
    }

    function maxRedeem(address owner) public view returns (uint256 maxWstUSFAmount) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 _usfAmount) public view returns (uint256 wstUSFAmount) {
        return IStUSF(stUSFAddress).previewDeposit(_usfAmount) / ST_USF_SHARES_OFFSET;
    }

    function previewMint(uint256 _wstUSFAmount) public view returns (uint256 usfAmount) {
        IERC20Rebasing stUSF = IERC20Rebasing(stUSFAddress);

        return (_wstUSFAmount * ST_USF_SHARES_OFFSET).mulDiv(
            stUSF.totalSupply() + 1, stUSF.totalShares() + ST_USF_SHARES_OFFSET, Math.Rounding.Ceil
        );
    }

    function previewWithdraw(uint256 _usfAmount) public view returns (uint256 wstUSFAmount) {
        return IStUSF(stUSFAddress).previewWithdraw(_usfAmount).ceilDiv(ST_USF_SHARES_OFFSET);
    }

    function previewRedeem(uint256 _wstUSFAmount) public view returns (uint256 usfAmount) {
        IERC20Rebasing stUSF = IERC20Rebasing(stUSFAddress);

        return (_wstUSFAmount * ST_USF_SHARES_OFFSET).mulDiv(
            stUSF.totalSupply() + 1, stUSF.totalShares() + ST_USF_SHARES_OFFSET, Math.Rounding.Floor
        );
    }

    function deposit(uint256 _usfAmount, address _receiver) public returns (uint256 wstUSFAmount) {
        wstUSFAmount = previewDeposit(_usfAmount);
        _assertNonZero(wstUSFAmount);
        _deposit(msg.sender, _receiver, _usfAmount, wstUSFAmount);

        return wstUSFAmount;
    }

    function deposit(uint256 _usfAmount) external returns (uint256 wstUSFAmount) {
        return deposit(_usfAmount, msg.sender);
    }

    function depositWithPermit(
        uint256 _usfAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 wstUSFAmount) {
        IERC20Permit usfPermit = IERC20Permit(usfAddress);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try usfPermit.permit(msg.sender, address(this), _usfAmount, _deadline, _v, _r, _s) {} catch {}
        return deposit(_usfAmount, _receiver);
    }

    function mint(uint256 _wstUSFAmount, address _receiver) public returns (uint256 usfAmount) {
        usfAmount = previewMint(_wstUSFAmount);
        _deposit(msg.sender, _receiver, usfAmount, _wstUSFAmount);

        return usfAmount;
    }

    function mint(uint256 _wstUSFAmount) external returns (uint256 usfAmount) {
        return mint(_wstUSFAmount, msg.sender);
    }

    function mintWithPermit(
        uint256 _wstUSFAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 usfAmount) {
        IERC20Permit usfPermit = IERC20Permit(usfAddress);
        usfAmount = previewMint(_wstUSFAmount);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try usfPermit.permit(msg.sender, address(this), usfAmount, _deadline, _v, _r, _s) {} catch {}
        _deposit(msg.sender, _receiver, usfAmount, _wstUSFAmount);

        return usfAmount;
    }

    function withdraw(uint256 _usfAmount, address _receiver, address _owner) public returns (uint256 wstUSFAmount) {
        uint256 maxusfAmount = maxWithdraw(_owner);
        if (_usfAmount > maxusfAmount) revert ExceededMaxWithdraw(_owner, _usfAmount, maxusfAmount);

        wstUSFAmount = previewWithdraw(_usfAmount);
        _withdraw(msg.sender, _receiver, _owner, _usfAmount, wstUSFAmount);

        return wstUSFAmount;
    }

    function withdraw(uint256 _usfAmount) external returns (uint256 wstUSFAmount) {
        return withdraw(_usfAmount, msg.sender, msg.sender);
    }

    function redeem(uint256 _wstUSFAmount, address _receiver, address _owner) public returns (uint256 usfAmount) {
        uint256 maxWstUSFAmount = maxRedeem(_owner);
        if (_wstUSFAmount > maxWstUSFAmount) revert ExceededMaxRedeem(_owner, _wstUSFAmount, maxWstUSFAmount);

        usfAmount = previewRedeem(_wstUSFAmount);
        _withdraw(msg.sender, _receiver, _owner, usfAmount, _wstUSFAmount);

        return usfAmount;
    }

    function redeem(uint256 _wstUSFAmount) external returns (uint256 usfAmount) {
        return redeem(_wstUSFAmount, msg.sender, msg.sender);
    }

    function wrap(uint256 _stUSFAmount, address _receiver) public returns (uint256 wstUSFAmount) {
        _assertNonZero(_stUSFAmount);

        wstUSFAmount = convertToShares(_stUSFAmount);
        _assertNonZero(wstUSFAmount);
        IERC20(stUSFAddress).safeTransferFrom(msg.sender, address(this), _stUSFAmount);
        _mint(_receiver, wstUSFAmount);

        emit Wrap(msg.sender, _receiver, _stUSFAmount, wstUSFAmount);

        return wstUSFAmount;
    }

    function wrap(uint256 _stUSFAmount) external returns (uint256 wstUSFAmount) {
        return wrap(_stUSFAmount, msg.sender);
    }

    function wrapWithPermit(
        uint256 _stUSFAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 wstUSFAmount) {
        IERC20Permit stUSFPermit = IERC20Permit(stUSFAddress);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try stUSFPermit.permit(msg.sender, address(this), _stUSFAmount, _deadline, _v, _r, _s) {} catch {}
        return wrap(_stUSFAmount, _receiver);
    }

    function unwrap(uint256 _wstUSFAmount, address _receiver) public returns (uint256 stUSFAmount) {
        _assertNonZero(_wstUSFAmount);

        IERC20Rebasing stUSF = IERC20Rebasing(stUSFAddress);

        uint256 stUSFSharesAmount = _wstUSFAmount * ST_USF_SHARES_OFFSET;
        stUSFAmount = stUSF.convertToUnderlyingToken(stUSFSharesAmount);
        _burn(msg.sender, _wstUSFAmount);
        // slither-disable-next-line unused-return
        stUSF.transferShares(_receiver, stUSFSharesAmount);

        emit Unwrap(msg.sender, _receiver, stUSFAmount, _wstUSFAmount);

        return stUSFAmount;
    }

    function unwrap(uint256 _wstUSFAmount) external returns (uint256 stUSFAmount) {
        return unwrap(_wstUSFAmount, msg.sender);
    }

    function _withdraw(address _caller, address _receiver, address _owner, uint256 _usfAmount, uint256 _wstUSFAmount)
        internal
    {
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _wstUSFAmount);
        }

        IStUSF stUSF = IStUSF(stUSFAddress);

        stUSF.withdraw(_usfAmount, _receiver);
        _burn(_owner, _wstUSFAmount);

        emit Withdraw(msg.sender, _receiver, _owner, _usfAmount, _wstUSFAmount);
    }

    function _deposit(address _caller, address _receiver, uint256 _usfAmount, uint256 _wstUSFAmount) internal {
        IStUSF stUSF = IStUSF(stUSFAddress);
        IERC20 usf = IERC20(usfAddress);

        usf.safeTransferFrom(_caller, address(this), _usfAmount);
        stUSF.deposit(_usfAmount);
        _mint(_receiver, _wstUSFAmount);

        emit Deposit(_caller, _receiver, _usfAmount, _wstUSFAmount);
    }

    function _assertNonZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function _assertNonZero(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}
