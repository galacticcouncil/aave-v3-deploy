"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getBatch = exports.addTransaction = void 0;
const batch = [];
function addTransaction(transaction, comment) {
    const tx = { ...transaction, comment };
    batch.push(tx);
    console.log("batch tx", batch.length - 1, tx);
}
exports.addTransaction = addTransaction;
function getBatch() {
    return batch;
}
exports.getBatch = getBatch;
