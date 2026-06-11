# ═══════════════════════════════════════════════════════════════════════════════
# org_contract_sanitizer.py
# Sanitizes raw Salesforce metadata JSON output from Execute Dynamic Operations.
# Fully org-agnostic — metadata-driven lean output optimized for AI Test Agents.
# ═══════════════════════════════════════════════════════════════════════════════
import json
import logging
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

class OrgContractSanitizer:
    """
    Sanitizes raw Salesforce metadata collected via Execute Dynamic Operations.
    """

    # Strictly necessary reference fields. System dates/stamps are stripped.
    ALWAYS_INCLUDE_FIELDS = {"Id", "Name"}

    LAYOUT_KEY_PREFIX   = "layout"
    PICKLIST_KEY_PREFIX = "picklist"

    # ───────────────────────────────────────────────────────────────────────────
    # PUBLIC ENTRY POINT
    # ───────────────────────────────────────────────────────────────────────────
    def sanitize_org_contract(self, raw: dict) -> dict:
        if not isinstance(raw, dict):
            logger.warning("⚠ sanitize_org_contract received non-dict input")
            return {"_error": True, "_errorMessage": "Input must be a dictionary"}

        try:
            has_record_types = self._detect_record_types(raw)
            
            # Extract raw picklists first so we can deduplicate them
            raw_picklists = self._sanitize_picklists(raw, has_record_types)
            if has_record_types:
                global_picks, rt_picks = self._deduplicate_picklists(raw_picklists)
            else:
                global_picks = raw_picklists
                rt_picks = None

            contract = {
                "generatedAt":         datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "object":              self._sanitize_object_name(raw),
                "hasRecordTypes":      has_record_types,
                "recordTypes":         self._sanitize_record_types(raw) if has_record_types else None,
                "layouts":             self._sanitize_layouts(raw, has_record_types),
                "fieldMeta":           self._sanitize_field_meta(raw, has_record_types),
                "globalPicklists":     global_picks,
                "recordTypePicklists": rt_picks,
                "validationRules":     self._sanitize_validation_rules(raw)
            }

            # Prune empty root keys for ultimate leanness
            contract = {k: v for k, v in contract.items() if v is not None and v != [] and v != {}}

            logger.info(f"✅ Contract sanitized for object: {contract.get('object', 'unknown')}")
            return contract

        except Exception as e:
            logger.warning(f"⚠ sanitize_org_contract failed: {e}")
            return {"_error": True, "_errorMessage": str(e)}

    # ───────────────────────────────────────────────────────────────────────────
    # RECORD TYPE DETECTION
    # ───────────────────────────────────────────────────────────────────────────
    def _detect_record_types(self, raw: dict) -> bool:
        try:
            describe_key = self._find_key_by_substring(raw, "describe")
            if not describe_key: return False
            for rt in self._safe_get(raw, describe_key, {}).get("recordTypeInfos", []):
                if isinstance(rt, dict) and not rt.get("master", False) and rt.get("active", False):
                    return True
            return False
        except Exception:
            return False

    def _sanitize_object_name(self, raw: dict) -> str:
        describe_key = self._find_key_by_substring(raw, "describe")
        return self._safe_get(raw, describe_key, {}).get("name", "unknown") if describe_key else "unknown"

    def _sanitize_record_types(self, raw: dict) -> list:
        try:
            describe_key = self._find_key_by_substring(raw, "describe")
            if not describe_key: return []
            result = []
            for rt in self._safe_get(raw, describe_key, {}).get("recordTypeInfos", []):
                if isinstance(rt, dict) and not rt.get("master", False) and rt.get("active", False):
                    result.append({
                        "id": rt.get("recordTypeId"),
                        "name": rt.get("name"),
                        "developerName": rt.get("developerName"),
                        "isDefault": rt.get("defaultRecordTypeMapping", False),
                    })
            return result
        except Exception:
            return []

    # ───────────────────────────────────────────────────────────────────────────
    # LAYOUTS (With Dead-Field Pruning)
    # ───────────────────────────────────────────────────────────────────────────
    def _sanitize_layouts(self, raw: dict, has_record_types: bool):
        try:
            layout_keys = self._find_keys_by_prefix(raw, self.LAYOUT_KEY_PREFIX)
            if not layout_keys: return {} if has_record_types else []

            if has_record_types:
                all_layouts = {}
                for layout_key in layout_keys:
                    rt_name = self._strip_prefix(layout_key, self.LAYOUT_KEY_PREFIX)
                    sanitized = self._sanitize_single_layout(raw, layout_key)
                    if sanitized and rt_name: all_layouts[rt_name] = sanitized
                return all_layouts
            else:
                sanitized = self._sanitize_single_layout(raw, layout_keys[0])
                return sanitized if sanitized is not None else []
        except Exception:
            return {} if has_record_types else []

    def _sanitize_single_layout(self, raw: dict, layout_key: str) -> list | None:
        try:
            sections_raw = self._safe_get(raw, layout_key, {}).get("sections", [])
            sections = []
            for section in sections_raw:
                if not isinstance(section, dict): continue
                fields_in_section = []
                
                for row in section.get("layoutRows", []):
                    if not isinstance(row, dict): continue
                    for item in row.get("layoutItems", []):
                        if not isinstance(item, dict): continue
                        
                        # Catch purely read-only formula / system fields
                        is_new_edit = item.get("editableForNew", False)
                        is_upd_edit = item.get("editableForUpdate", False)
                        ui_beh = item.get("uiBehavior")
                        
                        if not is_new_edit and not is_upd_edit and ui_beh == "Readonly":
                            continue # Purge field
                            
                        for comp in item.get("layoutComponents", []):
                            if isinstance(comp, dict) and comp.get("componentType") == "Field":
                                api_name = comp.get("apiName")
                                if api_name:
                                    fields_in_section.append({
                                        "apiName": api_name,
                                        "label": item.get("label"),
                                        "required": item.get("required", False),
                                        "uiBehavior": ui_beh
                                    })

                # Prune the section entirely if all fields were stripped
                if fields_in_section:
                    sections.append({
                        "heading": section.get("heading", ""),
                        "collapsible": section.get("collapsible", False),
                        "fields": fields_in_section,
                    })

            return sections if sections else None
        except Exception:
            return None

    # ───────────────────────────────────────────────────────────────────────────
    # FIELD META (Ultra-Lean)
    # ───────────────────────────────────────────────────────────────────────────
    def _sanitize_field_meta(self, raw: dict, has_record_types: bool):
        try:
            describe_key = self._find_key_by_substring(raw, "describe")
            if not describe_key: return {} if has_record_types else []

            all_fields_raw = self._safe_get(raw, describe_key, {}).get("fields", [])
            field_map = {f["name"]: f for f in all_fields_raw if isinstance(f, dict) and f.get("name")}
            layout_keys = self._find_keys_by_prefix(raw, self.LAYOUT_KEY_PREFIX)

            if has_record_types:
                result = {}
                for lk in layout_keys:
                    rt_name = self._strip_prefix(lk, self.LAYOUT_KEY_PREFIX)
                    allowlist = self._extract_field_names_from_layout(raw, lk) | self.ALWAYS_INCLUDE_FIELDS
                    if rt_name: result[rt_name] = self._build_slim_field_list(field_map, allowlist)
                return result
            else:
                allowlist = set()
                for lk in layout_keys: allowlist |= self._extract_field_names_from_layout(raw, lk)
                allowlist |= self.ALWAYS_INCLUDE_FIELDS
                return self._build_slim_field_list(field_map, allowlist)
        except Exception:
            return {} if has_record_types else []

    def _build_slim_field_list(self, field_map: dict, allowlist: set) -> list:
        result = []
        for api_name in sorted(allowlist):
            field = field_map.get(api_name)
            if not field: continue

            field_type = field.get("type", "")
            entry = {
                "name": field.get("name"),
                "label": field.get("label"),
                "type": field_type
            }

            ref = field.get("referenceTo")
            if ref: entry["referenceTo"] = ref

            if field_type in ("string", "textarea", "email", "phone", "url"):
                length = field.get("length")
                if length: entry["length"] = length

            result.append(entry)
        return result

    # ───────────────────────────────────────────────────────────────────────────
    # PICKLISTS & DEDUPLICATION
    # ───────────────────────────────────────────────────────────────────────────
    def _sanitize_picklists(self, raw: dict, has_record_types: bool) -> dict:
        try:
            picklist_keys = self._find_keys_by_prefix(raw, self.PICKLIST_KEY_PREFIX)
            if not picklist_keys: return {}

            if has_record_types:
                result = {}
                for pk in picklist_keys:
                    rt_name = self._strip_prefix(pk, self.PICKLIST_KEY_PREFIX)
                    layout_key = f"{self.LAYOUT_KEY_PREFIX}_{rt_name}"
                    allowlist = self._extract_field_names_from_layout(raw, layout_key) | self.ALWAYS_INCLUDE_FIELDS
                    if rt_name: result[rt_name] = self._build_picklist_block(raw, pk, allowlist)
                return result
            else:
                layout_keys = self._find_keys_by_prefix(raw, self.LAYOUT_KEY_PREFIX)
                allowlist = set()
                for lk in layout_keys: allowlist |= self._extract_field_names_from_layout(raw, lk)
                allowlist |= self.ALWAYS_INCLUDE_FIELDS
                return self._build_picklist_block(raw, picklist_keys[0], allowlist)
        except Exception:
            return {}

    def _deduplicate_picklists(self, rt_picklists: dict) -> tuple[dict, dict]:
        """
        Extracts picklists that are completely identical across all record types 
        to a global block, returning (global_picklists, remaining_rt_picklists).
        """
        global_picks = {}
        cleaned_rt_picks = {rt: {} for rt in rt_picklists}
        
        # Build a map of FieldName -> List of RecordTypes it appears in
        field_appearances = {}
        for rt, fields in rt_picklists.items():
            for field in fields:
                field_appearances.setdefault(field, []).append(rt)
                
        for field, rts in field_appearances.items():
            # If it doesn't appear in all record types, or there's only 1 RT, skip dedupe
            if len(rts) < len(rt_picklists) or len(rt_picklists) <= 1:
                for rt in rts: cleaned_rt_picks[rt][field] = rt_picklists[rt][field]
                continue
                
            # Check if values are identical across all record types
            base_val_str = json.dumps(rt_picklists[rts[0]][field], sort_keys=True)
            is_global = all(json.dumps(rt_picklists[rt][field], sort_keys=True) == base_val_str for rt in rts)
            
            if is_global:
                global_picks[field] = rt_picklists[rts[0]][field]
            else:
                for rt in rts: cleaned_rt_picks[rt][field] = rt_picklists[rt][field]
                
        # Remove empty RT dicts
        cleaned_rt_picks = {k: v for k, v in cleaned_rt_picks.items() if v}
        return global_picks, cleaned_rt_picks

    def _build_picklist_block(self, raw: dict, picklist_key: str, allowlist: set) -> dict:
        picklist_map = self._safe_get(raw, picklist_key, {}).get("picklistFieldValues", {})
        block = {}
        for api_name, data in picklist_map.items():
            if not isinstance(data, dict) or api_name not in allowlist: continue
            
            clean_vals = []
            for v in data.get("values", []):
                if not isinstance(v, dict): continue
                entry = {"label": v.get("label"), "value": v.get("value")}
                if v.get("validFor"): entry["validFor"] = v["validFor"]
                attrs = v.get("attributes")
                if isinstance(attrs, dict) and attrs.get("converted") is True: entry["converted"] = True
                clean_vals.append(entry)

            def_raw = data.get("defaultValue")
            def_val = def_raw.get("value") if isinstance(def_raw, dict) else def_raw
            
            field_block = {"values": clean_vals}
            if def_val is not None: field_block["defaultValue"] = def_val
            
            ctrl_vals = data.get("controllerValues")
            if ctrl_vals: field_block["controllerValues"] = ctrl_vals
            
            block[api_name] = field_block
        return block

    # ───────────────────────────────────────────────────────────────────────────
    # VALIDATION RULES
    # ───────────────────────────────────────────────────────────────────────────
    def _sanitize_validation_rules(self, raw: dict) -> list:
        try:
            vr_key = self._find_key_by_substring(raw, "validationRule")
            if not vr_key: return []
            result = []
            for rule in self._safe_get(raw, vr_key, {}).get("records", []):
                if isinstance(rule, dict):
                    result.append({
                        "active": rule.get("Active"),
                        "errorMessage": rule.get("ErrorMessage"),
                        "errorCondition": rule.get("ErrorConditionFormula"),
                        "description": rule.get("Description"),
                    })
            return result
        except Exception:
            return []

    # ───────────────────────────────────────────────────────────────────────────
    # UTILITY HELPERS
    # ───────────────────────────────────────────────────────────────────────────
    def _extract_field_names_from_layout(self, raw: dict, layout_key: str) -> set:
        names = set()
        for section in self._safe_get(raw, layout_key, {}).get("sections", []):
            if not isinstance(section, dict): continue
            for row in section.get("layoutRows", []):
                if not isinstance(row, dict): continue
                for item in row.get("layoutItems", []):
                    if not isinstance(item, dict): continue
                    
                    # Ensure we don't add field names to allowlist if they are read-only
                    is_new = item.get("editableForNew", False)
                    is_upd = item.get("editableForUpdate", False)
                    if not is_new and not is_upd and item.get("uiBehavior") == "Readonly":
                        continue
                        
                    for comp in item.get("layoutComponents", []):
                        if isinstance(comp, dict) and comp.get("componentType") == "Field":
                            api = comp.get("apiName")
                            if api: names.add(api)
        return names

    def _strip_prefix(self, key: str, prefix: str) -> str:
        return key[len(prefix):].lstrip("_")

    def _find_keys_by_prefix(self, raw: dict, prefix: str) -> list:
        if not isinstance(raw, dict): return []
        return sorted(k for k in raw if k.lower().startswith(prefix.lower()))

    def _find_key_by_substring(self, raw: dict, substring: str) -> str | None:
        if not isinstance(raw, dict): return None
        sub_lower = substring.lower()
        for k in raw:
            if sub_lower in k.lower(): return k
        return None

    def _safe_get(self, data: dict, key: str, default=None):
        try: return data.get(key, default)
        except Exception: return default


