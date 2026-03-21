#!/bin/bash
# =============================================================================
# Generates a "Gazette" newspaper article for a given turn using OpenAI.
#
# Reads aggregate game data from status.json, history.json, and diplomacy.json.
# Produces a fun, unreliable wartime newspaper entry. Occasionally injects
# misinformation which gets retracted in a later issue.
#
# Usage:
#   ./generate_gazette.sh <turn> [year]
#   ./generate_gazette.sh --rebuild   # rebuild all past gazette entries
#
# Requires: curl, jq
# Env: OPENAI_API_KEY (or reads from /data/saves/openai_api_key)
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAVE_DIR="${SAVE_DIR:-/data/saves}"
WEBROOT="${WEBROOT:-/opt/freeciv/www}"
GAZETTE_FILE="$SAVE_DIR/gazette.json"
HISTORY_FILE="$SAVE_DIR/history.json"
DIPLOMACY_FILE="$SAVE_DIR/diplomacy.json"

# API key: env var > .env file in script dir > file in save dir
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  OPENAI_API_KEY=$(grep '^OPENAI_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^OPENAI_API_KEY=//' | tr -d '[:space:]"'"'")
fi
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SAVE_DIR/openai_api_key" ]; then
  OPENAI_API_KEY=$(cat "$SAVE_DIR/openai_api_key" | tr -d '[:space:]')
fi
if [ -z "$OPENAI_API_KEY" ]; then
  echo "[gazette] No OpenAI API key found, skipping"
  exit 0
fi

# Parse args
REBUILD=false
TURN=""
YEAR=""
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    *) if [ -z "$TURN" ]; then TURN="$arg"; elif [ -z "$YEAR" ]; then YEAR="$arg"; fi ;;
  esac
done

# Load or init gazette
if [ -f "$GAZETTE_FILE" ] && jq . "$GAZETTE_FILE" >/dev/null 2>&1; then
  GAZETTE_JSON=$(cat "$GAZETTE_FILE")
else
  GAZETTE_JSON="[]"
fi

