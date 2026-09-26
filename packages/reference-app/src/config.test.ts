import { describe, expect, it } from "vitest";
import { parseConfig } from "./config";
const valid = {
  schemaVersion: 1,
  appId: "web",
  environment: "test",
  version: "1.2.3",
  apiBaseUrl: "/api",
};
describe("public JSON contract", () => {
  it("accepts all deployment environments without changing API base", () => {
    for (const environment of ["dev", "test", "prod"])
      expect(
        parseConfig(JSON.stringify({ ...valid, environment }), "web")
          .environment,
      ).toBe(environment);
  });
  it.each([
    { ...valid, appId: "console" },
    { ...valid, schemaVersion: 2 },
    { ...valid, environment: "staging" },
    { ...valid, environment: ["test"] },
    { ...valid, version: "" },
    { ...valid, version: 3 },
    { ...valid, apiBaseUrl: "https://example.com" },
    { ...valid, password: "secret" },
    { appId: "web" },
    null,
  ])("rejects invalid fields", (value) =>
    expect(() => parseConfig(JSON.stringify(value), "web")).toThrow(),
  );
  it.each([
    '{"schemaVersion":1,"appId":"web","environment":"test","version":"x","apiBaseUrl":"/api","version":"x"}',
    '{"schemaVersion":1,/* comment */"appId":"web","environment":"test","version":"x","apiBaseUrl":"/api"}',
    '{"schemaVersion":1,"appId":"web","environment":"test","version":"x","apiBaseUrl":"/api",}',
  ])("rejects duplicate keys and nonstandard JSON", (value) =>
    expect(() => parseConfig(value, "web")).toThrow(),
  );
});
