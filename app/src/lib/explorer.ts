export const DEFAULT_EXPLORER_BASE = 'https://solana.fm/tx';
export const DEFAULT_EXPLORER_CLUSTER = 'testnet-solana';

export const buildExplorerTxUrl = (signature: string, cluster?: string): string => {
  const base = process.env.NEXT_PUBLIC_EXPLORER_URL || DEFAULT_EXPLORER_BASE;
  const normalizedBase = base.endsWith('/') ? base.slice(0, -1) : base;
  const url = `${normalizedBase}/${signature}`;
  const resolvedCluster = cluster ?? process.env.NEXT_PUBLIC_EXPLORER_CLUSTER ?? DEFAULT_EXPLORER_CLUSTER;
  return resolvedCluster ? `${url}?cluster=${resolvedCluster}` : url;
};
