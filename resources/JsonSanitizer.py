"""
JsonSanitizer.py  —  v2
-----------------------
Robot Framework Python library for safe AI JSON reply parsing.

KEY DESIGN CHANGE vs v1
-----------------------
Step 4 (XPath \\= re-injection) has been REMOVED from the sanitizer.

Reason: re-injecting \\= inside JSON string values produces invalid JSON
escape sequences (\\= is not a valid JSON escape per RFC 8259), which causes
json.JSONDecoder to raise JSONDecodeError at parse time.

The correct contract is:
  - JSON is stored and parsed with BARE = signs (valid JSON).
  - \\= is re-injected ONLY at Robot Framework execution time, by the
    keyword that dispatches the parsed step to ClickElement / TypeText.
  - See: escape_xpath_arg() below, which callers MUST use when building
    the args list for any keyword whose first argument starts with "xpath=".

Import in your .robot file with:
    Library    JsonSanitizer.py
"""

import re
import json


# ---------------------------------------------------------------------------
# Valid single-character JSON escape characters per RFC 8259
# ---------------------------------------------------------------------------
_VALID_JSON_ESCAPES = set('"\\\/bfnrtu')


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def sanitize_ai_json_reply(raw_text: str) -> str:
    """
    Sanitization pipeline for AI-generated JSON reply strings.

    Steps:
      1. Strip markdown code fences  (```json ... ``` or ``` ... ```)
      2. Flatten ALL backslash-equals variants to bare =  (clean slate)
      3. Remove every \\<char> where <char> is NOT a valid JSON escape
         character.  Handles \\', \\!, \\@, and any other AI-injected
         invalid escape by dropping the backslash and keeping the char.

    NOTE: Step 4 (XPath \\= re-injection) intentionally does NOT exist here.
    XPath arguments must be escaped at Robot Framework dispatch time, not
    inside the JSON payload.  Use escape_xpath_arg() for that purpose.

    Returns the sanitized string, ready for json.JSONDecoder().raw_decode().
    """

    # ── STEP 1: Strip markdown fences ──────────────────────────────────────
    text = raw_text.strip()
    text = re.sub(r'^```(?:json)?\s*', '', text, flags=re.DOTALL)
    text = re.sub(r'\s*```$',          '', text, flags=re.DOTALL)
    text = text.strip()

    # ── STEP 2: Flatten all \\= variants to bare = ─────────────────────────
    # Pass A: collapse \\\\= (double-backslash-equals) first to avoid
    #         double-processing when the AI mixes both styles.
    text = text.replace('\\\\=', '=')
    # Pass B: collapse remaining lone \\=
    text = text.replace('\\=', '=')

    # ── STEP 3: Remove all remaining invalid JSON escape sequences ──────────
    # Character-by-character walk: immune to regex escaping ambiguity.
    # Keeps \\<valid_char>, drops \\ when followed by an invalid char.
    result = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '\\' and i + 1 < len(text):
            next_ch = text[i + 1]
            if next_ch in _VALID_JSON_ESCAPES:
                # Valid JSON escape — keep both characters as-is.
                result.append(ch)
                result.append(next_ch)
                i += 2
            else:
                # Invalid JSON escape (e.g. \\', \\!, \\@) — drop the
                # backslash, keep the following character.
                result.append(next_ch)
                i += 2
        else:
            result.append(ch)
            i += 1

    return ''.join(result)


def find_json_start(text: str) -> int:
    """
    Returns the index of the first '{' or '[' in the string.
    Raises ValueError if neither is found.
    """
    brace   = text.find('{')
    bracket = text.find('[')

    candidates = [i for i in [brace, bracket] if i > -1]
    if not candidates:
        raise ValueError(
            "Parser Error: No JSON structure found in AI reply. "
            f"Raw text starts with: {text[:200]!r}"
        )
    return min(candidates)


def parse_ai_json_reply(raw_text: str):
    """
    Full pipeline: sanitize then parse.

    Returns the decoded Python object (dict or list).
    Raises ValueError with a clear diagnostic message on failure,
    including the character position and surrounding context.
    """
    sanitized  = sanitize_ai_json_reply(raw_text)
    start_idx  = find_json_start(sanitized)
    clean_suffix = sanitized[start_idx:]

    try:
        parsed, _ = json.JSONDecoder().raw_decode(clean_suffix)
        return parsed
    except json.JSONDecodeError as exc:
        char_pos      = exc.pos
        context_start = max(0, char_pos - 60)
        context_end   = min(len(clean_suffix), char_pos + 60)
        snippet       = clean_suffix[context_start:context_end]
        raise ValueError(
            f"JSONDecodeError at char {char_pos}: {exc.msg}\n"
            f"Context: ...{snippet!r}..."
        ) from exc


def escape_xpath_arg(arg: str) -> str:
    """
    Re-injects \\= into an XPath argument string for Robot Framework.

    Call this at DISPATCH TIME (when building the keyword call), NOT
    during JSON parsing.  Only transforms strings that start with 'xpath='.

    Example
    -------
    Input  (from parsed JSON):  "xpath=//input[@id='abc']"
    Output (for RF execution):  "xpath=//input[@id\\='abc']"
    """
    if not arg.startswith('xpath='):
        return arg

    prefix = 'xpath='
    body   = arg[len(prefix):]
    # Re-escape every bare = in the predicate body.
    escaped_body = re.sub(r'(?<!\\)=', r'\\=', body)
    return prefix + escaped_body
