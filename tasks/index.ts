// Auxiliary
const accounts = require("./accounts");
const verifier = require("./verifier");

// Mock
const deployMock = require("./deploy/mock/mock");

// Main
const deployMatchPool = require("./deploy/MatchPool");
const upgradeMatchPool = require("./upgrade/MatchPool");
const matchPool = require("./MatchPool");

export {
  accounts,
  verifier,
  //
  deployMock,
  //
  deployMatchPool,
  upgradeMatchPool,
  matchPool
};
