import { PopulatedTransaction } from "ethers";

let batch: PopulatedTransaction[] = [];

export function addTransaction(
  transaction: PopulatedTransaction,
  comment?: string
) {
  const tx = { ...transaction, comment };
  batch.push(tx);
  console.log("batch tx", batch.length - 1, tx);
}

export function getBatch() {
  return batch;
}

export function clearBatch() {
  batch = [];
}