# ═══════════════════════════════════════════════════════════════════════════════
# ROBOT FRAMEWORK INTERFACE
# ═══════════════════════════════════════════════════════════════════════════════
def sanitize_org_contract(raw_input) -> str:
    """
    Robot Framework-callable entry point. Seamlessly handles flat dicts, 
    multi-object dicts, or JSON string inputs.
    """
    if isinstance(raw_input, dict):
        raw = raw_input
    else:
        try:
            raw = json.loads(raw_input)
        except json.JSONDecodeError as e:
            return json.dumps({"_error": True, "_errorMessage": f"Invalid JSON input: {e}"}, indent=2)

    sanitizer = OrgContractSanitizer()
    processed_raw = {}
    
    for k, v in raw.items():
        if isinstance(v, str):
            try: processed_raw[k] = json.loads(v)
            except json.JSONDecodeError: processed_raw[k] = v
        else:
            processed_raw[k] = v

    is_multi_object_bundle = all(isinstance(v, dict) for v in processed_raw.values()) and any(
        any("describe" in sub_k.lower() for sub_k in v) for v in processed_raw.values() if isinstance(v, dict)
    )

    if is_multi_object_bundle:
        master_contract = {}
        for obj_name, obj_raw_data in processed_raw.items():
            master_contract[obj_name] = sanitizer.sanitize_org_contract(obj_raw_data)
        return json.dumps(master_contract, indent=2, default=str)
    
    result = sanitizer.sanitize_org_contract(processed_raw)
    return json.dumps(result, indent=2, default=str)