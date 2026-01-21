# Solana zkLogin + Passkey 混合钱包方案（摘要）

> 目标：将 Sui zkLogin + Passkey 方案移植到 Solana，使用多签/阈值策略实现“主登录 + 备用恢复”，彻底取消助记词。

## 核心价值

- **主登录（zkLogin）**：OAuth（Google/Facebook），跨设备恢复
- **备用恢复（Passkey/WebAuthn）**：设备绑定 + 生物识别
- **阈值签名**：1-of-N 或 M-of-N（单一方式登录或双重验证）
- **隐私**：ZK Proof 隐藏 OAuth 身份与链上地址关联
- **Sui 验证**：Sui 主网已验证 zkLogin + Passkey 组合

## 关键流程

### 1) 创建账户（zkLogin）
1. 生成临时密钥对 + nonce（绑定 max_epoch）
2. OAuth 登录获取 JWT（含 iss/aud/sub/nonce）
3. 获取用户 salt（中心化或派生）
4. 生成 Groth16 证明（证明 JWT 有效且 nonce 绑定临时公钥）
5. 链上创建 Identity：写入 address_seed、创建 vault PDA

### 2) 添加 Passkey 备用
1. WebAuthn 创建 credential（secp256r1）
2. 用 zkLogin 或已有 passkey 授权
3. 链上存储 PasskeyInfo（公钥 + credential id）

### 3) 签名交易
- zkLogin：临时私钥签名 + 附 ZK proof
- Passkey：浏览器 WebAuthn 签名 + 链上 secp256r1 验证

## 链上验证模块

- **Groth16/BN254**：复用 Sui zkLogin 电路（alt_bn128 syscall）
- **secp256r1**：使用 Solana SIMD-0075 原生验签

## 代码结构建议

```
solana-zklogin/
├── programs/zklogin-wallet/
│   ├── instructions/ (create_identity / add_passkey / execute_*)
│   ├── verifier/ (groth16 + secp256r1)
│   └── state.zig
├── circuits/ (zkLogin.circom)
├── artifacts/ (wasm/zkey/verifying_key)
├── services/ (prover + salt)
└── app/ (Next.js 前端)
```

## 复用资源

- zkLogin 电路与 ceremony：Sui 官方 / kzero-circuit
- Prover：`mysten/zklogin` 镜像
- Passkey：WebAuthn + secp256r1

## 风险与注意点

- **Salt 管理**：中心化 salt 会引入关联风险
- **JWT 有效期**：需绑定 slot/epoch 限制
- **多签策略**：支持 1-of-2、2-of-2 等模式

## Roadmap（建议）

1. 验证电路兼容（Groth16 + BN254）
2. 接入 secp256r1 验证
3. 接入 OAuth + Salt 服务
4. 完成 HybridIdentity 账户与阈值签名

---

参考来源：Sui zkLogin 文档与电路、WebAuthn 规范、Solana secp256r1 SIMD 提案。
