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
    Evaluate                    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)    modules=urllib3
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
    [Arguments]                 ${target_assistant_id}      ${DIALOGUE_ID}
    ...                         ${prompt}
    ...                         ${max_retries}=50
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
        ...                     url=${url}
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
            ${wait_seconds}=    Evaluate                    min(${backoff_base} * (2 ** ${exponent}), 30)
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

Generate Initial Test Steps
    [Documentation]             Combines the system rules and user intent, sends it to the AI, and retrieves the structured JSON step sequence.
    [Arguments]                 ${assistant_id}             ${user_intent}

    # Fetch the rigid rules telling the AI to output exactly a JSON array
    ${system_prompt}=           Generate Agentic System Prompt

    # Combine the system rules with the specific scenario the test wants to run
    ${full_prompt}=             Catenate                    SEPARATOR=\n\n
    ...                         ${system_prompt}
    ...                         USER INTENT: ${user_intent}

    Log To Console              🧠 Generating initial test steps for intent: ${user_intent}

    # Send to the active dialogue thread (DIALOGUE_ID is stored as a suite variable)
    Send Message To Agent       ${assistant_id}             ${DIALOGUE_ID}              ${full_prompt}

    # Wait for the AI's compiled response
    ${ai_reply}=                Retrieve Agent Reply

    RETURN                      ${ai_reply}

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

    ${DIALOGUE_ID}              Create Dialogue Thread      ${TARGET_ASSISTANT_ID}

    Log To Console              🧠 Giving the ${agent_name} access to the org data...
    Attach Document To Dialogue                             ${meta_file}                ${DIALOGUE_ID}
    Verify Document Is Ready    org_context_${timestamp}.json                           ${DIALOGUE_ID}

    RETURN                      ${meta_file}


Get Agent ID By Name
    [Documentation]             Resolves a Copado AI assistant ID by its visible name within a given workspace.
    [Arguments]                 ${target_name}              ${workspace_id}
    ${WSPACE}=                  String.Strip String         ${workspace_id}

    Log To Console              Discovering assistants in workspace: ${WSPACE}

    ${url_workspace}            Set Variable                /organizations/${CLEAN_ORG}/workspaces/${WSPACE}

    ${workspace_detail_res}=    GET On Session
    ...                         alias=CopadoSession
    ...                         url=${url_workspace}
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

    # ADD THIS BLOCK:
    IF                          '${TARGET_ASSISTANT_ID}' == 'knowledge'
        Fail                    ❌ Could not find an Assistant named '${target_name}'. Please verify the name in your workspace.
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

    ${url_dialogues}            Set Variable                /organizations/${CLEAN_ORG}/dialogues

    ${create_dial_res}=         POST On Session
    ...                         alias=CopadoSession
    ...                         url=${url_dialogues}
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
    [Arguments]                 ${DIALOGUE_ID}              ${max_attempts}=12          ${poll_interval}=5s

    Log To Console              ⏳ Waiting for dialogue ${DIALOGUE_ID} to become idle...

    ${url}                      Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}

    FOR                         ${attempt}                  IN RANGE                    1                           ${max_attempts} + 1
        ${dial_res}=            GET On Session
        ...                     alias=CopadoSession
        ...                     url=${url}
        ...                     expected_status=any
        ...                     timeout=30

        ${dial_data}=           Set Variable                ${dial_res.json()}

        ${status}=              Get From Dictionary         ${dial_data}                status                      default=unknown
        ${is_processing}=       Get From Dictionary         ${dial_data}                is_processing               default=${False}

        # ADD THIS BLOCK:
        IF                      '${status}' in ['failed', 'error']
            Fail                ❌ Dialogue entered an ERROR state during document indexing!
        END

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
    [Arguments]                 ${file_path}                ${DIALOGUE_ID}

    ${absolute_path}=           Normalize Path              ${file_path}
    Should Exist                ${absolute_path}

    # ${file_name}=               Fetch From Right            ${absolute_path}            /
    # ${file_handle}=             Evaluate                    open($absolute_path, 'rb')
    # # ${file_tuple}=            Create List                 ${file_name}                ${file_handle}              application/octet-stream
    # ${file_tuple}=              Create List                 ${file_name}                ${file_handle}              application/json
    # ${file_obj}=                Create Dictionary           file=${file_tuple}
    
    ${file_name}=               Fetch From Right            ${absolute_path}            /
    ${file_handle}=             Evaluate                    open($absolute_path, 'rb')
    
    # --- NEW: Dynamic MIME Type detection ---
    ${ext}=                     Evaluate                    '${file_name}'.split('.')[-1].lower()
    ${mime_type}=               Evaluate                    'image/png' if '${ext}' in ['png', 'jpg', 'jpeg'] else 'application/json'
    ${file_tuple}=              Create List                 ${file_name}                ${file_handle}              ${mime_type}
    # ----------------------------------------
    
    ${file_obj}=                Create Dictionary           file=${file_tuple}

    ${upload_headers}=          Create Dictionary           accept=application/json

    ${dialogue_document_url}    Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/documents

    ${upload_res}=              POST On Session
    ...                         alias=CopadoSession
    ...                         url=${dialogue_document_url}
    ...                         headers=${upload_headers}
    ...                         files=${file_obj}
    ...                         expected_status=201
    ...                         timeout=90

    Log To Console              Document successfully attached: ${file_name}
    RETURN                      ${file_name}


