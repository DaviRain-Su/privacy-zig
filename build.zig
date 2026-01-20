const std = @import("std");

pub fn build(b: *std.Build) void {
    // This is a monorepo. Each component has its own build:
    //
    // - programs/privacy-pool/  -> Solana on-chain program
    // - app/                    -> Next.js frontend
    // - scripts/                -> TypeScript deployment scripts
    //
    // To build the on-chain program:
    //   cd programs/privacy-pool && zig build
    //
    // To run the frontend:
    //   cd app && npm install && npm run dev

    const info_step = b.step("info", "Show build information");
    info_step.dependOn(&b.addLog(
        \\privacy-zig - Anonymous transfers on Solana
        \\
        \\Components:
        \\  programs/privacy-pool/  - On-chain Zig program
        \\  app/                    - Next.js DApp
        \\  scripts/                - Deployment scripts
        \\
        \\Build on-chain program:
        \\  cd programs/privacy-pool && zig build
        \\
        \\Run DApp:
        \\  cd app && npm install && npm run dev
        \\
    ).step);

    // Default step shows info
    b.default_step = info_step;
}
