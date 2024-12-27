import { PopulatedTransaction } from "ethers";

const batch: PopulatedTransaction[] = [];

export function addTransaction(transaction: PopulatedTransaction) {
  batch.push(transaction);
  console.log("batch tx", batch.length, transaction);
}

export function getBatch() {
  return batch;
}
