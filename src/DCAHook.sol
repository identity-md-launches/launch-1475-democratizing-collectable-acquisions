// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {HookBase} from "./HookBase.sol";

/// @notice Five percent of the gross FWA side of DCA swaps belongs to the fixed creator.
/// @dev Fees are converted to native ETH inside the same PoolManager unlock. Bounded, unsold
/// FWA and unavailable/rejected ETH payouts remain ERC-6909 claims owned by this hook.
contract DCAHook is HookBase, IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    address public constant RECIPIENT = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
    address public constant PAIRED_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS = 10_000;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 private constant MAX_DELTA = (1 << 127) - 1;
    /// @dev Old FWA claims sold beside a new fee are capped at this multiple of that fee.
    uint256 public constant BACKLOG_MULTIPLE = 4;
    /// @dev Gas forwarded to the market sale; an exhausted or reverting market defers to claims.
    uint256 public constant CONVERSION_GAS = 2_000_000;
    uint8 private constant ACTION_NONE = 0;
    uint8 private constant ACTION_REDEEM_ETH = 1;
    uint8 private constant ACTION_REDEEM_PAIR = 2;

    address public immutable token;
    address public immutable factory;
    address public immutable owner;
    PoolId public launchPoolId;
    bool public initialized;

    PoolKey public conversionPool;
    bool public conversionConfigured;
    uint16 public maxPriceMoveBps;
    uint160 public maxConversionSqrtPriceX96;
    /// @dev Reference sqrt price for the relative bound: observed in an earlier block, so no
    /// same-block caller can set it. Zero until a sale has been attempted in a later block.
    uint160 public anchorSqrtPriceX96;
    uint160 public observedSqrtPriceX96;
    uint64 public observedBlock;
    uint8 private pendingAction;

    error OnlyOwner();
    error OnlyFactory();
    error InvalidPool();
    error AlreadyInitialized();
    error PoolNotInitialized();
    error InvalidConversionPool();
    error InvalidPriceLimits();
    error InvalidSwapAmount();
    error PartialFillNotSupported();
    error InvalidConversionDelta();
    error UnexpectedUnlock();
    error NothingToRedeem();

    event LaunchPoolInitialized(PoolId indexed poolId);
    event ConversionConfigured(
        PoolId indexed poolId,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint16 maxPriceMoveBps,
        uint160 maxSqrtPriceX96
    );
    event FeeCharged(PoolId indexed poolId, bool buy, uint256 grossPairAmount, uint256 pairFee);
    event FeeConverted(uint256 pairSpent, uint256 ethReceived, uint256 pairClaimsRemaining);
    event EthPaid(address indexed recipient, uint256 amount);
    event EthDeferred(uint256 amount);
    event PairPaid(address indexed recipient, uint256 amount);
    event ConversionSkipped(uint256 pairClaimsRemaining);

    /// @param manager Supplied by the launch as $poolManager; no external calls at construction.
    /// @param launchToken The freshly deployed DCAToken ($token).
    /// @param launchFactory The factory that must initialize the launch pool ($factory).
    /// @param initialOwner The launch owner ($owner), responsible for conversion configuration.
    constructor(IPoolManager manager, address launchToken, address launchFactory, address initialOwner)
        HookBase(manager)
    {
        if (launchToken == address(0) || launchFactory == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        if (launchToken == PAIRED_TOKEN) revert InvalidPool();
        token = launchToken;
        factory = launchFactory;
        owner = initialOwner;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        nonReentrant
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        address c0 = token < PAIRED_TOKEN ? token : PAIRED_TOKEN;
        address c1 = token < PAIRED_TOKEN ? PAIRED_TOKEN : token;
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert InvalidPool();
        launchPoolId = key.toId();
        initialized = true;
        emit LaunchPoolInitialized(launchPoolId);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Configure an existing native-ETH/FWA market on this manager, or replace its settings.
    /// @dev The relative bound limits the increase in FWA per ETH price per block, measured from a
    /// price observed in an earlier block. The absolute ceiling also prevents execution at an already
    /// adverse spot price. Native ETH is currency0. Configuring resets the anchor, so sales resume
    /// in the next block. Ownership cannot change the fee, recipient or launch pool. Trading never
    /// depends on this setting: unsold fees wait as FWA claims.
    function setConversionPool(PoolKey calldata key, uint16 priceMoveBps, uint160 sqrtPriceCeilingX96)
        external
        nonReentrant
        onlyOwner
    {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != PAIRED_TOKEN
                || address(key.hooks) == address(this) || key.tickSpacing <= 0
                || key.tickSpacing > TickMath.MAX_TICK_SPACING
                || (key.fee >= 1_000_000 && key.fee != 0x800000)
                || !Hooks.isValidHookAddress(key.hooks, key.fee)
                || (address(key.hooks) != address(0) && address(key.hooks).code.length == 0)
        ) revert InvalidConversionPool();
        if (
            priceMoveBps == 0 || priceMoveBps > 1000 || sqrtPriceCeilingX96 <= TickMath.MIN_SQRT_PRICE
                || sqrtPriceCeilingX96 >= TickMath.MAX_SQRT_PRICE
        ) revert InvalidPriceLimits();
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price == 0) revert InvalidConversionPool();
        conversionPool = key;
        maxPriceMoveBps = priceMoveBps;
        maxConversionSqrtPriceX96 = sqrtPriceCeilingX96;
        conversionConfigured = true;
        anchorSqrtPriceX96 = 0;
        observedSqrtPriceX96 = price;
        observedBlock = uint64(block.number);
        emit ConversionConfigured(
            key.toId(), key.fee, key.tickSpacing, address(key.hooks), priceMoveBps, sqrtPriceCeilingX96
        );
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        nonReentrant
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateSwap(key, params);
        uint256 fee = 0;
        if (_pairIsSpecified(key, params)) {
            uint256 amount = _magnitude(params.amountSpecified);
            // Buy: deduct 5% from gross input. Sell: gross up the requested net output.
            fee = params.amountSpecified < 0 ? _feeOnGross(amount) : _feeOnNet(amount);
            if (params.amountSpecified > 0 && amount + fee > MAX_DELTA) revert InvalidSwapAmount();
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt256().toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external nonReentrant onlyPoolManager returns (bytes4, int128) {
        _validateSwap(key, params);
        int128 pairDelta = Currency.unwrap(key.currency0) == PAIRED_TOKEN ? delta.amount0() : delta.amount1();
        bool buy = params.zeroForOne == (Currency.unwrap(key.currency0) == PAIRED_TOKEN);
        uint256 fee = 0;
        uint256 gross;
        bool specified = _pairIsSpecified(key, params);
        if (specified) {
            uint256 amount = _magnitude(params.amountSpecified);
            fee = buy ? _feeOnGross(amount) : _feeOnNet(amount);
            int256 expected = buy ? -(amount - fee).toInt256() : (amount + fee).toInt256();
            // afterSwap may adjust only the unspecified side. Reject a partial specified fill
            // atomically instead of charging a fee on FWA that never changed hands.
            if (int256(pairDelta) != expected) revert PartialFillNotSupported();
            gross = buy ? amount : amount + fee;
        } else {
            if (buy ? pairDelta > 0 : pairDelta < 0) revert InvalidSwapAmount();
            uint256 actual = _magnitude(int256(pairDelta));
            fee = buy ? _feeOnNet(actual) : _feeOnGross(actual);
            gross = buy ? actual + fee : actual;
            if (gross > MAX_DELTA) revert InvalidSwapAmount();
        }
        emit FeeCharged(launchPoolId, buy, gross, fee);
        _convertAndPay(fee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt256().toInt128());
    }

    /// @notice Anyone can redeem available ETH claims, always to the fixed recipient.
    /// @dev Call while the manager is locked; later swaps also automatically retry ETH payouts.
    function redeemEth() external nonReentrant {
        pendingAction = ACTION_REDEEM_ETH;
        poolManager.unlock("");
        pendingAction = ACTION_NONE;
    }

    /// @notice Owner-only exit for FWA fee claims that no market sale can convert: the claims are
    /// burned and the FWA is taken from the manager straight to the fixed recipient, never to this
    /// hook. Reverts, keeping the claims, if FWA refuses the transfer to the recipient.
    function redeemPair() external nonReentrant onlyOwner {
        pendingAction = ACTION_REDEEM_PAIR;
        poolManager.unlock("");
        pendingAction = ACTION_NONE;
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint8 action = pendingAction;
        if (action == ACTION_NONE) revert UnexpectedUnlock();
        pendingAction = ACTION_NONE;
        if (action == ACTION_REDEEM_ETH) _payEth(0);
        else _payPair();
        return "";
    }

    function _validateSwap(PoolKey calldata key, SwapParams calldata params) private view {
        if (!initialized) revert PoolNotInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(launchPoolId)) revert InvalidPool();
        if (
            params.amountSpecified == 0 || params.amountSpecified < -MAX_DELTA.toInt256()
                || params.amountSpecified > MAX_DELTA.toInt256()
        ) revert InvalidSwapAmount();
    }

    function _pairIsSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (Currency.unwrap(key.currency0) == PAIRED_TOKEN);
    }

    function _feeOnGross(uint256 gross) private pure returns (uint256) {
        return gross * FEE_BPS / BPS;
    }

    function _feeOnNet(uint256 net) private pure returns (uint256) {
        return net * FEE_BPS / (BPS - FEE_BPS);
    }

    function _magnitude(int256 amount) private pure returns (uint256) {
        return (amount < 0 ? -amount : amount).toUint256();
    }

    function _convertAndPay(uint256 fee) private {
        Currency pair = Currency.wrap(PAIRED_TOKEN);
        uint256 ethReceived = 0;
        if (fee == 0 || !conversionConfigured) {
            // A fee-free swap never moves the backlog, so dust trades cannot trigger a sale.
            // Without a market the fee simply waits as FWA claims; trading is never gated.
            if (fee != 0) poolManager.mint(address(this), pair.toId(), fee);
            emit ConversionSkipped(poolManager.balanceOf(address(this), pair.toId()));
        } else {
            // Old claims sold beside this fee are capped at a multiple of it, so moving the backlog
            // costs the trader a real fee, and each attempt stays within int128.
            uint256 oldClaims = Math.min(
                poolManager.balanceOf(address(this), pair.toId()),
                Math.min(fee * BACKLOG_MULTIPLE, MAX_DELTA - fee)
            );
            uint256 budget = fee + oldClaims;
            if (oldClaims != 0) poolManager.burn(address(this), pair.toId(), oldClaims);
            uint256 spent;
            (spent, ethReceived) = _sellPair(budget);
            // Never take FWA out of the manager; FWA can reject transfers to this hook.
            if (budget > spent) poolManager.mint(address(this), pair.toId(), budget - spent);
            emit FeeConverted(spent, ethReceived, poolManager.balanceOf(address(this), pair.toId()));
        }
        _payEth(ethReceived);
    }

    /// @dev Sells up to `budget` FWA for ETH on the configured market, bounded by the owner's limits
    /// measured from a reference price no same-block caller controls. Returns what was sold.
    function _sellPair(uint256 budget) private returns (uint256 spent, uint256 ethReceived) {
        PoolKey memory market = conversionPool;
        (uint160 price,,,) = poolManager.getSlot0(market.toId());
        uint160 base = _referencePrice(price);
        if (base == 0 || price >= maxConversionSqrtPriceX96) return (0, 0);
        // price is FWA/ETH. Selling FWA increases sqrt(price). sqrt(1 + bps/10000) is evaluated
        // with 1e9 precision and rounded down, tightening the bound. A spot price already more
        // than the bound above the reference means the market moved this block: defer.
        uint256 factor = Math.sqrt((BPS + maxPriceMoveBps) * 1e18 / BPS);
        uint160 limit = Math.min(FullMath.mulDiv(base, factor, 1e9), maxConversionSqrtPriceX96).toUint160();
        if (limit <= price) return (0, 0);
        // A reverting or gas-exhausting market only defers the sale; it never blocks trading.
        try poolManager.swap{gas: CONVERSION_GAS}(
            market, SwapParams(false, -budget.toInt256(), limit), ""
        ) returns (
            BalanceDelta converted
        ) {
            if (converted.amount0() < 0 || converted.amount1() > 0) revert InvalidConversionDelta();
            spent = _magnitude(int256(converted.amount1()));
            ethReceived = int256(converted.amount0()).toUint256();
            if (spent > budget) revert InvalidConversionDelta();
        } catch {
            return (0, 0);
        }
    }

    /// @dev The anchor is the market price observed by the last sale attempt in an earlier block.
    /// The base is the lower of anchor and spot: a lowered spot only tightens the bound.
    function _referencePrice(uint160 price) private returns (uint160) {
        if (observedBlock < block.number) anchorSqrtPriceX96 = observedSqrtPriceX96;
        observedSqrtPriceX96 = price;
        observedBlock = uint64(block.number);
        uint160 anchor = anchorSqrtPriceX96;
        return anchor < price ? anchor : price;
    }

    function _payPair() private {
        Currency pair = Currency.wrap(PAIRED_TOKEN);
        uint256 amount = Math.min(poolManager.balanceOf(address(this), pair.toId()), MAX_DELTA);
        if (amount == 0) revert NothingToRedeem();
        poolManager.burn(address(this), pair.toId(), amount);
        poolManager.take(pair, RECIPIENT, amount);
        emit PairPaid(RECIPIENT, amount);
    }

    function _payEth(uint256 newCredit) private {
        uint256 oldClaims = Math.min(poolManager.balanceOf(address(this), 0), MAX_DELTA - newCredit);
        uint256 pay = Math.min(newCredit + oldClaims, address(poolManager).balance);
        if (pay < newCredit) {
            poolManager.mint(address(this), 0, newCredit - pay);
            emit EthDeferred(newCredit - pay);
        } else if (pay > newCredit) {
            poolManager.burn(address(this), 0, pay - newCredit);
        }
        if (pay != 0) {
            // A rejected transfer rolls back take's delta. Mint a claim for the same credit so
            // a temporarily rejecting recipient cannot block trading or lose its entitlement.
            try poolManager.take(Currency.wrap(address(0)), RECIPIENT, pay) {
                emit EthPaid(RECIPIENT, pay);
            } catch {
                poolManager.mint(address(this), 0, pay);
                emit EthDeferred(pay);
            }
        }
    }
}
