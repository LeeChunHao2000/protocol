// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../interfaces/IAssetRegistry.sol";
import "../interfaces/IBasketHandler.sol";
import "../interfaces/IMain.sol";
import "../libraries/Array.sol";
import "../libraries/Fixed.sol";
import "./mixins/Component.sol";
import "hardhat/console.sol";
// A "valid collateral array" is a an IERC20[] value without rtoken, rsr, or any duplicate values

// A BackupConfig value is valid if erc20s is a valid collateral array
struct BackupConfig {
    uint256 max; // Maximum number of backup collateral erc20s to use in a basket
    IERC20[] erc20s; // Ordered list of backup collateral ERC20s
}

// What does a BasketConfig value mean?
//
// erc20s, targetAmts, and targetNames should be interpreted together.
// targetAmts[erc20] is the quantity of target units of erc20 that one BU should hold
// targetNames[erc20] is the name of erc20's target unit
// and then backups[tgt] is the BackupConfig to use for the target unit named tgt
//
// For any valid BasketConfig value:
//     erc20s == keys(targetAmts) == keys(targetNames)
//     if name is in values(targetNames), then backups[name] is a valid BackupConfig
//     erc20s is a valid collateral array
//
// In the meantime, treat erc20s as the canonical set of keys for the target* maps
struct BasketConfig {
    // The collateral erc20s in the prime (explicitly governance-set) basket
    IERC20[] erc20s;
    // Amount of target units per basket for each prime collateral token. {target/BU}
    mapping(IERC20 => uint192) targetAmts;
    // Cached view of the target unit for each erc20 upon setup
    mapping(IERC20 => bytes32) targetNames;
    // Backup configurations, per target name.
    mapping(bytes32 => BackupConfig) backups;
}

/// The type of BasketHandler.basket.
/// Defines a basket unit (BU) in terms of reference amounts of underlying tokens
// Logically, basket is just a mapping of erc20 addresses to ref-unit amounts.
// In the analytical comments I'll just refer to it that way.
//
// A Basket is valid if erc20s is a valid collateral array and erc20s == keys(refAmts)
struct Basket {
    IERC20[] erc20s; // enumerated keys for refAmts
    mapping(IERC20 => uint192) refAmts; // {ref/BU}
}

/*
 * @title BasketLibP1
 */
library BasketLibP1 {
    using BasketLibP1 for Basket;
    using FixLib for uint192;

    /// Set self to a fresh, empty basket
    // self'.erc20s = [] (empty list)
    // self'.refAmts = {} (empty map)
    function empty(Basket storage self) internal {
        uint256 length = self.erc20s.length;
        for (uint256 i = 0; i < length; ++i) self.refAmts[self.erc20s[i]] = FIX_ZERO;
        delete self.erc20s;
    }

    /// Set `self` equal to `other`
    function setFrom(Basket storage self, Basket storage other) internal {
        empty(self);
        uint256 length = other.erc20s.length;
        for (uint256 i = 0; i < length; ++i) {
            self.erc20s.push(other.erc20s[i]);
            self.refAmts[other.erc20s[i]] = other.refAmts[other.erc20s[i]];
        }
    }

    /// Add `weight` to the refAmount of collateral token `tok` in the basket `self`
    // self'.refAmts[tok] = self.refAmts[tok] + weight
    // self'.erc20s is keys(self'.refAmts)
    function add(
        Basket storage self,
        IERC20 tok,
        uint192 weight
    ) internal {
        // untestable:
        //      Both calls to .add() use a weight that has been CEIL rounded in the
        //      Fixed library div function, so weight will never be 0 here.
        //      Additionally, setPrimeBasket() enforces prime-basket tokens must have a weight > 0.
        if (weight == FIX_ZERO) return;
        if (self.refAmts[tok].eq(FIX_ZERO)) {
            self.erc20s.push(tok);
            self.refAmts[tok] = weight;
        } else {
            self.refAmts[tok] = self.refAmts[tok].plus(weight);
        }
    }
}

/**
 * @title BasketHandler
 * @notice Handles the basket configuration, definition, and evolution over time.
 */