Verify Document Is Ready
    [Arguments]                 ${file_name}                ${DIALOGUE_ID}

    ${url}                      Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}

    ${dialogue_res}=            GET On Session
    ...                         alias=CopadoSession
    ...                         url=${url}
    ...                         expected_status=any
    ...                         timeout=90

    ${agent_session_url}        Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/agent-session

    ${session_res}=             GET On Session
    ...                         alias=CopadoSession
    ...                         url=${agent_session_url}
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
    
    # Dynamically wait for the stream to finish (up to 120 seconds)
    Wait Until Dialogue Is Idle             ${DIALOGUE_ID}              max_attempts=24          poll_interval=5s

    ${dialogue_url}             Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}

    ${history_res}=             GET On Session
    ...                         alias=CopadoSession
    ...                         url=${dialogue_url}
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
    ...                         Insulated against 502/403 gateway crashes by reusing the active assistant ID.
    [Arguments]                 ${DIALOGUE_ID}              ${assistant_id}=${NONE}
    # Injects the login keyword explicitly at the top of the compiled test
    ${script_content}=          Set Variable                *** Test Cases ***\nAgentic Generated Test\n\ \ \ \ UI Login Via JWT\n

    FOR                         ${action}                   IN                          @{GOLDEN_PATH_SCRIPT}
        ${keyword}=             Get From Dictionary         ${action}                   keyword    default=# MISSING_KEYWORD
        ${args}=                Get From Dictionary         ${action}                   args                        default=@{EMPTY}
        ${kwargs}=              Get From Dictionary         ${action}                   kwargs                      default=&{EMPTY}

        ${step_string}=         Set Variable                \ \ \ \ ${keyword}

        FOR                     ${arg}                      IN                          @{args}
            ${step_string}=     Catenate                    SEPARATOR\=${SPACE}${SPACE}${SPACE}${SPACE}             ${step_string}             ${arg}
        END

        FOR                     ${key}                      ${val}                      IN                          &{kwargs}
            ${step_string}=     Catenate                    SEPARATOR\=${SPACE}${SPACE}${SPACE}${SPACE}             ${step_string}             ${key}=${val}
        END

        ${script_content}=      Catenate                    ${script_content}           ${step_string}
    END

    Log To Console              🌟 COMPILED GOLDEN PATH SCRIPT 🌟
    Log To Console              Script: \n${script_content}

    ${ts}=                      Get Time                    format=%Y%m%d_%H%M%S
    ${file_path}=               Set Variable                ${OUTPUT_DIR}/Agentic_Golden_Path_${ts}.robot
    Create File                 ${file_path}                ${script_content}
    Log To Console              💾 Backup saved to: ${file_path}

    # ── NETWORK RESILIENCY CHECK ──
    # If the assistant ID is passed, reuse it directly to protect teardown from gateway errors
    IF                          '${assistant_id}' != '${NONE}' and '${assistant_id}' != '${EMPTY}'
        ${TARGET_ASSISTANT_ID}=  Set Variable                ${assistant_id}
    ELSE
        ${TARGET_ASSISTANT_ID}=  Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}
    END
    
    Send Message To Agent       ${TARGET_ASSISTANT_ID}      ${DIALOGUE_ID}              Please store the ${file_path} to the Test Job SF_Regression_Baseline inside the test folder and please do not ask to confirm just go ahead
    
    # Wait for the AI to finish saving the file before we start the next test scenario
    ${ignore_reply}=            Retrieve Agent Reply

    RETURN                      ${script_content}


