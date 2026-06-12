*** Settings ***
Library                         RequestsLibrary
Library                         Collections
Library                         String
Library                         DateTime
Library                         OperatingSystem
Library                         QWeb
Library                         QForce
Library                         ../resources/DomParserLibrary.py
Library                         ../resources/ObjectSanitizer.py
Resource                        ../resources/MetadataRetrieval.robot
Library                         ../resources/ExplorationSessionLibrary.py
Library                         ../resources/JsonSanitizer.py

*** Variables ***
@{ALL_PROPOSED_STEPS}           # A: Every step the AI has suggested so far
@{EXECUTION_HISTORY_PASSED}     # B: Steps that technically executed without throwing a CRT error
@{EXECUTION_HISTORY_FAILED}     # C: Steps that threw an error
@{GOLDEN_PATH_SCRIPT}           # D: The final, optimized sequence to be saved as the real asset

*** Keywords *** 
Initialize Copado AI Session
    [Documentation]             Strips variables and creates a persistent network session pool.
    ${CLEAN_API_KEY}=           String.Strip String         ${project_api_key}
    ${CLEAN_ORG}=               String.Strip String         ${project_org_id}
    ${CLEAN_WSPACE}=            String.Strip String         ${project_workspace}
    Set Suite Variable          ${CLEAN_API_KEY}            ${CLEAN_API_KEY}
    Set Suite Variable          ${CLEAN_ORG}                ${CLEAN_ORG}
    Set Suite Variable          ${CLEAN_WSPACE}             ${CLEAN_WSPACE}

    ${headers}=                 Create Dictionary
    ...                         accept=application/json
    ...                         X-Authorization=${CLEAN_API_KEY}
    ...                         X-Workspace-Id=${CLEAN_WSPACE}

    # Create a persistent session to automatically capture and forward tracking cookies
    Create Session              alias=CopadoSession         url=https://copadogpt-api.robotic.copado.com            headers=${headers}
    Log To Console              Persistent request session initialized.


Send Message To Agent
    [Documentation]             Posts a prompt message to the specified assistant dialogue thread.
    ...                         403 RETRY STRATEGY:
    ...                         The Copado AI API returns 403 on a dialogue thread that is still
    ...                         warming up after creation or document upload.
    ...                         This keyword retries the POST up to ${max_retries} times using
    ...                         exponential backoff.
    [Arguments]                 ${target_assistant_id}
    ...                         ${prompt}
    ...                         ${max_retries}=10
    ...                         ${backoff_base}=10

    ${msg_uuid}=                Evaluate                    str(uuid.uuid4())           modules=uuid
    Log To Console              Sending message with request ID: ${msg_uuid}

    ${message_payload}=         Create Dictionary
    ...                         request_id=${msg_uuid}
    ...                         prompt=${prompt}
    ...                         assistantId=${target_assistant_id}

    # ── RETRY LOOP ──────────────────────────────────────────────────────────
    FOR                         ${attempt}                  IN RANGE                    1                           ${max_retries} + 1

        Log To Console          📤 [Attempt ${attempt}/${max_retries}] POSTing message to dialogue ${DIALOGUE_ID}...
        ${url}                  Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/messages
        ${response}=            POST On Session
        ...                     alias=CopadoSession
        ...                     url=/organizations/\${CLEAN_ORG}/dialogues/\${DIALOGUE_ID}/messages
        ...                     json=${message_payload}
        ...                     expected_status=any
        ...                     timeout=90

        ${http_status}=         Set Variable                ${response.status_code}
        Log To Console          ↳ HTTP ${http_status} received.

        # ── SUCCESS ─────────────────────────────────────────────────────────
        IF                      ${http_status} == 200
            Log To Console      ✅ Message accepted by API on attempt ${attempt}.
            RETURN
        END

        # ── 403: API not ready, back off and retry ───────────────────────────
        IF                      ${http_status} == 403
            IF                  ${attempt} == ${max_retries}
                Fail
                ...             SEND MESSAGE FAILED: Received 403 on all ${max_retries} attempts.
                ...             Dialogue ID: ${DIALOGUE_ID}
                ...             The API session context may not have finished initialising.
            END

            ${exponent}=        Evaluate                    ${attempt} - 1
            ${wait_seconds}=    Evaluate                    ${backoff_base} * (2 ** ${exponent})
            Log To Console      ⚠️ 403 received. API not ready. Backing off ${wait_seconds}s before retry ${attempt + 1}/${max_retries}...
            Sleep               ${wait_seconds}s
            CONTINUE
        END

        # ── ANY OTHER NON-200 STATUS: Fail immediately, no retry ─────────────
        Fail
        ...                     SEND MESSAGE FAILED: Unexpected HTTP ${http_status} on attempt ${attempt}.
        ...                     Dialogue ID: ${DIALOGUE_ID}
        ...                     Response body: ${response.text}
    END


