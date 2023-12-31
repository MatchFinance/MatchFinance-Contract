/**
 * Remember to use this function in the root path of your hardhat project
 */
import * as fs from "fs";

///
/// Deployed Contract Address Info Record
///
export const readAddressList = function () {
  // const filePath = __dirname + "/address.json"
  return JSON.parse(fs.readFileSync("info/address.json", "utf-8"));
};

export const storeAddressList = function (addressList: object) {
  fs.writeFileSync("info/address.json", JSON.stringify(addressList, null, "\t"));
};

export const clearAddressList = function () {
  const emptyList = {};
  fs.writeFileSync("info/address.json", JSON.stringify(emptyList, null, "\t"));
};

///
/// Deployment args record
///

export const readArgs = function () {
  return JSON.parse(fs.readFileSync("info/verify.json", "utf-8"));
};

export const storeArgs = function (args: object) {
  fs.writeFileSync("info/verify.json", JSON.stringify(args, null, "\t"));
};
