//! Merkle Tree implementation for privacy proofs
//!
//! Uses Poseidon hash for ZK-friendliness.
//! Supports membership proofs for privacy pools.

const std = @import("std");
const poseidon = @import("poseidon.zig");

/// Hash type (32 bytes)
pub const Hash = [32]u8;

/// Zero hash (empty leaf)
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

/// Merkle proof for membership verification
pub const MerkleProof = struct {
    /// Sibling hashes from leaf to root
    path: []const Hash,
    /// Path indices (0 = left, 1 = right)
    indices: []const u1,
    /// Leaf index in the tree
    leaf_index: u64,

    /// Verify the proof against a root and leaf
    pub fn verify(self: *const MerkleProof, root: Hash, leaf: Hash) bool {
        if (self.path.len != self.indices.len) {
            return false;
        }

        var current = leaf;
        for (self.path, self.indices) |sibling, index| {
            current = if (index == 0)
                poseidon.hash2(current, sibling)
            else
                poseidon.hash2(sibling, current);
        }

        return std.mem.eql(u8, &current, &root);
    }
};

/// Fixed-depth Merkle Tree
pub fn MerkleTree(comptime depth: u8) type {
    const capacity: u64 = @as(u64, 1) << depth;

    return struct {
        /// All nodes in the tree (level 0 = leaves)
        nodes: [depth + 1][]Hash,
        /// Number of leaves inserted
        leaf_count: u64,
        /// Current root hash
        root: Hash,
        /// Allocator for dynamic arrays
        allocator: std.mem.Allocator,
        /// Pre-computed zero hashes for each level
        zero_hashes: [depth + 1]Hash,

        const Self = @This();

        /// Initialize empty tree
        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{
                .nodes = undefined,
                .leaf_count = 0,
                .root = undefined,
                .allocator = allocator,
                .zero_hashes = computeZeroHashes(),
            };

            // Allocate space for each level
            var level_size: usize = capacity;
            for (0..depth + 1) |level| {
                self.nodes[level] = try allocator.alloc(Hash, level_size);
                // Initialize with zero hashes
                for (self.nodes[level]) |*node| {
                    node.* = self.zero_hashes[level];
                }
                level_size = (level_size + 1) / 2;
            }

            self.root = self.zero_hashes[depth];
            return self;
        }

        /// Free allocated memory
        pub fn deinit(self: *Self) void {
            for (0..depth + 1) |level| {
                self.allocator.free(self.nodes[level]);
            }
        }

        /// Insert a new leaf and update the tree
        pub fn insert(self: *Self, leaf: Hash) !u64 {
            if (self.leaf_count >= capacity) {
                return error.TreeFull;
            }

            const index = self.leaf_count;
            self.leaf_count += 1;

            // Set leaf
            self.nodes[0][index] = leaf;

            // Update path to root
            var current_index = index;
            for (1..depth + 1) |level| {
                const parent_index = current_index / 2;
                const left_child = current_index & ~@as(u64, 1);
                const right_child = left_child + 1;

                const left_hash = if (left_child < self.nodes[level - 1].len)
                    self.nodes[level - 1][left_child]
                else
                    self.zero_hashes[level - 1];

                const right_hash = if (right_child < self.nodes[level - 1].len)
                    self.nodes[level - 1][right_child]
                else
                    self.zero_hashes[level - 1];

                self.nodes[level][parent_index] = poseidon.hash2(left_hash, right_hash);
                current_index = parent_index;
            }

            self.root = self.nodes[depth][0];
            return index;
        }

        /// Get the current root
        pub fn getRoot(self: *const Self) Hash {
            return self.root;
        }

        /// Generate membership proof for a leaf
        pub fn getProof(self: *const Self, allocator: std.mem.Allocator, leaf_index: u64) !MerkleProof {
            if (leaf_index >= self.leaf_count) {
                return error.IndexOutOfBounds;
            }

            var path = try allocator.alloc(Hash, depth);
            var indices = try allocator.alloc(u1, depth);

            var current_index = leaf_index;
            for (0..depth) |level| {
                const sibling_index = current_index ^ 1;
                indices[level] = @truncate(current_index & 1);

                path[level] = if (sibling_index < self.nodes[level].len)
                    self.nodes[level][sibling_index]
                else
                    self.zero_hashes[level];

                current_index /= 2;
            }

            return MerkleProof{
                .path = path,
                .indices = indices,
                .leaf_index = leaf_index,
            };
        }

        /// Free proof memory
        pub fn freeProof(self: *const Self, allocator: std.mem.Allocator, proof: *MerkleProof) void {
            _ = self;
            allocator.free(proof.path);
            allocator.free(proof.indices);
        }

        /// Compute zero hashes for each level
        fn computeZeroHashes() [depth + 1]Hash {
            var zeros: [depth + 1]Hash = undefined;
            zeros[0] = ZERO_HASH;
            for (1..depth + 1) |level| {
                zeros[level] = poseidon.hash2(zeros[level - 1], zeros[level - 1]);
            }
            return zeros;
        }

        /// Get tree depth
        pub fn getDepth() u8 {
            return depth;
        }

        /// Get tree capacity
        pub fn getCapacity() u64 {
            return capacity;
        }
    };
}

