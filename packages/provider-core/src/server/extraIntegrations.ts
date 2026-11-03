/** T3 extra agent integrations: prompts, accessibility context, t3-code MCP.
 * Off by default; set T3_CODE_EXTRA_INTEGRATIONS=1 to restore upstream behavior.
 */
export function extraIntegrationsEnabled(
  env: Readonly<Record<string, string | undefined>> = process.env,
): boolean {
  return env.T3_CODE_EXTRA_INTEGRATIONS === "1";
}

export const T3_EXTRA_INTEGRATIONS_ENABLED = extraIntegrationsEnabled();
