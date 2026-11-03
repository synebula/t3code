import { it } from "@effect/vitest";
import { ChatAttachmentId, ChatImageAttachment } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import { afterEach, describe, expect, vi } from "vite-plus/test";

import { extraIntegrationsEnabled } from "./extraIntegrations.ts";

describe("extraIntegrationsEnabled", () => {
  it("defaults off and enables only on an explicit 1", () => {
    expect(extraIntegrationsEnabled({})).toBe(false);
    expect(extraIntegrationsEnabled({ T3_CODE_EXTRA_INTEGRATIONS: "0" })).toBe(false);
    expect(extraIntegrationsEnabled({ T3_CODE_EXTRA_INTEGRATIONS: "true" })).toBe(false);
    expect(extraIntegrationsEnabled({ T3_CODE_EXTRA_INTEGRATIONS: "1" })).toBe(true);
  });
});

describe("extra integrations disabled", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it("emits no agent prompt text", async () => {
    vi.stubEnv("T3_CODE_EXTRA_INTEGRATIONS", "0");
    vi.resetModules();
    const runtime = await import("./runtimeInstructions.ts");
    const orchestration = await import("./orchestrationInstructions.ts");

    expect(runtime.buildRuntimeInstructions({ harness: "Codex" })).toBe("");
    expect(runtime.PULL_REQUEST_LINKING_INSTRUCTIONS).toBe("");
    expect(orchestration.T3_CODE_ORCHESTRATION_INSTRUCTIONS).toBe("");
    expect(
      orchestration.t3OrchestrationPrompt({
        prompt: "Ship it.",
        hasT3Mcp: true,
        hasDeviceTools: true,
        orchestrationDelivered: false,
        deviceInstructionsDelivered: false,
      }),
    ).toBe("Ship it.");
    expect(orchestration.t3OrchestrationSystemPrompt(true, true)).toBeUndefined();
    expect(
      orchestration.t3AcpPromptWithInstructions({
        prompt: "Ship it.",
        state: { interactionMode: "default", hasT3Mcp: true, hasDeviceTools: true },
      }),
    ).toBe("Ship it.");
  });

  it.effect("leaves captured-window accessibility out of attachment context", () =>
    Effect.gen(function* () {
      vi.stubEnv("T3_CODE_EXTRA_INTEGRATIONS", "0");
      vi.resetModules();
      const { providerMessageTextWithAttachmentPaths } = yield* Effect.promise(
        () => import("./attachmentPrompt.ts"),
      );
      const attachment = ChatImageAttachment.make({
        id: ChatAttachmentId.make("captured-window"),
        type: "image",
        name: "window.png",
        mimeType: "image/png",
        sizeBytes: 12,
        source: {
          kind: "snap-shot",
          capturedAt: "2026-08-24T11:00:00.000Z",
          appName: "Editor",
          windowTitle: "main.ts",
          accessibleText: "Private window contents",
        },
      });

      const text = yield* providerMessageTextWithAttachmentPaths({
        text: "Fix this.",
        attachments: [attachment],
        resolveAttachmentPath: () => "/attachments/window.png",
      });

      expect(text).toContain("/attachments/window.png");
      expect(text).not.toContain("captured-window");
      expect(text).not.toContain("Private window contents");
    }),
  );
});
