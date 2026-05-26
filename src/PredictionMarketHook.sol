// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title PredictionMarketHook
/// @notice Uniswap V4 Hook that turns any pool into a prediction market
/// @dev "Hook the Future" Hackathon — X Layer × Uniswap × Flap
///
///         ┌─────────────────────────────────────────┐
///         │  CREATE: 任何人指定币对+时长+方向下注      │
///         │  BET:    其他人跟注 → 截止前10分钟锁盘     │
///         │  WAIT:   10分钟空窗期 → TWAP累加器记录      │
///         │  SETTLE: 到期 → 读TWAP → 赢家+创建者分钱   │
///         │  REFUND: 无人跟→退款 | 熔断→原路退         │
///         └─────────────────────────────────────────┘
contract PredictionMarketHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    // ============================================================
    //  CONSTANTS
    // ============================================================

    /// @notice 创建者抽水比例 (1% = 100 bps, 最大 500 bps = 5%)
    uint24 public constant CREATOR_FEE_BPS = 100;

    /// @notice 最小参与窗口: 创建后2小时内必须有人跟注
    uint256 public constant MIN_PARTICIPATION_WINDOW = 2 hours;

    /// @notice 截止前锁盘时间: 到期前10分钟关闭下注
    uint256 public constant BETTING_LOCK_WINDOW = 10 minutes;

    /// @notice TWAP 采样窗口: 到期前30分钟数据有效
    uint256 public constant TWAP_WINDOW = 30 minutes;

    /// @notice 最小赔率: 两边金额差距不超过 3:1 (denominator = 3)
    uint256 public constant MIN_ODDS_RATIO = 3;

    /// @notice 最小总下注额 (0.01 ETH)
    uint256 public constant MIN_TOTAL_BET = 0.01 ether;

    /// @notice 熔断阈值: 当前价格 < 开盘价 × 5% 时触发退款
    uint256 public constant MELTDOWN_THRESHOLD_BPS = 500; // 5%

    // ============================================================
    //  STATE
    // ============================================================

    /// @notice 每个池子的 TWAP 累加器
    struct TwapAccumulator {
        uint256 priceSum;    // ∑(price × deltaTime), price = sqrtPriceX96
        uint256 lastPrice;   // 上次记录的 sqrtPriceX96
        uint256 lastTime;    // 上次记录的时间戳
        uint256 totalTime;   // 累计时间
        bool active;         // 是否有活跃预测市场
    }

    mapping(PoolId => TwapAccumulator) public twapAccumulators;

    /// @notice 预测市场数据
    enum Direction { NONE, UP, DOWN }

    struct PredictionMarket {
        address creator;
        Currency token0;
        Currency token1;
        uint256 startTime;
        uint256 endTime;
        uint256 startPrice;       // 开盘 sqrtPriceX96
        uint256 totalUpBets;      // 总看涨下注 (native token)
        uint256 totalDownBets;    // 总看跌下注 (native token)
        bool settled;
        Direction winner;
        uint256 settlementPrice;  // 结算 sqrtPriceX96
    }

    mapping(PoolId => PredictionMarket) public markets;

    /// @notice 参与者下注记录
    mapping(PoolId => mapping(address => uint256)) public upBets;     // 看涨
    mapping(PoolId => mapping(address => uint256)) public downBets;   // 看跌

    /// @notice 参与者列表 (用于遍历退钱)
    mapping(PoolId => address[]) public participants;

    event MarketCreated(
        PoolId indexed poolId,
        address indexed creator,
        address indexed token0,
        address token1,
        uint256 endTime,
        uint256 startPrice
    );

    event BetPlaced(
        PoolId indexed poolId,
        address indexed better,
        Direction direction,
        uint256 amount
    );

    event MarketSettled(
        PoolId indexed poolId,
        Direction winner,
        uint256 settlementPrice,
        uint256 totalPool,
        uint256 creatorFee
    );

    event MarketRefunded(PoolId indexed poolId, string reason);

    // ============================================================
    //  CONSTRUCTOR
    // ============================================================

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,       // ← 每次 swap 后更新 TWAP
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============================================================
    //  TWAP ACCUMULATOR (afterSwap hook)
    // ============================================================

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        if (markets[poolId].startTime == 0 || markets[poolId].settled) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // 读取当前池子价格
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        TwapAccumulator storage acc = twapAccumulators[poolId];

        if (acc.active && acc.lastTime > 0) {
            // 累加: price × (当前时间 - 上次更新时间)
            uint256 timeDelta = block.timestamp - acc.lastTime;
            acc.priceSum += uint256(sqrtPriceX96) * timeDelta;
            acc.totalTime += timeDelta;
        }

        acc.lastPrice = uint256(sqrtPriceX96);
        acc.lastTime = block.timestamp;
        acc.active = true;

        return (BaseHook.afterSwap.selector, 0);
    }

    // ============================================================
    //  CREATE PREDICTION MARKET
    // ============================================================

    /// @notice 创建预测市场 (创建者必须先下注)
    /// @param key 池子标识
    /// @param duration 预测时长 (秒), 至少 1 小时
    /// @param direction 创建者的方向 (UP 或 DOWN)
    function createMarket(
        PoolKey calldata key,
        uint256 duration,
        Direction direction
    ) external payable {
        require(direction != Direction.NONE, "Direction required");
        require(duration >= 1 hours, "Min 1 hour");
        require(msg.value >= 0.001 ether, "Min bet 0.001 ETH");

        PoolId poolId = key.toId();

        // 确保没有活跃中的市场
        require(markets[poolId].startTime == 0 || markets[poolId].settled,
                "Market already active");

        // 读取当前价格
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        require(sqrtPriceX96 > 0, "Pool not initialized");

        // 初始化市场
        PredictionMarket storage market = markets[poolId];
        market.creator = msg.sender;
        market.token0 = key.currency0;
        market.token1 = key.currency1;
        market.startTime = block.timestamp;
        market.endTime = block.timestamp + duration + BETTING_LOCK_WINDOW;
        market.startPrice = uint256(sqrtPriceX96);

        // 创建者下注
        if (direction == Direction.UP) {
            market.totalUpBets = msg.value;
        } else {
            market.totalDownBets = msg.value;
        }
        _recordBet(poolId, msg.sender, direction, msg.value);

        // 初始化 TWAP
        TwapAccumulator storage acc = twapAccumulators[poolId];
        acc.lastPrice = uint256(sqrtPriceX96);
        acc.lastTime = block.timestamp;
        acc.active = true;

        emit MarketCreated(
            poolId, msg.sender,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            market.endTime,
            uint256(sqrtPriceX96)
        );
    }

    // ============================================================
    //  PLACE BET
    // ============================================================

    /// @notice 跟注
    /// @param poolId 池子 ID
    /// @param direction UP 或 DOWN
    function placeBet(PoolId poolId, Direction direction) external payable {
        require(direction != Direction.NONE, "Direction required");
        require(msg.value >= 0.001 ether, "Min bet 0.001 ETH");

        PredictionMarket storage market = markets[poolId];
        require(market.startTime > 0, "Market not found");
        require(!market.settled, "Already settled");

        // 截止前10分钟锁盘
        require(block.timestamp < market.endTime - BETTING_LOCK_WINDOW,
                "Betting window closed");

        // 赔率检查: 两边差距不超过 3:1
        (uint256 newTotalA, uint256 newTotalB) = direction == Direction.UP
            ? (market.totalUpBets + msg.value, market.totalDownBets)
            : (market.totalUpBets, market.totalDownBets + msg.value);

        if (newTotalA > 0 && newTotalB > 0) {
            uint256 larger = newTotalA > newTotalB ? newTotalA : newTotalB;
            uint256 smaller = newTotalA > newTotalB ? newTotalB : newTotalA;
            require(larger <= smaller * MIN_ODDS_RATIO, "Odds too skewed >3:1");
        }

        // 记录下注
        if (direction == Direction.UP) {
            market.totalUpBets += msg.value;
        } else {
            market.totalDownBets += msg.value;
        }
        _recordBet(poolId, msg.sender, direction, msg.value);

        emit BetPlaced(poolId, msg.sender, direction, msg.value);
    }

    // ============================================================
    //  SETTLE MARKET
    // ============================================================

    /// @notice 结算预测市场 (任何人都可以触发)
    function settle(PoolId poolId) external {
        PredictionMarket storage market = markets[poolId];
        require(market.startTime > 0, "Market not found");
        require(!market.settled, "Already settled");
        require(block.timestamp >= market.endTime, "Not yet ended");

        market.settled = true;
        twapAccumulators[poolId].active = false;

        uint256 totalPool = market.totalUpBets + market.totalDownBets;

        // ====== 熔断检查 ======
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 currentPrice = uint256(currentSqrtPriceX96);

        // 归一化价格比较: sqrtPrice 的平方
        if (currentPrice < (market.startPrice * MELTDOWN_THRESHOLD_BPS) / 10000) {
            // 价格暴跌 >95% → 熔断退款
            _refundAll(poolId, "Token meltdown >95%");
            emit MarketRefunded(poolId, "Meltdown");
            return;
        }

        // ====== 无人跟注 → 创建者退款 ======
        if (totalPool == market.totalUpBets || totalPool == market.totalDownBets) {
            // 只有一边下注，检查是否超过了参与窗口而无人跟
            if (block.timestamp >= market.startTime + MIN_PARTICIPATION_WINDOW) {
                _refundAll(poolId, "No participants");
                emit MarketRefunded(poolId, "No participants");
                return;
            }
            // 否则: 在 2 小时窗口内，等更多人来，暂不结算
            revert("Wait for participation window (2h)");
        }

        // ====== TWAP 判定方向 ======
        uint256 settlementPrice = _getTwap(poolId);
        market.winner = settlementPrice > market.startPrice
            ? Direction.UP
            : Direction.DOWN;
        market.settlementPrice = settlementPrice;

        // ====== 分钱 ======
        uint256 winnerPool = market.winner == Direction.UP
            ? market.totalUpBets
            : market.totalDownBets;

        // 创建者抽水 (1%)
        uint256 creatorFee = (totalPool * CREATOR_FEE_BPS) / 10000;
        uint256 payoutPool = totalPool - creatorFee;

        // 分给赢家 (按比例)
        address[] memory parts = participants[poolId];
        for (uint256 i = 0; i < parts.length; i++) {
            address better = parts[i];
            uint256 winAmount = market.winner == Direction.UP
                ? upBets[poolId][better]
                : downBets[poolId][better];

            if (winAmount > 0) {
                uint256 share = (winAmount * payoutPool) / winnerPool;
                (bool ok,) = payable(better).call{value: share}("");
                require(ok, "Transfer failed");
            }
        }

        // 创建者抽水
        if (creatorFee > 0) {
            (bool ok,) = payable(market.creator).call{value: creatorFee}("");
            require(ok, "Creator fee transfer failed");
        }

        emit MarketSettled(poolId, market.winner, settlementPrice, totalPool, creatorFee);
    }

    // ============================================================
    //  REFUND (无人跟注时创建者赎回)
    // ============================================================

    function refundIfNoParticipants(PoolId poolId) external {
        PredictionMarket storage market = markets[poolId];
        require(market.startTime > 0, "Market not found");
        require(!market.settled, "Already settled");
        require(block.timestamp >= market.startTime + MIN_PARTICIPATION_WINDOW,
                "Waiting window not expired");

        uint256 totalPool = market.totalUpBets + market.totalDownBets;
        require(totalPool == market.totalUpBets || totalPool == market.totalDownBets,
                "Has participants — use settle()");

        _refundAll(poolId, "Refund by creator");
        emit MarketRefunded(poolId, "No participants");
    }

    // ============================================================
    //  VIEW FUNCTIONS
    // ============================================================

    function getTwap(PoolId poolId) external view returns (uint256) {
        return _getTwap(poolId);
    }

    function getOdds(PoolId poolId) external view returns (
        uint256 upAmount,
        uint256 downAmount,
        uint256 upOdds,
        uint256 downOdds
    ) {
        PredictionMarket storage market = markets[poolId];
        upAmount = market.totalUpBets;
        downAmount = market.totalDownBets;

        if (upAmount + downAmount > 0) {
            upOdds = (upAmount * 100) / (upAmount + downAmount);
            downOdds = 100 - upOdds;
        }
    }

    function getParticipantBet(PoolId poolId, address better) external view
        returns (uint256 up, uint256 down)
    {
        up = upBets[poolId][better];
        down = downBets[poolId][better];
    }

    // ============================================================
    //  INTERNAL HELPERS
    // ============================================================

    function _getTwap(PoolId poolId) internal view returns (uint256) {
        TwapAccumulator storage acc = twapAccumulators[poolId];
        if (acc.totalTime == 0) {
            return acc.lastPrice;
        }
        return acc.priceSum / acc.totalTime;
    }

    function _recordBet(PoolId poolId, address better, Direction direction, uint256 amount) internal {
        if (direction == Direction.UP) {
            if (upBets[poolId][better] == 0 && downBets[poolId][better] == 0) {
                participants[poolId].push(better);
            }
            upBets[poolId][better] += amount;
        } else {
            if (upBets[poolId][better] == 0 && downBets[poolId][better] == 0) {
                participants[poolId].push(better);
            }
            downBets[poolId][better] += amount;
        }
    }

    function _refundAll(PoolId poolId, string memory /* reason */) internal {
        PredictionMarket storage market = markets[poolId];
        market.settled = true;

        address[] memory parts = participants[poolId];
        for (uint256 i = 0; i < parts.length; i++) {
            address better = parts[i];
            uint256 refund = upBets[poolId][better] + downBets[poolId][better];
            if (refund > 0) {
                upBets[poolId][better] = 0;
                downBets[poolId][better] = 0;
                (bool ok,) = payable(better).call{value: refund}("");
                require(ok, "Refund failed");
            }
        }
    }

    // ============================================================
    //  RECEIVE
    // ============================================================

    receive() external payable {}
}
