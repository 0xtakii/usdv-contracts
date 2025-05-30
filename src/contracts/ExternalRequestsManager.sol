// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ISimpleToken} from "../interfaces/ISimpleToken.sol";
import {IExternalRequestsManager} from "../interfaces/IExternalRequestsManager.sol";
import {IAddressesWhitelist} from "../interfaces/IAddressesWhitelist.sol";

contract ExternalRequestsManager is IExternalRequestsManager, AccessControlDefaultAdminRules, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");

    address public immutable ISSUE_TOKEN_ADDRESS;
    address public treasuryAddress;

    IAddressesWhitelist public providersWhitelist;
    bool public isWhitelistEnabled;

    mapping(address token => bool isAllowed) public allowedTokens;

    uint256 public burnRequestsCounter;
    mapping(uint256 id => Request request) public burnRequests;

    uint256 public mintRequestsCounter;
    mapping(uint256 id => Request request) public mintRequests;

    modifier onlyAllowedProviders() {
        if (isWhitelistEnabled && !providersWhitelist.isAllowedAccount(msg.sender)) {
            revert UnknownProvider(msg.sender);
        }
        _;
    }

    modifier burnRequestExist(uint256 _id) {
        if (burnRequests[_id].provider == address(0)) {
            revert BurnRequestNotExist(_id);
        }
        _;
    }

    modifier mintRequestExist(uint256 _id) {
        if (mintRequests[_id].provider == address(0)) {
            revert MintRequestNotExist(_id);
        }
        _;
    }

    modifier allowedToken(address _tokenAddress) {
        _assertNonZero(_tokenAddress);
        if (!allowedTokens[_tokenAddress]) {
            revert TokenNotAllowed(_tokenAddress);
        }
        _;
    }

    constructor(
        address _issueTokenAddress,
        address _treasuryAddress,
        address _providersWhitelistAddress,
        address[] memory _allowedTokenAddresses
    ) AccessControlDefaultAdminRules(1 days, msg.sender) {
        ISSUE_TOKEN_ADDRESS = _assertNonZero(_issueTokenAddress);
        treasuryAddress = _assertNonZero(_treasuryAddress);
        providersWhitelist = IAddressesWhitelist(_assertNonZero(_providersWhitelistAddress));

        for (uint256 i = 0; i < _allowedTokenAddresses.length; i++) {
            address allowedTokenAddress = _allowedTokenAddresses[i];
            _assertNonZero(allowedTokenAddress);
            // if (allowedTokenAddress.code.length == 0) revert InvalidTokenAddress(allowedTokenAddress);
            allowedTokens[allowedTokenAddress] = true;
        }

        // isWhitelistEnabled = false;
    }

    function setTreasury(address _treasuryAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_treasuryAddress);
        treasuryAddress = _treasuryAddress;
        emit TreasurySet(_treasuryAddress);
    }

    function setProvidersWhitelist(address _providersWhitelistAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_providersWhitelistAddress);
        if (_providersWhitelistAddress.code.length == 0) revert InvalidProvidersWhitelist(_providersWhitelistAddress);
        providersWhitelist = IAddressesWhitelist(_providersWhitelistAddress);
        emit ProvidersWhitelistSet(_providersWhitelistAddress);
    }

    function setWhitelistEnabled(bool _isEnabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isWhitelistEnabled = _isEnabled;
        emit WhitelistEnabledSet(_isEnabled);
    }

    function addAllowedToken(address _allowedTokenAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_allowedTokenAddress);
        if (_allowedTokenAddress.code.length == 0) revert InvalidTokenAddress(_allowedTokenAddress);
        allowedTokens[_allowedTokenAddress] = true;
        emit AllowedTokenAdded(_allowedTokenAddress);
    }

    function removeAllowedToken(address _allowedTokenAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_allowedTokenAddress);
        allowedTokens[_allowedTokenAddress] = false;
        emit AllowedTokenRemoved(_allowedTokenAddress);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._unpause();
    }

    function requestMint(address _depositTokenAddress, uint256 _amount, uint256 _minMintAmount)
        public
        onlyAllowedProviders
        allowedToken(_depositTokenAddress)
        whenNotPaused
    {
        _assertAmount(_amount);

        IERC20(_depositTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        Request memory request = _addMintRequest(_depositTokenAddress, _amount, _minMintAmount);

        emit MintRequestCreated(request.id, request.provider, request.token, request.amount, request.minExpectedAmount);
    }

    function requestMintWithPermit(
        address _depositTokenAddress,
        uint256 _amount,
        uint256 _minMintAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC20Permit tokenPermit = IERC20Permit(_depositTokenAddress);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try tokenPermit.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {} catch {}
        requestMint(_depositTokenAddress, _amount, _minMintAmount);
    }

    function cancelMint(uint256 _id) external mintRequestExist(_id) {
        Request storage request = mintRequests[_id];
        _assertAddress(request.provider, msg.sender);
        _assertState(State.CREATED, request.state);

        request.state = State.CANCELLED;

        IERC20 depositedToken = IERC20(request.token);
        depositedToken.safeTransfer(request.provider, request.amount);

        emit MintRequestCancelled(_id);
    }

    function completeMint(bytes32 _idempotencyKey, uint256 _id, uint256 _mintAmount)
        external
        onlyRole(SERVICE_ROLE)
        mintRequestExist(_id)
    {
        Request storage request = mintRequests[_id];
        _assertState(State.CREATED, request.state);
        if (_mintAmount < request.minExpectedAmount) {
            revert InsufficientMintAmount(_mintAmount, request.minExpectedAmount);
        }

        request.state = State.COMPLETED;

        IERC20 depositToken = IERC20(request.token);
        depositToken.safeTransfer(treasuryAddress, request.amount);

        ISimpleToken issueToken = ISimpleToken(ISSUE_TOKEN_ADDRESS);
        issueToken.mint(_idempotencyKey, request.provider, _mintAmount);

        emit MintRequestCompleted(_idempotencyKey, _id, _mintAmount);
    }

    function requestBurn(uint256 _issueTokenAmount, address _withdrawalTokenAddress, uint256 _minWithdrawalAmount)
        public
        onlyAllowedProviders
        allowedToken(_withdrawalTokenAddress)
        whenNotPaused
    {
        _assertAmount(_issueTokenAmount);

        IERC20 issueToken = IERC20(ISSUE_TOKEN_ADDRESS);
        issueToken.safeTransferFrom(msg.sender, address(this), _issueTokenAmount);

        Request memory request = _addBurnRequest(_withdrawalTokenAddress, _issueTokenAmount, _minWithdrawalAmount);

        emit BurnRequestCreated(request.id, request.provider, request.token, request.amount, request.minExpectedAmount);
    }

    function requestBurnWithPermit(
        uint256 _issueTokenAmount,
        address _withdrawalTokenAddress,
        uint256 _minWithdrawalAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC20Permit tokenPermit = IERC20Permit(ISSUE_TOKEN_ADDRESS);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try tokenPermit.permit(msg.sender, address(this), _issueTokenAmount, _deadline, _v, _r, _s) {} catch {}
        requestBurn(_issueTokenAmount, _withdrawalTokenAddress, _minWithdrawalAmount);
    }

    function cancelBurn(uint256 _id) external burnRequestExist(_id) {
        Request storage request = burnRequests[_id];
        _assertAddress(request.provider, msg.sender);
        _assertState(State.CREATED, request.state);

        request.state = State.CANCELLED;
        IERC20 issueToken = IERC20(ISSUE_TOKEN_ADDRESS);
        issueToken.safeTransfer(request.provider, request.amount);

        emit BurnRequestCancelled(_id);
    }

    function completeBurn(bytes32 _idempotencyKey, uint256 _id, uint256 _withdrawalAmount)
        external
        onlyRole(SERVICE_ROLE)
        burnRequestExist(_id)
    {
        Request storage request = burnRequests[_id];
        _assertState(State.CREATED, request.state);
        if (_withdrawalAmount < request.minExpectedAmount) {
            revert InsufficientWithdrawalAmount(_withdrawalAmount, request.minExpectedAmount);
        }

        request.state = State.COMPLETED;

        ISimpleToken issueToken = ISimpleToken(ISSUE_TOKEN_ADDRESS);
        issueToken.burn(_idempotencyKey, address(this), request.amount);

        // slither-disable-next-line arbitrary-send-erc20
        IERC20(request.token).safeTransferFrom(treasuryAddress, request.provider, _withdrawalAmount);

        emit BurnRequestCompleted(_id, request.amount, _withdrawalAmount);
    }

    /* 
     * @dev Will never be called except in extreme emergency case.
     */
    function emergencyWithdraw(IERC20 _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _token.safeTransfer(msg.sender, _amount);

        emit EmergencyWithdrawn(address(_token), _amount);
    }

    /* 
     * @dev Will never be called except in extreme emergency case. User funds will never be trapped.
     */
    function emergencyCancelMintRequest(uint256 _id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Request storage request = mintRequests[_id];
        _assertState(State.CREATED, request.state);

        uint256 requestAmount = request.amount; // check for existence
        if (requestAmount == 0) revert InvalidAmount(requestAmount);

        request.state = State.CANCELLED;

        emit EmergencyCancelMintRequest(_id);
    }

    function _addMintRequest(address _tokenAddress, uint256 _amount, uint256 _minExpectedAmount)
        internal
        returns (Request memory mintRequest)
    {
        uint256 id = mintRequestsCounter;
        mintRequest = Request({
            id: id,
            provider: msg.sender,
            state: State.CREATED,
            amount: _amount,
            token: _tokenAddress,
            minExpectedAmount: _minExpectedAmount
        });
        mintRequests[id] = mintRequest;

        unchecked {
            mintRequestsCounter++;
        }

        return mintRequest;
    }

    function _addBurnRequest(address _tokenAddress, uint256 _amount, uint256 _minWithdrawalAmount)
        internal
        returns (Request memory burnRequest)
    {
        uint256 id = burnRequestsCounter;
        burnRequest = Request({
            id: id,
            provider: msg.sender,
            state: State.CREATED,
            amount: _amount,
            token: _tokenAddress,
            minExpectedAmount: _minWithdrawalAmount
        });
        burnRequests[id] = burnRequest;

        unchecked {
            burnRequestsCounter++;
        }

        return burnRequest;
    }

    function _assertNonZero(address _address) internal pure returns (address nonZeroAddress) {
        if (_address == address(0)) revert ZeroAddress();
        return _address;
    }

    function _assertState(State _expected, State _current) internal pure {
        if (_expected != _current) revert IllegalState(_expected, _current);
    }

    function _assertAddress(address _expected, address _actual) internal pure {
        if (_expected != _actual) revert IllegalAddress(_expected, _actual);
    }

    function _assertAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}