Capture Org Context And Prime AI Agent
    [Documentation]             Fetches live org data, sanitizes it, persists as JSON, and primes the AI thread.
    [Arguments]                 ${area_objects}             ${timestamp}                ${agent_name}=Orchestrate Agent

    ${config}=                  Build Org Contract Config                               ${area_objects}
    ${raw_result}=              Execute Dynamic Operations                              ${config}
    ${obj_dict}=                Create Dictionary           Lead=${raw_result}
    ${clean_result}=            Sanitize Org Contract       ${obj_dict}

    ${meta_file}=               Set Variable                ${OUTPUT_DIR}/org_context_${timestamp}.json
    Create File                 ${meta_file}                ${clean_result}

    Initialize Copado AI Session
    ${TARGET_ASSISTANT_ID}=     Get Agent ID By Name        ${agent_name}               ${CLEAN_WSPACE}

    Create Dialogue Thread      ${TARGET_ASSISTANT_ID}

    Log To Console              🧠 Giving the ${agent_name} access to the org data...
    Attach Document To Dialogue                             ${meta_file}
    Verify Document Is Ready    org_context_${timestamp}.json

    RETURN                      ${meta_file}


Get Agent ID By Name
    [Documentation]             Resolves a Copado AI assistant ID by its visible name within a given workspace.
    [Arguments]                 ${target_name}              ${workspace_id}
    ${WSPACE}=                  String.Strip String         ${workspace_id}

    Log To Console              Discovering assistants in workspace: ${WSPACE}

    ${workspace_detail_res}=    GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/workspaces/${WSPACE}
    ...                         expected_status=200
    ...                         timeout=90

    ${workspace_data}=          Set Variable                ${workspace_detail_res.json()}
    ${assistants_list}=         Set Variable                ${workspace_data['assistants']}
    ${TARGET_ASSISTANT_ID}=     Set Variable                knowledge

    FOR                         ${assistant}                IN                          @{assistants_list}
        Log To Console          Found Agent: ${assistant['visible_name']} (ID: ${assistant['id']})
        IF                      '${target_name}' in '${assistant['visible_name']}'
            ${TARGET_ASSISTANT_ID}=                         Set Variable                ${assistant['id']}
            Log To Console      Target matched! Using Assistant ID: ${TARGET_ASSISTANT_ID}
            BREAK
        END
    END

    Log To Console              Resolved Assistant ID: ${TARGET_ASSISTANT_ID}
    RETURN                      ${TARGET_ASSISTANT_ID}


