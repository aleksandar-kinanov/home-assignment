const eslint = require('@eslint/js');
const tseslint = require('typescript-eslint');

module.exports = tseslint.config(
  { ignores: ['dist/**', 'node_modules/**'] },
  eslint.configs.recommended,
  {
    // Plain CommonJS config files (this one, jest.config.js) -- declare the
    // Node globals they actually use instead of disabling no-undef broadly.
    files: ['**/*.js'],
    languageOptions: {
      sourceType: 'commonjs',
      globals: {
        require: 'readonly',
        module: 'writable',
      },
    },
  },
  {
    // Scoped to *.ts only -- this config file itself is CommonJS (needs
    // require()), so applying TS-only rules like no-require-imports to it
    // would misfire.
    files: ['**/*.ts'],
    extends: [...tseslint.configs.recommended],
    rules: {
      // TypeScript is authoritative for undefined-variable checks; no-undef
      // produces false positives on ambient/global types (e.g. Jest globals
      // from @types/jest) that TS already understands.
      'no-undef': 'off',
    },
  },
);
