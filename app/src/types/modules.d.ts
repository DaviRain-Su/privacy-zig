declare module 'circomlibjs' {
  export function buildPoseidon(): Promise<any>;
}

declare module 'snarkjs' {
  export const groth16: {
    fullProve(
      input: any,
      wasmPath: string,
      zkeyPath: string
    ): Promise<{ proof: any; publicSignals: string[] }>;
    verify(
      verificationKey: any,
      publicSignals: string[],
      proof: any
    ): Promise<boolean>;
  };
}

declare module 'ffjavascript' {
  export const utils: {
    stringifyBigInts(obj: any): any;
    unstringifyBigInts(obj: any): any;
    leInt2Buff(n: bigint, len: number): Uint8Array;
    leBuff2int(buff: Uint8Array): bigint;
  };
}