Create Dialogue Thread
    [Documentation]             Creates a new AI dialogue thread with a dynamically generated name.
    [Arguments]                 ${target_assistant_id}

    ${timestamp}=               DateTime.Get Current Date                               result_format=%m/%d/%Y %I:%M:%S%p
    ${timestamp}=               String.Convert To Lower Case                            ${timestamp}
    ${dialogue_name}=           Set Variable                Test Creation ${timestamp}
    Log To Console              Creating dialogue: ${dialogue_name}

    ${dialogue_payload}=        Create Dictionary
    ...                         name=${dialogue_name}
    ...                         workspaceId=${CLEAN_WSPACE}
    ...                         assistantId=${target_assistant_id}

    ${create_dial_res}=         POST On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues
    ...                         json=${dialogue_payload}
    ...                         expected_status=201
    ...                         timeout=90

    ${dialogue_data}=           Set Variable                ${create_dial_res.json()}
    ${DIALOGUE_ID}=             Set Variable                ${dialogue_data['id']}
    Set Suite Variable          ${DIALOGUE_ID}              ${DIALOGUE_ID}
    Log To Console              Dialogue created with ID: ${DIALOGUE_ID}
    RETURN                      ${DIALOGUE_ID}

Wait Until Dialogue Is Idle
    [Documentation]             Polls the dialogue state endpoint until the thread reports it is idle.
    [Arguments]                 ${max_attempts}=12          ${poll_interval}=5s

    Log To Console              ⏳ Waiting for dialogue ${DIALOGUE_ID} to become idle...

    FOR                         ${attempt}                  IN RANGE                    1                           ${max_attempts} + 1
        ${dial_res}=            GET On Session
        ...                     alias=CopadoSession
        ...                     url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
        ...                     expected_status=any
        ...                     timeout=30

        ${dial_data}=           Set Variable                ${dial_res.json()}

        ${status}=              Get From Dictionary         ${dial_data}                status                      default=unknown
        ${is_processing}=       Get From Dictionary         ${dial_data}                is_processing               default=${False}

        Log To Console          [Attempt ${attempt}/${max_attempts}] Dialogue status: '${status}' | is_processing: ${is_processing}

        ${status_is_active}=    Run Keyword And Return Status
        ...                     Should Be True
        ...                     '${status}' in ['processing', 'active', 'streaming', 'running']

        IF                      not ${status_is_active} and not ${is_processing}
            Log To Console      ✅ Dialogue is idle. Proceeding after attempt ${attempt}.
            RETURN
        END

        Log To Console          🔄 Thread still active. Waiting ${poll_interval} before retry...
        Sleep                   ${poll_interval}
    END

    Fail
    ...                         TIMEOUT: Dialogue ${DIALOGUE_ID} did not become idle after ${max_attempts} attempts.
    ...                         Last known status: '${status}' | is_processing: ${is_processing}.


Attach Document To Dialogue
    [Documentation]             Uploads a local file using the persistent session pool.
    [Arguments]                 ${file_path}

    ${absolute_path}=           Normalize Path              ${file_path}
    Should Exist                ${absolute_path}

    ${file_name}=               Fetch From Right            ${absolute_path}            /
    ${file_handle}=             Evaluate                    open($absolute_path, 'rb')
    ${file_tuple}=              Create List                 ${file_name}                ${file_handle}              application/octet-stream
    ${file_obj}=                Create Dictionary           file=${file_tuple}

    ${upload_headers}=          Create Dictionary           accept=application/json

    ${upload_res}=              POST On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/documents
    ...                         headers=${upload_headers}
    ...                         files=${file_obj}
    ...                         expected_status=201
    ...                         timeout=90

    Log To Console              Document successfully attached: ${file_name}
    RETURN                      ${file_name}


Verify Document Is Ready
    [Arguments]                 ${file_name}

    ${dialogue_res}=            GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
    ...                         expected_status=any
    ...                         timeout=90

    ${session_res}=             GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/agent-session
    ...                         expected_status=any
    ...                         timeout=90

    Log To Console              \n--- [DIAGNOSTIC: DIALOGUE THREAD STATE] ---
    Log To Console              Dialogue HTTP Status: ${dialogue_res.status_code}
    Log To Console              ------------------------------------------
    Log To Console              \n--- [DIAGNOSTIC: AGENT SESSION STATE] ---
    Log To Console              Session HTTP Status: ${session_res.status_code}
    Log To Console              ----------------------------------------

    RETURN                      ${dialogue_res.json()}


