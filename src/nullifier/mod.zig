//! Nullifier Management for Privacy Pools
//!
//! Nullifiers prevent double-spending in privacy pools:
//! - Each deposit generates a unique nullifier
//! - When withdrawing, the nullifier is revealed and marked as spent
//! - The ZK proof ensures the nullifier corresponds to a valid deposit
//!
//! This module provides:
//! - Nullifier generation
//! - On-chain nullifier tracking (Bloom filter & set)
//! - Nullifier verification

const std = @import("std");
const poseidon = @import("../crypto/poseidon.zig");

/// Nullifier hash (32 bytes)
pub const NullifierHash = [32]u8;

/// Nullifier preimage (secret, kept by user)
pub const NullifierPreimage = [32]u8;

/// Full nullifier with both preimage and hash
pub const Nullifier = struct {
    /// Secret preimage (user keeps this)
    preimage: NullifierPreimage,
    /// Public hash (revealed when spending)
    hash: NullifierHash,

    /// Generate a new random nullifier
    pub fn generate() Nullifier {
        var preimage: NullifierPreimage = undefined;
        std.crypto.random.bytes(&preimage);
        return .{
            .preimage = preimage,
            .hash = poseidon.hash(&preimage),
        };
    }

    /// Create from existing preimage
    pub fn fromPreimage(preimage: NullifierPreimage) Nullifier {
        return .{
            .preimage = preimage,
            .hash = poseidon.hash(&preimage),
        };
    }

    /// Verify that hash matches preimage
    pub fn verify(self: *const Nullifier) bool {
        const expected = poseidon.hash(&self.preimage);
        return std.mem.eql(u8, &expected, &self.hash);
    }
};

/// Bloom filter for efficient nullifier lookup
/// False positives possible, false negatives not possible
pub const BloomFilter = struct {
    /// Bitmap (8KB = 65536 bits)
    bitmap: [1024]u64,
    /// Number of hash functions
    num_hashes: u8,

    const Self = @This();

    /// Initialize empty bloom filter
    pub fn init() Self {
        return .{
            .bitmap = [_]u64{0} ** 1024,
            .num_hashes = 7,
        };
    }

    /// Insert a nullifier hash
    pub fn insert(self: *Self, hash: NullifierHash) void {
        for (0..self.num_hashes) |i| {
            const idx = self.getIndex(hash, @truncate(i));
            const word_idx = idx / 64;
            const bit_idx: u6 = @truncate(idx % 64);
            self.bitmap[word_idx] |= @as(u64, 1) << bit_idx;
        }
    }

    /// Check if nullifier might be in the set
    /// Returns true if definitely not in set (can withdraw)
    /// Returns false if might be in set (need to check exact set)
    pub fn mightContain(self: *const Self, hash: NullifierHash) bool {
        for (0..self.num_hashes) |i| {
            const idx = self.getIndex(hash, @truncate(i));
            const word_idx = idx / 64;
            const bit_idx: u6 = @truncate(idx % 64);
            if ((self.bitmap[word_idx] & (@as(u64, 1) << bit_idx)) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Get bit index for a hash with given hash function index
    fn getIndex(self: *const Self, hash: NullifierHash, hash_fn_idx: u8) u16 {
        _ = self;
        // Use different parts of the hash for each function
        const offset = hash_fn_idx * 4;
        const bytes = hash[offset..][0..2];
        return std.mem.readInt(u16, bytes, .big);
    }
};

/// Exact nullifier set for on-chain storage
/// Uses sorted array for O(log n) lookup
pub const NullifierSet = struct {
    /// Sorted array of spent nullifiers
    nullifiers: std.ArrayList(NullifierHash),
    /// Allocator for memory management
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize empty set
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .nullifiers = .{},
            .allocator = allocator,
        };
    }

    /// Free memory
    pub fn deinit(self: *Self) void {
        self.nullifiers.deinit(self.allocator);
    }

    /// Check if nullifier is already spent
    pub fn isSpent(self: *const Self, hash: NullifierHash) bool {
        // Binary search
        const items = self.nullifiers.items;
        var left: usize = 0;
        var right: usize = items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = std.mem.order(u8, &items[mid], &hash);
            switch (cmp) {
                .eq => return true,
                .lt => left = mid + 1,
                .gt => right = mid,
            }
        }
        return false;
    }

    /// Mark nullifier as spent
    pub fn markSpent(self: *Self, hash: NullifierHash) !void {
        if (self.isSpent(hash)) {
            return error.NullifierAlreadySpent;
        }

        // Find insertion point (maintain sorted order)
        const items = self.nullifiers.items;
        var insert_idx: usize = items.len;
        for (items, 0..) |item, i| {
            if (std.mem.order(u8, &item, &hash) == .gt) {
                insert_idx = i;
                break;
            }
        }

        try self.nullifiers.insert(self.allocator, insert_idx, hash);
    }

    /// Get number of spent nullifiers
    pub fn count(self: *const Self) usize {
        return self.nullifiers.items.len;
    }
};

