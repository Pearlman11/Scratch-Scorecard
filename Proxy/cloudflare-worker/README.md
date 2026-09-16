# Scorecard parser proxy

A ~200-line Cloudflare Worker that reads the handwritten scores off a scorecard photo and returns JSON.

It exists for one reason: **the iPhone app must not contain an Anthropic API key.** An iOS app bundle is a
zip file that anyone who installs the app can open, and `strings` on the binary is enough to lift a key out
of it. A key shipped to a thousand phones is a key published a thousand times, billed to whoever owns it
until they notice. Obfuscating it, splitting it across constants, or fetching it at launch and caching it
are the same mistake with extra steps.

So the phone holds this Worker's URL — public information by nature — and this Worker holds the key.

## Deploy

```sh
npm install -g wrangler
wrangler login
cd Proxy/cloudflare-worker

# Stored encrypted by Cloudflare. Never written to wrangler.toml, never committed.
wrangler secret put ANTHROPIC_API_KEY

wrangler deploy
```

`wrangler deploy` prints a URL like `https://golf-scorecard-parser.<your-subdomain>.workers.dev`. Paste it
into the app under **Settings → AI scorecard reading**. The app rejects anything that is not `https://`.

### Closing it to strangers

A Worker URL is unguessable but not secret, and every call to this one spends money on your Anthropic
account. Left as deployed above, anyone who learns the URL can use it. To lock it down:

```sh
wrangler secret put CLIENT_TOKEN   # any long random string
```

Then paste `https://golf-scorecard-parser.<your-subdomain>.workers.dev/?t=THE_TOKEN` into the app instead.
The Worker also accepts the token as `Authorization: Bearer THE_TOKEN` if you prefer to put it there.

This is not the same mistake as shipping an API key: the token is yours, for your own server, typed in by
you on your own phone, and revoking it is one `wrangler secret put` away. It also cannot be used for
anything except reading a scorecard.

Free-tier Workers allow 100,000 requests a day, which is rather more scorecards than anyone plays. The
Anthropic usage is billed to your own account; one card is a single image and a few hundred output tokens.

## Contract

**Request** — `POST` with `content-type: application/json`:

```json
{ "image": "<base64 JPEG>", "imageMediaType": "image/jpeg", "holeCount": 18 }
```

**Response** — `200`:

```json
{
  "courseName": "Steel Canyon Golf Club",
  "teeName": "White",
  "players": [
    {
      "name": "J. PEARLMAN",
      "holes": [ { "holeNumber": 1, "playerScore": 6, "confidence": 0.93 } ],
      "writtenOut": 40, "writtenIn": 37, "writtenTotal": 77
    }
  ]
}
```

Errors return a non-2xx status and `{ "error": "..." }`. The app surfaces that text to the golfer, so the
Worker deliberately summarises upstream failures rather than forwarding an API error body that may contain
account or request detail.

## Design notes

**The response shape is enforced, not requested.** `output_config.format` with a JSON schema means the
model cannot return prose, a code fence, or a differently-shaped object. There is no "parse the JSON out of
the reply" step to go wrong.

**`null` is a wanted answer.** The system prompt says so at length. The failure mode of a language model on
an illegible cell is to produce something plausible, and a plausible wrong score is much worse for a golfer
than a blank the app asks them to fill in. The prompt explicitly forbids inferring a score from par, from
the other players, or from what would make the row add up.

**The subtotals are transcribed, never computed.** The prompt insists on this, and it is load-bearing: the
app adds up the hole scores itself and compares the result to the OUT/IN/TOTAL the model transcribed
(`RemoteScoreAudit`). If the model computed those cells instead of reading them, they would agree by
construction and the check would be worthless. Read independently, they are the card confirming its own
transcription — a far better signal than any self-reported confidence.

**Handwriting only.** Par, stroke index and yardages are printed, and the app already has them from a
verified course template that was checked against the physical card. The prompt tells the model to ignore
them, and the app ignores them if it returns them anyway.

## Privacy

Each request forwards one photograph to the Anthropic API and returns the transcription. The Worker stores
nothing: no KV, no R2, no D1, no logging of image data. The only thing written to logs is the status code of
a failed upstream call.

The app treats this as the one non-local step it has. It is off unless a URL is configured, it asks for
consent in words before the first photo leaves the phone, and it downscales to 1600px first so that less of
the image is sent than was captured. Every other feature — scanning, layout reconstruction, course
matching, the checksum solver, storage, the map — runs entirely on device with no network at all.

## Running it somewhere else

Nothing here is Cloudflare-specific beyond the `export default { fetch }` shape. The same handler ports to a
Vercel function, a Lambda behind API Gateway, or twenty lines of Express, as long as whatever you use keeps
`ANTHROPIC_API_KEY` server-side. If you put it behind an authenticated endpoint of your own, the app's
request is a plain JSON `POST` and will carry whatever headers you add to it.