Retrieve Agent Reply
    [Documentation]             Waits for the streaming agent to finish, then fetches the last message.
    Sleep                       5s

    ${history_res}=             GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
    ...                         expected_status=200
    ...                         timeout=90

    ${history_json}=            Set Variable                ${history_res.json()}
    ${all_messages}=            Set Variable                ${history_json['messages']}
    ${last_message}=            Set Variable                ${all_messages[-1]}
    ${ai_final_reply}=          Set Variable                ${last_message['content']}

    Log To Console              Compiled AI Agent Answer Received.
    RETURN                      ${ai_final_reply}


Compile Golden Path Script
    [Documentation]             Translates the JSON Golden Path into a pure Robot Framework script.
    ${script_content}=          Set Variable                *** Test Cases ***\nAgentic Generated Test\n

    FOR                         ${action}                   IN                          @{GOLDEN_PATH_SCRIPT}
        ${keyword}=             Get From Dictionary         ${action}                   keyword
        ${args}=                Get From Dictionary         ${action}                   args                        default=@{EMPTY}
        ${kwargs}=              Get From Dictionary         ${action}                   kwargs                      default=&{EMPTY}

        ${step_string}=         Set Variable                \ \ \ \ ${keyword}

        FOR                     ${arg}                      IN                          @{args}
            ${step_string}=     Catenate                    SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}              ${step_string}              ${arg}
        END

        FOR                     ${key}                      ${val}                      IN                          &{kwargs}
            ${step_string}=     Catenate                    SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}              ${step_string}              ${key}=${val}
        END

        ${script_content}=      Catenate                    SEPARATOR=\n                ${script_content}           ${step_string}
    END

    Log To Console              🌟 COMPILED GOLDEN PATH SCRIPT 🌟
    Log To Console              Script: \n${script_content}

    ${ts}=                      Get Time                    format=%Y%m%d_%H%M%S
    ${file_path}=               Set Variable                ${OUTPUT_DIR}/Agentic_Golden_Path_${ts}.robot
    Create File                 ${file_path}                ${script_content}
    Log To Console              💾 Backup saved to: ${file_path}

    ${TARGET_ASSISTANT_ID}=     Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}
    Send Message To Agent       ${TARGET_ASSISTANT_ID}      Please store the ${file_path} to the Test Job SF_Regression_Baseline inside the test folder and please do not ask to confirm just go ahead

    RETURN                      ${script_content}