# ---------------------------------------------------------------------------
# Build the context for a single turn's gazette entry
# ---------------------------------------------------------------------------
build_turn_context() {
  local target_turn="$1"
  local history diplomacy

  [ ! -f "$HISTORY_FILE" ] && { echo "{}"; return; }
  history=$(cat "$HISTORY_FILE")
  diplomacy=$(cat "$DIPLOMACY_FILE" 2>/dev/null || echo '{"current":[],"events":[]}')

  # Get current and previous turn data from history
  local current_entry prev_entry
  current_entry=$(echo "$history" | jq --argjson t "$target_turn" '[.[] | select(.turn == $t)] | .[0] // empty')
  prev_entry=$(echo "$history" | jq --argjson t "$((target_turn - 1))" '[.[] | select(.turn == $t)] | .[0] // empty')

  [ -z "$current_entry" ] && { echo "{}"; return; }

  # Build aggregate stats (no per-player breakdown to avoid leaking strategy)
  local context
  context=$(jq -n \
    --argjson curr "$current_entry" \
    --argjson prev "${prev_entry:-null}" \
    --argjson dipl_events "$(echo "$diplomacy" | jq --argjson t "$target_turn" '[.events[] | select(.turn == $t)]')" \
    --argjson all_history "$history" \
    '{
      turn: $curr.turn,
      year: $curr.year,
      year_display: (if $curr.year < 0 then "\(-$curr.year) BC" else "\($curr.year) AD" end),
      player_count: ($curr.players | keys | length),
      players: [$curr.players | to_entries[] | .key],

      totals: {
        total_cities: [$curr.players | to_entries[].value.cities] | add,
        total_units: [$curr.players | to_entries[].value.units] | add,
        total_population_proxy: [$curr.players | to_entries[].value.score] | add,
        total_techs: [$curr.players | to_entries[].value.techs // 0] | add,
        avg_gold: ([$curr.players | to_entries[].value.gold] | add / ([$curr.players | to_entries[].value.gold] | length)),
        govs_in_use: [$curr.players | to_entries[].value.government] | unique
      },

      deltas: (if $prev then (
        ([$curr.players | to_entries[].value.cities] | add) as $cc |
        ([$prev.players | to_entries[].value.cities] | add) as $pc |
        ([$curr.players | to_entries[].value.units] | add) as $cu |
        ([$prev.players | to_entries[].value.units] | add) as $pu |
        ([$curr.players | to_entries[].value.score] | add) as $cs |
        ([$prev.players | to_entries[].value.score] | add) as $ps |
        {
          cities_change: ($cc - $pc),
          units_change: ($cu - $pu),
          score_change: ($cs - $ps),
          new_players: [$curr.players | keys[] | select(. as $k | $prev.players | has($k) | not)]
        }
      ) else null end),

      diplomacy_events: [
        $dipl_events[] | {
          players: .players,
          type: (if .to == "Contact" then "first_contact"
                 elif .to == "War" then "war_declared"
                 elif .to == "Peace" then "peace_signed"
                 elif .to == "Alliance" then "alliance_formed"
                 elif .to == "Ceasefire" then "ceasefire"
                 elif .to == "Armistice" then "armistice"
                 else .from + " -> " + .to end)
        }
      ],

      score_leaders: [$curr.players | to_entries | sort_by(-.value.score)[:3] | .[].key],
      city_leaders: [$curr.players | to_entries | sort_by(-.value.cities)[:3] | .[].key],
      military_leaders: [$curr.players | to_entries | sort_by(-.value.units)[:3] | .[].key]
    }')

  echo "$context"
}

# ---------------------------------------------------------------------------
# Call OpenAI to generate a gazette entry
# ---------------------------------------------------------------------------
generate_entry() {
  local context="$1"
  local turn year_display
  turn=$(echo "$context" | jq -r '.turn')
  year_display=$(echo "$context" | jq -r '.year_display')

  local system_prompt
  system_prompt=$(cat <<'SYSPROMPT'
You are the editor of "The Civ Chronicle", a newspaper covering a Freeciv multiplayer game. Each issue is a full newspaper with distinct sections.

Your writing style should evolve with the era:
- Ancient era (4000 BC - 1000 BC): Write like ancient chronicles and proclamations. Dramatic, mythic tone. "The gods smile upon..." / "Let it be known..." — but keep it readable for a modern audience.
- Classical era (1000 BC - 500 AD): Roman/Greek historian style. Formal, authoritative, slightly pompous. Think Herodotus or Livy writing a tabloid.
- Medieval era (500 AD - 1400 AD): Town crier / medieval chronicle style. "Hear ye!" / "It is whispered in the courts..."
- Renaissance/Colonial (1400 - 1800): Broadsheet pamphlet style. Flowery but pointed, like 18th century newspapers.
- Industrial/Modern (1800+): Modern newspaper style. Punchy headlines, wire-service tone, with editorial flair.

Always keep it entertaining and understandable to a modern reader — the era flavoring is seasoning, not a barrier.

Rules:
- Use the aggregate data provided (total cities, units, scores, diplomacy events)
- DO NOT reveal specific player strategies, unit compositions, or per-player gold amounts
- DO NOT quote exact numbers for individual players. Keep individual details vague ("a growing empire", "one of the larger armies") so as not to give away strategic info
- You MAY name score leaders, city leaders, and military leaders — but be vague about the gap between them
- You MAY include rumors, gossip, and speculation — frame them clearly as "rumors suggest", "sources whisper", "unconfirmed reports indicate". These add flavor. They should be plausible but not confirmable from the data.
- Diplomacy events (first contact, peace, war, alliances) are public knowledge and can be reported directly
- Aggregate totals (total cities in the world, total units, general tech progress) are fine to share
- Keep it entertaining and dramatic — exaggerate for effect
- The headline should be a real newspaper headline — punchy and dramatic. Do NOT include the turn number or year in the headline (e.g. NOT "Turn 11 (3500 BC): ..."). The turn and year are already shown in the masthead.

The newspaper has these sections:

1. **Front Page** — The main headline story. 2-3 paragraphs covering the biggest events this turn (diplomacy, expansion, major shifts).

2. **Economy** — 1-2 paragraphs on cities, gold, trade, government types in use, economic trends. Include a fictional quote from one of the in-game player leaders (e.g. "Andrew, leader of the Canadians, was overheard saying..."). These are made-up quotes attributed to the actual players in the game — treat them as public figures being quoted by the press. Keep quotes in character for the era.

3. **Military** — 1-2 paragraphs on armies, unit counts, military buildup, tensions, conflicts. Include a fictional quote from one of the in-game player leaders commenting on military matters. Pick someone relevant — a military leader, a player involved in tensions, etc.

4. **Society** — 1-2 paragraphs on tech progress, cultural developments, the state of civilization. Include a fictional quote from one of the in-game player leaders on cultural or scientific matters.

5. **Opinion Column** — A short opinion piece (2-3 paragraphs) written IN THE VOICE of a real famous historical figure, philosopher, or writer who was alive during the game's current year. This is CRITICAL — the person MUST be from the right time. For 3500 BC, use figures like Imhotep or Gilgamesh. For 500 BC, Confucius or Sun Tzu. For 1500 AD, Machiavelli or Erasmus. For 1800 AD, Adam Smith or Marx. For 1950 AD, Orwell or Chomsky. You MUST faithfully reproduce their known writing style, rhetorical habits, and worldview. If Confucius writes, use his aphoristic style. If Machiavelli writes, be pragmatic and calculating. If Orwell writes, be clear-eyed and politically sharp. Research what they actually believed and let that shape their reaction to events. The column should feel like it could plausibly have been written by that person.

6. **Letters to the Editor** — 2-3 short letters from fictional citizens (a farmer, a soldier, a merchant, a priest, etc.) reacting to events. These should be funny, opinionated, and feel like real people griping or celebrating. Keep each letter to 2-4 sentences.

You have editorial freedom to adjust sections based on what's interesting this turn. If there's no military news, make that section shorter and expand economy or society. If a huge war just broke out, lead with it and add a "Special Report" section. The four core sections (front page, economy, military, society) should always be present, but you can adjust their weight and add extra sections when the story calls for it.

IMPORTANT: Every section should have a byline. Front page, economy, military, and society sections each need a fictional reporter name and title (e.g. "By Khamudi, Chief Scribe" or "By Marcus Varro, Senate Correspondent"). The byline style should match the era. Letters to the editor need the fictional author's name and role. ALL quoted historical figures must be from the correct time period for the game year.

## Continuity

You will be given the PREVIOUS issue of the newspaper (if one exists). Use it to maintain continuity:

- **Staff consistency**: Try to keep the same reporters/bylines across issues. They are your recurring staff. If you change a reporter (retirement, promotion, fired, eaten by lions), mention it briefly in the front page or a letter.
- **Corrections**: If the previous issue contained rumors or speculation that turned out wrong based on this turn's data, issue a correction. Be funny about it — "The Chronicle regrets to inform readers that our report of imminent war was, in fact, two shepherds arguing over a goat."
- **Running threads**: Reference previous stories. If last issue mentioned a military buildup, follow up on it. If an alliance was formed, check if it held.
- **Ads**: Include 1-2 small classified ads that are era-appropriate and funny. Plain text only, no HTML tags. These should feel like real ads from a newspaper of the current game year. Ancient: "WANTED: Experienced scout. Must have own sandals." Medieval: "FINE SWORDS, best Toledo steel, inquire at the guild hall." Modern: "DEFENSE CONTRACTOR seeks experienced logistics coordinator. Competitive salary. Security clearance required."

Return your response as JSON with this exact structure:
{
  "headline": "...",
  "sections": {
    "front_page": {"byline": "era-appropriate reporter name and title", "content": "..."},
    "economy": {"byline": "era-appropriate reporter name and title", "content": "..."},
    "military": {"byline": "era-appropriate reporter name and title", "content": "..."},
    "society": {"byline": "era-appropriate reporter name and title", "content": "..."}
  },
  "opinion": {
    "author": "a real historical figure alive at the game's current year",
    "author_title": "their real title or description",
    "title": "column title",
    "content": "..."
  },
  "letters": [
    {"author": "era-appropriate citizen role and name", "content": "..."},
    {"author": "era-appropriate citizen role and name", "content": "..."}
  ],
  "ads": [
    "era-appropriate classified ad, plain text, no HTML",
    "era-appropriate classified ad, plain text, no HTML"
  ],
  "corrections": "correction text or null if none needed",
  "illustration_caption": {
    "credit": "full credit line as it would appear in a newspaper of this era, e.g. 'Carving by a temple artisan, Memphis' or 'Illustration by Albrecht Dürer' or 'Photograph by Dorothea Lange, AP'",
    "description": "plain text description of what the image depicts"
  }
}

The illustration_caption credit should read exactly the way a newspaper of this era would credit artwork. This is a newspaper from THAT day — not looking back at history. Do NOT use words like "period", "era", "ancient", or "unknown." Write it as a natural credit line: "Carving by a temple artisan, Memphis" or "Engraving by Albrecht Dürer" or "Photograph by Dorothea Lange, AP". The medium (carving, painting, engraving, photograph) should match the era. The description should be plain text (no HTML).

All content fields should use simple HTML (<p>, <strong>, <em>) for formatting.
SYSPROMPT
)

  local prev_issue="$2"

  local user_prompt="Write the gazette for Turn ${turn} (${year_display}).

Game context:
${context}"

  if [ -n "$prev_issue" ] && [ "$prev_issue" != "null" ]; then
    user_prompt="${user_prompt}

Previous issue of The Civ Chronicle:
${prev_issue}"
  fi

  local request_body
  request_body=$(jq -n \
    --arg system "$system_prompt" \
    --arg user "$user_prompt" \
    '{
      model: "gpt-5.4",
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ],
      temperature: 0.9,
      max_completion_tokens: 3000,
      response_format: {type: "json_object"}
    }')

  local response
  response=$(curl -s --max-time 60 \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$request_body" \
    "https://api.openai.com/v1/chat/completions")

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$content" ]; then
    echo "[gazette] OpenAI call failed for turn $turn" >&2
    echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
    return 1
  fi

  # Validate it's JSON with expected fields
  if ! echo "$content" | jq -e '.headline and .sections and .opinion and .letters' >/dev/null 2>&1; then
    echo "[gazette] Invalid response format for turn $turn" >&2
    echo "$content" >&2
    return 1
  fi

  echo "$content"
}

# ---------------------------------------------------------------------------
# Generate a front-page illustration using Gemini image generation
# ---------------------------------------------------------------------------
generate_illustration() {
  local headline="$1"
  local year="$2"
  local target_turn="$3"
  local front_page_text="$4"
  local art_credit="$5"
  local illustration_desc="$6"

  # API key: env var > .env file > file in save dir
  local api_key="${GEMINI_API_KEY:-}"
  if [ -z "$api_key" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    api_key=$(grep '^GEMINI_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^GEMINI_API_KEY=//' | tr -d '[:space:]"'"'")
  fi
  if [ -z "$api_key" ] && [ -f "$SAVE_DIR/gemini_api_key" ]; then
    api_key=$(cat "$SAVE_DIR/gemini_api_key" | tr -d '[:space:]')
  fi
  if [ -z "$api_key" ]; then
    echo "[gazette] No Gemini API key found, skipping illustration" >&2
    return 1
  fi

  # Pick art style based on era
  local art_style
  if [ "$year" -lt -1000 ] 2>/dev/null; then
    art_style="ancient Mesopotamian/Egyptian stone relief carving style, carved into sandstone, hieroglyphic border elements"
  elif [ "$year" -lt 500 ] 2>/dev/null; then
    art_style="classical Greek/Roman mosaic or red-figure pottery style, terracotta and black tones"
  elif [ "$year" -lt 1400 ] 2>/dev/null; then
    art_style="medieval illuminated manuscript style, gold leaf accents, rich colors on parchment"
  elif [ "$year" -lt 1800 ] 2>/dev/null; then
    art_style="Renaissance woodcut engraving style, fine black ink crosshatching on cream paper"
  else
    art_style="vintage newspaper editorial illustration, pen and ink sketch style, crosshatched shading"
  fi

  # Strip HTML from front page text for the prompt
  local clean_text
  clean_text=$(echo "$front_page_text" | sed 's/<[^>]*>//g' | head -c 500)

  # Add artist style if available
  local artist_style=""
  if [ -n "$art_credit" ]; then
    artist_style="In the style described by: ${art_credit}. "
  fi
  local scene_desc="${clean_text}"
  if [ -n "$illustration_desc" ]; then
    scene_desc="Scene to depict: ${illustration_desc}. Context: ${clean_text}"
  fi

  local prompt="Generate a small newspaper illustration. ${artist_style}Style: ${art_style}. ${scene_desc}. No text or words in the image. Square format, detailed."

  local request_body
  request_body=$(jq -n \
    --arg prompt "$prompt" \
    '{
      contents: [{
        parts: [{text: $prompt}]
      }],
      generationConfig: {
        responseModalities: ["Text", "Image"],
        temperature: 0.8,
        imageConfig: {
          imageSize: "1K"
        }
      }
    }')

  echo "[gazette] Generating illustration for turn $target_turn..." >&2
  local response
  response=$(curl -s --max-time 60 \
    -H "x-goog-api-key: $api_key" \
    -H "Content-Type: application/json" \
    -d "$request_body" \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent")

  # Extract base64 image data from response
  local image_data
  image_data=$(echo "$response" | jq -r '.candidates[0].content.parts[] | select(.inlineData) | .inlineData.data // empty' 2>/dev/null | head -1)

  if [ -z "$image_data" ]; then
    echo "[gazette] Gemini image generation failed for turn $target_turn" >&2
    echo "$response" | jq -r '.error.message // empty' >&2 2>/dev/null
    return 1
  fi

  # Save image
  local filename="gazette-${target_turn}.png"
  echo "$image_data" | base64 -d > "$WEBROOT/$filename"
  echo "[gazette] Saved illustration: $filename" >&2
  echo "$filename"
}

# ---------------------------------------------------------------------------
# Process a single turn
# ---------------------------------------------------------------------------
process_turn() {
  local target_turn="$1"

  # Skip if already generated
  local exists
  exists=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn == $t)] | length')
  if [ "$exists" -gt 0 ] && [ "$REBUILD" = "false" ]; then
    echo "[gazette] Turn $target_turn already exists, skipping"
    return 0
  fi

  echo "[gazette] Generating gazette for turn $target_turn..."
  local context
  context=$(build_turn_context "$target_turn")
  [ "$context" = "{}" ] && { echo "[gazette] No history data for turn $target_turn"; return 0; }

  # Get previous issue for continuity
  local prev_issue
  prev_issue=$(echo "$GAZETTE_JSON" | jq --argjson t "$((target_turn - 1))" '[.[] | select(.turn == $t)] | .[0] // null')

  local entry
  entry=$(generate_entry "$context" "$prev_issue") || return 1

  local year
  year=$(echo "$context" | jq -r '.year')
  local year_display
  year_display=$(echo "$context" | jq -r '.year_display')

  # Generate front-page illustration
  local illustration=""
  local headline fp_content ill_artist ill_desc
  headline=$(echo "$entry" | jq -r '.headline')
  fp_content=$(echo "$entry" | jq -r '.sections.front_page.content // .sections.front_page // ""')
  ill_credit=$(echo "$entry" | jq -r '.illustration_caption.credit // ""')
  ill_desc=$(echo "$entry" | jq -r '.illustration_caption.description // ""')
  illustration=$(generate_illustration "$headline" "$year" "$target_turn" "$fp_content" "$ill_credit" "$ill_desc") || true

  # Remove existing entry for this turn if rebuilding
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn != $t)]')

  # Add new entry
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" --argjson y "$year" \
    --arg yd "$year_display" --argjson entry "$entry" --arg img "$illustration" \
    '. + [{
      turn: $t,
      year: $y,
      year_display: $yd,
      headline: $entry.headline,
      sections: $entry.sections,
      opinion: $entry.opinion,
      letters: $entry.letters,
      ads: ($entry.ads // []),
      corrections: ($entry.corrections // null),
      illustration: (if $img != "" then $img else null end),
      illustration_caption: ($entry.illustration_caption // null)
    }] | sort_by(.turn)')

  # Save after each entry
  echo "$GAZETTE_JSON" > "$GAZETTE_FILE.tmp"
  mv "$GAZETTE_FILE.tmp" "$GAZETTE_FILE"
  ln -sf "$GAZETTE_FILE" "$WEBROOT/gazette.json"

  echo "[gazette] Generated: $(echo "$entry" | jq -r '.headline')"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$REBUILD" = "true" ]; then
  echo "[gazette] Rebuilding gazette for all turns..."
  GAZETTE_JSON="[]"
  [ ! -f "$HISTORY_FILE" ] && { echo "[gazette] No history.json found"; exit 0; }
  TURNS=$(jq -r '.[].turn' "$HISTORY_FILE" | sort -n)
  # Skip turn 1 (no previous turn to compare), skip the latest (in progress)
  LAST_TURN=$(echo "$TURNS" | tail -1)
  for t in $TURNS; do
    [ "$t" -le 1 ] 2>/dev/null && continue
    [ "$t" -eq "$LAST_TURN" ] 2>/dev/null && continue
    process_turn "$t"
    sleep 1  # rate limit courtesy
  done
  echo "[gazette] Rebuild complete: $(echo "$GAZETTE_JSON" | jq 'length') entries"
else
  [ -z "$TURN" ] && { echo "Usage: $0 <turn> [year]  or  $0 --rebuild"; exit 1; }
  # Generate for the PREVIOUS turn (current turn just started, previous is complete)
  PREV_TURN=$((TURN - 1))
  [ "$PREV_TURN" -le 1 ] && { echo "[gazette] Too early for gazette (turn $PREV_TURN)"; exit 0; }
  process_turn "$PREV_TURN"
fi

echo "[gazette] Done"