/// Compact on-chain nullifier storage (for Solana account)
/// Uses fixed-size array with bitmap
pub const CompactNullifierSet = struct {
    /// Bloom filter for quick checks
    bloom: BloomFilter,
    /// Count of spent nullifiers
    spent_count: u64,

    const Self = @This();

    /// Initialize
    pub fn init() Self {
        return .{
            .bloom = BloomFilter.init(),
            .spent_count = 0,
        };
    }

    /// Check if nullifier might be spent (bloom filter check)
    pub fn mightBeSpent(self: *const Self, hash: NullifierHash) bool {
        return self.bloom.mightContain(hash);
    }

    /// Mark nullifier as spent
    pub fn markSpent(self: *Self, hash: NullifierHash) void {
        self.bloom.insert(hash);
        self.spent_count += 1;
    }

    /// Get size in bytes for Solana account
    pub fn size() usize {
        return @sizeOf(Self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "nullifier: generate and verify" {
    const n = Nullifier.generate();

    // Hash should be derived from preimage
    try std.testing.expect(n.verify());

    // Hash should be 32 bytes
    try std.testing.expectEqual(@as(usize, 32), n.hash.len);
}

test "nullifier: from preimage" {
    const preimage: NullifierPreimage = [_]u8{1} ** 32;
    const n = Nullifier.fromPreimage(preimage);

    try std.testing.expect(n.verify());
    try std.testing.expectEqualSlices(u8, &preimage, &n.preimage);
}

test "nullifier: deterministic hash" {
    const preimage: NullifierPreimage = [_]u8{42} ** 32;
    const n1 = Nullifier.fromPreimage(preimage);
    const n2 = Nullifier.fromPreimage(preimage);

    try std.testing.expectEqualSlices(u8, &n1.hash, &n2.hash);
}

test "bloom filter: basic operations" {
    var bloom = BloomFilter.init();

    const hash1: NullifierHash = [_]u8{1} ** 32;
    const hash2: NullifierHash = [_]u8{2} ** 32;
    const hash3: NullifierHash = [_]u8{3} ** 32;

    // Initially empty
    try std.testing.expect(!bloom.mightContain(hash1));
    try std.testing.expect(!bloom.mightContain(hash2));

    // Insert hash1
    bloom.insert(hash1);
    try std.testing.expect(bloom.mightContain(hash1));
    try std.testing.expect(!bloom.mightContain(hash3));

    // Insert hash2
    bloom.insert(hash2);
    try std.testing.expect(bloom.mightContain(hash1));
    try std.testing.expect(bloom.mightContain(hash2));
}

test "nullifier set: mark and check" {
    const allocator = std.testing.allocator;
    var set = NullifierSet.init(allocator);
    defer set.deinit();

    const hash1: NullifierHash = [_]u8{1} ** 32;
    const hash2: NullifierHash = [_]u8{2} ** 32;

    // Initially not spent
    try std.testing.expect(!set.isSpent(hash1));
    try std.testing.expect(!set.isSpent(hash2));

    // Mark hash1 as spent
    try set.markSpent(hash1);
    try std.testing.expect(set.isSpent(hash1));
    try std.testing.expect(!set.isSpent(hash2));

    // Cannot double-spend
    try std.testing.expectError(error.NullifierAlreadySpent, set.markSpent(hash1));

    // Can spend hash2
    try set.markSpent(hash2);
    try std.testing.expect(set.isSpent(hash2));
}

test "compact nullifier set: basic" {
    var set = CompactNullifierSet.init();

    const hash1: NullifierHash = [_]u8{1} ** 32;
    const hash2: NullifierHash = [_]u8{2} ** 32;

    try std.testing.expect(!set.mightBeSpent(hash1));

    set.markSpent(hash1);
    try std.testing.expect(set.mightBeSpent(hash1));
    try std.testing.expectEqual(@as(u64, 1), set.spent_count);

    set.markSpent(hash2);
    try std.testing.expectEqual(@as(u64, 2), set.spent_count);
}

test "compact nullifier set: size" {
    // Should be reasonable size for Solana account
    const size = CompactNullifierSet.size();
    try std.testing.expect(size < 10 * 1024); // Less than 10KB
}
