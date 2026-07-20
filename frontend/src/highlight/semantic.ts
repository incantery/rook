// The semantic-token legend, unified across language servers.
//
// LSP semantic tokens are integer indices into a legend the SERVER chooses:
// gopls publishes one list, vtsls another, and a third server could publish
// a fourth type at index 3 where gopls has "class". Monaco, meanwhile, reads
// getLegend() ONCE per provider registration and treats every token stream as
// speaking that one legend.
//
// So the provider publishes a unified legend — the LSP standard list, grown
// on demand — and each server's indices are remapped into it. Growing is safe
// because indices already handed to Monaco never move; only new names append.
// With one server per language the remap is the identity, which is the point:
// it costs nothing in the normal case and prevents a second server from
// silently coloring through a legend that isn't its own.

/** LSP 3.17's standard token types, in protocol order. */
export const STANDARD_TYPES = [
    "namespace",
    "type",
    "class",
    "enum",
    "interface",
    "struct",
    "typeParameter",
    "parameter",
    "variable",
    "property",
    "enumMember",
    "event",
    "function",
    "method",
    "macro",
    "keyword",
    "modifier",
    "comment",
    "string",
    "number",
    "regexp",
    "operator",
    "decorator",
];

/** LSP 3.17's standard token modifiers, in protocol order. */
export const STANDARD_MODIFIERS = [
    "declaration",
    "definition",
    "readonly",
    "static",
    "deprecated",
    "abstract",
    "async",
    "modification",
    "documentation",
    "defaultLibrary",
];

/** The growing unified legend. Module state on purpose: Monaco holds the
 *  arrays it was handed, so they must be mutated in place, never replaced. */
export const legendTypes: string[] = [...STANDARD_TYPES];
export const legendModifiers: string[] = [...STANDARD_MODIFIERS];

/** Index of `name`, appending it if new. */
export function legendIndex(list: string[], name: string): number {
    const i = list.indexOf(name);
    if (i !== -1) return i;
    list.push(name);
    return list.length - 1;
}

/** Rewrite a token stream's type and modifier indices from a server's legend
 *  into the unified one, in place.
 *
 *  `data` is groups of five — (deltaLine, deltaStartChar, length, type,
 *  modifiers) — and only the last two are touched: the first three are
 *  positional deltas that mean the same thing in both legends. Modifiers are
 *  a BITSET, so each set bit moves independently.
 *
 *  A trailing partial group (a malformed stream) is left alone rather than
 *  read past the end. */
export function remapTokens(data: Uint32Array, typeMap: number[], modMap: number[]): Uint32Array {
    for (let i = 0; i + 4 < data.length; i += 5) {
        data[i + 3] = typeMap[data[i + 3]] ?? data[i + 3];
        const bits = data[i + 4];
        if (bits === 0) continue;
        let remapped = 0;
        for (let b = 0; b < modMap.length; b++) {
            if (bits & (1 << b)) remapped |= 1 << modMap[b];
        }
        data[i + 4] = remapped;
    }
    return data;
}

/** Remap a server's token stream into the unified legend, growing it as
 *  needed. The whole job, from a host response to what Monaco consumes. */
export function unifyTokens(
    data: readonly number[],
    types: readonly string[],
    modifiers: readonly string[],
): Uint32Array {
    const typeMap = types.map((t) => legendIndex(legendTypes, t));
    const modMap = modifiers.map((m) => legendIndex(legendModifiers, m));
    return remapTokens(Uint32Array.from(data), typeMap, modMap);
}
