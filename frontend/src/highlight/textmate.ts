// TextMate tokenization for the Monaco panes — what VS Code itself runs, in
// place of Monaco's Monarch regexes.
//
// Monarch is a flat regex tokenizer with a keyword list: it colors keywords,
// strings, comments and numbers, and hands back one undifferentiated
// "identifier" for everything else. A TextMate grammar is a stack machine with
// begin/end rules and injections, so it can tell a call site from a
// declaration, an attribute name from its value, and a fenced code block from
// the prose around it.
//
// Everything here is lazy. The module is imported by term/monaco.ts, which is
// itself behind an await import(), and each grammar is its own dynamic import:
// opening a Go file downloads the oniguruma WASM and go.json, and nothing
// else. Boot is untouched.
//
// FAIL OPEN, always. Every failure path — no WASM, a grammar that won't parse,
// a tokenizer that throws mid-line — leaves Monaco's Monarch tokenizer in
// place for that language. Syntax color is the least important thing on the
// screen; it must never be the reason a file won't open.

import type * as monacoTypes from "monaco-editor";
import {INITIAL, Registry, parseRawGrammar, type IGrammar, type StateStack} from "vscode-textmate";
import {createOnigScanner, createOnigString, loadWASM} from "vscode-oniguruma";
import {GRAMMARS} from "./table";
import {pickScope} from "./scope";
import {BASE_COMMENTS} from "./comments";

/** Languages Monaco doesn't register itself — without this a .svelte file is
 *  plain text, grammar or no grammar.
 *
 *  json is here for the same reason and was missing: rook vendors a json
 *  grammar (table.ts) but Monaco's basic-languages ships no json
 *  contribution — that language comes from the json language SERVICE, which
 *  this build deliberately doesn't include. So the grammar had nothing to
 *  attach to and every .json file rendered as plain text. */
const EXTRA_LANGUAGES: {id: string; extensions: string[]}[] = [
    {id: "svelte", extensions: [".svelte"]},
    {id: "json", extensions: [".json", ".jsonc"]},
];

let registry: Registry | null = null;
let wasmLoaded: Promise<boolean> | null = null;

/** The oniguruma regex engine, as WASM. vscode-textmate needs it because
 *  TextMate patterns are Oniguruma-flavored — JS RegExp can't run them
 *  (\h, \G, POSIX classes, subexpression calls). */
async function ensureWasm(): Promise<boolean> {
    wasmLoaded ??= (async () => {
        try {
            // ?url keeps the .wasm a fetched asset rather than an inlined
            // base64 blob in the JS chunk
            const {default: wasmUrl} = await import("vscode-oniguruma/release/onig.wasm?url");
            const res = await fetch(wasmUrl);
            await loadWASM({data: await res.arrayBuffer()});
            return true;
        } catch (err) {
            console.warn("textmate: oniguruma unavailable, staying on monarch:", err);
            return false;
        }
    })();
    return wasmLoaded;
}

function ensureRegistry(): Registry {
    registry ??= new Registry({
        onigLib: Promise.resolve({createOnigScanner, createOnigString}),
        // Called for the grammar itself AND for every scope it embeds —
        // markdown alone names 57 languages for its fenced blocks. Anything
        // outside the vendored set resolves to null, which vscode-textmate
        // treats as "leave that region alone": a ```rust block highlights,
        // a ```haskell block stays plain. Never an error.
        loadGrammar: async (scopeName) => {
            const entry = GRAMMARS.find((g) => g.scope === scopeName);
            if (!entry) return null;
            try {
                const mod = (await entry.load()) as {default: unknown};
                return parseRawGrammar(JSON.stringify(mod.default), `${scopeName}.json`);
            } catch (err) {
                console.warn(`textmate: grammar ${scopeName} failed to load:`, err);
                return null;
            }
        },
    });
    return registry;
}

/** vscode-textmate's state is an immutable stack; Monaco wants an IState with
 *  equals/clone. This is the whole adapter. */
class TMState implements monacoTypes.languages.IState {
    constructor(readonly stack: StateStack) {}
    clone(): monacoTypes.languages.IState {
        return new TMState(this.stack);
    }
    equals(other: monacoTypes.languages.IState): boolean {
        return other instanceof TMState && other.stack === this.stack;
    }
}

/** A line long enough that a backtracking TextMate pattern can hang on it.
 *  Minified JS and embedded data URIs are the usual offenders; Monaco itself
 *  stops tokenizing around here for the same reason. */
const MAX_LINE = 20_000;

function providerFor(grammar: IGrammar): monacoTypes.languages.TokensProvider {
    return {
        getInitialState: () => new TMState(INITIAL),
        tokenize(line, state) {
            const prev = state instanceof TMState ? state.stack : INITIAL;
            if (line.length > MAX_LINE) {
                return {tokens: [{startIndex: 0, scopes: ""}], endState: new TMState(prev)};
            }
            try {
                const res = grammar.tokenizeLine(line, prev);
                return {
                    tokens: res.tokens.map((t) => ({
                        startIndex: t.startIndex,
                        // ONE scope per token is all Monaco's theme takes;
                        // pickScope decides which of the stack earns it
                        scopes: pickScope(t.scopes),
                    })),
                    endState: new TMState(res.ruleStack),
                };
            } catch (err) {
                // A grammar that throws must not take the file down: paint
                // the line flat and carry the state forward unchanged.
                console.warn("textmate: tokenize failed, line left plain:", err);
                return {tokens: [{startIndex: 0, scopes: ""}], endState: new TMState(prev)};
            }
        },
    };
}

let installed = false;

/** Register every vendored grammar with Monaco, replacing Monarch for those
 *  languages. Idempotent, and safe to call before any editor exists —
 *  registration is per-language-id, not per-editor.
 *
 *  Grammars attach LAZILY: registerTokensProviderFactory hands Monaco a
 *  factory it calls the first time a model of that language is tokenized, so
 *  opening one Go file pulls go.json and nothing else. A factory returning
 *  null leaves that language on its Monarch tokenizer. */
export function installTextMate(monaco: typeof monacoTypes): void {
    if (installed) return;
    installed = true;

    for (const lang of EXTRA_LANGUAGES) {
        const known = monaco.languages.getLanguages().some((l) => l.id === lang.id);
        if (!known) monaco.languages.register({id: lang.id, extensions: lang.extensions});
        // A grammar colours a language; it does not tell Monaco what a
        // comment looks like — that lives in the CONFIGURATION, and without
        // one `gc` silently does nothing. svelte's rule is refined per
        // position when the verb runs (comments.ts); this is the file-wide
        // default it starts from.
        const rule = BASE_COMMENTS[lang.id];
        if (rule) monaco.languages.setLanguageConfiguration(lang.id, {comments: rule});
    }

    for (const entry of GRAMMARS) {
        monaco.languages.registerTokensProviderFactory(entry.lang, {
            create: async () => {
                if (!(await ensureWasm())) return null; // monarch keeps the language
                try {
                    const grammar = await ensureRegistry().loadGrammar(entry.scope);
                    if (!grammar) return null;
                    return providerFor(grammar);
                } catch (err) {
                    console.warn(`textmate: ${entry.lang} staying on monarch:`, err);
                    return null;
                }
            },
        });
    }
}
