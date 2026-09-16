/**
 * Scorecard handwriting parser — Cloudflare Worker proxy.
 *
 * This exists so that the iPhone app never holds an Anthropic API key. An iOS app bundle is readable by
 * anyone who installs it, so a key shipped inside one is a published key. The phone holds this Worker's
 * URL, which is public information by nature; the key lives here, as a Worker secret, and never leaves.
 *
 * Deploy:
 *   npm install -g wrangler
 *   wrangler secret put ANTHROPIC_API_KEY
 *   wrangler deploy
 *
 * Then paste the deployed https:// URL into the app under Settings -> AI scorecard reading.
 */

const MODEL = "claude-opus-5";
const ANTHROPIC_VERSION = "2023-06-01";

/** Cap the request body. A rectified scorecard at 1600px JPEG is well under 1 MB; base64 adds a third. */
const MAX_BODY_BYTES = 6 * 1024 * 1024;

const ALLOWED_MEDIA_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

/**
 * The instruction that does the actual work.
 *
 * Two things in here matter more than anything else:
 *
 * 1. Handwriting only. Par, stroke index and yardages are printed, and the app already has them from a
 *    verified course template — a model's reading of them can only make that worse.
 * 2. `null` is a valid, wanted answer. The failure mode of a language model on an illegible cell is to
 *    produce something plausible, and a plausible wrong score is far worse for a golfer than a blank the
 *    app asks them to fill in. This is stated repeatedly and deliberately.
 *
 * The written OUT/IN/TOTAL are requested separately from the per-hole cells, and the model is told not to
 * compute them, because the app checks the row's sum against them. That check is only worth anything if
 * the two readings are independent.
 */
const SYSTEM_PROMPT = `You transcribe handwritten golf scores from a photograph of a paper scorecard.

WHAT TO READ
Read only the HANDWRITTEN player score rows — the numbers a golfer wrote in pen or pencil.
Ignore every printed row: hole numbers, par, handicap/stroke index, yardages, ratings, slope, course name
and logos. Those are already known and are not wanted.

A scorecard is a grid. Hole numbers 1-18 run across the top as printed column headers. Each golfer has one
horizontal row, usually with their name written at the left end. Read each row cell by cell, following the
printed hole columns, so that a score lands under the hole it was written under.

THE COLUMNS THAT ARE NOT HOLES
Most cards have an OUT column after hole 9, an IN column after hole 18, and a TOTAL (or TOT) column.
These hold sums, not hole scores. Never report one of them as a hole score.
Report them separately as writtenOut, writtenIn and writtenTotal.
Transcribe those cells as they are actually written. Do NOT compute them from the hole scores, and do not
correct them if they disagree with the hole scores — report exactly what is on the card. If a golfer left
one blank, report null for it.

WHEN YOU CANNOT READ A CELL
Report null. This is a correct and useful answer, and it is much better than a guess.
Report null when a cell is blank, smudged, cut off, obscured by glare, scribbled over, or genuinely
ambiguous. Do not infer a score from par. Do not infer it from the other players' scores. Do not infer it
from what would make the row add up to the written total — the application does that arithmetic itself,
and it can only do it correctly if you report honestly which cells you could not read.
A row with four nulls that are really nulls is a good answer. A row with no nulls that contains one
invented number is a bad answer.

MARKED-UP CELLS
Golfers circle birdies and box bogeys, and they scratch out a wrong score and write the right one beside or
above it. A circle or box is not part of the digit: read the digit inside it. Where a score has been struck
through and rewritten, report the correction, not the struck-through number.

CONFIDENCE
Give each cell a confidence from 0 to 1 reflecting how clearly you could actually read it.
Use the full range. A crisp, unambiguous digit is 0.95. A digit you are fairly sure of is 0.7. A digit you
are reading mostly from context is 0.4 — and if you are reading it entirely from context, report null
instead.

PLAYERS
Return one entry per handwritten row that has any scores in it, in top-to-bottom order.
Include the name as written if it is legible, otherwise null. Do not invent names.
Do not return rows that are entirely blank.`;

