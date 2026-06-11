import re
import json
from bs4 import BeautifulSoup, NavigableString
from robot.api.deco import keyword


class DomParserLibrary:
    ROBOT_LIBRARY_SCOPE = 'GLOBAL'

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 1 — NOISE & FILTER CONSTANTS
    # ─────────────────────────────────────────────────────────────────────────────

    NOISE_TAGS = {
        'lightning-icon', 'lightning-badge', 'lightning-pill', 'lightning-spinner',
        'lightning-progress-indicator', 'lightning-helptext', 'lightning-formatted-text',
        'lightning-formatted-url', 'lightning-formatted-date-time',
        'lightning-formatted-number', 'lightning-formatted-phone',
        'lightning-formatted-email', 'lightning-primitive-icon',
        'lightning-primitive-cell-types', 'lightning-primitive-datatable-iedbug',
        'lightning-message-context-consumer', 'lightning-message-context-provider',
        'lightning-relative-date-time',
    }

    NOISE_ROLES = {
        'presentation', 'none', 'separator', 'progressbar',
        'status', 'log', 'alert', 'tooltip',
    }

    NOISE_CLASS_FRAGMENTS = [
        'slds-assistive-text', 'slds-hide', 'slds-is-collapsed',
        'forceRecordCoverPhoto', 'slds-col--padded',
        'slds-resize-handle', 'slds-drag-handle', 'slds-th__action-icon',
    ]

    SHADOW_WRAPPER_TAGS = {
        'lightning-input', 'lightning-textarea', 'lightning-combobox',
        'lightning-picklist', 'lightning-input-address', 'lightning-input-name',
        'lightning-input-field', 'lightning-input-rich-text',
        'lightning-input-location', 'lightning-button', 'lightning-button-icon',
        'lightning-button-menu', 'lightning-button-icon-stateful',
        'lightning-button-group', 'lightning-button-stateful',
        'lightning-popup', 'lst-list-view-manager-pin-button',
        'lst-list-view-manager-settings-menu',
        'lst-list-view-manager-display-switcher', 'lst-list-view-picker',
        'lightning-layout', 'lightning-layout-item', 'lightning-card',
        'lightning-accordion', 'lightning-accordion-section',
        'lightning-tab', 'lightning-tabset', 'lightning-tree',
        'lightning-tree-grid', 'lightning-progress-indicator',
        'lightning-progress-step',
    }

    SKIP_ELEMENT_TYPES = {'picklist_option'}

    SYSTEM_TEXT_BLACKLIST = [
        'Skip to', 'Sorry to interrupt', 'CSS Error', 'Reload Page',
        'dismissError', 'auraErrorReload', 'Skip to Navigation',
        'Skip to Main Content', 'Accessibility Mode', 'Loading...',
        'Please wait', 'Processing',
    ]

    CONTAINER_PATTERNS = [
        r'^c-.*-(builder|wizard|container|wrapper|layout|page|manager|configurator)$',
        r'^flexipage-',
        r'^lightning-(layout|card|accordion|tab|tabset)',
        r'^(div|section|article|main|aside|nav|header|footer|form)$',
    ]

    CONTAINER_CHILD_THRESHOLD = 3
    CONTAINER_TEXT_THRESHOLD = 200

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 2 — DROPDOWN SIGNATURES
    # ─────────────────────────────────────────────────────────────────────────────

    DROPDOWN_SIGNATURES = [
        {
            'tags': ['lightning-combobox', 'lightning-dual-listbox', 'lightning-picklist'],
            'type': 'lightning_combobox',
            'dynamic': True,
        },
        {
            'tags': ['lightning-input'],
            'attributes': {'type': 'combobox'},
            'type': 'lightning_input_combobox',
            'dynamic': True,
        },
        {
            'tags': ['select'],
            'type': 'html_select',
            'dynamic': False,
        },
        {
            'tags': ['select'],
            'attributes': {'class': lambda c: c and 'uiInput' in c},
            'type': 'aura_select',
            'dynamic': False,
        },
        {
            'tags': ['lightning-input-field'],
            'attributes': {'data-field-type': 'Picklist'},
            'type': 'lightning_record_picklist',
            'dynamic': True,
        },
        {
            'tags': lambda t: t and t.startswith('c-'),
            'attributes': {'role': 'combobox'},
            'type': 'custom_lwc_combobox',
            'dynamic': True,
        },
        {
            'tags': ['div', 'button'],
            'attributes': {'role': 'combobox', 'aria-haspopup': 'listbox'},
            'type': 'slds_combobox',
            'dynamic': True,
        },
        {
            'tags': ['select'],
            'attributes': {'id': lambda i: i and ('j_id' in i or ':' in i)},
            'type': 'visualforce_select',
            'dynamic': False,
        },
        {
            'tags': ['select', 'div'],
            'attributes': {'class': lambda c: c and ('sbqq' in c.lower() or 'sb-' in c.lower())},
            'type': 'cpq_dropdown',
            'dynamic': True,
        },
        {
            'tags': lambda t: t and t.startswith('c-omni'),
            'attributes': {'role': lambda r: r in ['combobox', 'listbox']},
            'type': 'omnistudio_dropdown',
            'dynamic': True,
        },
    ]

    OUTPUT_ONLY_TYPES = {'output_field', 'record_view_form', 'badge', 'icon', 'pill'}

    RUNTIME_ID_PREFIXES = [
        'help-message-', 'error-message-',
        'label-', 'listbox-', 'dropdown-element-', 'tooltip-',
        'slds-combobox-', 'slds-listbox-',
    ]

    AURA_RENDER_ID_RE = re.compile(r'^\d+:\d+;[a-z]$')
    AURA_SUFFIXED_NAME_RE = re.compile(r'^(.+?)(:\d+;\w+|:\d+)$')
    RUNTIME_GARBAGE_RE = re.compile(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*-\d+$')

    CSS_POISON_PATTERNS = ['--sds-', '--slds-', '--SBQQ-', '@layer', '{--']

    # CSS class fragments that mark a child element as a supplementary
    # description rather than the primary label. Text from these elements
    # must never be merged into label_text; it is captured separately as
    # the "description" field on the identification block.
    DESCRIPTION_CLASS_FRAGMENTS = [
        'changeRecordTypeItemDescription',
        'changeRecordTypeLabel',
        'slds-form-element__help',
        'slds-form-element__static',
        'helpText',
        'fieldDescription',
        'record-type-description',
        'option-description',
        'item-description',
    ]

    # ─────────────────────────────────────────────────────────────────────────────
    # ENTRY POINT 1 — PARSE ELEMENTS FROM HTML
    # ─────────────────────────────────────────────────────────────────────────────

    @keyword("Parse Elements From HTML")
    def parse_elements_from_html(self, raw_html: str) -> str:
        try:
            soup = BeautifulSoup(raw_html, 'html.parser')
            elements = []

            # ── ERROR PANEL SCAN (must run first) ────────────────────────────
            form_errors = self._extract_form_errors(soup)
            elements.extend(form_errors)
            # ─────────────────────────────────────────────────────────────────

            # Pre-scan: identify datatable and native table descendants to skip
            datatable_descendants = set()
            native_tables = set()

            for tag in soup.find_all(['lightning-datatable', 'lightning-tree-grid']):
                for child in tag.find_all(True):
                    datatable_descendants.add(id(child))

            for tag in soup.find_all('table'):
                has_test_id = tag.get('data-test-id') or tag.get('data-id')
                has_data_rows = (
                    tag.find('tr', attrs={'data-id': True}) or
                    tag.find('tr', attrs={'data-test-id': True})
                )
                if has_test_id or has_data_rows:
                    native_tables.add(id(tag))
                    for child in tag.find_all(True):
                        datatable_descendants.add(id(child))

            for tag in soup.find_all(['lightning-datatable', 'lightning-tree-grid']):
                element_data = self._extract_element_data(tag)
                if element_data and not self._is_scored_duplicate(element_data, elements):
                    elements.append(element_data)

            for tag in soup.find_all('table'):
                if id(tag) in native_tables:
                    element_data = self._extract_element_data(tag)
                    if element_data and not self._is_scored_duplicate(element_data, elements):
                        elements.append(element_data)

            # --- TARGET TAG SCAN ---
            target_tags = [
                'button', 'a', 'input', 'select', 'textarea',
                'lightning-button', 'lightning-button-icon', 'lightning-button-menu',
                'lightning-input', 'lightning-combobox', 'lightning-dual-listbox',
                'lightning-checkbox', 'lightning-checkbox-group', 'lightning-radio-group',
                'lightning-slider', 'lightning-toggle', 'lightning-textarea',
                'lightning-pill', 'lightning-badge',
                'lightning-record-edit-form', 'lightning-record-view-form',
                'lightning-input-field', 'lightning-output-field',
                'c-omniscript', 'c-omni-input', 'c-omni-select', 'c-omni-button',
            ]

            for tag in soup.find_all(target_tags):
                if id(tag) in datatable_descendants:
                    continue
                if self._is_noise(tag):
                    continue
                if self._is_shadow_wrapper(tag):
                    continue
                element_data = self._extract_element_data(tag)
                if element_data:
                    el_type = element_data.get('element_type')
                    if el_type in self.SKIP_ELEMENT_TYPES:
                        continue
                    if not self._is_scored_duplicate(element_data, elements):
                        elements.append(element_data)

            # --- ROLE-BASED SCAN ---
            interactive_roles = [
                'button', 'link', 'checkbox', 'radio', 'tab', 'menuitem',
                'option', 'switch', 'textbox', 'gridcell', 'columnheader',
                'rowheader', 'combobox',
            ]
            for tag in soup.find_all(attrs={'role': lambda r: r in interactive_roles}):
                if id(tag) in datatable_descendants:
                    continue
                if self._is_noise(tag):
                    continue
                if self._is_shadow_wrapper(tag):
                    continue
                element_data = self._extract_element_data(tag, is_custom=True)
                if element_data:
                    el_type = element_data.get('element_type')
                    if el_type in self.SKIP_ELEMENT_TYPES:
                        continue
                    if not self._is_scored_duplicate(element_data, elements):
                        elements.append(element_data)

            # --- CUSTOM LWC SCAN ---
            for tag in soup.find_all(lambda t: t.name and t.name.startswith('c-')):
                if id(tag) in datatable_descendants:
                    continue
                if self._is_noise(tag):
                    continue
                if self._is_container_component(tag):
                    continue
                element_data = self._extract_element_data(tag, is_custom=True)
                if element_data:
                    el_type = element_data.get('element_type')
                    if el_type in self.SKIP_ELEMENT_TYPES:
                        continue
                    if not self._is_scored_duplicate(element_data, elements):
                        elements.append(element_data)

            # Final scored deduplication pass
            elements = self._deduplicate_form_fields(elements)

            # Tag non-modal elements as background when a modal is present
            modal_present = any(
                (el.get('context') or {}).get('is_in_modal')
                for el in elements
            )
            if modal_present:
                for el in elements:
                    ctx = el.get('context') or {}
                    if not ctx.get('is_in_modal'):
                        ctx['is_background'] = True
                        el['context'] = ctx

            return json.dumps(elements, indent=2)

        except Exception as e:
            return json.dumps({
                'error': str(e),
                'error_type': type(e).__name__,
                'message': 'Failed to parse HTML. Check input HTML structure.',
            }, indent=2)

    # ─────────────────────────────────────────────────────────────────────────────
    # FORM ERROR PANEL EXTRACTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _extract_form_errors(self, soup):
        results = []

        error_panels = soup.find_all(
            lambda t: t.name and (
                'forceFormPageError' in ' '.join(t.get('class') or []) or
                t.name == 'records-record-edit-error'
            )
        )

        for dialog in soup.find_all(attrs={'role': 'dialog'}):
            if dialog.find('records-record-edit-error'):
                if dialog not in error_panels:
                    error_panels.append(dialog)

        for panel in error_panels:
            if panel.name == 'records-record-edit-error':
                outer = panel.find_parent(
                    lambda t: t.name and 'forceFormPageError' in ' '.join(t.get('class') or [])
                )
                if outer and outer in error_panels:
                    continue

            title_el = panel.find('h2')
            title_text = self._get_safe_text(title_el) if title_el else 'Form Error'

            notification_el = panel.find(class_='genericNotification')
            notification_text = self._get_safe_text(notification_el) if notification_el else None

            field_errors = []
            errors_list = panel.find('ul', class_='errorsList')
            if errors_list:
                for li in errors_list.find_all('li'):
                    field_label = li.get_text(strip=True)
                    if field_label:
                        anchor = li.find('a')
                        entry = {'field': field_label}
                        if anchor and anchor.get('data-index') is not None:
                            entry['index'] = int(anchor.get('data-index'))
                        field_errors.append(entry)

            if not field_errors:
                for li in panel.find_all('li'):
                    text = li.get_text(strip=True)
                    if text and len(text) < 80:
                        field_errors.append({'field': text})

            if not field_errors and not title_text:
                continue

            behavioral_metadata = {'is_error_panel': True}
            if notification_text:
                behavioral_metadata['error_message'] = notification_text
            if field_errors:
                behavioral_metadata['field_errors'] = field_errors

            element_data = {
                'element_type': 'form_error_panel',
                'element_details': {
                    'tag': panel.name.lower() if panel.name else 'div',
                    'type': None,
                    'attributes': {
                        'role': panel.get('role') or 'dialog',
                        'aria-label': panel.get('aria-label') or title_text,
                        'class': self._get_class_string(panel),
                    },
                },
                'identification': {
                    'label_text': title_text,
                    'label_source': 'inner_text',
                },
                'behavioral_metadata': behavioral_metadata,
                'context': {
                    'is_error_panel': True,
                    'is_in_modal': True,
                },
            }

            results.append(self._prune_empty_values(element_data))

        return results

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 1 — NOISE GATE
    # ─────────────────────────────────────────────────────────────────────────────

    def _is_noise(self, tag):
        if not tag or not hasattr(tag, 'name') or not tag.name:
            return True
        tag_name = tag.name.lower()
        role = (tag.get('role') or '').lower()
        classes = ' '.join(tag.get('class') or [])

        if tag_name in self.NOISE_TAGS:
            return True
        if role in self.NOISE_ROLES:
            return True
        if any(f in classes for f in self.NOISE_CLASS_FRAGMENTS):
            return True
        return False

    def _is_shadow_wrapper(self, tag):
        if not tag or not hasattr(tag, 'name') or not tag.name:
            return False
        return tag.name.lower() in self.SHADOW_WRAPPER_TAGS

    # ─────────────────────────────────────────────────────────────────────────────
    # CONTAINER DETECTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _is_container_component(self, tag):
        if not tag or not hasattr(tag, 'name'):
            return False
        tag_name = tag.name.lower()
        for pattern in self.CONTAINER_PATTERNS:
            if re.match(pattern, tag_name):
                if tag_name.startswith('c-'):
                    return self._validate_custom_container(tag)
                return True
        return False

    def _validate_custom_container(self, tag):
        if not tag:
            return False
        interactive_children = tag.find_all([
            'button', 'input', 'select', 'textarea', 'a',
            'lightning-button', 'lightning-input', 'lightning-combobox',
        ])
        if len(interactive_children) >= self.CONTAINER_CHILD_THRESHOLD:
            return True
        text = tag.get_text(strip=True)
        if len(text) >= self.CONTAINER_TEXT_THRESHOLD:
            return True
        nested_custom = tag.find_all(lambda t: t.name and t.name.startswith('c-'))
        if len(nested_custom) >= 2:
            return True
        return False

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 1 — TEXT EXTRACTION PRIMITIVES
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_safe_text(self, tag, max_len=300):
        """
        Returns the full recursive text content of a tag, stripping noise
        child elements (style, script, svg, etc.) and CSS poison strings.
        Use _get_direct_text() when you need only the tag's own text nodes,
        not the text of its descendants.
        """
        if not tag:
            return ''
        try:
            cloned = BeautifulSoup(str(tag), 'html.parser').find(tag.name)
            if cloned:
                for noise in cloned.find_all(['style', 'script', 'svg', 'canvas', 'iframe', 'noscript']):
                    noise.decompose()
                raw = cloned.get_text(separator=' ', strip=True)
            else:
                raw = tag.get_text(separator=' ', strip=True)
        except Exception:
            raw = tag.get_text(separator=' ', strip=True)

        raw = re.sub(r'\s+', ' ', raw).strip()
        if len(raw) > max_len:
            return ''
        for poison in self.CSS_POISON_PATTERNS:
            if poison in raw:
                return ''
        return raw

    def _get_direct_text(self, tag, max_len=150):
        """
        Returns ONLY the direct NavigableString children of a tag, never
        descending into child elements. This prevents text that belongs to a
        child element (e.g. a description <div> or assistive <span>) from
        being attributed to the parent element (e.g. a <label> or <legend>).

        Use this wherever a label or heading must not absorb the text of its
        nested children.
        """
        if not tag:
            return ''
        parts = []
        for node in tag.children:
            if isinstance(node, NavigableString):
                text = node.strip()
                if text:
                    parts.append(text)
        raw = ' '.join(parts).strip()
        raw = re.sub(r'\s+', ' ', raw)
        if len(raw) > max_len:
            return ''
        for poison in self.CSS_POISON_PATTERNS:
            if poison in raw:
                return ''
        return raw

    def _get_label_span_text(self, container):
        """
        Looks for the dedicated SLDS label span (slds-form-element__label)
        inside a container element and returns its text. This is the cleanest
        source for the human-readable option name inside a wrapping <label>.
        Returns empty string if not found.
        """
        if not container:
            return ''
        span = container.find(class_='slds-form-element__label')
        if span:
            return self._get_safe_text(span)
        return ''

    def _find_description_text(self, tag):
        """
        Searches for supplementary description text associated with an
        interactive element. Description text lives in sibling or cousin
        elements that carry known description CSS class fragments
        (e.g. changeRecordTypeItemDescription, slds-form-element__help).

        This text must NEVER be merged into label_text. It is returned
        separately so the identification block can expose it as its own
        "description" key, giving the AI full context without polluting
        the locator value.

        Search order:
          1. Sibling elements within the same parent column div.
          2. Cousin elements within the wrapping <label>.
          3. aria-describedby reference on the tag itself.
        """
        if not tag:
            return ''

        def _matches_description_class(el):
            classes = ' '.join(el.get('class') or [])
            return any(frag in classes for frag in self.DESCRIPTION_CLASS_FRAGMENTS)

        # Search 1: siblings within the same parent div column
        parent = tag.parent
        if parent and hasattr(parent, 'find_all'):
            for sibling in parent.find_all(True, recursive=False):
                if sibling == tag:
                    continue
                if _matches_description_class(sibling):
                    text = self._get_safe_text(sibling, max_len=300)
                    if text:
                        return text

        # Search 2: anywhere inside the wrapping <label>
        parent_label = tag.find_parent('label')
        if parent_label:
            for desc_el in parent_label.find_all(True):
                if _matches_description_class(desc_el):
                    text = self._get_safe_text(desc_el, max_len=300)
                    if text:
                        return text

        # Search 3: aria-describedby reference
        describedby = tag.get('aria-describedby')
        if describedby:
            root = tag
            while root.parent:
                root = root.parent
            ref_el = root.find(id=describedby)
            if ref_el:
                text = self._get_safe_text(ref_el, max_len=300)
                if text:
                    return text

        return ''

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 3 — ID CLASSIFIER & NAME CLEANER
    # ─────────────────────────────────────────────────────────────────────────────

    def _classify_id(self, id_val):
        if not id_val:
            return None
        if re.match(r'^[a-zA-Z0-9]{15}$', id_val) or re.match(r'^[a-zA-Z0-9]{18}$', id_val):
            return 'salesforce_record_id'
        if self.AURA_RENDER_ID_RE.match(id_val):
            return 'runtime_garbage'
        LOCATOR_ONLY_GARBAGE_PREFIXES = [
            'help-message-', 'error-message-',
            'label-', 'listbox-', 'dropdown-element-', 'tooltip-',
            'slds-combobox-', 'slds-listbox-',
        ]
        if any(id_val.startswith(p) for p in LOCATOR_ONLY_GARBAGE_PREFIXES):
            return 'runtime_garbage'
        if self.RUNTIME_GARBAGE_RE.match(id_val):
            return 'runtime_garbage'
        return 'stable_component_id'

    def _clean_name(self, raw_name):
        if not raw_name:
            return None
        match = self.AURA_SUFFIXED_NAME_RE.match(raw_name)
        if match:
            return match.group(1)
        return raw_name

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 2 — CLASSIFICATION
    # ─────────────────────────────────────────────────────────────────────────────

    def _classify_element_type(self, tag):
        if not tag or not hasattr(tag, 'name') or not tag.name:
            return 'unknown'

        tag_name = tag.name.lower()
        tag_type = (tag.get('type') or '').lower()
        role = (tag.get('role') or '').lower()
        classes = ' '.join(tag.get('class') or []).lower()

        if role == 'option' or 'slds-listbox__option' in classes:
            return 'picklist_option'

        if tag_name == 'lightning-input-field':
            return 'input_field'
        if tag_name == 'lightning-output-field':
            return 'output_field'
        if tag_name == 'lightning-record-edit-form':
            return 'record_edit_form'
        if tag_name == 'lightning-record-view-form':
            return 'record_view_form'
        if tag_name in ('lightning-datatable', 'lightning-tree-grid'):
            return 'datatable'
        if tag_name == 'lightning-tree':
            return 'tree'
        if tag_name == 'lightning-dual-listbox':
            return 'dual_listbox'
        if tag_name in ('lightning-checkbox-group', 'lightning-radio-group'):
            return tag_name.replace('lightning-', '')
        if tag_name == 'lightning-toggle':
            return 'toggle'
        if tag_name == 'lightning-slider':
            return 'slider'
        if tag_name == 'lightning-pill':
            return 'pill'
        if tag_name == 'lightning-badge':
            return 'badge'
        if tag_name == 'lightning-icon':
            return 'icon'

        if tag_name == 'table':
            has_test_id = tag.get('data-test-id') or tag.get('data-id')
            has_data_rows = (
                tag.find('tr', attrs={'data-id': True}) or
                tag.find('tr', attrs={'data-test-id': True})
            )
            if has_test_id or has_data_rows:
                return 'native_table'

        dropdown_info = self._detect_dropdown_type(tag)
        if dropdown_info:
            return 'dropdown'

        if 'textarea' in tag_name:
            return 'textarea'

        if tag_name in ('input', 'lightning-input'):
            if tag_type == 'checkbox':
                return 'checkbox'
            if tag_type == 'radio':
                return 'radio'
            if tag_type == 'password':
                return 'password_field'
            return 'input_field'

        if 'button' in tag_name or role == 'button' or 'slds-button' in classes:
            return 'button'

        if tag_name == 'a':
            return 'button' if role == 'button' else 'link'

        if role == 'checkbox':
            return 'checkbox'
        if role == 'radio':
            return 'radio'

        if tag_name.startswith('c-omni'):
            return 'omniscript_element'

        if tag_name.startswith('c-'):
            if role in ('button', 'link'):
                return role
            if 'button' in tag_name:
                return 'button'
            if 'input' in tag_name:
                return 'input_field'
            return 'custom_component'

        return 'unknown'

    # ─────────────────────────────────────────────────────────────────────────────
    # DROPDOWN DETECTION & EXTRACTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _detect_dropdown_type(self, tag):
        if not tag or not hasattr(tag, 'name') or not tag.name:
            return None
        tag_name = tag.name.lower()

        for sig in self.DROPDOWN_SIGNATURES:
            tag_match = False
            if callable(sig['tags']):
                tag_match = sig['tags'](tag_name)
            elif isinstance(sig['tags'], list):
                tag_match = tag_name in sig['tags']

            if not tag_match:
                continue

            if 'attributes' in sig:
                attr_match = True
                for attr_key, attr_value in sig['attributes'].items():
                    tag_attr = tag.get(attr_key)
                    if callable(attr_value):
                        if not attr_value(tag_attr):
                            attr_match = False
                            break
                    elif tag_attr != attr_value:
                        attr_match = False
                        break
                if not attr_match:
                    continue

            return {
                'dropdown_type': sig['type'],
                'is_dynamic': sig.get('dynamic', True),
                'tag_name': tag_name,
            }
        return None

    def _extract_dropdown_options(self, tag):
        if not tag:
            return None
        dropdown_info = self._detect_dropdown_type(tag)
        if not dropdown_info:
            return None

        dropdown_type = dropdown_info['dropdown_type']
        is_dynamic = dropdown_info['is_dynamic']

        if dropdown_type in ('html_select', 'aura_select', 'visualforce_select'):
            return self._extract_static_select_options(tag)

        if is_dynamic:
            if dropdown_type == 'lightning_combobox':
                return self._extract_lightning_combobox_options(tag)
            elif dropdown_type == 'slds_combobox':
                listbox = self._find_adjacent_listbox(tag)
                if listbox:
                    return self._extract_slds_listbox_options(listbox)
            elif dropdown_type == 'lightning_record_picklist':
                return self._extract_lightning_record_picklist_options(tag)
            elif dropdown_type == 'custom_lwc_combobox':
                parent = tag.find_parent()
                if parent:
                    listbox = parent.find(attrs={'role': 'listbox'})
                    if listbox:
                        return self._extract_slds_listbox_options(listbox)
            elif dropdown_type in ('cpq_dropdown', 'omnistudio_dropdown'):
                if tag.name == 'select':
                    return self._extract_static_select_options(tag)
                listbox = self._find_adjacent_listbox(tag)
                if listbox:
                    return self._extract_slds_listbox_options(listbox)
        return None

    def _extract_static_select_options(self, tag):
        if not tag or tag.name != 'select':
            return None
        options = []
        for opt in tag.find_all('option'):
            option_data = {
                'value': opt.get('value', ''),
                'label': opt.get_text(strip=True),
            }
            if opt.get('selected'):
                option_data['selected'] = True
            if opt.get('disabled'):
                option_data['disabled'] = True
            if option_data['label'] or option_data['value']:
                options.append(option_data)
        return options if options else None

    def _extract_lightning_combobox_options(self, tag):
        combobox = tag if tag.name == 'lightning-combobox' else tag.find_parent('lightning-combobox')
        if not combobox:
            return None
        option_items = combobox.find_all('lightning-base-combobox-item', {'role': 'option'})
        if not option_items:
            return None
        options = []
        for item in option_items:
            option_data = {
                'value': item.get('data-value', ''),
                'label': item.get_text(strip=True),
            }
            if item.get('aria-selected') == 'true':
                option_data['selected'] = True
            if option_data['label'] or option_data['value']:
                options.append(option_data)
        return options if options else None

    def _find_adjacent_listbox(self, tag):
        if not tag:
            return None
        listbox = tag.find_next_sibling(attrs={'role': 'listbox'})
        if listbox:
            return listbox
        parent = tag.parent
        if parent:
            listbox = parent.find_next_sibling(attrs={'role': 'listbox'})
            if listbox:
                return listbox
        container = tag.find_parent(attrs={'class': lambda c: c and 'slds-combobox' in (
            ' '.join(c) if isinstance(c, list) else c
        )})
        if container:
            listbox = container.find(attrs={'role': 'listbox'})
            if listbox:
                return listbox
        if parent and parent.parent:
            listbox = parent.parent.find(attrs={'role': 'listbox'})
            if listbox:
                return listbox
        return None

    def _extract_slds_listbox_options(self, listbox):
        if not listbox:
            return None
        option_elements = listbox.find_all(attrs={'role': 'option'})
        if not option_elements:
            return None
        options = []
        for opt in option_elements:
            option_data = {
                'value': opt.get('data-value', '') or opt.get('data-item-id', ''),
                'label': opt.get_text(strip=True),
            }
            if opt.get('aria-selected') == 'true':
                option_data['selected'] = True
            if option_data['label'] or option_data['value']:
                options.append(option_data)
        return options if options else None

    def _extract_lightning_record_picklist_options(self, tag):
        input_field = tag if tag.name == 'lightning-input-field' else tag.find_parent('lightning-input-field')
        if not input_field:
            return None
        combobox = input_field.find('lightning-combobox')
        if combobox:
            return self._extract_lightning_combobox_options(combobox)
        listbox = input_field.find(attrs={'role': 'listbox'})
        if listbox:
            return self._extract_slds_listbox_options(listbox)
        return None

    # ─────────────────────────────────────────────────────────────────────────────
    # ELEMENT DATA EXTRACTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _extract_element_data(self, tag, is_custom=False):
        if not tag:
            return None
        try:
            if self._is_container_component(tag):
                return None

            element_type = self._classify_element_type(tag)

            if element_type in self.SKIP_ELEMENT_TYPES:
                return None

            identification = self._get_identification(tag)

            label_text = identification.get('label_text', '')
            if label_text and any(b in label_text for b in self.SYSTEM_TEXT_BLACKLIST):
                return None

            behavioral_metadata = self._get_behavioral_metadata(tag, element_type)
            validation = self._get_validation(tag)

            structure = None
            if element_type in ('input_field', 'dropdown', 'textarea'):
                structure = self._detect_structural_pattern(tag)

            dropdown_data = None
            if element_type == 'dropdown':
                dropdown_info = self._detect_dropdown_type(tag)
                dropdown_options = self._extract_dropdown_options(tag)
                dropdown_data = {
                    'dropdown_type': dropdown_info.get('dropdown_type') if dropdown_info else 'unknown',
                    'is_dynamic': dropdown_info.get('is_dynamic', True) if dropdown_info else True,
                }
                if dropdown_options:
                    dropdown_data['options'] = dropdown_options
                    dropdown_data['options_available'] = True
                else:
                    dropdown_data['options_available'] = False
                    dropdown_data['note'] = 'Options not in DOM — dropdown may be closed or loads dynamically'

            context = self._get_context_info(tag)
            qforce_hints = self._get_qforce_hints(element_type, identification, structure)
            is_output_only = element_type in self.OUTPUT_ONLY_TYPES

            element_data = {
                'element_type': element_type,
                'element_details': {
                    'tag': tag.name.lower() if tag.name else 'unknown',
                    'type': tag.get('type') or None,
                    'attributes': self._get_key_attributes(tag),
                },
                'identification': identification,
            }

            if behavioral_metadata:
                element_data['behavioral_metadata'] = behavioral_metadata
            if validation:
                element_data['validation'] = validation
            if structure:
                element_data['structure'] = structure
            if dropdown_data:
                element_data['dropdown'] = dropdown_data
            if context:
                element_data['context'] = context
            if qforce_hints:
                element_data['qforce_hints'] = qforce_hints
            if is_output_only:
                element_data['is_output_only'] = True

            return self._prune_empty_values(element_data)

        except Exception:
            return None

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 4 — BEHAVIORAL METADATA
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_behavioral_metadata(self, tag, element_type):
        metadata = {}
        tag_name = tag.name.lower() if tag.name else ''

        if tag.get('required') is not None or tag.get('aria-required') == 'true':
            metadata['is_required'] = True
        if tag.get('disabled') is not None or tag.get('aria-disabled') == 'true':
            metadata['is_disabled'] = True
        if tag.get('readonly') is not None or tag.get('aria-readonly') == 'true':
            metadata['is_readonly'] = True

        def _has_error_signal(node):
            if not node or not hasattr(node, 'get'):
                return False
            classes = ' '.join(node.get('class') or [])
            return node.get('aria-invalid') == 'true' or 'slds-has-error' in classes

        error_found = _has_error_signal(tag)
        if not error_found:
            walker = tag.parent
            for _ in range(3):
                if not walker or not hasattr(walker, 'get'):
                    break
                if _has_error_signal(walker):
                    error_found = True
                    break
                walker = walker.parent if hasattr(walker, 'parent') else None
        if error_found:
            metadata['has_error'] = True

        aria_expanded = tag.get('aria-expanded')
        if aria_expanded is not None:
            metadata['is_expanded'] = aria_expanded == 'true'

        aria_selected = tag.get('aria-selected')
        if aria_selected is not None:
            metadata['is_selected'] = aria_selected == 'true'

        aria_checked = tag.get('aria-checked')
        if aria_checked is not None:
            metadata['is_checked'] = aria_checked == 'true'

        VALUE_CAPTURE_TYPES = {
            'input_field', 'textarea', 'dropdown', 'toggle',
            'slider', 'checkbox', 'radio', 'dual_listbox',
        }
        is_password = (tag.get('type') or '').lower() == 'password'
        if element_type in VALUE_CAPTURE_TYPES and not is_password:
            val = tag.get('value')
            if val is not None and val != '':
                metadata['current_value'] = val

        role = (tag.get('role') or '').lower()
        if role == 'combobox' or 'combobox' in tag_name:
            controls_id = tag.get('aria-controls')
            if controls_id:
                soup = tag.find_parent()
                while soup and soup.parent:
                    soup = soup.parent
                listbox = soup.find(id=controls_id) if soup else None
                if listbox:
                    options = [
                        self._get_safe_text(o)
                        for o in listbox.find_all(attrs={'role': 'option'})
                    ]
                    options = [o for o in options if o]
                    if options:
                        metadata['available_options'] = options

        if tag_name == 'select':
            opts = []
            for o in tag.find_all('option'):
                opts.append({
                    'value': o.get('value', ''),
                    'label': o.get_text(strip=True),
                    'selected': o.get('selected') is not None,
                })
            if opts:
                metadata['available_options'] = opts

        if tag_name in ('lightning-datatable', 'lightning-tree-grid'):
            columns = []
            for th in tag.find_all('th', attrs={'role': 'columnheader'}):
                label = th.get('aria-label') or ''
                col_key = th.get('data-col-key-value') or ''
                if label and label not in ('Row Number', 'Action'):
                    columns.append({'label': label, 'col_key': col_key})

            data_rows = []
            for tr in tag.find_all('tr', attrs={'data-row-key-value': True}):
                row_obj = {}
                for cell in tr.find_all(
                    ['th', 'td'],
                    attrs={'role': lambda r: r in ('rowheader', 'gridcell')}
                ):
                    col_key = cell.get('data-col-key-value') or ''
                    matched = next((c for c in columns if c['col_key'] == col_key), None)
                    col_label = matched['label'] if matched else None
                    if not col_label:
                        continue
                    link = cell.find('a', href=re.compile(r'/lightning/r/'))
                    text = self._get_safe_text(cell)
                    if not text:
                        continue
                    row_obj[col_label] = {'text': text, 'href': link.get('href')} if link else text
                if row_obj:
                    data_rows.append(row_obj)

            metadata['columns'] = [c['label'] for c in columns]
            metadata['row_count'] = len(data_rows)
            metadata['rows'] = data_rows
            metadata['row_xpath_patterns'] = {
                'by_name_column': "//th[@role='rowheader' and normalize-space()='{value}']",
                'row_link': "//a[contains(@href,'/lightning/r/') and @title='{value}']",
                'row_actions': "//tr[.//th[@role='rowheader' and normalize-space()='{value}']]//button[normalize-space()='Show Actions']",
                'row_checkbox': "//tr[.//th[@role='rowheader' and normalize-space()='{value}']]//input[@type='checkbox']",
            }

        if element_type == 'native_table':
            metadata.update(self._extract_native_table(tag))

        return metadata if metadata else None

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 4 — VALIDATION BLOCK
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_validation(self, tag):
        rules = {}
        for attr in ('maxlength', 'minlength', 'min', 'max', 'pattern', 'inputmode', 'step'):
            val = tag.get(attr)
            if val is not None:
                key = attr.replace('length', '_length')
                rules[key] = val
        input_type = tag.get('type')
        if input_type and input_type != 'text':
            rules['format'] = input_type
        return rules if rules else None

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 5 — NATIVE TABLE EXTRACTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _is_cell_noise(self, child):
        if not hasattr(child, 'get'):
            return True
        if child.get('aria-hidden') == 'true':
            return True
        cell_noise_roles = {'presentation', 'img', 'separator', 'progressbar'}
        if child.get('role') in cell_noise_roles:
            return True
        cell_noise_tags = {'svg', 'lightning-icon', 'c-icon', 'lightning-primitive-icon'}
        if child.name and child.name.lower() in cell_noise_tags:
            return True
        cell_noise_classes = [
            'slds-assistive-text', 'sr-only', 'visually-hidden',
            'slds-hide', 'assistive-text', 'screen-reader-only',
        ]
        classes = ' '.join(child.get('class') or [])
        if any(c in classes for c in cell_noise_classes):
            return True
        if re.match(r'^Progress\s+\d+%$', child.get_text(strip=True), re.IGNORECASE):
            return True
        return False

    def _get_cell_text(self, td):
        cell_aria = td.get('aria-label') or td.get('title')
        if cell_aria and cell_aria.strip():
            return cell_aria.strip()

        direct_text_nodes = [
            n for n in td.children
            if isinstance(n, NavigableString) and n.strip()
        ]

        visible_children = [
            c for c in td.children
            if hasattr(c, 'name') and c.name and not self._is_cell_noise(c)
        ]

        if direct_text_nodes:
            return direct_text_nodes[0].strip()

        if len(visible_children) == 1:
            child = visible_children[0]
            child_aria = child.get('aria-label') or child.get('title')
            if child_aria and child_aria.strip():
                return child_aria.strip()
            for node in child.children:
                if isinstance(node, NavigableString) and node.strip():
                    return node.strip()
            visible_grandchildren = [
                g for g in child.children
                if hasattr(g, 'name') and g.name and not self._is_cell_noise(g)
            ]
            if len(visible_grandchildren) == 1:
                gc = visible_grandchildren[0]
                gc_aria = gc.get('aria-label') or gc.get('title')
                if gc_aria and gc_aria.strip():
                    return gc_aria.strip()
                for node in gc.children:
                    if isinstance(node, NavigableString) and node.strip():
                        return node.strip()

        if len(visible_children) > 1:
            parts = []
            for child in visible_children:
                if len(parts) >= 2:
                    break
                if not list(child.children):
                    t = child.get_text(strip=True)
                    if t:
                        parts.append(t)
            if parts:
                return ''.join(parts)

        fallback = self._get_safe_text(td, max_len=60)
        return fallback if fallback else None

    def _infer_cell_type(self, values):
        if not values:
            return 'unknown'
        sample = values[0]
        if re.match(r'^\$[\d,]+(\.\d+)?$', sample):
            return 'currency'
        if re.match(r'^\d{4}-\d{2}-\d{2}$', sample):
            return 'date'
        if re.match(r'^\d+%$', sample):
            return 'percent'
        if re.match(r'^(true|false|yes|no)$', sample, re.IGNORECASE):
            return 'boolean'
        if re.match(r'^\d+$', sample):
            return 'number'
        if re.match(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$', sample):
            return 'email'
        if re.match(r'^https?://', sample):
            return 'url'
        return 'text'

    def _find_table_rows(self, table):
        selectors_order = [
            {'data-id': True},
            {'data-test-id': True},
            {'data-row-key': True},
        ]
        for attrs in selectors_order:
            rows = table.find_all('tr', attrs=attrs)
            rows = [
                r for r in rows
                if r.find_all('td') and
                any(td.get_text(strip=True) for td in r.find_all('td'))
            ]
            if rows:
                return rows
        rows = table.find_all('tr')
        rows = [
            r for r in rows
            if r.find_all('td') and
            any(td.get_text(strip=True) for td in r.find_all('td'))
        ]
        return rows

    def _extract_row_data(self, tr, columns):
        row_obj = {}
        for key in ('data-id', 'data-test-id', 'data-row-key'):
            val = tr.get(key)
            if val:
                row_obj[f'_{key.replace("-", "_")}'] = val
        return row_obj

    def _extract_native_table(self, tag):
        metadata = {}
        header_row = tag.find('tr')
        columns = []
        if header_row:
            for th in header_row.find_all(['th', 'td']):
                label = th.get('aria-label') or th.get_text(strip=True)
                data_label = th.get('data-label') or label
                if label:
                    columns.append({'label': label, 'data_label': data_label})

        all_rows = self._find_table_rows(tag)
        sample = []
        for tr in all_rows[:5]:
            row_obj = self._extract_row_data(tr, columns)
            cells = tr.find_all('td')
            for i, cell in enumerate(cells):
                col_label = columns[i]['label'] if i < len(columns) else f'col_{i}'
                data_label = cell.get('data-label') or col_label
                text = self._get_cell_text(cell)
                if text:
                    row_obj[data_label] = text
            if row_obj:
                sample.append(row_obj)

        column_schema = []
        for col in columns:
            values = [
                row.get(col['data_label'], '')
                for row in sample
                if row.get(col['data_label'])
            ]
            column_schema.append({
                'label': col['label'],
                'data_label': col['data_label'],
                'inferred_type': self._infer_cell_type(values),
            })

        metadata['columns'] = column_schema
        metadata['total_rows'] = len(all_rows)
        metadata['sample_rows'] = sample
        metadata['row_xpath_patterns'] = {
            'row_by_data_id': "//tr[@data-id='{value}']",
            'row_by_test_id': "//tr[@data-test-id='{value}']",
            'row_by_key': "//tr[@data-row-key='{value}']",
            'cell_by_label': "//tr[@data-id='{row_id}']//td[@data-label='{column}']",
            'cell_by_text': "//td[@data-label='{column}' and normalize-space()='{value}']",
            'cell_positional': "//tr[@data-id='{row_id}']/td[{index}]",
            'edit_button_by_row': "//tr[@data-id='{row_id}']//button[@title='Edit']",
            'row_containing_text': "//tr[.//td[normalize-space()='{value}']]",
        }
        return metadata

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 3 — IDENTIFICATION & LABEL FINDING
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_identification(self, tag):
        result = {}

        label_text, label_source = self._find_label_with_source(tag)
        if label_text:
            result['label_text'] = label_text
            result['label_source'] = label_source

        # Capture supplementary description text as its own field.
        # This text is intentionally kept separate from label_text so it
        # never contaminates the locator value used by QForce keywords.
        description = self._find_description_text(tag)
        if description:
            result['description'] = description

        if not label_text:
            tag_name = tag.name.lower() if tag.name else ''
            role = (tag.get('role') or '').lower()
            if tag_name in ('button', 'a') or role == 'button':
                inner = self._get_safe_text(tag)
                if inner and 0 < len(inner) <= 60:
                    words = inner.lower().split()
                    has_dup = len(words) != len(set(words))
                    has_camel = bool(re.search(r'[a-z][A-Z]', inner))
                    if not has_dup and not has_camel:
                        result['label_text'] = inner
                        result['label_source'] = 'inner_text'

        placeholder = tag.get('placeholder')
        if placeholder:
            result['placeholder'] = placeholder[:100]

        aria_label = tag.get('aria-label')
        if aria_label:
            result['aria_label'] = aria_label[:100]

        title = tag.get('title')
        if title and not result.get('label_text'):
            result['label_text'] = title[:100]
            result['label_source'] = 'title_attr'

        el_id = tag.get('id')
        if el_id:
            id_type = self._classify_id(el_id)
            if id_type and id_type != 'runtime_garbage':
                result['id'] = el_id
                result['id_type'] = id_type

        name = tag.get('name')
        if name:
            result['name'] = self._clean_name(name)

        return result

    def _find_label_with_source(self, tag):
        """
        Resolves the human-readable label for an interactive element using a
        prioritised strategy chain. Returns (label_text, source_name).

        CRITICAL RULE: Text must never be extracted from a child element and
        then attributed solely to its parent. Each strategy targets the most
        specific label element available and uses _get_direct_text() wherever
        a parent element (label, legend, heading) might contain child elements
        whose text should not bleed into the label value.

        Description text (e.g. changeRecordTypeItemDescription) is handled
        separately by _find_description_text() and exposed as its own
        "description" key on the identification block. It must never appear
        inside label_text.
        """

        # Strategy 1: <label for="id"> explicit association
        el_id = tag.get('id')
        if el_id:
            root = tag
            while root.parent:
                root = root.parent
            label_el = root.find('label', attrs={'for': el_id})
            if label_el:
                # Use _get_direct_text first so that description child elements
                # inside the <label> do not contaminate the label text.
                text = self._get_direct_text(label_el)
                if not text:
                    # Fallback: look for the dedicated label-text child span.
                    label_span = label_el.find(class_='slds-form-element__label')
                    if label_span:
                        text = self._get_safe_text(label_span)
                if text:
                    return text[:100], 'standard_label'

        # Strategy 2: aria-labelledby
        labelledby = tag.get('aria-labelledby')
        if labelledby:
            root = tag
            while root.parent:
                root = root.parent
            ref_el = root.find(id=labelledby)
            if ref_el:
                text = self._get_safe_text(ref_el)
                if text:
                    return text[:100], 'aria_labelledby'

        # Strategy 3: aria-label
        aria_label = tag.get('aria-label')
        if aria_label and aria_label.strip():
            return aria_label.strip()[:100], 'aria_label'

        # Strategy 4: Wrapping <label>
        # A <label> that wraps a radio/checkbox also wraps the option name span
        # AND a description div. We must resolve only the option name here.
        # Priority order:
        #   a) Dedicated SLDS label span (slds-form-element__label) — most precise.
        #   b) Direct text nodes of the <label> only — no child element text.
        # The description div text is intentionally excluded here; it is
        # captured by _find_description_text() instead.
        parent_label = tag.find_parent('label')
        if parent_label:
            text = self._get_label_span_text(parent_label)
            if not text:
                text = self._get_direct_text(parent_label)
            if text:
                return text[:100], 'wrapped_label'

        # Strategy 5: Slot label (child label/span inside the element itself)
        label_span = tag.find(class_='slds-form-element__label')
        if label_span:
            text = self._get_safe_text(label_span)
            if text:
                return text[:100], 'slot_label'
        slot_label = tag.find('label')
        if slot_label:
            text = self._get_direct_text(slot_label)
            if not text:
                text = self._get_safe_text(slot_label)
            if text:
                return text[:100], 'slot_label'

        # Strategy 6: title attribute
        title = tag.get('title')
        if title:
            return title[:100], 'title_attr'

        # Strategy 7: Sibling div pattern
        input_wrapper = tag.parent
        if input_wrapper and hasattr(input_wrapper, 'name') and input_wrapper.name == 'div':
            for sibling in input_wrapper.find_previous_siblings('div'):
                if not sibling:
                    continue
                text = self._get_safe_text(sibling)
                if text and len(text) < 100 and not sibling.find('input'):
                    words = text.lower().split()
                    has_dup = len(words) != len(set(words))
                    has_camel = bool(re.search(r'[a-z][A-Z]', text))
                    if not has_dup and not has_camel:
                        return text, 'sibling_div'

        # Strategy 8: Ancestor label walk (combobox / input)
        tag_name = tag.name.lower() if tag.name else ''
        role = (tag.get('role') or '').lower()
        if role == 'combobox' or tag_name == 'input':
            ancestor = tag.parent
            for _ in range(8):
                if not ancestor or not hasattr(ancestor, 'find'):
                    break
                for selector_class in ('slds-form-element__label',):
                    ancestor_label = ancestor.find(class_=selector_class)
                    if ancestor_label and ancestor_label != tag:
                        text = self._get_safe_text(ancestor_label)
                        if text and len(text) <= 80:
                            words = text.lower().split()
                            has_dup = len(words) != len(set(words))
                            has_camel = bool(re.search(r'[a-z][A-Z]', text))
                            if not has_dup and not has_camel:
                                return text[:100], 'ancestor_label_walk'
                legend = ancestor.find('legend')
                if legend and legend != tag:
                    # Use _get_direct_text on <legend> to avoid pulling in
                    # assistive <span> children that duplicate the modal title.
                    text = self._get_direct_text(legend)
                    if not text:
                        text = self._get_safe_text(legend)
                    if text and len(text) <= 80:
                        return text[:100], 'ancestor_label_walk'
                ancestor = ancestor.parent if hasattr(ancestor, 'parent') else None

        # Strategy 9: Ancestor sibling label walk (up 5 levels)
        ancestor = tag.parent.parent if tag.parent else None
        for _ in range(5):
            if not ancestor or not hasattr(ancestor, 'name'):
                break
            prev_sibling = ancestor.find_previous_sibling()
            if prev_sibling and hasattr(prev_sibling, 'find'):
                nested_label = prev_sibling.find(
                    lambda t: t.name in ('label', 'legend') or
                    (t.get('class') and any('label' in c for c in (t.get('class') or [])))
                )
                if nested_label:
                    text = self._get_direct_text(nested_label)
                    if not text:
                        text = self._get_safe_text(nested_label)
                    if text and len(text) <= 60:
                        return text[:100], 'ancestor_sibling_label'
                sib_text = self._get_safe_text(prev_sibling)
                if sib_text and len(sib_text) <= 60:
                    words = sib_text.lower().split()
                    has_dup = len(words) != len(set(words))
                    has_camel = bool(re.search(r'[a-z][A-Z]', sib_text))
                    if not has_dup and not has_camel:
                        return sib_text[:100], 'ancestor_sibling_div'
            if hasattr(ancestor, 'find'):
                container_label = ancestor.find(
                    lambda t: t.name in ('label', 'legend') and t != tag
                )
                if container_label and not container_label.find(tag.name):
                    text = self._get_direct_text(container_label)
                    if not text:
                        text = self._get_safe_text(container_label)
                    if text and len(text) <= 60:
                        return text[:100], 'container_label'
            ancestor = ancestor.parent if hasattr(ancestor, 'parent') else None

        # Strategy 10: Placeholder fallback
        placeholder = tag.get('placeholder')
        if placeholder:
            return placeholder[:100], 'placeholder'

        return None, None

    # ─────────────────────────────────────────────────────────────────────────────
    # STRUCTURAL PATTERN DETECTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _detect_structural_pattern(self, tag):
        if not tag:
            return None
        structure = {}
        label_text, label_source = self._find_label_with_source(tag)

        if not label_source:
            structure['pattern'] = 'unknown'
            return structure

        structure['pattern'] = label_source

        if label_source == 'standard_label':
            el_id = tag.get('id')
            if el_id:
                root = tag
                while root.parent:
                    root = root.parent
                label_el = root.find('label', attrs={'for': el_id})
                if label_el:
                    structure['label_element'] = {
                        'tag': 'label',
                        'for': el_id,
                        'class': self._get_class_string(label_el),
                        'text': label_text,
                    }

        elif label_source == 'wrapped_label':
            parent_label = tag.find_parent('label')
            if parent_label:
                structure['label_element'] = {
                    'tag': 'label',
                    'class': self._get_class_string(parent_label),
                    'text': label_text,
                    'position': 'wrapping_parent',
                }

        elif label_source == 'sibling_div':
            input_wrapper = tag.parent
            if input_wrapper and input_wrapper.name == 'div':
                for sibling in input_wrapper.find_previous_siblings('div'):
                    if not sibling:
                        continue
                    sibling_text = self._get_safe_text(sibling)
                    if sibling_text and len(sibling_text) < 100 and not sibling.find('input'):
                        structure['label_element'] = {
                            'tag': 'div',
                            'class': self._get_class_string(sibling),
                            'text': sibling_text,
                            'position': 'preceding_sibling',
                        }
                        break
                structure['input_container'] = {
                    'tag': 'div',
                    'class': self._get_class_string(input_wrapper),
                }
                common_parent = input_wrapper.parent
                if common_parent and hasattr(common_parent, 'name') and common_parent.name == 'div':
                    structure['common_parent'] = {
                        'tag': 'div',
                        'class': self._get_class_string(common_parent),
                    }
                structure['relationship'] = 'label_div -> sibling -> input_wrapper_div -> child -> input'

        elif label_source == 'aria_labelledby':
            structure['label_element'] = {
                'id': tag.get('aria-labelledby'),
                'text': label_text,
            }

        elif label_source in (
            'aria_label', 'slot_label', 'ancestor_label_walk',
            'ancestor_sibling_label', 'container_label',
        ):
            structure['label_text'] = label_text

        elif label_source == 'placeholder':
            structure['placeholder'] = label_text

        return structure

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 7 — CONTEXT DETECTION
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_context_info(self, tag):
        if not tag:
            return None
        context = {}

        modal = tag.find_parent(lambda t: t.name and (
            'slds-modal' in ' '.join(t.get('class') or []) or
            t.name in ('force-record-create-modal', 'records-lwc-modal-base')
        ))
        if modal:
            modal_header = modal.find('h2')
            # Use _get_direct_text for the modal <h2> to avoid pulling in any
            # nested child element text into the modal title.
            context['modal_title'] = (
                self._get_direct_text(modal_header) or
                self._get_safe_text(modal_header)
            ) if modal_header else None
            context['is_in_modal'] = True

        form_section = tag.find_parent(lambda t: t.name and t.name in (
            'records-record-layout-section', 'force-form-section',
            'lightning-accordion-section',
        ) or (t.get('class') and 'slds-section' in ' '.join(t.get('class') or [])))
        if form_section:
            section_title = form_section.find(
                lambda t: t.name in ('legend', 'h3') or
                (t.get('class') and 'slds-section__title' in ' '.join(t.get('class') or []))
            )
            if section_title:
                context['form_section'] = (
                    self._get_direct_text(section_title) or
                    self._get_safe_text(section_title)
                )

        tab_panel = tag.find_parent(attrs={'role': 'tabpanel'})
        if tab_panel:
            tab_id = tab_panel.get('aria-labelledby')
            if tab_id:
                root = tab_panel
                while root.parent:
                    root = root.parent
                tab_el = root.find(id=tab_id)
                context['active_tab'] = self._get_safe_text(tab_el) if tab_el else tab_panel.get('data-tab-value')
            else:
                context['active_tab'] = tab_panel.get('data-tab-value')

        related_list = tag.find_parent(lambda t: t.name and t.name in (
            'force-related-list-single-container',
            'force-related-list-container',
            'lightning-related-list',
        ))
        if related_list:
            title_el = related_list.find(['h2'])
            context['related_list'] = self._get_safe_text(title_el) if title_el else None
            context['is_in_related_list'] = True

        datatable_row = tag.find_parent('tr', attrs={'data-row-key-value': True})
        if datatable_row:
            context['datatable_row_key'] = datatable_row.get('data-row-key-value')
            context['is_in_datatable'] = True

        quick_action = tag.find_parent(lambda t: t.name and t.name in (
            'force-quick-action-panel', 'forceActionBody',
        ) or (t.get('class') and 'forceActionBody' in ' '.join(t.get('class') or [])))
        if quick_action:
            qa_title = quick_action.find('h2')
            context['quick_action_title'] = self._get_safe_text(qa_title) if qa_title else None
            context['is_in_quick_action'] = True

        omni_step = tag.find_parent(lambda t: t.name and (
            t.name == 'c-omniscript-step' or t.get('data-omni-step-name')
        ))
        if omni_step:
            context['omni_step'] = omni_step.get('data-omni-step-name') or omni_step.get('name')
            context['is_in_omniscript'] = True

        flow_screen = tag.find_parent(lambda t: t.name and t.name in (
            'runtime_platform_flow-screen-field', 'lightning-flow-screen',
        ))
        if flow_screen:
            context['flow_screen'] = flow_screen.get('data-field-name') or 'flow_screen'
            context['is_in_flow'] = True

        form = tag.find_parent('form')
        if form:
            form_name = form.get('name') or form.get('id')
            if form_name:
                context['form'] = form_name

        card = tag.find_parent('lightning-card')
        if card:
            card_title = card.get('title')
            if card_title:
                context['card'] = card_title

        if not context.get('form_section'):
            section = self._find_section_header(tag)
            if section:
                context['section'] = section

        return context if context else None

    def _find_section_header(self, tag):
        """
        Walks up ancestor elements looking for a heading or legend to use as
        the section label. Uses _get_direct_text() to avoid pulling child
        element text (e.g. assistive spans) into the section name.
        """
        if not tag:
            return None
        parent = tag.parent
        for _ in range(10):
            if not parent:
                break
            if hasattr(parent, 'find'):
                for heading_tag in ('h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'legend'):
                    heading = parent.find(heading_tag)
                    if heading:
                        # Prefer direct text only; fall back to safe full text
                        # only when the element has no direct text nodes.
                        text = self._get_direct_text(heading)
                        if not text:
                            text = self._get_safe_text(heading)
                        if text and len(text) < 100:
                            return text
            parent = parent.parent if hasattr(parent, 'parent') else None
        return None

    # ─────────────────────────────────────────────────────────────────────────────
    # QFORCE HINTS
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_qforce_hints(self, element_type, identification, structure):
        locator_options = []

        label_text = identification.get('label_text')
        if label_text:
            hint = {
                'type': 'label_text',
                'value': label_text,
                'reliability': 'high',
                'notes': 'QForce can locate by label text',
            }
            # Surface the description as a separate note so the AI has full
            # context when choosing between options with similar names.
            description = identification.get('description')
            if description:
                hint['description'] = description
            locator_options.append(hint)

        if structure and structure.get('pattern') in (
            'lwc_sibling_div', 'standard_label', 'wrapped_label',
            'slot_label', 'ancestor_label_walk', 'ancestor_sibling_label',
        ):
            locator_options.append({
                'type': 'xpath',
                'pattern': structure.get('pattern'),
                'reliability': 'high',
                'notes': f"Navigate using {structure.get('pattern')} pattern",
            })

        aria_label = identification.get('aria_label')
        if aria_label:
            locator_options.append({
                'type': 'aria_label',
                'value': aria_label,
                'reliability': 'medium',
                'notes': 'Use aria-label attribute',
            })

        placeholder = identification.get('placeholder')
        if placeholder:
            locator_options.append({
                'type': 'placeholder',
                'value': placeholder,
                'reliability': 'low',
                'notes': 'Placeholder may not be unique',
            })

        field_name = identification.get('field_name') or identification.get('data_field')
        if field_name:
            locator_options.append({
                'type': 'field_name',
                'value': field_name,
                'reliability': 'high',
                'notes': 'Salesforce field API name — stable locator',
            })

        return {'locator_options': locator_options} if locator_options else None

    # ─────────────────────────────────────────────────────────────────────────────
    # PHASE 6 — SCORED DEDUPLICATION
    # ─────────────────────────────────────────────────────────────────────────────

    def _field_score(self, element_data):
        tag = element_data.get('element_details', {}).get('tag', '')
        attrs = element_data.get('element_details', {}).get('attributes', {})
        identification = element_data.get('identification', {})
        score = 0

        native_tags = {'input', 'textarea', 'select', 'button', 'a'}
        if tag in native_tags:
            score += 10

        if re.match(r'^(lightning|c|runtime|force|lst|aura)-', tag):
            score -= 5

        rich_input_types = {
            'text', 'email', 'tel', 'number', 'date', 'datetime-local',
            'time', 'url', 'password', 'search', 'month', 'week',
            'color', 'range', 'file', 'checkbox', 'radio',
        }
        el_type = element_data.get('element_details', {}).get('type') or ''
        if el_type.lower() in rich_input_types:
            score += 5

        if attrs.get('name'):
            score += 3
        if identification.get('aria_label') or attrs.get('title'):
            score += 2
        if attrs.get('role') == 'combobox':
            score += 2

        return score

    def _is_scored_duplicate(self, element_data, elements_list):
        label = (element_data.get('identification') or {}).get('label_text')
        el_type = element_data.get('element_type')
        if not label:
            return False
        for existing in elements_list:
            existing_label = (existing.get('identification') or {}).get('label_text')
            existing_type = existing.get('element_type')
            if label == existing_label and el_type == existing_type:
                return True
        return False

    def _deduplicate_form_fields(self, elements):
        COLLAPSIBLE_TYPES = {
            'input_field', 'dropdown', 'textarea',
            'checkbox', 'radio', 'button',
        }

        field_groups = {}
        keep_elements = []

        for el in elements:
            label = (el.get('identification') or {}).get('label_text')
            section = (
                (el.get('context') or {}).get('form_section') or
                (el.get('context') or {}).get('modal_title') or
                '__global__'
            )
            el_type = el.get('element_type')

            if (
                el_type == 'custom_component' and
                not label and
                (
                    (el.get('context') or {}).get('is_in_modal') or
                    (el.get('context') or {}).get('form_section')
                )
            ):
                continue

            if not label or el_type not in COLLAPSIBLE_TYPES:
                keep_elements.append(el)
                continue

            group_key = f'{label}||{section}'
            if group_key not in field_groups:
                field_groups[group_key] = el
            else:
                existing = field_groups[group_key]
                existing_score = self._field_score(existing)
                new_score = self._field_score(el)
                if new_score > existing_score:
                    merged_meta = {
                        **(existing.get('behavioral_metadata') or {}),
                        **(el.get('behavioral_metadata') or {}),
                    }
                    merged_validation = {
                        **(existing.get('validation') or {}),
                        **(el.get('validation') or {}),
                    }
                    merged = {**el}
                    if merged_meta:
                        merged['behavioral_metadata'] = merged_meta
                    else:
                        merged.pop('behavioral_metadata', None)
                    if merged_validation:
                        merged['validation'] = merged_validation
                    else:
                        merged.pop('validation', None)
                    field_groups[group_key] = merged

        return keep_elements + list(field_groups.values())

    # ─────────────────────────────────────────────────────────────────────────────
    # UTILITIES
    # ─────────────────────────────────────────────────────────────────────────────

    def _get_class_string(self, tag):
        if not tag:
            return None
        try:
            css_class = tag.get('class', '')
            if isinstance(css_class, list):
                return ' '.join(css_class) if css_class else None
            return css_class if css_class else None
        except Exception:
            return None

    def _get_key_attributes(self, tag):
        attrs = {}
        allowed = {
            'id', 'name', 'type', 'role', 'aria-label',
            'aria-expanded', 'aria-selected', 'aria-checked',
            'aria-required', 'aria-disabled', 'aria-invalid', 'aria-readonly',
            'aria-multiselectable', 'data-record-id', 'data-object-api-name',
            'data-field', 'data-field-name', 'data-value', 'data-col-key-value',
            'data-test-id', 'data-id', 'data-tab-value', 'data-aura-class',
            'href', 'title', 'placeholder', 'value', 'inputmode',
            'maxlength', 'min', 'max',
        }
        meaningful_aura = re.compile(
            r'(forceOutput|forceInput|uiInput|runtime_|forceRecord|forceLookup|forceAction|forceSearch|forceList)',
            re.IGNORECASE,
        )
        for attr in allowed:
            val = tag.get(attr)
            if val is None or val == '':
                continue
            if isinstance(val, list):
                val = ' '.join(val)
            if attr == 'id' and self._classify_id(val) == 'runtime_garbage':
                continue
            if attr == 'data-aura-class' and not meaningful_aura.search(val):
                continue
            attrs[attr] = val
        return attrs

    def _prune_empty_values(self, data):
        if isinstance(data, dict):
            pruned = {}
            for key, value in data.items():
                cleaned = self._prune_empty_values(value)
                if cleaned is not None and cleaned != {} and cleaned != []:
                    pruned[key] = cleaned
            return pruned
        elif isinstance(data, list):
            pruned = [self._prune_empty_values(item) for item in data]
            return [item for item in pruned if item is not None and item != {} and item != []]
        else:
            return data

    # ─────────────────────────────────────────────────────────────────────────────
    # ENTRY POINT 2 — PAGE NAME EXTRACTION
    # ─────────────────────────────────────────────────────────────────────────────

    @keyword("Extract Page Name")
    def extract_page_name(self, json_output: str) -> str:
        """
        Derives a filesystem-safe page name from the parsed element JSON.
        Priority:
          1. modal_title
          2. Known href map
          3. Active nav link label (only if not generic)
          4. First non-generic section name
          5. First section name regardless
          6. Fallback: 'unknown_page'
        """
        def slugify(text):
            text = text.lower().strip()
            text = re.sub(r'[^a-z0-9]+', '_', text)
            return text.strip('_')[:60]

        def normalize(text):
            return (
                text
                .replace('\u2019', "'")
                .replace('\u2018', "'")
                .replace('\u201c', '"')
                .replace('\u201d', '"')
            )

        GENERIC_SECTIONS = {
            'sales', 'recent records', 'set goals', 'my goals',
            "today's events", "today's tasks", 'to do list',
            'close deals', 'plan my accounts', 'grow relationships',
            'build pipeline', 'just so you know',
        }

        HREF_TO_PAGE_NAME = {
            '/lightning/page/home': 'sales_home',
            '/lightning/page/forecasting': 'forecasts',
        }

        try:
            elements = json.loads(json_output)
        except Exception:
            return 'unknown_page'

        for el in elements:
            modal_title = (el.get('context') or {}).get('modal_title')
            if modal_title:
                return slugify(modal_title)

        sections = []
        for el in elements:
            section = (el.get('context') or {}).get('section')
            if section and section not in sections:
                sections.append(section)

        for el in elements:
            if el.get('element_type') == 'link':
                href = (el.get('element_details') or {}).get('attributes', {}).get('href', '')
                if href in HREF_TO_PAGE_NAME:
                    return HREF_TO_PAGE_NAME[href]

        for el in elements:
            if el.get('element_type') == 'link':
                href = (el.get('element_details') or {}).get('attributes', {}).get('href', '')
                label = (el.get('identification') or {}).get('label_text', '')
                normalized_label = normalize(label).lower()
                if (
                    any(seg in href for seg in ('/o/', '/n/'))
                    and label in sections
                    and normalized_label not in GENERIC_SECTIONS
                ):
                    return slugify(label)

        for section in sections:
            if normalize(section).lower() not in GENERIC_SECTIONS:
                return slugify(section)

        if sections:
            return slugify(sections[0])

        return 'unknown_page'