contract BasketHandlerP1 is ComponentP1, IBasketHandler {
    using BasketLibP1 for Basket;
    using CollateralStatusComparator for CollateralStatus;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using FixLib for uint192;

    uint192 public constant MAX_TARGET_AMT = 1e3 * FIX_ONE; // {target/BU} max basket weight
    uint48 public constant MIN_WARMUP_PERIOD = 60; // {s} 1 minute
    uint48 public constant MAX_WARMUP_PERIOD = 31536000; // {s} 1 year

    // Peer components
    IAssetRegistry private assetRegistry;
    IBackingManager private backingManager;
    IERC20 private rsr;
    IRToken private rToken;
    IStRSR private stRSR;

    // config is the basket configuration, from which basket will be computed in a basket-switch
    // event. config is only modified by governance through setPrimeBakset and setBackupConfig
    BasketConfig private config;

    // basket, disabled, nonce, and timestamp are only ever set by `_switchBasket()`
    // basket is the current basket.
    Basket private basket;

    uint48 public override nonce; // {basketNonce} A unique identifier for this basket instance
    uint48 public override timestamp; // The timestamp when this basket was last set

    // If disabled is true, status() is DISABLED, the basket is invalid,
    // and everything except redemption should be paused.
    bool private disabled;

    // === Function-local transitory vars ===

    // These are effectively local variables of _switchBasket.
    // Nothing should use their values from previous transactions.
    EnumerableSet.Bytes32Set private _targetNames;
    Basket private _newBasket;

    // === Warmup Period ===
    // Added in 3.0.0

    // Warmup Period
    uint48 public warmupPeriod; // {s} how long to wait until issuance/trading after regaining SOUND

    // basket status changes, mainly set when `trackStatus()` is called
    // used to enforce warmup period, after regaining SOUND
    uint48 private lastStatusTimestamp;
    CollateralStatus private lastStatus;

    // === Historical basket nonces ===
    // Added in 3.0.0

    // Nonce of the first reference basket from the current prime basket history
    // There can be 0 to any number of baskets with nonce >= primeNonce
    uint48 public primeNonce; // {basketNonce}

    // A history of baskets by basket nonce; includes current basket
    mapping(uint48 => Basket) private basketHistory;

    // ===

    // ==== Invariants ====
    // basket is a valid Basket:
    //   basket.erc20s is a valid collateral array and basket.erc20s == keys(basket.refAmts)
    // config is a valid BasketConfig:
    //   erc20s == keys(targetAmts) == keys(targetNames)
    //   erc20s is a valid collateral array
    //   for b in vals(backups), b.erc20s is a valid collateral array.
    // if basket.erc20s is empty then disabled == true

    // BasketHandler.init() just leaves the BasketHandler state zeroed
    function init(IMain main_, uint48 warmupPeriod_) external initializer {
        __Component_init(main_);

        assetRegistry = main_.assetRegistry();
        backingManager = main_.backingManager();
        rsr = main_.rsr();
        rToken = main_.rToken();
        stRSR = main_.stRSR();

        setWarmupPeriod(warmupPeriod_);

        // Set last status to DISABLED (default)
        lastStatus = CollateralStatus.DISABLED;
        lastStatusTimestamp = uint48(block.timestamp);

        disabled = true;
    }

    /// Disable the basket in order to schedule a basket refresh
    /// @custom:protected
    // checks: caller is assetRegistry
    // effects: disabled' = true
    function disableBasket() external {
        require(_msgSender() == address(assetRegistry), "asset registry only");

        uint256 len = basket.erc20s.length;
        uint192[] memory refAmts = new uint192[](len);
        for (uint256 i = 0; i < len; ++i) refAmts[i] = basket.refAmts[basket.erc20s[i]];
        emit BasketSet(nonce, basket.erc20s, refAmts, true);
        disabled = true;
    }

    /// Switch the basket, only callable directly by governance or after a default
    /// @custom:interaction OR @custom:governance
    // checks: either caller has OWNER,
    //         or (basket is disabled after refresh and we're unpaused and unfrozen)
    // actions: calls assetRegistry.refresh(), then _switchBasket()
    // effects:
    //   Either: (basket' is a valid nonempty basket, without DISABLED collateral,
    //            that satisfies basketConfig) and disabled' = false
    //   Or no such basket exists and disabled' = true
    function refreshBasket() external {
        assetRegistry.refresh();

        require(
            main.hasRole(OWNER, _msgSender()) ||
                (status() == CollateralStatus.DISABLED && !main.tradingPausedOrFrozen()),
            "basket unrefreshable"
        );
        _switchBasket();

        trackStatus();
    }

    /// Track basket status changes if they ocurred
    // effects: lastStatus' = status(), and lastStatusTimestamp' = current timestamp
    /// @custom:refresher
    function trackStatus() public {
        CollateralStatus currentStatus = status();
        if (currentStatus != lastStatus) {
            emit BasketStatusChanged(lastStatus, currentStatus);
            lastStatus = currentStatus;
            lastStatusTimestamp = uint48(block.timestamp);
        }
    }

    /// Set the prime basket in the basket configuration, in terms of erc20s and target amounts
    /// @param erc20s The collateral for the new prime basket
    /// @param targetAmts The target amounts (in) {target/BU} for the new prime basket
    /// @custom:governance
    // checks:
    //   caller is OWNER
    //   len(erc20s) == len(targetAmts)
    //   erc20s is a valid collateral array
    //   for all i, erc20[i] is in AssetRegistry as collateral
    //   for all i, 0 < targetAmts[i] <= MAX_TARGET_AMT == 1000
    //
    // effects:
    //   config'.erc20s = erc20s
    //   config'.targetAmts[erc20s[i]] = targetAmts[i], for i from 0 to erc20s.length-1
    //   config'.targetNames[e] = assetRegistry.toColl(e).targetName, for e in erc20s
    function setPrimeBasket(IERC20[] calldata erc20s, uint192[] calldata targetAmts) external {
        governanceOnly();
        require(erc20s.length > 0, "cannot empty basket");
        require(erc20s.length == targetAmts.length, "must be same length");
        requireValidCollArray(erc20s);

        // Clean up previous basket config
        for (uint256 i = 0; i < config.erc20s.length; ++i) {
            delete config.targetAmts[config.erc20s[i]];
            delete config.targetNames[config.erc20s[i]];
        }
        delete config.erc20s;

        // Set up new config basket
        bytes32[] memory names = new bytes32[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; ++i) {
            // This is a nice catch to have, but in general it is possible for
            // an ERC20 in the prime basket to have its asset unregistered.
            require(assetRegistry.toAsset(erc20s[i]).isCollateral(), "token is not collateral");
            require(0 < targetAmts[i], "invalid target amount; must be nonzero");
            require(targetAmts[i] <= MAX_TARGET_AMT, "invalid target amount; too large");

            config.erc20s.push(erc20s[i]);
            config.targetAmts[erc20s[i]] = targetAmts[i];
            names[i] = assetRegistry.toColl(erc20s[i]).targetName();
            config.targetNames[erc20s[i]] = names[i];
        }

        primeNonce = nonce + 1; // set primeNonce to the next nonce
        emit PrimeBasketSet(primeNonce, erc20s, targetAmts, names);
    }

    /// Set the backup configuration for some target name
    /// @custom:governance
    // checks:
    //   caller is OWNER
    //   erc20s is a valid collateral array
    //   for all i, erc20[i] is in AssetRegistry as collateral
    //
    // effects:
    //   config'.backups[targetName] = {max: max, erc20s: erc20s}
    function setBackupConfig(
        bytes32 targetName,
        uint256 max,
        IERC20[] calldata erc20s
    ) external {
        governanceOnly();
        requireValidCollArray(erc20s);
        BackupConfig storage conf = config.backups[targetName];
        conf.max = max;
        delete conf.erc20s;

        for (uint256 i = 0; i < erc20s.length; ++i) {
            // This is a nice catch to have, but in general it is possible for
            // an ERC20 in the backup config to have its asset altered.
            require(assetRegistry.toAsset(erc20s[i]).isCollateral(), "token is not collateral");
            conf.erc20s.push(erc20s[i]);
        }
        emit BackupConfigSet(targetName, max, erc20s);
    }

    /// @return Whether this contract owns enough collateral to cover rToken.basketsNeeded() BUs
    /// ie, whether the protocol is currently fully collateralized
    function fullyCollateralized() external view returns (bool) {
        BasketRange memory held = basketsHeldBy(address(backingManager));
        return held.bottom >= rToken.basketsNeeded();
    }

    /// @return status_ The status of the basket
    // returns DISABLED if disabled == true, and worst(status(coll)) otherwise
    function status() public view returns (CollateralStatus status_) {
        uint256 size = basket.erc20s.length;

        // untestable:
        //      disabled is only set in _switchBasket, and only if size > 0.
        if (disabled || size == 0) return CollateralStatus.DISABLED;

        for (uint256 i = 0; i < size; ++i) {
            CollateralStatus s = assetRegistry.toColl(basket.erc20s[i]).status();
            if (s.worseThan(status_)) status_ = s;
        }
    }

    /// @return Whether the basket is ready to issue and trade
    function isReady() external view returns (bool) {
        return
            status() == CollateralStatus.SOUND &&
            (block.timestamp >= lastStatusTimestamp + warmupPeriod);
    }

    /// @param erc20 The token contract to check for quantity for
    /// @return {tok/BU} The token-quantity of an ERC20 token in the basket.
    // Returns 0 if erc20 is not registered or not in the basket
    // Returns FIX_MAX (in lieu of +infinity) if Collateral.refPerTok() is 0.
    // Otherwise returns (token's basket.refAmts / token's Collateral.refPerTok())
    function quantity(IERC20 erc20) public view returns (uint192) {
        try assetRegistry.toColl(erc20) returns (ICollateral coll) {
            return _quantity(erc20, coll);
        } catch {
            return FIX_ZERO;
        }
    }

    /// @param erc20 The token contract
    /// @param coll The registered collateral plugin contract
    /// @return {tok/BU} The token-quantity of an ERC20 token in the basket.
    // Returns 0 if coll is not in the basket
    // Returns FIX_MAX (in lieu of +infinity) if Collateral.refPerTok() is 0.
    // Otherwise returns (token's basket.refAmts / token's Collateral.refPerTok())
    function _quantity(IERC20 erc20, ICollateral coll) internal view returns (uint192) {
        uint192 refPerTok = coll.refPerTok();
        if (refPerTok == 0) return FIX_MAX;

        // {tok/BU} = {ref/BU} / {ref/tok}
        return basket.refAmts[erc20].div(refPerTok, CEIL);
    }

    /// Should not revert
    /// @return {UoA/BU} The lower end of the price estimate
    /// @return {UoA/BU} The upper end of the price estimate
    // returns sum(quantity(erc20) * price(erc20) for erc20 in basket.erc20s)
    function price() external view returns (uint192, uint192) {
        (Price memory p, ) = prices();
        return (p.low, p.high);
    }

    /// Should not revert
    /// lowLow should be nonzero when the asset might be worth selling
    /// @return {UoA/BU} The lower end of the lot price estimate
    /// @return {UoA/BU} The upper end of the lot price estimate
    // returns sum(quantity(erc20) * lotPrice(erc20) for erc20 in basket.erc20s)
    function lotPrice() external view returns (uint192, uint192) {
        (, Price memory lotP) = prices();
        return (lotP.low, lotP.high);
    }

    /// Returns both the price() & lotPrice() at once, for gas optimization
    /// @return price_ {UoA/tok} The low and high price estimate of an RToken
    /// @return lotPrice_ {UoA/tok} The low and high lotprice of an RToken
    function prices() public view returns (Price memory price_, Price memory lotPrice_) {
        uint256 low256;
        uint256 high256;
        uint256 lotLow256;
        uint256 lotHigh256;

        uint256 len = basket.erc20s.length;
        for (uint256 i = 0; i < len; ++i) {
            uint192 qty = quantity(basket.erc20s[i]);
            if (qty == 0) continue;

            IAsset asset = assetRegistry.toAsset(basket.erc20s[i]);
            (uint192 lowP, uint192 highP) = asset.price();
            (uint192 lotLowP, uint192 lotHighP) = asset.lotPrice();

            low256 += qty.safeMul(lowP, RoundingMode.FLOOR);
            high256 += qty.safeMul(highP, RoundingMode.CEIL);
            lotLow256 += qty.safeMul(lotLowP, RoundingMode.FLOOR);
            lotHigh256 += qty.safeMul(lotHighP, RoundingMode.CEIL);
        }

        // safe downcast: FIX_MAX is type(uint192).max
        price_.low = low256 >= FIX_MAX ? FIX_MAX : uint192(low256);
        price_.high = high256 >= FIX_MAX ? FIX_MAX : uint192(high256);
        lotPrice_.low = lotLow256 >= FIX_MAX ? FIX_MAX : uint192(lotLow256);
        lotPrice_.high = lotHigh256 >= FIX_MAX ? FIX_MAX : uint192(lotHigh256);
    }

    /// Return the current issuance/redemption value of `amount` BUs
    /// @dev Subset of logic of quoteCustomRedemption; more gas efficient for current nonce
    /// @param amount {BU}
    /// @return erc20s The backing collateral erc20s
    /// @return quantities {qTok} ERC20 token quantities equal to `amount` BUs
    // Returns (erc20s, [quantity(e) * amount {as qTok} for e in erc20s])
    function quote(uint192 amount, RoundingMode rounding)
        external
        view
        returns (address[] memory erc20s, uint256[] memory quantities)
    {
        uint256 length = basket.erc20s.length;
        erc20s = new address[](length);
        quantities = new uint256[](length);

        for (uint256 i = 0; i < length; ++i) {
            erc20s[i] = address(basket.erc20s[i]);
            ICollateral coll = assetRegistry.toColl(IERC20(erc20s[i]));

            // {qTok} = {tok/BU} * {BU} * {tok} * {qTok/tok}
            quantities[i] = _quantity(basket.erc20s[i], coll)
                .safeMul(amount, rounding)
                .shiftl_toUint(
                    int8(IERC20Metadata(address(basket.erc20s[i])).decimals()),
                    rounding
                );
        }
    }

    /// Return the redemption value of `amount` BUs for a linear combination of historical baskets
    /// @param basketNonces An array of basket nonces to do redemption from
    /// @param portions {1} An array of Fix quantities
    /// @param amount {BU}
    /// @return erc20s The backing collateral erc20s
    /// @return quantities {qTok} ERC20 token quantities equal to `amount` BUs
    // Returns (erc20s, [quantity(e) * amount {as qTok} for e in erc20s])
    function quoteCustomRedemption(
        uint48[] memory basketNonces,
        uint192[] memory portions,
        uint192 amount
    ) external view returns (address[] memory erc20s, uint256[] memory quantities) {
        // directly after upgrade the primeNonce will be 0, which is not a valid value
        require(primeNonce > 0, "primeNonce uninitialized");
        require(basketNonces.length == portions.length, "portions does not mirror basketNonces");

        IERC20[] memory erc20sAll = new IERC20[](assetRegistry.size());
        uint192[] memory refAmtsAll = new uint192[](erc20sAll.length);

        uint256 len; // length of return arrays

        // Calculate the linear combination basket
        for (uint48 i = 0; i < basketNonces.length; ++i) {
            require(
                basketNonces[i] >= primeNonce && basketNonces[i] <= nonce,
                "invalid basketNonce"
            ); // will always revert directly after setPrimeBasket()
            Basket storage b = basketHistory[basketNonces[i]];
            // Add-in refAmts contribution from historical basket
            for (uint256 j = 0; j < b.erc20s.length; ++j) {
                IERC20 erc20 = b.erc20s[j];
                if (address(erc20) == address(0)) continue;

                // Ugly search through erc20sAll
                uint256 erc20Index = type(uint256).max;
                for (uint256 k = 0; k < len; ++k) {
                    if (erc20 == erc20sAll[k]) {
                        erc20Index = k;
                        continue;
                    }
                }

                // Add new ERC20 entry if not found
                uint192 amt = portions[i].mul(b.refAmts[erc20], FLOOR);
                if (erc20Index == type(uint256).max) {
                    erc20sAll[len] = erc20;

                    // {ref} = {1} * {ref}
                    refAmtsAll[len] = amt;
                    ++len;
                } else {
                    // {ref} = {1} * {ref}
                    refAmtsAll[erc20Index] += amt;
                }
            }
        }

        erc20s = new address[](len);
        quantities = new uint256[](len);

        // Calculate quantities
        for (uint256 i = 0; i < len; ++i) {
            erc20s[i] = address(erc20sAll[i]);
            IAsset asset = assetRegistry.toAsset(IERC20(erc20s[i]));
            if (!asset.isCollateral()) continue; // skip token if no longer registered

            // prevent div-by-zero
            uint192 refPerTok = ICollateral(address(asset)).refPerTok();
            if (refPerTok == 0) continue; // quantities[i] = 0;

            // {tok} = {BU} * {ref/BU} / {ref/tok}
            quantities[i] = amount.mulDiv(refAmtsAll[i], refPerTok, FLOOR).shiftl_toUint(
                int8(asset.erc20Decimals()),
                FLOOR
            );
            // marginally more penalizing than its sibling calculation that uses _quantity()
            // because does not intermediately CEIL as part of the division
        }
    }

    /// @return baskets {BU}
    ///          .top The number of partial basket units: e.g max(coll.map((c) => c.balAsBUs())
    ///          .bottom The number of whole basket units held by the account
    /// @dev Returns (FIX_ZERO, FIX_MAX) for an empty or DISABLED basket
    // Returns:
    //    (0, 0), if (basket.erc20s is empty) or (disabled is true) or (status() is DISABLED)
    //    min(e.balanceOf(account) / quantity(e) for e in basket.erc20s if quantity(e) > 0),
    function basketsHeldBy(address account) public view returns (BasketRange memory baskets) {
        uint256 length = basket.erc20s.length;
        if (length == 0 || disabled) return BasketRange(FIX_ZERO, FIX_MAX);
        baskets.bottom = FIX_MAX;

        for (uint256 i = 0; i < length; ++i) {
            ICollateral coll = assetRegistry.toColl(basket.erc20s[i]);
            if (coll.status() == CollateralStatus.DISABLED) return BasketRange(FIX_ZERO, FIX_MAX);

            uint192 refPerTok = coll.refPerTok();
            // If refPerTok is 0, then we have zero of coll's reference unit.
            // We know that basket.refAmts[basket.erc20s[i]] > 0, so we have no baskets.
            if (refPerTok == 0) return BasketRange(FIX_ZERO, FIX_MAX);

            // {tok/BU} = {ref/BU} / {ref/tok}.  0-division averted by condition above.
            uint192 q = basket.refAmts[basket.erc20s[i]].div(refPerTok, CEIL);
            // q > 0 because q = (n).div(_, CEIL) and n > 0

            // {BU} = {tok} / {tok/BU}
            uint192 inBUs = coll.bal(account).div(q);
            baskets.bottom = fixMin(baskets.bottom, inBUs);
            baskets.top = fixMax(baskets.top, inBUs);
        }
    }

    // === Governance Setters ===

    /// @custom:governance
    function setWarmupPeriod(uint48 val) public {
        governanceOnly();
        require(val >= MIN_WARMUP_PERIOD && val <= MAX_WARMUP_PERIOD, "invalid warmupPeriod");
        emit WarmupPeriodSet(warmupPeriod, val);
        warmupPeriod = val;
    }

    // === Private ===

    /* _switchBasket computes basket' from three inputs:
       - the basket configuration (config: BasketConfig)
       - the function (isGood: erc20 -> bool), implemented here by goodCollateral()
       - the function (targetPerRef: erc20 -> Fix) implemented by the Collateral plugin

       ==== Definitions ====

       We use e:IERC20 to mean any erc20 token address, and tgt:bytes32 to mean any target name

       // targetWeight(b, e) is the target-unit weight of token e in basket b
       Let targetWeight(b, e) = b.refAmt[e] * targetPerRef(e)

       // backups(tgt) is the list of sound backup tokens we plan to use for target `tgt`.
       Let backups(tgt) = config.backups[tgt].erc20s
                          .filter(isGood)
                          .takeUpTo(config.backups[tgt].max)

       Let primeWt(e) = if e in config.erc20s and isGood(e)
                        then config.targetAmts[e]
                        else 0
       Let backupWt(e) = if e in backups(tgt)
                         then unsoundPrimeWt(tgt) / len(Backups(tgt))
                         else 0
       Let unsoundPrimeWt(tgt) = sum(config.targetAmts[e]
                                     for e in config.erc20s
                                     where config.targetNames[e] == tgt and !isGood(e))

       ==== The correctness condition ====

       If unsoundPrimeWt(tgt) > 0 and len(backups(tgt)) == 0 for some tgt, then disabled' == true.
       Else, disabled' == false and targetWeight(basket', e) == primeWt(e) + backupWt(e) for all e.

       ==== Higher-level desideratum ====

       The resulting total target weights should equal the configured target weight. Formally:

       let configTargetWeight(tgt) = sum(config.targetAmts[e]
                                         for e in config.erc20s
                                         where _targetNames[e] == tgt)

       let targetWeightSum(b, tgt) = sum(targetWeight(b, e)
                                         for e in config.erc20s
                                         where _targetNames[e] == tgt)

       Given all that, if disabled' == false, then for all tgt,
           targetWeightSum(basket', tgt) == configTargetWeight(tgt)

       ==== Usual specs ====

       Then, finally, given all that, the effects of _switchBasket() are:
         nonce' = nonce + 1
         basket' = _newBasket, as defined above
         timestamp' = now
    */

    /// Select and save the next basket, based on the BasketConfig and Collateral statuses
    /// (The mutator that actually does all the work in this contract.)
    function _switchBasket() private {
        disabled = false;

        // _targetNames := {}
        while (_targetNames.length() > 0) _targetNames.remove(_targetNames.at(0));

        // _newBasket := {}
        _newBasket.empty();

        // _targetNames = set(values(config.targetNames))
        // (and this stays true; _targetNames is not touched again in this function)
        uint256 basketLength = config.erc20s.length;
        for (uint256 i = 0; i < basketLength; ++i) {
            _targetNames.add(config.targetNames[config.erc20s[i]]);
        }
        uint256 targetsLength = _targetNames.length();

        // "good" collateral is collateral with any status() other than DISABLED
        // goodWeights and totalWeights are in index-correspondence with _targetNames
        // As such, they're each interepreted as a map from target name -> target weight

        // {target/BU} total target weight of good, prime collateral with target i
        // goodWeights := {}
        uint192[] memory goodWeights = new uint192[](targetsLength);

        // {target/BU} total target weight of all prime collateral with target i
        // totalWeights := {}
        uint192[] memory totalWeights = new uint192[](targetsLength);

        // For each prime collateral token:
        for (uint256 i = 0; i < basketLength; ++i) {
            IERC20 erc20 = config.erc20s[i];

            // Find collateral's targetName index
            uint256 targetIndex;
            for (targetIndex = 0; targetIndex < targetsLength; ++targetIndex) {
                if (_targetNames.at(targetIndex) == config.targetNames[erc20]) break;
            }
            assert(targetIndex < targetsLength);
            // now, _targetNames[targetIndex] == config.targetNames[config.erc20s[i]]

            // Set basket weights for good, prime collateral,
            // and accumulate the values of goodWeights and targetWeights
            uint192 targetWeight = config.targetAmts[erc20];
            totalWeights[targetIndex] = totalWeights[targetIndex].plus(targetWeight);

            if (goodCollateral(config.targetNames[erc20], erc20) && targetWeight.gt(FIX_ZERO)) {
                goodWeights[targetIndex] = goodWeights[targetIndex].plus(targetWeight);
                _newBasket.add(
                    erc20,
                    targetWeight.div(assetRegistry.toColl(erc20).targetPerRef(), CEIL)
                );
                // this div is safe: targetPerRef() > 0: goodCollateral check
            }
        }

        // Analysis: at this point:
        // for all tgt in target names,
        //   totalWeights(tgt)
        //   = sum(config.targetAmts[e] for e in config.erc20s where _targetNames[e] == tgt), and
        //   goodWeights(tgt)
        //   = sum(primeWt(e) for e in config.erc20s where _targetNames[e] == tgt)
        // for all e in config.erc20s,
        //   targetWeight(_newBasket, e)
        //   = sum(primeWt(e) if goodCollateral(e), else 0)

        // For each tgt in target names, if we still need more weight for tgt then try to add the
        // backup basket for tgt to make up that weight:
        for (uint256 i = 0; i < targetsLength; ++i) {
            if (totalWeights[i].lte(goodWeights[i])) continue; // Don't need any backup weight

            // "tgt" = _targetNames[i]
            // Now, unsoundPrimeWt(tgt) > 0

            uint256 size = 0; // backup basket size
            BackupConfig storage backup = config.backups[_targetNames.at(i)];

            // Find the backup basket size: min(backup.max, # of good backup collateral)
            uint256 backupLength = backup.erc20s.length;
            for (uint256 j = 0; j < backupLength && size < backup.max; ++j) {
                if (goodCollateral(_targetNames.at(i), backup.erc20s[j])) size++;
            }

            // Now, size = len(backups(tgt)). Do the disable check:
            // Remove bad collateral and mark basket disabled. Pause most protocol functions
            if (size == 0) disabled = true;

            // Set backup basket weights...
            uint256 assigned = 0;
            // needed = unsoundPrimeWt(tgt)
            uint192 needed = totalWeights[i].minus(goodWeights[i]);

            // Loop: for erc20 in backups(tgt)...
            for (uint256 j = 0; j < backupLength && assigned < size; ++j) {
                IERC20 erc20 = backup.erc20s[j];
                if (goodCollateral(_targetNames.at(i), erc20)) {
                    // Across this .add(), targetWeight(_newBasket',erc20)
                    // = targetWeight(_newBasket,erc20) + unsoundPrimeWt(tgt) / len(backups(tgt))
                    _newBasket.add(
                        erc20,
                        needed.div(assetRegistry.toColl(erc20).targetPerRef().mulu(size), CEIL)
                        // this div is safe: targetPerRef > 0: goodCollateral check
                    );
                    assigned++;
                }
            }
            // Here, targetWeight(_newBasket, e) = primeWt(e) + backupWt(e) for all e targeting tgt
        }
        // Now we've looped through all values of tgt, so for all e,
        //   targetWeight(_newBasket, e) = primeWt(e) + backupWt(e)

        // Notice if basket is actually empty
        uint256 newBasketLength = _newBasket.erc20s.length;
        if (newBasketLength == 0) disabled = true;

        // Update the basket if it's not disabled
        if (!disabled) {
            nonce += 1;
            basket.setFrom(_newBasket);
            basketHistory[nonce].setFrom(_newBasket);
            timestamp = uint48(block.timestamp);
        }

        // Keep records, emit event
        basketLength = basket.erc20s.length;
        uint192[] memory refAmts = new uint192[](basketLength);
        for (uint256 i = 0; i < basketLength; ++i) {
            refAmts[i] = basket.refAmts[basket.erc20s[i]];
        }
        emit BasketSet(nonce, basket.erc20s, refAmts, disabled);
    }

    /// Require that erc20s is a valid collateral array
    function requireValidCollArray(IERC20[] calldata erc20s) internal view {
        IERC20 zero = IERC20(address(0));

        for (uint256 i = 0; i < erc20s.length; i++) {
            // Require collateral is NOT in [0x0, RSR, RToken, StRSR]
            require(
                erc20s[i] != zero &&
                    erc20s[i] != rsr &&
                    erc20s[i] != IERC20(address(rToken)) &&
                    erc20s[i] != IERC20(address(stRSR)),
                "invalid collateral"
            );
        }

        require(ArrayLib.allUnique(erc20s), "contains duplicates");
    }

    /// Good collateral is registered, collateral, SOUND, has the expected targetName,
    /// has nonzero targetPerRef() and refPerTok(), and is not a system token or 0 addr
    function goodCollateral(bytes32 targetName, IERC20 erc20) private view returns (bool) {
        // untestable:
        //      All calls to goodCollateral pass an erc20 from the config or the backup.
        //      Both setPrimeBasket and setBackupConfig must pass a call to requireValidCollArray,
        //      which runs the 4 checks below.
        if (
            erc20 == IERC20(address(0)) ||
            erc20 == rsr ||
            erc20 == IERC20(address(rToken)) ||
            erc20 == IERC20(address(stRSR))
        ) return false;

        try assetRegistry.toColl(erc20) returns (ICollateral coll) {
            return
                targetName == coll.targetName() &&
                coll.status() == CollateralStatus.SOUND &&
                coll.refPerTok() > 0 &&
                coll.targetPerRef() > 0;
        } catch {
            return false;
        }
    }

    // solhint-disable-next-line no-empty-blocks
    function governanceOnly() private view governance {}

    // ==== FacadeRead views ====
    // Not used in-protocol; helpful for reconstructing state

    /// Get a reference basket in today's collateral tokens, by nonce
    /// @param basketNonce {basketNonce}
    /// @return erc20s The erc20s in the reference basket
    /// @return quantities {qTok/BU} The quantity of whole tokens per whole basket unit
    function getHistoricalBasket(uint48 basketNonce)
        external
        view
        returns (IERC20[] memory erc20s, uint256[] memory quantities)
    {
        Basket storage b = basketHistory[basketNonce];
        erc20s = new IERC20[](b.erc20s.length);
        quantities = new uint256[](erc20s.length);

        for (uint256 i = 0; i < b.erc20s.length; ++i) {
            erc20s[i] = b.erc20s[i];

            // {qTok/BU} = {tok/BU} * {qTok/tok}
            quantities[i] = quantity(basket.erc20s[i]).shiftl_toUint(
                int8(IERC20Metadata(address(basket.erc20s[i])).decimals()),
                FLOOR
            );
        }
    }

    /// Getter part1 for `config` struct variable
    /// @dev Indices are shared across return values
    /// @return erc20s The erc20s in the prime basket
    /// @return targetNames The bytes32 name identifier of the target unit, per ERC20
    /// @return targetAmts {target/BU} The amount of the target unit in the basket, per ERC20
    function getPrimeBasket()
        external
        view
        returns (
            IERC20[] memory erc20s,
            bytes32[] memory targetNames,
            uint192[] memory targetAmts
        )
    {
        erc20s = new IERC20[](config.erc20s.length);
        targetNames = new bytes32[](erc20s.length);
        targetAmts = new uint192[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; ++i) {
            erc20s[i] = config.erc20s[i];
            targetNames[i] = config.targetNames[erc20s[i]];
            targetAmts[i] = config.targetAmts[erc20s[i]];
        }
    }

    /// Getter part2 for `config` struct variable
    /// @param targetName The name of the target unit to lookup the backup for
    /// @return erc20s The backup erc20s for the target unit, in order of most to least desirable
    /// @return max The maximum number of tokens from the array to use at a single time
    function getBackupConfig(bytes32 targetName)
        external
        view
        returns (IERC20[] memory erc20s, uint256 max)
    {
        BackupConfig storage backup = config.backups[targetName];
        erc20s = new IERC20[](backup.erc20s.length);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            erc20s[i] = backup.erc20s[i];
        }
        max = backup.max;
    }

    // ==== Storage Gap ====

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[40] private __gap;
}
