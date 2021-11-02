// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/Oracle.sol";
import "./IAsset.sol";
import "./IAssetManager.sol";
import "./IDefaultMonitor.sol";
import "./IFurnace.sol";
import "./IRToken.sol";
import "./IStRSR.sol";
import "./IVault.sol";

/// @notice The 4 canonical states of the system
enum State {
    CALM, // 100% capitalized + no auctions
    DOUBT, // in this state for 24h before default, no auctions or unstaking
    TRADING, // auctions in progress, no unstaking
    PRECAUTIONARY // no auctions, no issuance, no unstaking
}

/// @notice Configuration of the system
struct Config {
    // Time (seconds)
    uint256 rewardStart; // the timestamp of the very first weekly reward handout
    uint256 rewardPeriod; // the duration of time between reward events
    uint256 auctionPeriod; // the length of an auction
    uint256 stRSRWithdrawalDelay; // the "thawing time" of staked RSR before withdrawal
    uint256 defaultDelay; // how long to wait until switching vaults after detecting default
    // Percentage values (relative to SCALE)
    uint256 maxTradeSlippage; // the maximum amount of slippage in percentage terms we will accept in a trade
    uint256 auctionClearingTolerance; // the maximum % difference between auction clearing price and oracle data allowed.
    uint256 maxAuctionSize; // the max size of an auction, as a fraction of RToken supply
    uint256 minRecapitalizationAuctionSize; // the min size of a recapitalization auction, as a fraction of RToken supply
    uint256 minRevenueAuctionSize; // the min size of a revenue auction (RToken/COMP/AAVE), as a fraction of RToken supply
    uint256 migrationChunk; // how much backing to migrate at a time, as a fraction of RToken supply
    uint256 issuanceRate; // the number of RToken to issue per block, as a fraction of RToken supply
    uint256 defaultThreshold; // the percent deviation required before a token is marked as in-default
    uint256 f; // The Revenue Factor: the fraction of revenue that goes to stakers
    // TODO: Revenue Distribution Map

    // Sample values
    //
    // rewardStart = timestamp of first weekly handout
    // rewardPeriod = 604800 (1 week)
    // auctionPeriod = 1800 (30 minutes)
    // stRSRWithdrawalDelay = 1209600 (2 weeks)
    // defaultDelay = 86400 (24 hours)
    // maxTradeSlippage = 1e17 (10%)
    // auctionClearingTolerance = 1e17 (10%)
    // maxAuctionSize = 1e16 (1%)
    // minRecapitalizationAuctionSize = 1e15 (0.1%)
    // minRevenueAuctionSize = 1e14 (0.01%)
    // migrationChunk = 2e17 (20%)
    // issuanceRate = 25e13 (0.025% per block, or ~0.1% per minute)
    // defaultThreshold = 5e16 (5% deviation)
    // f = 6e17 (60% to stakers)
}

/// @notice Tracks data for an issuance
/// @param vault The vault the issuance is against
/// @param amount The quantity of RToken the issuance is for
/// @param BUs The number of BUs that corresponded to `amount` at time of issuance
/// @param basketAmounts The collateral token quantities that were used to pay for the issuance
/// @param issuer The account issuing RToken
/// @param blockAvailableAt The block number at which the issuance can complete
/// @param processed false when the issuance is still vesting
struct SlowIssuance {
    IVault vault;
    uint256 amount;
    uint256 BUs;
    uint256[] basketAmounts;
    address issuer;
    uint256 blockAvailableAt;
    bool processed;
}

/**
 * @title IMain
 * @notice The central coordinator for the entire system, as well as the external interface.
 * @dev
 */
interface IMain {
    /// @notice Emitted when issuance is started, at the point collateral is taken in
    /// @param issuanceId The index off the issuance, a globally unique identifier
    /// @param issuer The account performing the issuance
    /// @param amount The quantity of RToken being issued
    event IssuanceStart(
        uint256 indexed issuanceId,
        address indexed issuer,
        uint256 indexed amount,
        uint256 blockAvailableAt
    );

    /// @notice Emitted when an RToken issuance is canceled, such as during a default
    /// @param issuanceId The index of the issuance, a globally unique identifier
    event IssuanceCancel(uint256 indexed issuanceId);

    /// @notice Emitted when an RToken issuance is completed successfully
    /// @param issuanceId The index of the issuance, a globally unique identifier
    event IssuanceComplete(uint256 indexed issuanceId);

    /// @notice Emitted when a redemption of RToken occurs
    /// @param redeemer The address of the account redeeeming RTokens
    /// @param amount The quantity of RToken being redeemed
    event Redemption(address indexed redeemer, uint256 indexed amount);

    /// @notice Emitted when there is a change in system state.
    event StateChange(State indexed oldState, State indexed newState);

    //

    /// @notice Begin a time-delayed issuance of RToken for basket collateral
    /// @param amount The quantity {qRToken} of RToken to issue
    function issue(uint256 amount) external;

    /// @notice Redeem RToken for basket collateral
    /// @param amount The quantity {qRToken} of RToken to redeem
    function redeem(uint256 amount) external;

    /// @notice Runs the central auction loop
    function poke() external;

    /// @notice Performs the expensive checks for default, such as calculating VWAPs
    function noticeDefault() external;

    /// @return Whether the system is paused
    function paused() external view returns (bool);

    /// @return The quantities of collateral tokens that would be required to issue `amount` RToken
    function quote(uint256 amount) external view returns (uint256[] memory);

    /// @return erc20s The addresses of the ERC20s backing the RToken
    function backingTokens() external view returns (address[] memory);

    /// @return The timestamp of the next rewards event
    function nextRewards() external view returns (uint256);

    // System-internal API

    /// @return The RSR ERC20 deployment on this chain
    function rsr() external view returns (IERC20);

    /// @return The RToken provided by the system
    function rToken() external view returns (IRToken);

    /// @return The RToken Furnace associated with this RToken instance
    function furnace() external view returns (IFurnace);

    /// @return The staked form of RSR for this RToken instance
    function stRSR() external view returns (IStRSR);

    /// @return The AssetManager associated with this RToken instance
    function manager() external view returns (IAssetManager);

    /// @return The DefaultMonitor associated with this RToken instance
    function monitor() external view returns (IDefaultMonitor);

    /// @return The price in USD of `token` on Aave {UNITS}
    function consultAaveOracle(address token) external view returns (uint256);

    /// @return The price in USD of `token` on Compound {UNITS}
    function consultCompoundOracle(address token) external view returns (uint256);

    /// @return The deployment of the comptroller on this chain
    function comptroller() external view returns (IComptroller);

    /// @return The asset for the RToken
    function rTokenAsset() external view returns (IAsset);

    /// @return The asset for RSR
    function rsrAsset() external view returns (IAsset);

    /// @return The asset for COMP
    function compAsset() external view returns (IAsset);

    /// @return The asset for AAVE
    function aaveAsset() external view returns (IAsset);

    /// @return 1e18, TODO: get rid of
    function SCALE() external view returns (uint256);

    /// @return The system configuration
    function config() external view returns (Config memory);
}