// ============================================================================
// Common tree types
// ============================================================================

/// Standard 20-level tree (1M leaves)
pub const Tree20 = MerkleTree(20);

/// Smaller 10-level tree (1K leaves) for testing
pub const Tree10 = MerkleTree(10);

// ============================================================================
// Tests
// ============================================================================

test "merkle: init and insert" {
    const allocator = std.testing.allocator;
    var tree = try Tree10.init(allocator);
    defer tree.deinit();

    const leaf1: Hash = [_]u8{1} ** 32;
    const idx1 = try tree.insert(leaf1);
    try std.testing.expectEqual(@as(u64, 0), idx1);

    const leaf2: Hash = [_]u8{2} ** 32;
    const idx2 = try tree.insert(leaf2);
    try std.testing.expectEqual(@as(u64, 1), idx2);

    // Root should change after insertions
    const root = tree.getRoot();
    try std.testing.expect(!std.mem.eql(u8, &root, &ZERO_HASH));
}

test "merkle: proof verification" {
    const allocator = std.testing.allocator;
    var tree = try Tree10.init(allocator);
    defer tree.deinit();

    const leaf1: Hash = [_]u8{1} ** 32;
    const leaf2: Hash = [_]u8{2} ** 32;
    const leaf3: Hash = [_]u8{3} ** 32;

    _ = try tree.insert(leaf1);
    _ = try tree.insert(leaf2);
    _ = try tree.insert(leaf3);

    const root = tree.getRoot();

    // Get proof for leaf2
    var proof = try tree.getProof(allocator, 1);
    defer {
        allocator.free(proof.path);
        allocator.free(proof.indices);
    }

    // Verify proof
    try std.testing.expect(proof.verify(root, leaf2));

    // Wrong leaf should fail
    try std.testing.expect(!proof.verify(root, leaf1));

    // Wrong root should fail
    const wrong_root: Hash = [_]u8{99} ** 32;
    try std.testing.expect(!proof.verify(wrong_root, leaf2));
}

test "merkle: deterministic root" {
    const allocator = std.testing.allocator;

    // Create two trees with same leaves
    var tree1 = try Tree10.init(allocator);
    defer tree1.deinit();
    var tree2 = try Tree10.init(allocator);
    defer tree2.deinit();

    const leaves = [_]Hash{
        [_]u8{1} ** 32,
        [_]u8{2} ** 32,
        [_]u8{3} ** 32,
    };

    for (leaves) |leaf| {
        _ = try tree1.insert(leaf);
        _ = try tree2.insert(leaf);
    }

    // Same leaves should produce same root
    try std.testing.expectEqualSlices(u8, &tree1.getRoot(), &tree2.getRoot());
}

test "merkle: tree capacity" {
    try std.testing.expectEqual(@as(u64, 1024), Tree10.getCapacity());
    try std.testing.expectEqual(@as(u8, 10), Tree10.getDepth());
}
