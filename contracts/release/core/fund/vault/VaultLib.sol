// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Council <council@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../../../../persistent/dispatcher/IDispatcher.sol";
import "../../../../persistent/vault/VaultLibBase2.sol";
import "../../../interfaces/IWETH.sol";
import "../comptroller/IComptroller.sol";
import "../debt-positions/IDebtPosition.sol";
import "./IVault.sol";

/// @title VaultLib Contract
/// @author Enzyme Council <security@enzyme.finance>
/// @notice The per-release proxiable library contract for VaultProxy
/// @dev The difference in terminology between "asset" and "trackedAsset" is intentional.
/// A fund might actually have asset balances of un-tracked assets,
/// but only tracked assets are used in gav calculations.
/// Note that this contract inherits VaultLibSafeMath (a verbatim Open Zeppelin SafeMath copy)
/// from SharesTokenBase via VaultLibBase2
contract VaultLib is VaultLibBase2, IVault {
    using SafeERC20 for ERC20;

    // Before updating TRACKED_ASSETS_LIMIT in the future, it is important to consider:
    // 1. The highest tracked assets limit ever allowed in the protocol
    // 2. That the next value will need to be respected by all future releases
    uint256 private constant TRACKED_ASSETS_LIMIT = 20;

    address private immutable WETH_TOKEN;

    modifier notShares(address _asset) {
        __assertNotShares(_asset);
        _;
    }

    modifier onlyAccessor() {
        require(msg.sender == accessor, "Only the designated accessor can make this call");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    constructor(address _weth) public {
        WETH_TOKEN = _weth;
    }

    /// @dev If a VaultProxy receives ETH, immediately wrap into WETH.
    /// Will not be able to receive ETH via .transfer() or .send() due to limited gas forwarding.
    receive() external payable {
        IWETH(payable(WETH_TOKEN)).deposit{value: payable(address(this)).balance}();
    }

    /////////////
    // GENERAL //
    /////////////

    /// @notice Claim ownership of the contract
    function claimOwnership() external {
        address nextOwner = nominatedOwner;
        require(
            msg.sender == nextOwner,
            "claimOwnership: Only the nominatedOwner can call this function"
        );

        delete nominatedOwner;

        address prevOwner = owner;
        owner = nextOwner;

        emit OwnershipTransferred(prevOwner, nextOwner);
    }

    /// @notice Revoke the nomination of a new contract owner
    function removeNominatedOwner() external onlyOwner {
        address removedNominatedOwner = nominatedOwner;
        require(
            removedNominatedOwner != address(0),
            "removeNominatedOwner: There is no nominated owner"
        );

        delete nominatedOwner;

        emit NominatedOwnerRemoved(removedNominatedOwner);
    }

    /// @notice Sets the account that is allowed to migrate a fund to new releases
    /// @param _nextMigrator The account to set as the allowed migrator
    /// @dev Set to address(0) to remove the migrator.
    function setMigrator(address _nextMigrator) external onlyOwner {
        address prevMigrator = migrator;
        require(_nextMigrator != prevMigrator, "setMigrator: Value already set");

        migrator = _nextMigrator;

        emit MigratorSet(prevMigrator, _nextMigrator);
    }

    /// @notice Nominate a new contract owner
    /// @param _nextNominatedOwner The account to nominate
    /// @dev Does not prohibit overwriting the current nominatedOwner
    function setNominatedOwner(address _nextNominatedOwner) external onlyOwner {
        require(
            _nextNominatedOwner != address(0),
            "setNominatedOwner: _nextNominatedOwner cannot be empty"
        );
        require(
            _nextNominatedOwner != owner,
            "setNominatedOwner: _nextNominatedOwner is already the owner"
        );
        require(
            _nextNominatedOwner != nominatedOwner,
            "setNominatedOwner: _nextNominatedOwner is already nominated"
        );

        nominatedOwner = _nextNominatedOwner;

        emit NominatedOwnerSet(_nextNominatedOwner);
    }

    ///////////
    // VAULT //
    ///////////

    /// @notice Adds a tracked asset to the fund
    /// @param _asset The asset to add
    /// @dev Allows addition of already tracked assets to fail silently.
    function addTrackedAsset(address _asset) external override onlyAccessor notShares(_asset) {
        if (!isTrackedAsset(_asset)) {
            require(
                trackedAssets.length < TRACKED_ASSETS_LIMIT,
                "addTrackedAsset: Limit exceeded"
            );

            assetToIsTracked[_asset] = true;
            trackedAssets.push(_asset);

            emit TrackedAssetAdded(_asset);
        }
    }

    /// @notice Adds a new debt position to the fund
    /// @param _debtPosition The debt position to add
    /// TODO: Decide whether or not it makes sense to impose a debt position limit
    function addDebtPosition(address _debtPosition) external override onlyAccessor {
        if (!isActiveDebtPosition(_debtPosition)) {
            debtPositionToIsActive[_debtPosition] = true;
            activeDebtPositions.push(_debtPosition);
        }

        emit DebtPositionAdded(_debtPosition);
    }

    /// @notice Adds collateral assets to a specific debt position
    /// @param _debtPosition The debt position address
    /// @param _assets The assets to add as collateral
    /// @param _amounts The amounts of collateral to be added
    /// @param _data Additional data to be processed by the debt position
    function addCollateralAssets(
        address _debtPosition,
        address[] memory _assets,
        uint256[] memory _amounts,
        bytes memory _data
    ) external override onlyAccessor {
        for (uint256 i; i < _assets.length; i++) {
            __assertNotShares(_assets[i]);
            ERC20(_assets[i]).safeTransfer(_debtPosition, _amounts[i]);
        }

        IDebtPosition(_debtPosition).addCollateralAssets(_assets, _amounts, _data);
    }

    /// @notice Grants an allowance to a spender to use the fund's asset
    /// @param _asset The asset for which to grant an allowance
    /// @param _target The spender of the allowance
    /// @param _amount The amount of the allowance
    function approveAssetSpender(
        address _asset,
        address _target,
        uint256 _amount
    ) external override onlyAccessor notShares(_asset) {
        ERC20(_asset).approve(_target, _amount);
    }

    /// @notice Borrows a set of assets from a specific debt position
    /// @param _debtPosition The debt position address
    /// @param _assets The assets to borrow
    /// @param _amounts The amounts of assets to be borrowed
    /// @param _data Additional data to be processed by the debt position
    function borrowAssets(
        address _debtPosition,
        address[] memory _assets,
        uint256[] memory _amounts,
        bytes memory _data
    ) external override onlyAccessor {
        IDebtPosition(_debtPosition).borrowAssets(_assets, _amounts, _data);
    }

    /// @notice Makes an arbitrary call with this contract as the sender
    /// @param _contract The contract to call
    /// @param _callData The call data for the call
    function callOnContract(address _contract, bytes calldata _callData)
        external
        override
        onlyAccessor
    {
        (bool success, bytes memory returnData) = _contract.call(_callData);
        require(success, string(returnData));
    }

    /// @notice Removes a tracked asset from the fund
    /// @param _asset The asset to remove
    function removeTrackedAsset(address _asset) external override onlyAccessor {
        __removeTrackedAsset(_asset);
    }

    /// @notice Removes an amount of collateral assets from a specific debt position
    /// @param _debtPosition The debt position address
    /// @param _assets The assets to remove as collateral
    /// @param _amounts The amounts of collateral to be removed
    /// @param _data Additional data to be processed by the debt position
    function removeCollateralAssets(
        address _debtPosition,
        address[] memory _assets,
        uint256[] memory _amounts,
        bytes memory _data
    ) external override onlyAccessor {
        IDebtPosition(_debtPosition).removeCollateralAssets(_assets, _amounts, _data);
    }

    /// @notice Removes a debt position from the fund
    /// @param _debtPosition The debt position to remove
    function removeDebtPosition(address _debtPosition) external override onlyAccessor {
        if (isActiveDebtPosition(_debtPosition)) {
            debtPositionToIsActive[_debtPosition] = false;

            uint256 debtPositionsCount = activeDebtPositions.length;
            for (uint256 i; i < debtPositionsCount; i++) {
                if (activeDebtPositions[i] == _debtPosition) {
                    if (i < debtPositionsCount - 1) {
                        activeDebtPositions[i] = activeDebtPositions[debtPositionsCount - 1];
                    }
                    activeDebtPositions.pop();
                    break;
                }
            }

            emit DebtPositionRemoved(_debtPosition);
        }
    }

    /// @notice Repays an amount of assets from a specific debt position
    /// @param _debtPosition The debt position address
    /// @param _assets The assets to be repaid
    /// @param _amounts The amounts to be repaid
    /// @param _data Additional data to be processed by the debt position
    function repayBorrowedAssets(
        address _debtPosition,
        address[] memory _assets,
        uint256[] memory _amounts,
        bytes memory _data
    ) external override onlyAccessor {
        for (uint256 i; i < _assets.length; i++) {
            __assertNotShares(_assets[i]);
            ERC20(_assets[i]).safeTransfer(_debtPosition, _amounts[i]);
        }

        IDebtPosition(_debtPosition).repayBorrowedAssets(_assets, _amounts, _data);
    }

    /// @notice Withdraws an asset from the VaultProxy to a given account
    /// @param _asset The asset to withdraw
    /// @param _target The account to which to withdraw the asset
    /// @param _amount The amount of asset to withdraw
    function withdrawAssetTo(
        address _asset,
        address _target,
        uint256 _amount
    ) external override onlyAccessor notShares(_asset) {
        ERC20(_asset).safeTransfer(_target, _amount);

        emit AssetWithdrawn(_asset, _target, _amount);
    }

    /// @dev Helper to the get the Vault's balance of a given asset
    function __getAssetBalance(address _asset) private view returns (uint256 balance_) {
        return ERC20(_asset).balanceOf(address(this));
    }

    /// @dev Helper to remove an asset from a fund's tracked assets.
    /// Allows removal of non-tracked asset to fail silently.
    function __removeTrackedAsset(address _asset) private {
        if (isTrackedAsset(_asset)) {
            assetToIsTracked[_asset] = false;

            uint256 trackedAssetsCount = trackedAssets.length;
            for (uint256 i; i < trackedAssetsCount; i++) {
                if (trackedAssets[i] == _asset) {
                    if (i < trackedAssetsCount - 1) {
                        trackedAssets[i] = trackedAssets[trackedAssetsCount - 1];
                    }
                    trackedAssets.pop();
                    break;
                }
            }

            emit TrackedAssetRemoved(_asset);
        }
    }

    ////////////
    // SHARES //
    ////////////

    /// @notice Burns fund shares from a particular account
    /// @param _target The account for which to burn shares
    /// @param _amount The amount of shares to burn
    function burnShares(address _target, uint256 _amount) external override onlyAccessor {
        __burn(_target, _amount);
    }

    /// @notice Mints fund shares to a particular account
    /// @param _target The account for which to burn shares
    /// @param _amount The amount of shares to mint
    function mintShares(address _target, uint256 _amount) external override onlyAccessor {
        __mint(_target, _amount);
    }

    /// @notice Transfers fund shares from one account to another
    /// @param _from The account from which to transfer shares
    /// @param _to The account to which to transfer shares
    /// @param _amount The amount of shares to transfer
    /// @dev For protocol use only, all other transfers should operate
    /// via standard ERC20 functions
    function transferShares(
        address _from,
        address _to,
        uint256 _amount
    ) external override onlyAccessor {
        __transfer(_from, _to, _amount);
    }

    // ERC20 overrides

    /// @notice Gets the `symbol` value of the shares token
    /// @return symbol_ The `symbol` value
    /// @dev Defers the shares symbol value to the Dispatcher contract
    function symbol() public view override returns (string memory symbol_) {
        return IDispatcher(creator).getSharesTokenSymbol();
    }

    /// @dev Standard implementation of ERC20's transfer().
    /// Overridden to allow arbitrary logic in ComptrollerProxy prior to transfer.
    function transfer(address _recipient, uint256 _amount) public override returns (bool) {
        IComptroller(accessor).preTransferSharesHook(msg.sender, _recipient, _amount);

        return super.transfer(_recipient, _amount);
    }

    /// @dev Standard implementation of ERC20's transferFrom().
    /// Overridden to allow arbitrary logic in ComptrollerProxy prior to transfer.
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        IComptroller(accessor).preTransferSharesHook(_sender, _recipient, _amount);

        return super.transferFrom(_sender, _recipient, _amount);
    }

    /// @dev Checks that assets are not shares
    function __assertNotShares(address _asset) private view {
        require(_asset != address(this), "Cannot act on shares");
    }

    ///////////////////
    // STATE GETTERS //
    ///////////////////

    /// @notice Gets the `accessor` variable
    /// @return accessor_ The `accessor` variable value
    function getAccessor() external view override returns (address accessor_) {
        return accessor;
    }

    /// @notice Gets the `creator` variable
    /// @return creator_ The `creator` variable value
    function getCreator() external view returns (address creator_) {
        return creator;
    }

    /// @notice Gets the `migrator` variable
    /// @return migrator_ The `migrator` variable value
    function getMigrator() external view returns (address migrator_) {
        return migrator;
    }

    /// @notice Gets the account that is nominated to be the next owner of this contract
    /// @return nominatedOwner_ The account that is nominated to be the owner
    function getNominatedOwner() external view returns (address nominatedOwner_) {
        return nominatedOwner;
    }

    /// @notice Gets the `owner` variable
    /// @return owner_ The `owner` variable value
    function getOwner() external view override returns (address owner_) {
        return owner;
    }

    /// @notice Gets the `debtPositions` variable
    /// @return debtPositions_ The `debtPositions` variable value
    function getActiveDebtPositions()
        external
        view
        override
        returns (address[] memory debtPositions_)
    {
        return activeDebtPositions;
    }

    /// @notice Gets the `trackedAssets` variable
    /// @return trackedAssets_ The `trackedAssets` variable value
    function getTrackedAssets() external view override returns (address[] memory trackedAssets_) {
        return trackedAssets;
    }

    /// @notice Check whether a debt position is active on the vault
    /// @param _debtPosition The debtPosition to check
    /// @return isActiveDebtPosition_ True if the address is an active debt position on the vault
    function isActiveDebtPosition(address _debtPosition)
        public
        view
        override
        returns (bool isActiveDebtPosition_)
    {
        return debtPositionToIsActive[_debtPosition];
    }

    /// @notice Gets the `WETH_TOKEN` variable
    /// @return wethToken_ The `WETH_TOKEN` variable value
    function getWethToken() external view returns (address wethToken_) {
        return WETH_TOKEN;
    }

    /// @notice Check whether an address is a tracked asset of the fund
    /// @param _asset The address to check
    /// @return isTrackedAsset_ True if the address is a tracked asset of the fund
    function isTrackedAsset(address _asset) public view override returns (bool isTrackedAsset_) {
        return assetToIsTracked[_asset];
    }
}
