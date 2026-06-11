# ─────────────────────────────────────────────────────────────────────────────
# ExplorationSessionLibrary.py
#
# Robot Framework library — Exploration Session Management
# Companion to DomParserLibrary.py
# ─────────────────────────────────────────────────────────────────────────────

import json
import os
import re
from datetime import datetime, timezone
from robot.api.deco import keyword


class ExplorationSessionLibrary:

    ROBOT_LIBRARY_SCOPE = 'GLOBAL'

    # ─────────────────────────────────────────────────────────────────────────
    # INIT
    # ─────────────────────────────────────────────────────────────────────────

    def __init__(self):
        self._session: dict = {}
        self._session_file_path: str = ''
        self._element_index: dict = {}
        self._coverage_sets: dict = {}

    # ─────────────────────────────────────────────────────────────────────────
    # LOAD / SAVE / CREATE
    # ─────────────────────────────────────────────────────────────────────────

    @keyword("Load Exploration Session")
    def load_exploration_session(self, session_file_path: str) -> dict:
        """
        Loads the session JSON from disk into memory and builds the cache.
        Returns the full session dict.
        """
        if not os.path.exists(session_file_path):
            raise FileNotFoundError(f"Session file not found: {session_file_path}")

        with open(session_file_path, 'r', encoding='utf-8') as f:
            self._session = json.load(f)

        self._session_file_path = session_file_path
        self._rebuild_cache()
        return self._session

    @keyword("Create Exploration Session")
    def create_exploration_session(
        self,
        object_name: str,
        start_state: str,
        session_file_path: str = None,
    ) -> dict:
        """
        Initialises a brand-new in-memory session for the given object.
        No file needs to exist on disk — session is built from scratch.
        Optionally accepts a file path for where Save Exploration Session
        will write the output. Defaults to OUTPUT_DIR/exploration_{object}.json
        if not provided.
        """
        if not session_file_path:
            output_dir = os.environ.get('ROBOT_OUTPUT_DIR', os.getcwd())
            session_file_path = os.path.join(
                output_dir, f"exploration_{_slug(object_name)}.json"
            )

        self._session_file_path = session_file_path
        self._element_index = {}
        self._coverage_sets = {}

        self._session = {
            'exploration_session': {
                'object_name': object_name,
                'start_state': start_state,
                'created_at': _utc_now(),
                'last_updated': _utc_now(),
                'states': {},
                'tab_inventory': [],
                'interaction_log': [],
                'coverage_summary': {
                    'total_states_discovered': 0,
                    'total_elements_observed': 0,
                    'total_elements_attempted': 0,
                    'total_elements_resolved': 0,
                    'total_elements_skipped': 0,
                    'tabs_visited': 0,
                    'tabs_total': 0,
                    'pct_complete': 0,
                },
            }
        }

        return self._session

    @keyword("Save Exploration Session")
    def save_exploration_session(self) -> None:
        """
        Flushes the in-memory cache back into _session and writes to disk.
        """
        self._require_session()
        self._flush_cache_to_session()

        # BUG FIX #2: these were merged onto one line
        self._session['exploration_session']['last_updated'] = _utc_now()

        with open(self._session_file_path, 'w', encoding='utf-8') as f:
            json.dump(self._session, f, indent=4)

    # ─────────────────────────────────────────────────────────────────────────
    # STATE REGISTRATION
    # ─────────────────────────────────────────────────────────────────────────

    @keyword("Register New State")
    def register_new_state(
        self,
        state_key: str,
        page_name: str,
        page_title: str,
        url_pattern: str,
        view_type: str,
        active_tab: str = None,
        modal_title: str = None,
        is_modal_open: bool = False,
        capture_trigger: str = 'navigation',
    ) -> None:
        """
        Adds a new state slot to the session and cache if it doesn't exist.
        Safe to call multiple times — will not overwrite an existing state.
        """
        self._require_session()

        states = self._session['exploration_session'].setdefault('states', {})
        if state_key in states:
            return

        states[state_key] = {
            'page_context': {
                'state_key': state_key,
                'page_name': page_name,
                'page_title': page_title,
                'url_pattern': url_pattern,
                'view_type': view_type,
                'active_tab': active_tab,
                'modal_title': modal_title,
                'is_modal_open': is_modal_open,
                'captured_at': _utc_now(),
                'capture_trigger': capture_trigger,
            },
            'active_elements': [],
            'coverage': {
                'observed': [],
                'attempted': [],
                'resolved': [],
                'skipped': [],
            },
        }

        self._coverage_sets[state_key] = {
            'observed': set(),
            'attempted': set(),
            'resolved': set(),
            'skipped': set(),
        }

        self._update_coverage_summary()

    # ─────────────────────────────────────────────────────────────────────────
    # ELEMENT INGESTION
    # ─────────────────────────────────────────────────────────────────────────

    @keyword("Ingest Parsed Elements Into State")
    def ingest_parsed_elements_into_state(
        self, state_key: str, parsed_elements_json: str
    ) -> int:
        """
        Merges the JSON output of DomParserLibrary's 'Parse Elements From HTML'
        into the given state's element list and cache index.
        Returns the count of newly added elements.
        """
        self._require_session()
        self._require_state(state_key)

        try:
            incoming = json.loads(parsed_elements_json)
        except Exception as e:
            raise ValueError(f"Invalid JSON from Parse Elements From HTML: {e}")

        states = self._session['exploration_session']['states']
        state = states[state_key]
        existing_elements = state.setdefault('active_elements', [])

        coverage = self._coverage_sets.setdefault(state_key, {
            'observed': set(), 'attempted': set(),
            'resolved': set(), 'skipped': set(),
        })

        # BUG FIX #3: 'added = 0' was merged onto the closing }) line
        added = 0
        for el in incoming:
            element_id = self._build_element_id(el)
            cache_key = f"{state_key}:{element_id}"

            if cache_key in self._element_index:
                continue

            el['element_id'] = element_id
            el['exploration'] = {
                'status': 'observed',
                'interaction_attempts': [],
                'resolved_outcome': None,
            }

            existing_elements.append(el)
            self._element_index[cache_key] = el
            coverage['observed'].add(element_id)
            added += 1

        self._update_coverage_summary()
        return added

    # ─────────────────────────────────────────────────────────────────────────
    # ELEMENT QUEUING
    # ─────────────────────────────────────────────────────────────────────────

    @keyword("Get Next Tab To Visit")
    def get_next_tab_to_visit(self) -> dict:
        """
        Returns the next tab in tab_inventory where visited == False.
        Returns an empty dict if all tabs have been visited.
        """
        self._require_session()
        tabs = self._session['exploration_session'].get('tab_inventory', [])
        for tab in tabs:
            if not tab.get('visited', False):
                return tab
        return {}

    @keyword("Get Next Element To Interact")
    def get_next_element_to_interact(self, state_key: str) -> dict:
        """
        Returns the next actionable element in the given state that has not
        yet been attempted, resolved, or skipped.
        Returns an empty dict when nothing remains.
        """
        self._require_session()
        self._require_state(state_key)

        coverage = self._coverage_sets.get(state_key, {})
        observed = coverage.get('observed', set())
        attempted = coverage.get('attempted', set())
        resolved = coverage.get('resolved', set())
        skipped = coverage.get('skipped', set())

        state = self._session['exploration_session']['states'][state_key]

        for element in state.get('active_elements', []):
            element_id = element.get('element_id')
            if not element_id:
                continue

            if element_id not in observed:
                continue
            if element_id in attempted or element_id in resolved or element_id in skipped:
                continue

            if element.get('is_output_only'):
                continue

            ctx = element.get('context') or {}
            if ctx.get('is_background'):
                continue

            # BUG FIX #4: '# Skip disabled' comment was dedented, breaking the block
            validation = element.get('validation') or {}
            behavioral = element.get('behavioral_metadata') or {}
            if validation.get('disabled') or behavioral.get('is_disabled'):
                continue

            return element

        return {}

    # ─────────────────────────────────────────────────────────────────────────
    # COVERAGE TRACKING
    # ─────────────────────────────────────────────────────────────────────────

    # BUG FIX #4 (cont): @keyword("Update Coverage") was concatenated onto
    # the closing brace of get_next_element_to_interact with no newline
    @keyword("Update Coverage")
    def update_coverage(
        self, state_key: str, element_id: str, status: str
    ) -> None:
        """
        Promotes an element to the given status in the coverage cache.
        Status must be one of: observed | attempted | resolved | skipped
        """
        VALID = {'observed', 'attempted', 'resolved', 'skipped'}
        PROMOTION_ORDER = ['observed', 'attempted', 'resolved', 'skipped']

        if status not in VALID:
            raise ValueError(f"Invalid status '{status}'. Must be one of: {VALID}")

        self._require_session()
        self._require_state(state_key)

        coverage = self._coverage_sets.setdefault(state_key, {
            'observed': set(), 'attempted': set(),
            'resolved': set(), 'skipped': set(),
        })

        target_index = PROMOTION_ORDER.index(status)

        for i, bucket in enumerate(PROMOTION_ORDER):
            if i < target_index:
                coverage[bucket].discard(element_id)

        coverage[status].add(element_id)

        cache_key = f"{state_key}:{element_id}"
        el = self._element_index.get(cache_key)
        if el:
            el.setdefault('exploration', {})['status'] = status

        self._update_coverage_summary()

    # ─────────────────────────────────────────────────────────────────────────
    # INTERACTION LOGGING
    # ─────────────────────────────────────────────────────────────────────────

    @keyword("Record Interaction Outcome")
    def record_interaction_outcome(
        self,
        state_key: str,
        element_id: str,
        action_type: str,
        locator_used: str,
        locator_strategy: str,
        succeeded: bool,
        value_used: str = None,
        state_changed: bool = False,
        new_state_key: str = None,
        elements_appeared: list = None,
        elements_disappeared: list = None,
        dropdown_options_captured: list = None,
    ) -> str:
        """
        Appends a full interaction record to interaction_log.
        Returns the log_id of the new entry (e.g. 'il_007').
        """
        self._require_session()

        session = self._session['exploration_session']
        log = session.setdefault('interaction_log', [])
        log_id = f"il_{str(len(log) + 1).zfill(3)}"

        # BUG FIX #5: timestamp = _utc_now() and entry = { were on the same line
        timestamp = _utc_now()

        entry = {
            'log_id': log_id,
            'state_key': state_key,
            'element_id': element_id,
            'action_type': action_type,
            'locator_used': locator_used,
            'locator_strategy': locator_strategy,
            'value_used': value_used,
            'succeeded': succeeded,
            'outcome': {
                'state_changed': state_changed,
                'new_state_key': new_state_key,
                'elements_appeared': elements_appeared or [],
                'elements_disappeared': elements_disappeared or [],
                'dropdown_options_captured': dropdown_options_captured or [],
            },
            'timestamp': timestamp,
        }
        log.append(entry)

        cache_key = f"{state_key}:{element_id}"
        el = self._element_index.get(cache_key)
        if el:
            exploration = el.setdefault('exploration', {})
            attempts = exploration.setdefault('interaction_attempts', [])
            attempts.append({
                'action_type': action_type,
                'value_used': value_used,
                'locator_strategy': locator_strategy,
                'locator_used': locator_used,
                'succeeded': succeeded,
                'timestamp': timestamp,
            })
            if succeeded:
                exploration['resolved_outcome'] = {
                    'state_changed': state_changed,
                    'new_state_key': new_state_key,
                    'elements_appeared': elements_appeared or [],
                    'elements_disappeared': elements_disappeared or [],
                }

        return log_id

    @keyword("Mark Tab Visited")
    def mark_tab_visited(self, tab_label: str) -> None:
        """
        Marks a tab in tab_inventory as visited = True by its label.
        """
        self._require_session()
        tabs = self._session['exploration_session'].get('tab_inventory', [])
        for tab in tabs:
            if tab.get('label') == tab_label:
                tab['visited'] = True
                self._update_coverage_summary()
                return

    @keyword("Get Session Coverage Summary")
    def get_session_coverage_summary(self) -> dict:
        """
        Returns the current coverage_summary block from the session.
        """
        self._require_session()
        self._update_coverage_summary()
        return self._session['exploration_session'].get('coverage_summary', {})

    @keyword("Get Element From Cache")
    def get_element_from_cache(self, state_key: str, element_id: str) -> dict:
        """
        Direct O(1) cache lookup by compound key.
        Returns the element dict or an empty dict if not found.
        """
        cache_key = f"{state_key}:{element_id}"
        return self._element_index.get(cache_key, {})

    # ─────────────────────────────────────────────────────────────────────────
    # INTERNAL — CACHE MANAGEMENT
    # ─────────────────────────────────────────────────────────────────────────

    def _rebuild_cache(self) -> None:
        """
        Rebuilds _element_index and _coverage_sets from the loaded session.
        """
        self._element_index = {}
        self._coverage_sets = {}

        states = self._session.get('exploration_session', {}).get('states', {})

        # BUG FIX #6: 'for state_key' was merged onto the states = ... line
        for state_key, state in states.items():
            raw_coverage = state.get('coverage', {})
            self._coverage_sets[state_key] = {
                'observed': set(raw_coverage.get('observed', [])),
                'attempted': set(raw_coverage.get('attempted', [])),
                'resolved': set(raw_coverage.get('resolved', [])),
                'skipped': set(raw_coverage.get('skipped', [])),
            }

            for el in state.get('active_elements', []):
                element_id = el.get('element_id')
                if element_id:
                    cache_key = f"{state_key}:{element_id}"
                    self._element_index[cache_key] = el

    def _flush_cache_to_session(self) -> None:
        """
        Writes coverage sets back to the session JSON structure as lists.
        """
        states = self._session.get('exploration_session', {}).get('states', {})

        for state_key, state in states.items():
            sets = self._coverage_sets.get(state_key, {})
            state['coverage'] = {
                'observed': sorted(sets.get('observed', set())),
                'attempted': sorted(sets.get('attempted', set())),
                'resolved': sorted(sets.get('resolved', set())),
                'skipped': sorted(sets.get('skipped', set())),
            }

    def _update_coverage_summary(self) -> None:
        """Recalculates coverage_summary from cache sets."""
        session = self._session.get('exploration_session', {})
        tabs = session.get('tab_inventory', [])

        total_observed = 0
        total_attempted = 0
        total_resolved = 0
        total_skipped = 0

        for sets in self._coverage_sets.values():
            total_observed += len(sets.get('observed', set()))
            total_attempted += len(sets.get('attempted', set()))
            total_resolved += len(sets.get('resolved', set()))
            total_skipped += len(sets.get('skipped', set()))

        tabs_visited = sum(1 for t in tabs if t.get('visited'))
        tabs_total = len(tabs)
        total_elements = total_observed + total_skipped
        pct = round((total_resolved / total_elements) * 100) if total_elements > 0 else 0

        # BUG FIX #7: this assignment was dedented to module level
        session['coverage_summary'] = {
            'total_states_discovered': len(session.get('states', {})),
            'total_elements_observed': total_observed,
            'total_elements_attempted': total_attempted,
            'total_elements_resolved': total_resolved,
            'total_elements_skipped': total_skipped,
            'tabs_visited': tabs_visited,
            'tabs_total': tabs_total,
            'pct_complete': pct,
        }

    # ─────────────────────────────────────────────────────────────────────────
    # INTERNAL — ELEMENT ID BUILDER
    # ─────────────────────────────────────────────────────────────────────────

    # BUG FIX #8: def _build_element_id was concatenated onto the comment block
    def _build_element_id(self, el: dict) -> str:
        """
        Builds a deterministic element_id from key fields.
        Format: label|type|section|tag  (all slugified, max 30 chars each)
        """
        label = (el.get('identification') or {}).get('label_text', 'unlabeled')
        el_type = el.get('element_type', 'unknown')
        section = (
            (el.get('context') or {}).get('modal_title') or
            (el.get('context') or {}).get('form_section') or
            (el.get('context') or {}).get('active_tab') or
            'global'
        )
        tag = (el.get('element_details') or {}).get('tag', 'unknown')

        return '|'.join([
            _slug(label),
            _slug(el_type),
            _slug(section),
            _slug(tag),
        ])

    # ─────────────────────────────────────────────────────────────────────────
    # INTERNAL — GUARDS
    # ─────────────────────────────────────────────────────────────────────────

    def _require_session(self) -> None:
        if not self._session:
            raise RuntimeError(
                "No session loaded. Call 'Load Exploration Session' first."
            )

    def _require_state(self, state_key: str) -> None:
        states = self._session.get('exploration_session', {}).get('states', {})
        if state_key not in states:
            raise ValueError(
                f"State key '{state_key}' not found. "
                f"Call 'Register New State' before interacting with it."
            )


# ─────────────────────────────────────────────────────────────────────────────
# MODULE-LEVEL HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _slug(s: str, max_len: int = 30) -> str:
    return re.sub(r'[^a-z0-9_]', '_', (s or 'null').lower())[:max_len].strip('_')