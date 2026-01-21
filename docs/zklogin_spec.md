# Solana zkLogin + Passkey 混合钱包技术方案

## 项目概述

将 Sui 的 zkLogin + Passkey 方案完整移植到 Solana，利用 Sui 原生的 Multisig 机制实现 zkLogin 与 Passkey 的灵活组合。

### Sui 已验证的方案

**Sui 从 2025年8月起已在主网支持 zkLogin + Passkey 组合：**

```typescript
// Sui 官方示例：zkLogin + Passkey 组成 Multisig
const multiSigPublicKey = MultiSigPublicKey.fromPublicKeys({
  threshold: 1,  // 1-of-2: 任一方式可签名
  publicKeys: [
    { publicKey: zkLoginPublicIdentifier, weight: 1 },  // zkLogin (Google)
    { publicKey: passkeyPublicKey, weight: 1 },         // Passkey (Face ID)
  ],
});

// 或者 2-of-2: 双重验证
const secureMultiSig = MultiSigPublicKey.fromPublicKeys({
  threshold: 2,
  publicKeys: [
    { publicKey: zkLoginPublicIdentifier, weight: 1 },
    { publicKey: passkeyPublicKey, weight: 1 },
  ],
});
```

### 核心价值主张

| 特性 | 说明 |
|------|------|
| **主登录** | Google/Facebook OAuth (zkLogin) - 跨设备、易恢复 |
| **备用恢复** | Passkey/WebAuthn (secp256r1) - 设备绑定、生物识别 |
| **灵活组合** | Multisig 支持 1-of-N 或 M-of-N 任意配置 |
| **隐私保护** | ZK Proof 隐藏 OAuth 身份与链上地址的关联 |
| **无助记词** | 完全消除 seed phrase |
| **Sui 验证** | 已在 Sui 主网运行，经过审计 |

---

## 架构设计

### 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户层                                          │
│  ┌──────────────────────────────┐    ┌──────────────────────────────┐       │
│  │      主登录 (zkLogin)         │    │    备用恢复 (Passkey)         │       │
│  │  Google / Facebook OAuth     │    │   Face ID / Touch ID         │       │
│  └──────────────┬───────────────┘    └──────────────┬───────────────┘       │
└─────────────────┼───────────────────────────────────┼───────────────────────┘
                  │                                   │
┌─────────────────┼───────────────────────────────────┼───────────────────────┐
│                 ▼                                   ▼                       │
│  ┌──────────────────────────────┐    ┌──────────────────────────────┐       │
│  │      ZK Prover Service       │    │     WebAuthn Browser API      │       │
│  │   (复用 Sui zkLogin 电路)     │    │    (secp256r1 Secure Enclave) │       │
│  └──────────────┬───────────────┘    └──────────────┬───────────────┘       │
│                 │                                   │                       │
│                 ▼                                   ▼                       │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │                    Solana 链上验证程序                            │       │
│  │  ┌─────────────────────┐    ┌─────────────────────┐              │       │
│  │  │ Groth16 Verifier    │    │ secp256r1 Precompile │              │       │
│  │  │ (alt_bn128 syscall) │    │ (SIMD-0075)          │              │       │
│  │  └─────────────────────┘    └─────────────────────┘              │       │
│  │                        │                                         │       │
│  │                        ▼                                         │       │
│  │  ┌──────────────────────────────────────────────────────┐       │       │
│  │  │           Identity Account (PDA)                      │       │       │
│  │  │  - zk_address_seed: [u8; 32]  // from zkLogin        │       │       │
│  │  │  - passkeys: Vec<PasskeyInfo> // backup recovery     │       │       │
│  │  │  - threshold: u8              // multi-sig support   │       │       │
│  │  └──────────────────────────────────────────────────────┘       │       │
│  └──────────────────────────────────────────────────────────────────┘       │
│                              服务层                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 账户结构