Execute Agentic JSON Steps
    [Documentation]             Iterates over AI-proposed JSON steps, executes them, and routes failures.
    [Arguments]                 ${json_steps}
    ...                         ${user_intent}

    @{DESTRUCTIVE_TRIGGERS}=    Create List
    ...                         save                        next                        done                        submit                     confirm            create    finish

    FOR                         ${index}                    ${step}                     IN ENUMERATE                @{json_steps}
        # ADD DEFAULTS HERE
        ${step_intent}=         Get From Dictionary         ${step}                     intent        default=UNKNOWN_STEP_INTENT
        ${strategies}=          Get From Dictionary         ${step}                     strategies    default=@{EMPTY}
        ${is_risky}=            Get From Dictionary         ${step}                     is_risky      default=${False}

        Log To Console          \n🤖 Attempting Intent: ${step_intent}

        ${step_passed}=         Set Variable                ${False}
        ${last_error}=          Set Variable                ${EMPTY}
        ${failure_mode}=        Set Variable                HARD_KEYWORD_ERROR

        FOR                     ${strategy_actions}         IN                          @{strategies}
            ${strategy_passed}=                             Set Variable                ${True}
            ${temp_passed_actions}=                         Create List

            FOR                 ${action}                   IN                          @{strategy_actions}
                ${keyword}=     Get From Dictionary         ${action}                   keyword                     default=UNKNOWN_KEYWORD
                
                # --- NEW SAFETY FILTER ---
                IF              '${keyword}' == 'UI Login Via JWT' or '${keyword}' == 'Login'
                    Log To Console      ⏩ Skipping '${keyword}' during agentic execution (already logged in).
                    CONTINUE
                END
                # -------------------------

                ${args}=        Get From Dictionary         ${action}                   args                        default=@{EMPTY}
                ${raw_kwargs}=                              Get From Dictionary         ${action}                   kwargs                     default=&{EMPTY}

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
                ${status}       ${message}=                 Run Keyword And Ignore Error                            ${keyword}                 @{escaped_args}    &{clean_kwargs}

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
                        ${review_found}=                    IsText                      Review the following fields                            timeout=2s
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
                    ${last_error}=                          Catenate                    ${last_error}               [Strategy failed] ${keyword} → ${message}
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
            RETURN              FAIL                        ${step}                     ${last_error}               ${index}                   ${failure_mode}
        END
    END

    RETURN                      PASS                        ${NONE}                     ${EMPTY}                    -1                         NONE


