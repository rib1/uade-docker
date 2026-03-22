// ESLint configuration for UADE Web Player frontend
module.exports = [
  {
    files: ["*.js"],
    languageOptions: {
      ecmaVersion: 2021,
      sourceType: "module",
      globals: {
        window: "readonly",
        document: "readonly",
        console: "readonly",
        setTimeout: "readonly",
        fetch: "readonly",
      },
    },
    rules: {
      curly: ["error", "all"],
      eqeqeq: ["error", "always"],
      semi: ["error", "always"],
      quotes: ["error", "double"],
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-lonely-if": "error",
      "no-unused-vars": ["error", {
        argsIgnorePattern: "^_",
        caughtErrors: "all",
        caughtErrorsIgnorePattern: "^_",
        varsIgnorePattern: "^_"
      }],
      "no-var": "error",
      "no-console": "off"
    },
  },
];
