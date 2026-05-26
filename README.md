# 🎯 PredictionMarketHook

> Uniswap V4 Hook: 一个池子 = DEX + 预测市场 + 自动结算

**"Hook the Future" Hackathon** — X Layer × Uniswap × Flap

---

## 解决的问题

| 传统预测市场 | PredictionMarketHook |
|-------------|---------------------|
| 依赖外部预言机 (Chainlink) | **池子自己的 TWAP 当裁判** |
| 需要独立的平台和合约 | **长在 Uniswap 池子上** |
| 开预测需要平台审批 | **任何人都能开** |
| 结算要等人工投票 | **全自动，到时间就结算** |

---

## 怎么玩

```
创建者: 选择 Token 对 + 预测时长 → 下注 UP/DOWN → 创建市场
参与者: 看到市场 → 跟注 UP 或 DOWN → 赔率实时可见
结算: 到时 → Hook 读 TWAP → 判定涨跌 → 赢家+创建者分钱
异常: 币归零 → 熔断退款 | 无人跟 → 创建者赎回
```

---

## 风控机制

| 攻击向量 | 防御 |
|---------|------|
| 结算点价格操纵 | TWAP 30分钟累加器 |
| 闪电贷砸盘 | TWAP 天然免疫 + 截止前10分钟锁盘 |
| 两边严重失衡 | 赔率线 3:1 封顶 |
| 创建者 rug | 所有权部署后废弃，只结算时转账 |
| Token 归零 | 当前价 < 开盘价 × 5% → 熔断退款 |
| 无人参与 | 2小时窗口后创建者一键赎回 |

---

## 部署

```bash
# 安装依赖
forge install

# 部署到 X Layer 主网
forge script script/Deploy.s.sol --rpc-url xlayer --broadcast --private-key $PRIVATE_KEY

# 验证合约
forge verify-contract --chain-id 196 --etherscan-api-key $OKX_EXPLORER_API_KEY \
    <DEPLOYED_ADDRESS> src/PredictionMarketHook.sol:PredictionMarketHook \
    --constructor-args $(cast abi-encode "constructor(address)" $POOL_MANAGER)
```

---

## 测试

```bash
forge test -vvv
```

---

## 技术架构

```
┌──────────────────────────────────────────────────────┐
│                    Uniswap V4 Pool                     │
│  ┌──────────────┐    ┌────────────────────────────┐  │
│  │ AMM (swap)   │    │ PredictionMarketHook       │  │
│  │              │    │                            │  │
│  │ token0⇄token1│    │ afterSwap → 更新TWAP       │  │
│  │              │    │ createMarket() → 开预测    │  │
│  │  每次swap    │    │ placeBet() → 下注          │  │
│  │  触发Hook    │    │ settle() → 读TWAP结算      │  │
│  └──────────────┘    └────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

---

## 提交清单

- [ ] 合约部署到 X Layer 主网/测试网
- [ ] 可验证的合约地址
- [ ] Twitter 发布 @XLayerOfficial @Uniswap @flapdotsh
- [ ] Google Form 提交 (截止 5/28 23:59 UTC)
- [ ] Demo 视频 (1-3 分钟)

---

## License

MIT