Execute Agentic JSON Steps
    [Documentation]             Iterates over AI-proposed JSON steps, executes them, and routes failures.
    [Arguments]                 ${json_steps}
    ...                         ${user_intent}

    @{DESTRUCTIVE_TRIGGERS}=    Create List
    ...                         save                        next                        done                        submit                      confirm            create    finish

    FOR                         ${index}                    ${step}                     IN ENUMERATE                @{json_steps}
        ${step_intent}=         Get From Dictionary         ${step}                     intent
        ${strategies}=          Get From Dictionary         ${step}                     strategies
        ${is_risky}=            Get From Dictionary         ${step}                     is_risky                    default=${False}

        Log To Console          \n🤖 Attempting Intent: ${step_intent}

        ${step_passed}=         Set Variable                ${False}
        ${last_error}=          Set Variable                ${EMPTY}
        ${failure_mode}=        Set Variable                HARD_KEYWORD_ERROR

        FOR                     ${strategy_actions}         IN                          @{strategies}
            ${strategy_passed}=                             Set Variable                ${True}
            ${temp_passed_actions}=                         Create List

            FOR                 ${action}                   IN                          @{strategy_actions}
                ${keyword}=     Get From Dictionary         ${action}                   keyword                     default=UNKNOWN_KEYWORD
                ${args}=        Get From Dictionary         ${action}                   args                        default=@{EMPTY}
                ${raw_kwargs}=                              Get From Dictionary         ${action}                   kwargs                      default=&{EMPTY}

                IF              '${keyword}' == 'UNKNOWN_KEYWORD'
                    ${strategy_passed}=                     Set Variable                ${False}
                    ${last_error}=                          Catenate                    ${last_error}               [Strategy failed] AI returned malformed JSON missing the 'keyword' key.
                    BREAK
                END

                ${is_dict}=     Evaluate                    isinstance($raw_kwargs, dict)
                IF              not ${is_dict}
                    ${raw_kwargs}=                          Create Dictionary
                END

                ${clean_kwargs}=                            Create Dictionary
                FOR             ${key}                      ${val}                      IN                          &{raw_kwargs}
                    ${is_bool}=                             Evaluate                    isinstance($val, bool)
                    IF          ${is_bool}
                        ${str_val}=                         Evaluate                    str($val)
                        Set To Dictionary                   ${clean_kwargs}             ${key}                      ${str_val}
                    ELSE
                        Set To Dictionary                   ${clean_kwargs}             ${key}                      ${val}
                    END
                END

                ${escaped_args}=                            Create List
                FOR             ${arg}                      IN                          @{args}
                    ${is_str}=                              Evaluate                    isinstance($arg, str)
                    IF          ${is_str}
                        ${arg}=                             Evaluate                    JsonSanitizer.escape_xpath_arg($arg)
                    END
                    Append To List                          ${escaped_args}             ${arg}
                END

                ${url_before}=                              GetUrl
                Set To Dictionary                           ${action}                   url_before                  ${url_before}

                Log To Console                              ↳ Executing: ${keyword}
                ${status}       ${message}=                 Run Keyword And Ignore Error                            ${keyword}                  @{escaped_args}    &{clean_kwargs}

                ${url_after}=                               GetUrl
                Set To Dictionary                           ${action}                   url_after                   ${url_after}

                IF              '${status}' == 'PASS'
                    ${is_destructive}=                      Set Variable                ${False}
                    FOR         ${arg}                      IN                          @{escaped_args}
                        ${arg_lower}=                       Evaluate                    str($arg).lower().strip()
                        ${trigger_hit}=                     Run Keyword And Return Status
                        ...     Should Contain              ${DESTRUCTIVE_TRIGGERS}     ${arg_lower}
                        IF      ${trigger_hit}
                            ${is_destructive}=              Set Variable                ${True}
                            BREAK
                        END
                    END

                    IF          ${is_destructive}
                        Log To Console                      🔍 Destructive action detected. Running Post-Action Snag Check...
                        UseModal                            Off
                        ${snag_found}=                      IsText                      We hit a snag               timeout=3s
                        ${review_found}=                    IsText                      Review the following fields                             timeout=2s
                        ${field_error}=                     IsElement
                        ...     xpath=//div[contains(@class,'slds-has-error')]
                        ...     timeout=2s
                        ${toast_error}=                     IsElement
                        ...     xpath=//*[contains(@class,'slds-theme_error')]
                        ...     timeout=2s

                        ${snag_detected}=                   Evaluate
                        ...     $snag_found or $review_found or $field_error or $toast_error

                        IF      ${snag_detected}
                            UseModal                        On
                            ${snag_detail}=                 Set Variable                ${EMPTY}
                            IF                              ${snag_found}
                                ${snag_detail}=             Set Variable                'We hit a snag' banner visible
                            ELSE IF                         ${review_found}
                                ${snag_detail}=             Set Variable                'Review the following fields' banner visible
                            ELSE IF                         ${field_error}
                                ${snag_detail}=             Set Variable                slds-has-error field element detected
                            ELSE IF                         ${toast_error}
                                ${snag_detail}=             Set Variable                slds-theme_error toast element detected
                            END

                            ${strategy_passed}=             Set Variable                ${False}
                            ${failure_mode}=                Set Variable                SILENT_APP_ERROR
                            ${last_error}=                  Set Variable
                            ...                             SILENT_APP_ERROR: ${snag_detail} after ${keyword} ${escaped_args}
                            Log To Console                  ❌ Snag detected: ${last_error}
                            BREAK
                        ELSE
                            Log To Console                  ✅ Snag Check passed. No error signals detected.
                        END
                    END

                    IF          ${strategy_passed}
                        Append To List                      ${temp_passed_actions}      ${action}
                    END

                ELSE
                    ${strategy_passed}=                     Set Variable                ${False}
                    ${failure_mode}=                        Set Variable                HARD_KEYWORD_ERROR
                    ${last_error}=                          Catenate                    SEPARATOR=\n                ${last_error}               [Strategy failed] ${keyword} → ${message}
                    Log To Console                          ↳ Strategy failed at ${keyword}: ${message}.
                    BREAK
                END
            END

            IF                  ${strategy_passed}
                FOR             ${passed_action}            IN                          @{temp_passed_actions}
                    Append To Passed History                ${passed_action}
                    Append To Golden Path                   ${passed_action}
                END
                ${step_passed}=                             Set Variable                ${True}
                BREAK
            ELSE IF             '${failure_mode}' == 'SILENT_APP_ERROR'
                Log To Console                              ⛔ SILENT_APP_ERROR confirmed. Skipping all remaining fallback strategies.
                BREAK
            END
        END

        IF                      not ${step_passed}
            Append To Failed History                        ${step}
            Log To Console      ❌ All strategies failed for: ${step_intent}. Mode: ${failure_mode}. Pausing for Agentic Re-Prompt.
            RETURN              FAIL                        ${step}                     ${last_error}               ${index}                    ${failure_mode}
        END
    END

    RETURN                      PASS                        ${NONE}                     ${EMPTY}                    -1                          NONE


