'use strict';

// Vercel entrypoint: run the compiled backend so TypeScript path aliases have
// already been rewritten to relative CommonJS imports by `tsc-alias`.
const { createApp } = require('../dist/app.js');

module.exports = createApp();
