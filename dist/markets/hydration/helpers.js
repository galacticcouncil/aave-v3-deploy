"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.tokenAddress = void 0;
function numToBuffer(num) {
    const arr = new Uint8Array(4);
    for (let i = 0; i < 4; i++)
        arr.set([num / 0x100 ** i], 3 - i);
    return Buffer.from(arr);
}
function tokenAddress(assetId) {
    const tokenAddress = Buffer.from("0000000000000000000000000000000100000000", "hex");
    const assetIdBuffer = numToBuffer(+assetId);
    assetIdBuffer.copy(tokenAddress, 16);
    return "0x" + tokenAddress.toString("hex");
}
exports.tokenAddress = tokenAddress;