Generate Agentic System Prompt
    [Documentation]             Defines clean, low-bloat rules for the blind initial generation phase.
    ${rules}=                   Catenate                    SEPARATOR=\n
    ...                         You are an AI Test Agent operating Copado Robotic Testing (CRT) via QWeb and QForce.
    ...                         Translate the user intent into a clean, chronological sequence of baseline test steps.
    ...
    ...                         RULES FOR INITIAL PHASE (NO DOM CONTEXT AVAILABLE):
    ...                         1. Output ONLY a structured JSON array matching the schema format below. No conversational text.
    ...                         2. Separate "keyword", "args" (array), and "kwargs" (object) cleanly.
    ...                         3. THE 1-TO-1 ACTION RULE: Every object in the root array represents exactly ONE discrete browser interaction. Do not combine sequential steps.
    ...                         4. LINEAR CONTRACT: Because you cannot see the live DOM yet, provide exactly ONE execution track inside the "strategies" array. Do not attempt to guess or invent backup paths.
    ...                         5. Ambiguous clicks (like "Save") MUST include "partial_match=False" in kwargs.
    ...
    ...                         INITIAL SCHEMA FORMAT:
    ...                         [
    ...                         {
    ...                         "intent": "Launch the Sales application context",
    ...                         "is_risky": true,
    ...                         "confidence_score": 98,
    ...                         "strategies": [
    ...                         [
    ...                         { "keyword": "LaunchApp", "args": ["Sales"], "kwargs": {} }
    ...                         ]
    ...                         ]
    ...                         }
    ...                         ]
    RETURN                      ${rules}


Resolve Step Failure
    [Documentation]             Recovers from a failed agentic step by opening a FRESH dialogue thread for the AI Surgeon.
    [Arguments]                 ${assistant_id}
    ...                         ${failed_step}
    ...                         ${error_message}
    ...                         ${remaining_steps}
    ...                         ${dom_json_path}
    ...                         ${executed_history_json}
    ...                         ${user_intent}
    ...                         ${failure_mode}=HARD_KEYWORD_ERROR

    ${ORIGINAL_DIALOGUE_ID}=    Set Variable                ${DIALOGUE_ID}
    Log To Console              🔒 Original dialogue preserved: ${ORIGINAL_DIALOGUE_ID}

    Log To Console              🆕 Opening fresh surgeon dialogue...
    Create Dialogue Thread      ${assistant_id}
    Log To Console              ✅ Surgeon dialogue created: ${DIALOGUE_ID}