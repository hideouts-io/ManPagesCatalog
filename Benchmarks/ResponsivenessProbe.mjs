/**
 * Rendered-app probe for the Codex cua_repl native App interface.
 * Import this module in cua_repl after selecting a uniquely named test app.
 * Pass an action using accessibilityIndex(state, id), then verify the returned
 * accessibility state. Save returned measurements beside the scan export.
 * Timing includes input dispatch, automation settling and AX observation;
 * it is an upper bound on observed response, not event-to-pixel latency.
 * Capture a fresh AX state after screenshots before further interactions.
 */

/** @typedef {{getAXState: (options: {emit: boolean, disableDiffing: boolean}) => Promise<string>}} ProbeApp */
/** @typedef {{label: string, dispatchMilliseconds: number, actionToObservedMilliseconds: number, state: string}} ProbeResult */

/** @param {string} state @param {string} identifier @returns {number} */
export function accessibilityIndex(state, identifier) {
    const matches = state.split("\n").filter(line => /^\s*\d+ /.test(line)
        && line.includes("ID: " + identifier)
        && line.split("ID: ")[1].split(",")[0].trim() === identifier);
    if (matches.length !== 1) {
        throw new Error(`Expected one accessibility identifier ${identifier}; found ${matches.length}.`);
    }
    return Number(matches[0].trim().match(/^\d+/)[0]);
}

/**
 * Each operation starts with fresh identifier mapping and fails without fallback
 * clicks if the app, control or expected result differs. Use the same operations
 * while idle and while the production scan's inspected counters are increasing.
 * @param {ProbeApp} app
 * @param {string} appName
 * @param {string} label
 * @param {(state: string) => Promise<void>} action
 * @param {(state: string) => boolean} verify
 * @returns {Promise<ProbeResult>}
 */
export async function measureNativeOperation(app, appName, label, action, verify) {
    const before = await app.getAXState({emit: false, disableDiffing: true});
    if (!before.includes(`App: ${appName}.`)) throw new Error(`Wrong app before ${label}.`);
    const started = performance.now();
    await action(before);
    const dispatched = performance.now();
    const state = await app.getAXState({emit: false, disableDiffing: true});
    const observed = performance.now();
    if (!state.includes(`App: ${appName}.`) || !verify(state)) {
        throw new Error(`Rendered response verification failed: ${label}.`);
    }
    return {label, dispatchMilliseconds: dispatched - started,
        actionToObservedMilliseconds: observed - started, state};
}