```rust
#[account]
pub struct HybridIdentity {
    // zkLogin 相关
    pub zk_address_seed: [u8; 32],     // H(iss || aud || sub || salt)
    pub iss_hash: [u8; 32],            // OAuth Provider 标识
    
    // Passkey 备用恢复
    pub passkeys: Vec<PasskeyInfo>,    // 最多 5 个设备
    pub passkey_count: u8,
    
    // 账户配置
    pub threshold: u8,                  // 签名阈值 (1 = 单签, 2+ = 多签)
    pub nonce: u64,                     // 防重放
    
    // Vault
    pub vault: Pubkey,                  // 资金存储 PDA
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct PasskeyInfo {
    pub pubkey: [u8; 33],              // 压缩 secp256r1 公钥
    pub credential_id: [u8; 64],       // WebAuthn credential ID
    pub device_name: String,           // "iPhone 15 Pro"
    pub added_at: i64,                 // 添加时间
}
```

---

## 核心流程

### 1. 创建账户 (zkLogin)

```
用户选择 "用 Google 登录"
    │
    ▼
┌─────────────────────────────────────┐
│ 1. 生成临时密钥对 (ephemeral keypair) │
│    ed25519 或 secp256k1              │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 2. 构造 nonce                        │
│    nonce = H(eph_pubkey || max_epoch │
│            || randomness)            │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 3. OAuth 登录                        │
│    重定向到 Google，nonce 嵌入请求   │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 4. 获取 JWT                          │
│    包含 iss, aud, sub, nonce         │
│    由 Google RSA 私钥签名            │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 5. 获取 Salt                         │
│    从 Salt 服务获取用户专属 salt     │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 6. 生成 ZK Proof                     │
│    证明：                            │
│    - JWT 签名有效                    │
│    - nonce 正确嵌入临时公钥          │
│    - address_seed 正确派生           │
│    隐藏：JWT 内容、salt              │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 7. 链上创建 Identity                 │
│    - 验证 ZK Proof                   │
│    - 存储 address_seed               │
│    - 创建 Vault PDA                  │
└─────────────────────────────────────┘
```

### 2. 添加 Passkey 备用

```
用户点击 "添加备用设备"
    │
    ▼
┌─────────────────────────────────────┐
│ 1. WebAuthn navigator.credentials    │
│    .create() 生成新的 Passkey        │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 2. 用 zkLogin 签名授权交易           │
│    （或现有 Passkey）                │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ 3. 链上添加 PasskeyInfo              │
│    - 验证授权签名                    │
│    - 存储新 secp256r1 公钥           │
└─────────────────────────────────────┘
```

### 3. 签名交易

```
          zkLogin 路径                    Passkey 路径
               │                               │
               ▼                               ▼
    ┌───────────────────┐           ┌───────────────────┐
    │ 1. 检查 JWT 有效期 │           │ 1. 触发生物识别    │
    │    (max_epoch)    │           │    Face ID等      │
    └─────────┬─────────┘           └─────────┬─────────┘
              │                               │
              ▼                               ▼
    ┌───────────────────┐           ┌───────────────────┐
    │ 2. 用临时私钥签名  │           │ 2. Secure Enclave │
    │    交易消息       │           │    签名交易       │
    └─────────┬─────────┘           └─────────┬─────────┘
              │                               │
              ▼                               ▼
    ┌───────────────────┐           ┌───────────────────┐
    │ 3. 附加 ZK Proof   │           │ 3. 附加 WebAuthn  │
    │    + JWT 部分信息  │           │    验证数据       │
    └─────────┬─────────┘           └─────────┬─────────┘
              │                               │
              └───────────┬───────────────────┘
                          ▼
              ┌───────────────────────┐
              │ 4. 链上验证           │
              │    Groth16 或 secp256r1│
              └───────────────────────┘
```

---

## 技术实现

### 复用 Sui zkLogin 电路

**关键资源：**

| 资源 | 链接 |
|------|------|
| zkLogin 电路参考 | https://github.com/kzero-xyz/kzero-circuit |
| Sui 官方 Ceremony | https://github.com/sui-foundation/zklogin-ceremony-contributions |
| Prover Docker 镜像 | `mysten/zklogin:prover-*` |
| 审计报告 | https://github.com/sui-foundation/security-audits/blob/main/zksecurity_zklogin-circuits.pdf |

**电路复用策略：**

Sui 的 zkLogin 电路使用 Groth16 + BN254 曲线，与 Solana 的 `alt_bn128` syscall 完全兼容。

