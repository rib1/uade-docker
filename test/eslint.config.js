module.exports = [
  {
    files: ["*.js"],
    languageOptions: {
      ecmaVersion: 2021,
      sourceType: "commonjs",
      globals: {
        console: "readonly",
        module: "readonly",
        process: "readonly",
        require: "readonly",
      },
    },
    rules: {
      semi: ["error", "always"],
      quotes: ["error", "double"],
      "no-unused-vars": "warn",
      "no-console": "off",
    },
  },
];
