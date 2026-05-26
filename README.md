# PredictionMarketHook

一个 Uniswap V4 Hook，让任何池子都能开预测市场。不需要预言机、不需要平台，到时间自动结算。

这是给 X Layer "Hook the Future" 黑客松做的。合约已经部署在 X Layer 测试网上了。

---

## 它能干嘛

Polymarket 那种预测市场大家都用过，但有个问题：它得靠 Chainlink 这种外部预言机来判输赢。而且还得到 Polymarket 的平台上去开，不是你想开就能开。

这个 Hook 的思路很简单——Uniswap 池子本身就有价格，为什么还要找外部预言机呢？

挂上这个 Hook 之后，任何人都可以在任意一个 V4 池子上开一局预测。赌 UP 还是 DOWN，到时间了 Hook 自己去看池子的 TWAP，自动把钱分给赢家。

相当于把 Polymarket 的核心功能直接塞进了 Uniswap。不用部署新合约，不用桥接资产，不用相信第三方——池子自己的价格就是裁判。

---

## 简单讲下流程

创建市场的人选好池子和时长，自己先押一边。其他人看到之后可以跟注。到期前十分钟锁盘，防止有人在最后一秒砸盘作弊。时间到了谁都能来点结算，Hook 算出 TWAP 之后自动分钱。

如果两边下注差太多（超过 3:1），就不让继续押了，保护少数那一方。如果币价跌了超过 95%，触发熔断，所有人原路退钱。要是两小时了都没人来跟注，创建者可以一键赎回。

---

## 合约

部署在 X Layer 测试网上：

`0x0e855f486081E8e7f575dc2EB6Ea9b83A42ef49E`

X Layer Testnet · Chain 195

---

## 测试结果

```
创建市场 → 0.01 ETH 押涨 ✅
跟注     → 0.005 ETH 押跌 ✅  
赔率     → 66% / 34% ✅
TWAP    → 正常读取 ✅
```

---

## 文件

- `src/PredictionMarketHook.sol` — 合约代码
- `script/Deploy.s.sol` — Foundry 部署脚本  
- `test/PredictionMarketHook.t.sol` — 测试
- `foundry.toml` — 构建配置