Generate Agentic System Prompt
    [Documentation]             Defines clean, low-bloat rules for the blind initial generation phase.
    ...                         Upgraded with Fix 3: Enforced post-save Salesforce UI sync rules.
    ${rules}=                   Catenate
    ...                         You are an AI Test Agent operating Copado Robotic Testing (CRT) via QWeb and QForce.
    ...                         Translate the user intent into a clean, chronological sequence of baseline test steps.
    ...
    ...                         RULES FOR INITIAL PHASE (NO DOM CONTEXT AVAILABLE):
    ...                         1. Output ONLY a structured JSON array matching the schema format below. No conversational text.
    ...                         2. Separate "keyword", "args" (array), and "kwargs" (object) cleanly.
    ...                         3. THE 1-TO-1 ACTION RULE: Every object in the root array represents exactly ONE discrete browser interaction. Do not combine sequential steps.
    ...                         4. LINEAR CONTRACT: Because you cannot see the live DOM yet, provide exactly ONE execution track inside the "strategies" array. Do not attempt to guess or invent backup paths.
    ...                         5. Ambiguous clicks (like "Save") MUST include "partial_match\=False" in kwargs.
    ...                         6. ASSUME PRE-AUTHENTICATED: The browser is already open and logged into Salesforce. Do NOT include any login steps or keywords (like UI Login Via JWT). Start immediately with the test intent.
    ...                         7. POST-SAVE SYNCHRONIZATION CONSTRAINT: When submitting a record creation form via a "Save" button interaction, Salesforce Lightning requires asynchronous backend transactions to commit before drawing the record title layout header. You must structure subsequent verification assertions to expect or naturally allow a page load buffer (e.g. tracking visible field strings or using explicit waiting parameters) before calling rigid text-header layout checks.
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
    ...                         Includes an integrated self-correction loop to handle malformed json layouts or root arrays.
    [Arguments]                 ${assistant_id}
    ...                         ${failed_step}
    ...                         ${error_message}
    ...                         ${remaining_steps}
    ...                         ${dom_json_path}
    ...                         ${screenshot_path}
    ...                         ${executed_history_json}
    ...                         ${user_intent}
    ...                         ${failure_mode}=HARD_KEYWORD_ERROR

    ${ORIGINAL_DIALOGUE_ID}=    Set Variable                ${DIALOGUE_ID}
    Log To Console              🔒 Original dialogue preserved: ${ORIGINAL_DIALOGUE_ID}

    Log To Console              🆕 Opening fresh surgeon dialogue...
    ${DIALOGUE_ID}              Create Dialogue Thread      ${assistant_id}
    Log To Console              ✅ Surgeon dialogue created: ${DIALOGUE_ID}

    # Attach the DOM state if available
    IF  '${dom_json_path}' != '${NONE}'
        Attach Document To Dialogue    ${dom_json_path}    ${DIALOGUE_ID}
    END

    # --- Convert Screenshot to Base64 Markdown ---
    ${markdown_image}=          Set Variable                ${EMPTY}
    IF  '${screenshot_path}' != '${NONE}'
        Log To Console          📸 Encoding failure screenshot for AI Vision...
        ${base64_image}=        Evaluate                    __import__('base64').b64encode(open(r'${screenshot_path}', 'rb').read()).decode('utf-8')
        ${markdown_image}=      Set Variable                \n\n![Screenshot](data:image/png;base64,${base64_image})
    END

    # Build the Initial Surgeon Prompt
    ${surgeon_prompt}=          Catenate
    ...                         You are an AI Surgeon tasked with fixing a broken test step.
    ...                         Original Goal: ${user_intent}
    ...                         Failed Step: ${failed_step}
    ...                         Error Encountered: ${error_message}
    ...                         Failure Mode: ${failure_mode}
    ...                         Execution History: ${executed_history_json}
    ...                         Remaining Steps: ${remaining_steps}
    ...                         Please analyze the attached DOM context AND the visual screenshot below to fix the broken step.
    ...                         RULES:
    ...                         1. You MUST output ONLY valid JSON. Do not output raw Robot Framework script or conversational text.
    ...                         2. Your response must match this exact dictionary schema:
    ...                         {
    ...                           "escalate": false,
    ...                           "escalation_reason": "",
    ...                           "recovery_steps": [ { "intent": "Describe the action", "keyword": "...", "args": [], "kwargs": {} } ],
    ...                           "corrected_steps": [ { "intent": "Describe the action", "keyword": "...", "args": [], "kwargs": {} } ]
    ...                         }${markdown_image}
    
    # Dispatch initial request
    Send Message To Agent       ${assistant_id}    ${DIALOGUE_ID}    ${surgeon_prompt}
    ${ai_reply}=                Retrieve Agent Reply
    
    # ── SELF-CORRECTION RETRY LOOP ──────────────────────────────────────────
    FOR    ${attempt}    IN RANGE    1    10
        # Safely dry-run parse the text block without tripping structural framework exceptions
        ${status}    ${parsed}=  Run Keyword And Ignore Error    Extract Agent JSON Reply    ${ai_reply}
        ${is_dict}=              Evaluate                    isinstance($parsed, dict) if '${status}' == 'PASS' else False
        
        IF    ${is_dict}
            Log To Console      ✅ AI Surgeon payload validated successfully as Dictionary structure on attempt ${attempt}.
            BREAK
        END
        
        # If execution reaches here, the AI returned an invalid layout (like a raw list or syntax garbage)
        Log To Console          ⚠️ AI Surgeon returned invalid schema structure (Attempt ${attempt}/3). Issuing error correction...
        
        ${correction_prompt}=    Catenate
        ...                     CRITICAL ERROR: Your previous response violated the structural constraints.\n
        ...                     The response must be a single root JSON object/dictionary enclosed in curly braces {}.\n
        ...                     You returned a raw list/array or text format which caused a system type parsing failure.\n
        ...                     Please re-read the required keys ("escalate", "escalation_reason", "recovery_steps", "corrected_steps") and resubmit your response wrapped strictly inside a single JSON dictionary object.
        
        Send Message To Agent   ${assistant_id}    ${DIALOGUE_ID}    ${correction_prompt}
        ${ai_reply}=            Retrieve Agent Reply
    END
    # ─────────────────────────────────────────────────────────────────────────
    
    # Restore the original dialogue ID so the main execution thread can resume
    Set Suite Variable          ${DIALOGUE_ID}     ${ORIGINAL_DIALOGUE_ID}
    
    RETURN                      ${ai_reply}


    # ════════════════════════════════════════════════════════════════════
    # AGENTIC STEP TRACKING - Appenders & Setters
    # ════════════════════════════════════════════════════════════════════