```
Sui zkLogin 电路
    │
    ├── circuits/zkLogin.circom      ← 直接复用
    ├── zkLogin.r1cs                 ← 编译产物
    ├── zkLogin.wasm                 ← 浏览器证明
    └── zkLogin.zkey                 ← Trusted Setup
           │
           ▼
    复用 Sui Ceremony 的 zkey（或自己做 ceremony）
           │
           ▼
    导出 verification_key.json
           │
           ▼
    嵌入 Solana 程序验证
```

### Solana 程序实现

基于你的 `privacy-zig` 项目结构：

```
solana-zklogin/
├── programs/
│   └── zklogin-wallet/
│       └── src/
│           ├── lib.zig              # 主程序入口
│           ├── instructions/
│           │   ├── create_identity.zig   # 创建账户
│           │   ├── add_passkey.zig       # 添加备用
│           │   ├── execute_zklogin.zig   # zkLogin 交易
│           │   └── execute_passkey.zig   # Passkey 交易
│           ├── state.zig            # 账户结构
│           └── verifier/
│               ├── groth16.zig      # ZK 验证 (复用你现有的)
│               └── secp256r1.zig    # Passkey 验证
│
├── circuits/                        # 从 kzero-circuit fork
│   ├── zkLogin.circom
│   └── ...
│
├── artifacts/
│   ├── zkLogin.wasm
│   ├── zkLogin.zkey
│   └── verification_key.json
│
├── services/
│   ├── prover/                      # ZK 证明服务
│   │   └── Dockerfile               # 复用 Sui 的镜像或自建
│   └── salt/                        # Salt 管理服务
│
└── app/                             # Next.js 前端
    └── src/
        ├── lib/
        │   ├── zklogin.ts           # zkLogin 流程
        │   ├── passkey.ts           # Passkey 流程
        │   └── hybrid-wallet.ts     # 统一接口
        └── ...
```

### 关键代码实现

#### 1. Groth16 验证 (复用 privacy-zig)

```zig
// verifier/groth16.zig
const alt_bn128 = @import("solana-zig").alt_bn128;

pub fn verify_zklogin_proof(
    proof: *const Groth16Proof,
    public_inputs: []const [32]u8,
    vk: *const VerificationKey,
) bool {
    // 构造 pairing inputs
    // 调用 alt_bn128.pairing()
    // 验证 e(A, B) = e(alpha, beta) * e(L, gamma) * e(C, delta)
    return alt_bn128.pairing(pairing_input);
}
```

#### 2. secp256r1 验证 (Passkey)

```zig
// verifier/secp256r1.zig
const secp256r1_program = @import("solana-zig").secp256r1;

pub fn verify_passkey_signature(
    message: []const u8,
    signature: *const Secp256r1Signature,
    pubkey: *const [33]u8,
) bool {
    // 使用 SIMD-0075 precompile
    return secp256r1_program.verify(message, signature, pubkey);
}
```

#### 3. 前端 zkLogin 流程

```typescript
// app/src/lib/zklogin.ts
import { generateNonce, generateRandomness } from '@mysten/zklogin';

export async function createZkLoginAccount() {
    // 1. 生成临时密钥对
    const ephemeralKeyPair = Keypair.generate();
    
    // 2. 获取当前 epoch (Solana slot 转换)
    const currentSlot = await connection.getSlot();
    const maxEpoch = Math.floor(currentSlot / SLOTS_PER_EPOCH) + 2;
    
    // 3. 生成 nonce
    const randomness = generateRandomness();
    const nonce = generateNonce(
        ephemeralKeyPair.publicKey,
        maxEpoch,
        randomness
    );
    
    // 4. 重定向到 Google OAuth
    const params = new URLSearchParams({
        client_id: GOOGLE_CLIENT_ID,
        redirect_uri: REDIRECT_URI,
        response_type: 'id_token',
        scope: 'openid',
        nonce: nonce,
    });
    window.location.href = `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
}

export async function completeZkLogin(jwt: string) {
    // 5. 获取 salt
    const salt = await getSalt(jwt);
    
    // 6. 生成 ZK proof
    const proof = await generateZkProof(jwt, ephemeralKeyPair, salt);
    
    // 7. 计算 address seed
    const addressSeed = computeAddressSeed(jwt, salt);
    
    // 8. 创建链上 Identity
    const tx = await createIdentityTx(proof, addressSeed, ephemeralKeyPair);
    await sendTransaction(tx);
}
```

#### 4. 前端 Passkey 流程

```typescript
// app/src/lib/passkey.ts

