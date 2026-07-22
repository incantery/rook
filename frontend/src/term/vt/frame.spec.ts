import {describe, expect, it} from "vitest";
import {decodeFrame} from "./frame";
import {ClientGrid} from "./grid";
import fixtureData from "./testdata/frames.json";

// The cross-language conformance gate. Go encodes a snapshot Frame for each
// corpus capture and packs the grid it must reconstruct to (internal/vt/
// wirefixture_test.go). Here the TypeScript decoder replays the frame into a
// blank ClientGrid and must land the identical grid, cell for cell — proving the
// codec and the color/attr interpretation agree across the language boundary.
// Regenerate with: VT_GEN_FIXTURES=1 go test ./internal/vt -run TestWriteWireFixtures

interface Fixture {
    name: string;
    cols: number;
    rows: number;
    frame: string; // hex
    cursor: {X: number; Y: number; Visible: boolean};
    grid: string[]; // one packed row per line; cells split by US, fields by RS
}

const US = "\x1f";
const RS = "\x1e";

function hexToBytes(hex: string): Uint8Array {
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
    return out;
}

const fixtures = fixtureData as Fixture[];

describe("wire decoder reconstructs the emulator grid", () => {
    for (const fx of fixtures) {
        it(fx.name, () => {
            const frame = decodeFrame(hexToBytes(fx.frame));
            const grid = new ClientGrid(fx.cols, fx.rows);
            grid.apply(frame);

            // cursor
            expect(grid.cursor).toEqual({
                x: fx.cursor.X,
                y: fx.cursor.Y,
                visible: fx.cursor.Visible,
            });

            // every cell, against the packed expectation
            for (let y = 0; y < fx.rows; y++) {
                const packed = fx.grid[y].split(US);
                for (let x = 0; x < fx.cols; x++) {
                    const [c, w, fg, bg, a] = packed[x].split(RS);
                    const got = grid.token(x, y);
                    const want = {c, w: Number(w), fg, bg, a};
                    if (
                        got.c !== want.c ||
                        got.w !== want.w ||
                        got.fg !== want.fg ||
                        got.bg !== want.bg ||
                        got.a !== want.a
                    ) {
                        throw new Error(
                            `${fx.name} (${x},${y}) got ${JSON.stringify(got)} want ${JSON.stringify(want)}`,
                        );
                    }
                }
            }
        });
    }
});

describe("decoder edge cases", () => {
    it("rejects an unknown wire version", () => {
        expect(() => decodeFrame(new Uint8Array([99]))).toThrow(/wire version/);
    });

    it("rejects a truncated frame", () => {
        // version + a cursor that runs off the end
        expect(() => decodeFrame(new Uint8Array([1, 0x80]))).toThrow(/truncated|varint/);
    });
});