Append To Proposed Steps
    [Arguments]                 ${step}
    Append To List              ${ALL_PROPOSED_STEPS}       ${step}
    Set Suite Variable          @{ALL_PROPOSED_STEPS}       @{ALL_PROPOSED_STEPS}

Append To Passed History
    [Arguments]                 ${step}
    Append To List              ${EXECUTION_HISTORY_PASSED}                             ${step}
    Set Suite Variable          @{EXECUTION_HISTORY_PASSED}                             @{EXECUTION_HISTORY_PASSED}

Append To Failed History
    [Arguments]                 ${step}
    Append To List              ${EXECUTION_HISTORY_FAILED}                             ${step}
    Set Suite Variable          @{EXECUTION_HISTORY_FAILED}                             @{EXECUTION_HISTORY_FAILED}

Append To Golden Path
    [Arguments]                 ${step}
    Append To List              ${GOLDEN_PATH_SCRIPT}       ${step}
    Set Suite Variable          @{GOLDEN_PATH_SCRIPT}       @{GOLDEN_PATH_SCRIPT}

Set All Proposed Steps
    [Arguments]                 @{steps}
    Set Suite Variable          @{ALL_PROPOSED_STEPS}       @{steps}


Extract Agent JSON Reply
    [Documentation]             Extracts and parses the JSON from Copado AI's structured reply safely.
    ...                         Handles three input shapes:
    ...                         1. A full dialogue dict     (the raw dialogue_data object)
    ...                         2. A content list           (the AI message's content array)
    ...                         3. A plain string           (a raw JSON text block, optionally fenced)
    ...
    ...                         All escape sanitization is delegated to JsonSanitizer.py to avoid
    ...                         Robot Framework escaping-layer interference with regex patterns.
    [Arguments]                 ${ai_final_reply}

    ${raw_text}=                Set Variable                ${ai_final_reply}

    # ── STEP 0: UNWRAP FULL DIALOGUE DICT ──────────────────────────────────
    # If the caller passed the entire dialogue_data object, drill into
    # messages -> last AI turn -> content list before any further processing.
    ${is_dict}=                 Evaluate                    isinstance($ai_final_reply, dict)
    IF                          ${is_dict}
        ${messages}=            Get From Dictionary         ${ai_final_reply}           messages                    default=${NONE}
        IF                      $messages == $NONE or len($messages) == 0
            Fail                Parser Error: dialogue_data contains no messages.
        END
        # Walk messages to find the last AI (assistant) turn
        ${ai_content}=          Set Variable                ${NONE}
        FOR                     ${msg}                      IN                          @{messages}
            ${role}=            Get From Dictionary         ${msg}                      role                        default=${EMPTY}
            IF                  '${role}' == 'ai'
                ${ai_content}=                              Get From Dictionary         ${msg}                      content                    default=${NONE}
            END
        END
        IF                      $ai_content == $NONE
            Fail                Parser Error: No AI message found in dialogue_data.
        END
        ${raw_text}=            Set Variable                ${ai_content}
    END

    # ── STEP 1: UNWRAP CONTENT LIST ────────────────────────────────────────
    # Pull the raw JSON text payload out of the Copado API content list wrapper.
    # Priority: prefer the block that carries an artifact (the structured JSON block).
    # Fall back to the first block that starts with '[' or '{'.
    ${is_list}=                 Evaluate                    isinstance($raw_text, list)
    IF                          ${is_list}
        FOR                     ${item}                     IN                          @{raw_text}
            ${artifact}=        Get From Dictionary         ${item}                     artifact                    default=${NONE}
            IF                  $artifact != $NONE
                ${raw_text}=    Get From Dictionary         ${item}                     text
                BREAK
            END
            ${text_val}=        Get From Dictionary         ${item}                     text                        default=${EMPTY}
            ${stripped}=        Evaluate                    str($text_val).strip()

            # Safe native string probing
            ${starts_with_bracket}=                         Run Keyword And Return Status                           Should Contain             ${stripped}        [
            ${starts_with_brace}=                           Run Keyword And Return Status                           Should Contain             ${stripped}        {
            IF                  ${starts_with_bracket} or ${starts_with_brace}
                ${raw_text}=    Set Variable                ${text_val}
                BREAK
            END
        END
    END

    # Guard: after unwrapping, raw_text must now be a string
    ${is_still_non_string}=     Evaluate                    not isinstance($raw_text, str)
    IF                          ${is_still_non_string}
        Log To Console          🚨 FATAL: raw_text type\=${raw_text.__class__.__name__} | value\=${raw_text}
        Fail                    Parser Error: Input could not be reduced to a JSON string after unwrapping.
    END

    # ── STEP 2: SANITIZE + PARSE (delegated to Python library) ─────────────
    # parse_ai_json_reply() handles fence stripping, escape flattening,
    # invalid escape removal, and XPath \= re-injection in pure Python,
    # with no Robot Framework escaping-layer interference.
    ${parsed_json}=             Evaluate                    JsonSanitizer.parse_ai_json_reply($raw_text)
    # ${parsed_json}=           Evaluate                    JsonSanitizer.parse_ai_json_reply($raw_text)            modules=JsonSanitizer
    Log To Console              Stack Parser: Contract extraction completed successfully.

    RETURN                      ${parsed_json}