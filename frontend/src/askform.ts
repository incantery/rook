/** The ask form's decision logic, kept out of AskView.svelte so it can be
 *  tested without a DOM: what the rows are, which of them start picked,
 *  what a toggle does, and exactly what Enter sends. The component owns
 *  $state and pixels; every rule about what an answer MEANS lives here.
 *
 *  The wire shape is deliberately loose (the host carries the questions
 *  payload opaquely, so the form can grow fields without a daemon
 *  release), which means normalizing is this module's first job:
 *  `options` may be absent — that's a free-text question, not an error. */

export interface AskOption {
    label: string;
    description?: string;
    /** a concrete artifact to compare — mockup, snippet, config. Rendered
     *  verbatim in a monospace panel beside the rows. */
    preview?: string;
    /** the asker's suggestion: pre-ticked in multi, under the cursor in
     *  single, so Enter alone is a complete answer */
    recommended?: boolean;
}

export interface AskQuestion {
    question: string;
    header?: string;
    multiSelect?: boolean;
    /** absent or empty = a free-text question: no rows, just the input */
    options?: AskOption[];
}

export interface AskAnswer {
    question: string;
    header?: string;
    selected: string[];
    other?: string;
}

/** One question with the wire's optionality collapsed away — the shape the
 *  component renders against. */
export interface FormQuestion {
    question: string;
    header?: string;
    multi: boolean;
    options: AskOption[];
    /** no options at all: the text input IS the question */
    freeText: boolean;
    /** the "Other…" row, one past the last option */
    otherIdx: number;
    /** options + Other */
    rowCount: number;
}

export function formQuestion(q: AskQuestion): FormQuestion {
    const options = q?.options ?? [];
    return {
        question: q?.question ?? "",
        header: q?.header,
        // a single option list with nothing to choose between is still a
        // list; multi only means "several may apply"
        multi: q?.multiSelect === true,
        options,
        freeText: options.length === 0,
        otherIdx: options.length,
        rowCount: options.length + 1,
    };
}

/** Rows ticked before the user touches anything. Only multi pre-ticks: in
 *  a single-select a pre-picked row would be an answer nobody gave, since
 *  picking there commits. Single-select puts the cursor there instead. */
export function initialPicks(fq: FormQuestion): Set<number> {
    if (!fq.multi) return new Set();
    const picks = new Set<number>();
    fq.options.forEach((o, i) => {
        if (o.recommended) picks.add(i);
    });
    return picks;
}

/** Where the cursor starts: the recommended row if the asker named one. */
export function initialCursor(fq: FormQuestion): number {
    const i = fq.options.findIndex((o) => o.recommended);
    return i < 0 ? 0 : i;
}

export function toggle(picked: ReadonlySet<number>, i: number): Set<number> {
    const next = new Set(picked);
    if (next.has(i)) next.delete(i);
    else next.add(i);
    return next;
}

/** What Enter sends in a multi-select.
 *
 *  Untouched list → the fast path this form shipped with: Enter takes the
 *  row under the cursor, so the common "one of these, actually" costs one
 *  key. Once the user has toggled ANYTHING, Enter means exactly what is
 *  ticked — including nothing ticked, which is the only honest way to say
 *  "none of these" without inventing a row for it. */
export function enterPicks(
    picked: ReadonlySet<number>,
    touched: boolean,
    cursor: number,
): Set<number> {
    if (touched || picked.size > 0) return new Set(picked);
    return new Set([cursor]);
}

/** The answer for one question. Labels, not indexes: the asker wrote them
 *  and reads them back, and an index would silently rot if the model ever
 *  reorders its options between raise and answer. */
export function shapeAnswer(
    fq: FormQuestion,
    picked: ReadonlySet<number>,
    otherText: string,
): AskAnswer {
    const selected = [...picked]
        .filter((i) => i >= 0 && i < fq.options.length)
        .sort((a, b) => a - b)
        .map((i) => fq.options[i].label);
    const other = otherText.trim();
    return {
        question: fq.question,
        ...(fq.header ? {header: fq.header} : {}),
        selected,
        ...(other ? {other} : {}),
    };
}

/** Whether a decision can be sent at all. A free-text question with an
 *  empty box has nothing in it; everything else can go — an empty multi is
 *  "none of these", which is a real answer. */
export function canSend(fq: FormQuestion, picked: ReadonlySet<number>, otherText: string): boolean {
    if (fq.freeText) return otherText.trim().length > 0;
    if (fq.multi) return true;
    return picked.size > 0 || otherText.trim().length > 0;
}