export async function addPasskeyBackup(identity: PublicKey) {
    // 1. 创建 WebAuthn credential
    const credential = await navigator.credentials.create({
        publicKey: {
            challenge: new Uint8Array(32), // 从链上获取
            rp: { name: "Solana zkLogin Wallet" },
            user: {
                id: identity.toBytes(),
                name: "user@example.com",
                displayName: "User"
            },
            pubKeyCredParams: [
                { type: "public-key", alg: -7 } // ES256 (P-256)
            ],
            authenticatorSelection: {
                authenticatorAttachment: "platform",
                userVerification: "required"
            }
        }
    });
    
    // 2. 提取公钥
    const publicKey = extractPublicKey(credential);
    
    // 3. 发送添加 Passkey 交易
    const tx = await addPasskeyTx(identity, publicKey, credential.id);
    await sendTransaction(tx);
}

export async function signWithPasskey(
    identity: PublicKey,
    message: Uint8Array
) {
    // 1. 获取 WebAuthn assertion
    const assertion = await navigator.credentials.get({
        publicKey: {
            challenge: message,
            rpId: window.location.hostname,
            userVerification: "required"
        }
    });
    
    // 2. 提取签名
    const signature = extractSignature(assertion);
    const authenticatorData = assertion.response.authenticatorData;
    const clientDataJSON = assertion.response.clientDataJSON;
    
    return { signature, authenticatorData, clientDataJSON };
}
```

---

## 服务组件

### 1. ZK Prover 服务

**选项 A：复用 Sui 官方镜像**

```yaml
# docker-compose.yml
version: '3'
services:
  zklogin-prover:
    image: mysten/zklogin:prover-a66971815c15ba10c699203c5e3826a18eabc4ee
    ports:
      - "8080:8080"
    environment:
      - RUST_LOG=info
```

**选项 B：自建 Prover (基于 snarkjs)**

```typescript
// services/prover/index.ts
import * as snarkjs from 'snarkjs';

export async function generateProof(input: ZkLoginInput) {
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        'circuits/zkLogin.wasm',
        'circuits/zkLogin.zkey'
    );
    return { proof, publicSignals };
}
```

### 2. Salt 服务

```typescript
// services/salt/index.ts
import { createHmac } from 'crypto';

const MASTER_SEED = process.env.SALT_MASTER_SEED;

export function getSalt(jwt: string): string {
    const payload = decodeJwt(jwt);
    const { iss, aud, sub } = payload;
    
    // 确定性派生 salt
    const input = `${iss}|${aud}|${sub}`;
    const hmac = createHmac('sha256', MASTER_SEED);
    hmac.update(input);
    
    return hmac.digest('hex');
}
```

**Salt 安全考虑：**

| 选项 | 优点 | 缺点 |
|------|------|------|
| 中心化 Salt 服务 | 用户无需记忆 | 服务商可关联身份 |
| 用户自管理 Salt | 完全隐私 | 丢失 = 丢失账户 |
| 从密码派生 Salt | 折中方案 | 需要记忆密码 |

---

## 安全模型

### 威胁分析

| 威胁 | zkLogin 防护 | Passkey 防护 |
|------|-------------|--------------|
| OAuth 账户被盗 | 需要 salt + ZK proof | Passkey 独立于 OAuth |
| Salt 泄露 | 仅能关联身份，无法盗取资金 | 不影响 Passkey |
| 临时密钥泄露 | 有过期时间 (max_epoch) | N/A |
| 设备丢失 | 可用其他 OAuth 设备恢复 | 需要其他已注册 Passkey |
| 量子攻击 | 需升级电路 | secp256r1 同样受影响 |

### 多重签名支持

```
threshold = 1 (默认)
    └── 任一方式可签名

threshold = 2 (高安全)
    └── 需要 zkLogin + Passkey 双重验证
    └── 或 2 个不同 Passkey

threshold = 3 (机构级)
    └── zkLogin + 2 Passkey
    └── 或 3 Passkey
