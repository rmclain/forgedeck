'use strict';

const companion = require('./lib/companion');
const security = require('./lib/security');

module.exports = {
  createCompanion: companion.createCompanion,
  loadReleaseFile: companion.loadReleaseFile,
  SCHEMA_VERSION: companion.SCHEMA_VERSION,
  WINDOWS: companion.WINDOWS,
  ENVIRONMENTS: companion.ENVIRONMENTS,
  CAPABILITIES: companion.CAPABILITIES,
  SCOPES: security.SCOPES,
  generateToken: security.generateToken,
  hashToken: security.hashToken,
  signRequest: security.signRequest,
  maskEmail: security.maskEmail,
  security,
};
