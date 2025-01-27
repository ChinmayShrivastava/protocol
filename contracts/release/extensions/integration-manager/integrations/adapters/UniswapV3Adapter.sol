// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Council <council@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../utils/actions/UniswapV3ActionsMixin.sol";
import "../utils/AdapterBase.sol";

/// @title UniswapV3SwapAdapter Contract
/// @author Enzyme Council <security@enzyme.finance>
/// @notice Adapter for interacting with UniswapV3 swaps
contract UniswapV3Adapter is AdapterBase, UniswapV3ActionsMixin {
    constructor(address _integrationManager, address _router)
        public
        AdapterBase(_integrationManager)
        UniswapV3ActionsMixin(_router)
    {}

    // EXTERNAL FUNCTIONS

    /// @notice Trades assets on UniswapV3
    /// @param _vaultProxy The VaultProxy of the calling fund
    /// @param _actionData Data specific to this action
    function takeOrder(address _vaultProxy, bytes calldata _actionData, bytes calldata)
        external
        onlyIntegrationManager
    {
        (
            address[] memory pathAddresses,
            uint24[] memory pathFees,
            uint256 outgoingAssetAmount,
            uint256 minIncomingAssetAmount
        ) = __decodeCallArgs(_actionData);

        __uniswapV3Swap(_vaultProxy, pathAddresses, pathFees, outgoingAssetAmount, minIncomingAssetAmount);
    }

    /// @notice Parses the expected assets in a particular action
    /// @param _selector The function selector for the callOnIntegration
    /// @param _actionData Data specific to this action
    /// @return spendAssetsHandleType_ A type that dictates how to handle granting
    /// the adapter access to spend assets (`None` by default)
    /// @return spendAssets_ The assets to spend in the call
    /// @return spendAssetAmounts_ The max asset amounts to spend in the call
    /// @return incomingAssets_ The assets to receive in the call
    /// @return minIncomingAssetAmounts_ The min asset amounts to receive in the call
    function parseAssetsForAction(address, bytes4 _selector, bytes calldata _actionData)
        external
        view
        override
        returns (
            IIntegrationManager.SpendAssetsHandleType spendAssetsHandleType_,
            address[] memory spendAssets_,
            uint256[] memory spendAssetAmounts_,
            address[] memory incomingAssets_,
            uint256[] memory minIncomingAssetAmounts_
        )
    {
        require(_selector == TAKE_ORDER_SELECTOR, "parseAssetsForAction: _selector invalid");

        (
            address[] memory pathAddresses,
            uint24[] memory pathFees,
            uint256 outgoingAssetAmount,
            uint256 minIncomingAssetAmount
        ) = __decodeCallArgs(_actionData);

        require(pathAddresses.length >= 2, "parseAssetsForAction: pathAddresses must be >= 2");
        require(
            pathAddresses.length == pathFees.length + 1,
            "parseAssetsForAction: incorrect pathAddresses or pathFees length"
        );

        spendAssets_ = new address[](1);
        spendAssets_[0] = pathAddresses[0];
        spendAssetAmounts_ = new uint256[](1);
        spendAssetAmounts_[0] = outgoingAssetAmount;

        incomingAssets_ = new address[](1);
        incomingAssets_[0] = pathAddresses[pathAddresses.length - 1];
        minIncomingAssetAmounts_ = new uint256[](1);
        minIncomingAssetAmounts_[0] = minIncomingAssetAmount;

        return (
            IIntegrationManager.SpendAssetsHandleType.Transfer,
            spendAssets_,
            spendAssetAmounts_,
            incomingAssets_,
            minIncomingAssetAmounts_
        );
    }

    /// @dev Helper to decode the encoded callOnIntegration call arguments
    function __decodeCallArgs(bytes memory _actionData)
        private
        pure
        returns (
            address[] memory pathAddresses,
            uint24[] memory pathFees,
            uint256 outgoingAssetAmount,
            uint256 minIncomingAssetAmount
        )
    {
        return abi.decode(_actionData, (address[], uint24[], uint256, uint256));
    }
}