```

---

## 开发路线图

### Phase 1: 核心验证 (2-3 周)

- [ ] Fork kzero-circuit，适配 Solana
- [ ] 在 privacy-zig 中实现 zkLogin Groth16 验证
- [ ] 测试 verification_key 与链上验证兼容性

### Phase 2: Passkey 集成 (1-2 周)

- [ ] 从 Keyless 项目移植 secp256r1 验证
- [ ] 实现 HybridIdentity 账户结构
- [ ] 前端 WebAuthn 集成

### Phase 3: OAuth 流程 (2 周)

- [ ] Google OAuth 集成
- [ ] Salt 服务部署
- [ ] ZK Prover 服务部署

### Phase 4: 完整钱包 (2-3 周)

- [ ] 统一钱包 UI
- [ ] 多签支持
- [ ] 测试网部署

### Phase 5: 生产就绪 (持续)

- [ ] 安全审计
- [ ] Trusted Setup Ceremony（或复用 Sui 的）
- [ ] 主网部署

---

## 资源汇总

### Sui 官方资源（直接复用）

| 资源 | 链接 | 用途 |
|------|------|------|
| **zkLogin 电路** | https://github.com/sui-foundation/zklogin-ceremony-contributions | Circom 电路 + Trusted Setup |
| **zkLogin SDK** | `@mysten/sui/zklogin` | 可参考实现逻辑 |
| **Passkey SDK** | `@mysten/sui/keypairs/passkey` | WebAuthn 集成参考 |
| **Multisig SDK** | `@mysten/sui/multisig` | 组合签名参考 |
| **zkLogin Prover** | `mysten/zklogin:prover-*` | Docker 镜像直接复用 |
| **zkLogin 审计** | https://github.com/sui-foundation/security-audits | 安全审计报告 |

### 第三方参考

| 项目 | 链接 | 用途 |
|------|------|------|
| kzero-circuit | https://github.com/kzero-xyz/kzero-circuit | zkLogin 电路独立实现 |
| polymedia-zklogin-demo | https://github.com/juzybits/polymedia-zklogin-demo | 完整 E2E 示例 |
| Keyless (Solana) | https://github.com/Tgcohce/solana-university-hackathon | Passkey 实现参考 |
| privacy-zig | https://github.com/DaviRain-Su/privacy-zig | Groth16 验证基础 |

### 代码仓库

| 项目 | 用途 |
|------|------|
| https://github.com/kzero-xyz/kzero-circuit | zkLogin 电路参考 |
| https://github.com/sui-foundation/zklogin-ceremony-contributions | Trusted Setup |
| https://github.com/juzybits/polymedia-zklogin-demo | Sui zkLogin 完整示例 |
| https://github.com/Tgcohce/solana-university-hackathon | Passkey 实现参考 |
| https://github.com/DaviRain-Su/privacy-zig | Groth16 验证基础 |

### 文档

| 文档 | 链接 |
|------|------|
| Sui zkLogin 官方文档 | https://docs.sui.io/concepts/cryptography/zklogin |
| zkLogin 学术论文 | https://arxiv.org/pdf/2401.11735 |
| Solana secp256r1 SIMD | https://github.com/solana-foundation/solana-improvement-documents/blob/main/proposals/0048-native-program-for-secp256r1-sigverify.md |
| WebAuthn 规范 | https://www.w3.org/TR/webauthn-2/ |

### Docker 镜像

```bash
# Sui zkLogin Prover
docker pull mysten/zklogin:prover-a66971815c15ba10c699203c5e3826a18eabc4ee
docker pull mysten/zklogin:prover-fe-a66971815c15ba10c699203c5e3826a18eabc4ee
```

---

## 结论

这个混合方案结合了：

1. **zkLogin 的便利性**：用熟悉的 Google 账户登录，跨设备恢复
2. **Passkey 的安全性**：设备级生物识别，硬件保护
3. **ZK 的隐私性**：链上不暴露 OAuth 身份
4. **Solana 的性能**：快速、低成本交易

通过复用 Sui 的 zkLogin 电路和 Trusted Setup，可以大大减少开发工作量，同时保持与经过审计的密码学实现的兼容性。