/** The response shape, enforced by the API rather than requested politely. */
const OUTPUT_SCHEMA = {
  type: "object",
  properties: {
    courseName: {
      anyOf: [{ type: "string" }, { type: "null" }],
      description: "Course name printed on the card, or null if not visible.",
    },
    teeName: {
      anyOf: [{ type: "string" }, { type: "null" }],
      description: "The tee the round was played from, only if it is marked on the card. Otherwise null.",
    },
    players: {
      type: "array",
      description: "One entry per handwritten score row, top to bottom.",
      items: {
        type: "object",
        properties: {
          name: {
            anyOf: [{ type: "string" }, { type: "null" }],
            description: "Name written at the head of the row, or null if illegible or absent.",
          },
          holes: {
            type: "array",
            items: {
              type: "object",
              properties: {
                holeNumber: { type: "integer", description: "1-18, from the printed column header." },
                playerScore: {
                  anyOf: [{ type: "integer" }, { type: "null" }],
                  description: "Strokes written in this cell, or null if not readable. Never a guess.",
                },
                confidence: {
                  type: "number",
                  description: "0-1, how clearly this cell could be read.",
                },
              },
              required: ["holeNumber", "playerScore", "confidence"],
              additionalProperties: false,
            },
          },
          writtenOut: {
            anyOf: [{ type: "integer" }, { type: "null" }],
            description: "The OUT cell as written. Not computed. Null if blank or unreadable.",
          },
          writtenIn: {
            anyOf: [{ type: "integer" }, { type: "null" }],
            description: "The IN cell as written. Not computed. Null if blank or unreadable.",
          },
          writtenTotal: {
            anyOf: [{ type: "integer" }, { type: "null" }],
            description: "The TOTAL cell as written. Not computed. Null if blank or unreadable.",
          },
        },
        required: ["name", "holes", "writtenOut", "writtenIn", "writtenTotal"],
        additionalProperties: false,
      },
    },
  },
  required: ["courseName", "teeName", "players"],
  additionalProperties: false,
};

/**
 * Optional access control.
 *
 * A Worker URL is unguessable but not secret, and this one spends money on someone's Anthropic account
 * every time it is called. Setting a CLIENT_TOKEN secret closes it to anyone who has not been given the
 * token. The app sends whatever URL the golfer pasted, so the simplest way to supply it is to paste a URL
 * with the token on the end — https://....workers.dev/?t=THE_TOKEN — which is why the query parameter is
 * accepted alongside the header.
 *
 * Left unset, the endpoint is open to anyone who learns the URL. That is a reasonable trade for a personal
 * deployment and a bad one for a shared link.
 */
function isAuthorised(request, env) {
  if (!env.CLIENT_TOKEN) return true;
  const header = request.headers.get("authorization") || "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7) : null;
  const query = new URL(request.url).searchParams.get("t");
  return bearer === env.CLIENT_TOKEN || query === env.CLIENT_TOKEN;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ error: "POST a JSON body with { image, imageMediaType, holeCount }." }, 405);
    }
    if (!env.ANTHROPIC_API_KEY) {
      return json({ error: "This proxy has no ANTHROPIC_API_KEY configured." }, 500);
    }
    if (!isAuthorised(request, env)) {
      return json({ error: "This scorecard parser is not open to this client." }, 401);
    }

    const declaredLength = Number(request.headers.get("content-length") || 0);
    if (declaredLength > MAX_BODY_BYTES) {
      return json({ error: "That image is too large. Send it at 1600px or smaller." }, 413);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "The request body was not valid JSON." }, 400);
    }

    const { image, imageMediaType = "image/jpeg", holeCount = 18 } = body || {};
    if (typeof image !== "string" || image.length === 0) {
      return json({ error: "No image was supplied." }, 400);
    }
    if (image.length > MAX_BODY_BYTES) {
      return json({ error: "That image is too large. Send it at 1600px or smaller." }, 413);
    }
    if (!ALLOWED_MEDIA_TYPES.has(imageMediaType)) {
      return json({ error: `Unsupported image type: ${imageMediaType}.` }, 400);
    }

    const holes = Number.isInteger(holeCount) && holeCount > 0 && holeCount <= 18 ? holeCount : 18;

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: env.MODEL || MODEL,
        max_tokens: 4096,
        system: SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: [
              { type: "image", source: { type: "base64", media_type: imageMediaType, data: image } },
              {
                type: "text",
                text:
                  `This card covers ${holes} holes. Transcribe the handwritten score rows.\n` +
                  `Report null for any cell you cannot actually read.`,
              },
            ],
          },
        ],
        output_config: { format: { type: "json_schema", schema: OUTPUT_SCHEMA } },
      }),
    });

    if (!upstream.ok) {
      // The upstream error body can contain account and request detail, so it is summarised rather than
      // forwarded to the phone verbatim.
      console.error("anthropic error", upstream.status, await upstream.text());
      return json({ error: `The model service returned ${upstream.status}.` }, 502);
    }

    const message = await upstream.json();
    const text = (message.content || [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");

    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      return json({ error: "The model did not return usable JSON." }, 502);
    }

    return json(parsed);
  },
};
