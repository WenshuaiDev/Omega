import { parseTree } from "jsonc-parser";
import type { ParseError } from "jsonc-parser";

export type AppId = "web" | "console";
export interface RuntimeConfig {
  schemaVersion: 1;
  appId: AppId;
  environment: "dev" | "test" | "prod";
  version: string;
  apiBaseUrl: "/api";
}

export function parseConfig(text: string, appId: AppId): RuntimeConfig {
  const errors: ParseError[] = [];
  const tree = parseTree(text, errors, {
    disallowComments: true,
    allowTrailingComma: false,
  });
  if (errors.length || tree?.type !== "object")
    throw new Error("公开配置必须是有效 JSON 对象");
  const keys = (tree.children ?? []).map(
    (property) => property.children?.[0]?.value as unknown,
  );
  const fields = [
    "schemaVersion",
    "appId",
    "environment",
    "version",
    "apiBaseUrl",
  ];
  if (
    keys.length !== fields.length ||
    new Set(keys).size !== keys.length ||
    fields.some((key) => !keys.includes(key))
  ) {
    throw new Error("公开配置包含缺失、重复或未知字段");
  }
  const config: unknown = JSON.parse(text);
  if (!config || typeof config !== "object")
    throw new Error("公开配置格式错误");
  const value = config as Record<string, unknown>;
  if (
    value.schemaVersion !== 1 ||
    value.appId !== appId ||
    !["dev", "test", "prod"].includes(String(value.environment)) ||
    typeof value.environment !== "string" ||
    typeof value.version !== "string" ||
    !value.version.trim() ||
    value.version.length > 128 ||
    value.apiBaseUrl !== "/api"
  ) {
    throw new Error("公开配置 schema、应用、环境、版本或 API 地址无效");
  }
  return value as unknown as RuntimeConfig;
}
