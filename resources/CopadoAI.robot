*** Settings ***
Documentation                   Persistent interaction session management with Copado AI.
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

# ── COPADO REPOSITORY & JOB METADATA VARIABLES ───────────────────────────
${PROJECT_NAME}                 IOVIOtrial
${PROJECT_ID}                   107859
${TEST_JOB_NAME}                SF_Regression_Baseline
${TEST_JOB_ID}                  188251
# ─────────────────────────────────────────────────────────────────────────

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

    Create Session              alias=CopadoSession         url=https://copadogpt-api.robotic.copado.com            headers=${headers}
    Log To Console              Persistent request session initialized.

Send Message To Agent
    [Documentation]             Posts a prompt message to the specified assistant dialogue thread with exponential backoff for 403 warming periods.
    [Arguments]                 ${target_assistant_id}      ${DIALOGUE_ID}              ${prompt}    ${max_retries}=50    ${backoff_base}=10
    ${msg_uuid}=                Evaluate                    str(uuid.uuid4())           modules=uuid
    Log To Console              Sending message with request ID: ${msg_uuid}

    ${message_payload}=         Create Dictionary
    ...                         request_id=${msg_uuid}
    ...                         prompt=${prompt}
    ...                         assistantId=${target_assistant_id}

    FOR                         ${attempt}                  IN RANGE                    1                           ${max_retries} + 1
        Log To Console          📤 [Attempt ${attempt}/${max_retries}] POSTing message to dialogue ${DIALOGUE_ID}...
        ${url}                  Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/messages
        ${response}=            POST On Session             alias=CopadoSession         url=${url}                  json=${message_payload}    expected_status=any    timeout=90
        ${http_status}=         Set Variable                ${response.status_code}
        Log To Console          ↳ HTTP ${http_status} received.

        IF                      ${http_status} == 200
            Log To Console      ✅ Message accepted by API on attempt ${attempt}.
            RETURN
        END

        IF                      ${http_status} == 403
            IF                  ${attempt} == ${max_retries}
                Fail            SEND MESSAGE FAILED: Received 403 on all ${max_retries} attempts. Dialogue ID: ${DIALOGUE_ID}
            END
            ${exponent}=        Evaluate                    ${attempt} - 1
            ${wait_seconds}=    Evaluate                    min(${backoff_base} * (2 ** ${exponent}), 30)
            Log To Console      ⚠️ 403 received. API not ready. Backing off ${wait_seconds}s before retry ${attempt + 1}/${max_retries}...
            Sleep               ${wait_seconds}s
            CONTINUE
        END

        Fail                    SEND MESSAGE FAILED: Unexpected HTTP ${http_status} on attempt ${attempt}. Dialogue ID: ${DIALOGUE_ID}. Response: ${response.text}
    END

Generate Initial Test Steps
    [Documentation]             Combines the system rules and user intent, sends it to the AI, and retrieves the structured JSON step sequence.
    [Arguments]                 ${assistant_id}             ${user_intent}
    ${system_prompt}=           Generate Agentic System Prompt
    ${full_prompt}=             Catenate                    SEPARATOR=\n\n             ${system_prompt}            USER INTENT: ${user_intent}
    Log To Console              🧠 Generating initial test steps for intent: ${user_intent}
    Send Message To Agent       ${assistant_id}             ${DIALOGUE_ID}              ${full_prompt}
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
    ${url_workspace}=           Set Variable                /organizations/${CLEAN_ORG}/workspaces/${WSPACE}
    ${workspace_detail_res}=    GET On Session              alias=CopadoSession         url=${url_workspace}        expected_status=200    timeout=90
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

    ${url_dialogues}=           Set Variable                /organizations/${CLEAN_ORG}/dialogues
    ${create_dial_res}=         POST On Session             alias=CopadoSession         url=${url_dialogues}        json=${dialogue_payload}    expected_status=201    timeout=90
    ${dialogue_data}=           Set Variable                ${create_dial_res.json()}
    ${DIALOGUE_ID}=             Set Variable                ${dialogue_data['id']}
    Set Suite Variable          ${DIALOGUE_ID}              ${DIALOGUE_ID}
    Log To Console              Dialogue created with ID: ${DIALOGUE_ID}
    RETURN                      ${DIALOGUE_ID}

Wait Until Dialogue Is Idle
    [Documentation]             Polls the dialogue state endpoint until the thread reports it is idle.
    [Arguments]                 ${DIALOGUE_ID}              ${max_attempts}=12          ${poll_interval}=5s
    Log To Console              ⏳ Waiting for dialogue ${DIALOGUE_ID} to become idle...
    ${url}=                     Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}

    FOR                         ${attempt}                  IN RANGE                    1                           ${max_attempts} + 1
        ${dial_res}=            GET On Session              alias=CopadoSession         url=${url}                  expected_status=any    timeout=30
        ${dial_data}=           Set Variable                ${dial_res.json()}
        ${status}=              Get From Dictionary         ${dial_data}                status                      default=unknown
        ${is_processing}=       Get From Dictionary         ${dial_data}                is_processing               default=${False}

        IF                      '${status}' in ['failed', 'error']
            Fail                ❌ Dialogue entered an ERROR state during document indexing!
        END

        Log To Console          [Attempt ${attempt}/${max_attempts}] Dialogue status: '${status}' | is_processing: ${is_processing}
        ${status_is_active}=    Run Keyword And Return Status                           Should Be True              '${status}' in ['processing', 'active', 'streaming', 'running']

        IF                      not ${status_is_active} and not ${is_processing}
            Log To Console      ✅ Dialogue is idle. Proceeding after attempt ${attempt}.
            RETURN
        END

        Log To Console          🔄 Thread still active. Waiting ${poll_interval} before retry...
        Sleep                   ${poll_interval}
    END

    Fail                        TIMEOUT: Dialogue ${DIALOGUE_ID} did not become idle after ${max_attempts} attempts. Last known status: '${status}'

Attach Document To Dialogue
    [Documentation]             Uploads a local file using the persistent session pool.
    [Arguments]                 ${file_path}                ${DIALOGUE_ID}
    ${absolute_path}=           Normalize Path              ${file_path}
    Should Exist                ${absolute_path}
    
    ${file_name}=               Fetch From Right            ${absolute_path}            /
    ${file_handle}=             Evaluate                    open($absolute_path, 'rb')
    
    ${ext}=                     Evaluate                    '${file_name}'.split('.')[-1].lower()
    ${mime_type}=               Evaluate                    'image/png' if '${ext}' in ['png', 'jpg', 'jpeg'] else 'application/json'
    ${file_tuple}=              Create List                 ${file_name}                ${file_handle}              ${mime_type}
    
    ${file_obj}=                Create Dictionary           file=${file_tuple}
    ${upload_headers}=          Create Dictionary           accept=application/json
    ${dialogue_document_url}=   Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/documents

    ${upload_res}=              POST On Session             alias=CopadoSession         url=${dialogue_document_url}    headers=${upload_headers}    files=${file_obj}    expected_status=201    timeout=90
    Log To Console              Document successfully attached: ${file_name}
    RETURN                      ${file_name}

Verify Document Is Ready
    [Arguments]                 ${file_name}                ${DIALOGUE_ID}
    ${url}=                     Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
    ${dialogue_res}=            GET On Session              alias=CopadoSession         url=${url}                  expected_status=any    timeout=90
    ${agent_session_url}=       Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/agent-session
    ${session_res}=             GET On Session              alias=CopadoSession         url=${agent_session_url}    expected_status=any    timeout=90

    Log To Console              \n--- [DIAGNOSTIC: DIALOGUE THREAD STATE] ---
    Log To Console              Dialogue HTTP Status: ${dialogue_res.status_code}
    Log To Console              ------------------------------------------
    Log To Console              \n--- [DIAGNOSTIC: AGENT SESSION STATE] ---
    Log To Console              Session HTTP Status: ${session_res.status_code}
    Log To Console              ----------------------------------------
    RETURN                      ${dialogue_res.json()}

Retrieve Agent Reply
    [Documentation]             Waits for the streaming agent to finish and ensures the messages history array is populated with the AI response to eliminate race conditions.
    [Arguments]                 ${max_polls}=15             ${poll_sleep}=3s
    Wait Until Dialogue Is Idle                             ${DIALOGUE_ID}              max_attempts=24             poll_interval=5s
    ${dialogue_url}=            Set Variable                /organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}

    FOR                         ${poll_idx}                 IN RANGE                    1                           ${max_polls} + 1
        ${history_res}=         GET On Session              alias=CopadoSession         url=${dialogue_url}         expected_status=200    timeout=90
        ${history_json}=        Set Variable                ${history_res.json()}
        ${all_messages}=        Get From Dictionary         ${history_json}             messages                    default=@{EMPTY}
        ${msg_count}=           Get Length                  ${all_messages}

        IF                      ${msg_count} > 0
            ${last_message}=    Get From List               ${all_messages}             -1
            ${role}=            Get From Dictionary         ${last_message}             role                        default=${EMPTY}
            
            IF                  '${role}' == 'ai' or '${role}' == 'assistant'
                ${ai_final_reply}=                          Get From Dictionary         ${last_message}             content
                Log To Console                              ✅ Compiled AI Agent Answer Received.
                RETURN                                      ${ai_final_reply}
            END
        END

        Log To Console          🔄 Message queue unpopulated or AI role pending (Poll ${poll_idx}/${max_polls}). Waiting ${poll_sleep}...
        Sleep                   ${poll_sleep}
    END

    Fail                        ❌ TIMEOUT: Dialogue history messages array is empty or missing AI response after polling constraints.

Compile Golden Path Script
    [Documentation]             Translates the JSON Golden Path into a pure Robot Framework script.
    ...                         Formats the output with structural Settings, Suite Setup, Test Setup, and clean step breaks.
    [Arguments]                 ${DIALOGUE_ID}              ${assistant_id}=${NONE}
    
    ${four_spaces}=             Set Variable                ${SPACE}${SPACE}${SPACE}${SPACE}
    
    # ── BUILD THE CORRECT ROBOT FRAMEWORK HEADERS ────────────────────────────
    # Configured with Suite Setup for JWT Auth and Test Setup to enforce navigation to Home page
    ${settings_block}=          Set Variable                *** Settings ***\nResource${four_spaces}../resources/common_keywords.robot\nSuite Setup${four_spaces}UI Login Via JWT\nTest Setup${four_spaces}Home\n\n
    ${test_cases_block}=        Set Variable                *** Test Cases ***\nAgentic Generated Test\n
    ${script_content}=          Set Variable                ${settings_block}${test_cases_block}
    # ─────────────────────────────────────────────────────────────────────────

    FOR                         ${action}                   IN                          @{GOLDEN_PATH_SCRIPT}
        ${keyword}=             Get From Dictionary         ${action}                   keyword                     default=# MISSING_KEYWORD
        ${args}=                Get From Dictionary         ${action}                   args                        default=@{EMPTY}
        ${kwargs}=              Get From Dictionary         ${action}                   kwargs                      default=&{EMPTY}

        # Skip adding inline logins since it is now safely handled by the Suite Setup
        IF                      '${keyword}' == 'UI Login Via JWT' or '${keyword}' == 'Login'
            CONTINUE
        END

        # Start the step with 4 spaces indentation
        ${step_string}=         Set Variable                ${four_spaces}${keyword}

        # Append positional arguments separated by 4 spaces
        FOR                     ${arg}                      IN                          @{args}
            ${step_string}=     Catenate                    SEPARATOR=${four_spaces}    ${step_string}              ${arg}
        END

        # Append keyword arguments separated by 4 spaces
        FOR                     ${key}                      ${val}                      IN                          &{kwargs}
            ${step_string}=     Catenate                    SEPARATOR=${four_spaces}    ${step_string}              ${key}=${val}
        END

        # Append the complete formatted line with a trailing explicit newline character (\n)
        ${script_content}=      Set Variable                ${script_content}${step_string}\n
    END

    Log To Console              🌟 COMPILED GOLDEN PATH SCRIPT 🌟
    Log To Console              Script: \n${script_content}

    ${ts}=                      Get Time                    format=%Y%m%d_%H%M%S
    ${file_name}=               Set Variable                Agentic_Golden_Path_${ts}.robot
    ${file_path}=               Set Variable                ${OUTPUT_DIR}/${file_name}
    Create File                 ${file_path}                ${script_content}
    Log To Console              💾 Backup saved to: ${file_path}

    IF                          '${assistant_id}' != '${NONE}' and '${assistant_id}' != '${EMPTY}'
        ${TARGET_ASSISTANT_ID}=  Set Variable               ${assistant_id}
    ELSE
        ${TARGET_ASSISTANT_ID}=  Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}
    END
    
    ${agent_prompt}=            Catenate
    ...                         Please create a new file named "${file_name}" inside the "tests/" folder of the Test Job "${TEST_JOB_NAME}" (ID: ${TEST_JOB_ID}) within Project "${PROJECT_NAME}" (ID: ${PROJECT_ID}).\n\n
    ...                         Here is the exact file content you must write:\n
    ...                         ${script_content}\n\n
    ...                         Do not attempt to read local filesystem paths and do not pause to ask for human confirmation.
    ...                         Use your internal file upload/creation tools to commit this content immediately.
    
    # ── SEND SCRIPT TO THE AGENT FOR COMMITMENT ──────────────────────────────
    Send Message To Agent       ${TARGET_ASSISTANT_ID}      ${DIALOGUE_ID}              ${agent_prompt}
    ${agent_reply}=             Retrieve Agent Reply
    
    # Check if the AI triggered its safety confirmation protocol (handles "confirm" or "proceed")
    ${reply_lower}=             Convert To Lower Case        ${agent_reply}
    ${requires_confirm}=        Run Keyword And Return Status    Should Contain     ${reply_lower}    confirm
    ${requires_proceed}=        Run Keyword And Return Status    Should Contain     ${reply_lower}    proceed
    
    IF                          ${requires_confirm} or ${requires_proceed}
        Log To Console          \n⚠️ AI requested confirmation before uploading/committing the file.
        Log To Console          💬 Sending confirmation response: "Yes"
        
        Send Message To Agent   ${TARGET_ASSISTANT_ID}      ${DIALOGUE_ID}              Yes
        ${final_reply}=         Retrieve Agent Reply
        
        Log To Console          ✅ File commit processed successfully.
    ELSE
        Log To Console          ✅ File created directly without confirmation hurdles.
    END
    # ─────────────────────────────────────────────────────────────────────────

    RETURN                      ${script_content}

Execute Agentic JSON Steps
    [Documentation]             Iterates over AI-proposed JSON steps, executes them, and routes failures.
    [Arguments]                 ${json_steps}               ${user_intent}
    @{DESTRUCTIVE_TRIGGERS}=    Create List                 save                        next                        done                        submit                     confirm            create    finish

    FOR                         ${index}                    ${step}                     IN ENUMERATE                @{json_steps}
        ${step_intent}=         Get From Dictionary         ${step}                     intent                      default=UNKNOWN_STEP_INTENT
        ${strategies}=          Get From Dictionary         ${step}                     strategies                  default=@{EMPTY}
        ${is_risky}=            Get From Dictionary         ${step}                     is_risky                    default=${False}

        Log To Console          \n🤖 Attempting Intent: ${step_intent}
        ${step_passed}=         Set Variable                ${False}
        ${last_error}=          Set Variable                ${EMPTY}
        ${failure_mode}=        Set Variable                HARD_KEYWORD_ERROR

        FOR                         ${strategy_actions}         IN                          @{strategies}
            ${strategy_passed}=                             Set Variable                ${True}
            ${temp_passed_actions}=                         Create List

            FOR                 ${action}                   IN                          @{strategy_actions}
                ${keyword}=     Get From Dictionary         ${action}                   keyword                     default=UNKNOWN_KEYWORD
         
                IF              '${keyword}' == 'UI Login Via JWT' or '${keyword}' == 'Login'
                    Log To Console      ⏩ Skipping '${keyword}' during agentic execution (already logged in).
                    CONTINUE
                END

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
                        ${trigger_hit}=                     Run Keyword And Return Status                           Should Contain              ${DESTRUCTIVE_TRIGGERS}    ${arg_lower}
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
                        ${field_error}=                     IsElement                   xpath=//div[contains(@class,'slds-has-error')]          timeout=2s
                        ${toast_error}=                     IsElement                   xpath=//*[contains(@class,'slds-theme_error')]         timeout=2s
                        ${snag_detected}=                   Evaluate                    $snag_found or $review_found or $field_error or $toast_error

                        IF      ${snag_detected}
                            UseModal                        On
                            ${snag_detail}=                 Set Variable                ${EMPTY}
                            IF      ${snag_found}
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
                            ${last_error}=                  Set Variable                SILENT_APP_ERROR: ${snag_detail} after ${keyword} ${escaped_args}
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
            Log To Console                                  ❌ All strategies failed for: ${step_intent}.
            RETURN              FAIL                        ${step}                     ${last_error}               ${index}                   ${failure_mode}
        END
    END
    RETURN                      PASS                        ${NONE}                     ${EMPTY}                    -1                         NONE

Generate Agentic System Prompt
    [Documentation]             Defines clean, low-bloat rules for the blind initial generation phase.
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
    [Arguments]                 ${assistant_id}             ${failed_step}              ${error_message}            ${remaining_steps}    ${dom_json_path}    ${screenshot_path}    ${executed_history_json}    ${user_intent}    ${failure_mode}=HARD_KEYWORD_ERROR
    ${ORIGINAL_DIALOGUE_ID}=    Set Variable                ${DIALOGUE_ID}
    Log To Console              🔒 Original dialogue preserved: ${ORIGINAL_DIALOGUE_ID}
    Log To Console              🆕 Opening fresh surgeon dialogue...
    ${DIALOGUE_ID}              Create Dialogue Thread      ${assistant_id}
    Log To Console              ✅ Surgeon dialogue created: ${DIALOGUE_ID}

    IF  '${dom_json_path}' != '${NONE}'
        Attach Document To Dialogue                         ${dom_json_path}            ${DIALOGUE_ID}
    END

    ${markdown_image}=          Set Variable                ${EMPTY}
    IF  '${screenshot_path}' != '${NONE}'
        Log To Console          📸 Encoding failure screenshot for AI Vision...
        ${base64_image}=        Evaluate                    __import__('base64').b64encode(open(r'${screenshot_path}', 'rb').read()).decode('utf-8')
        ${markdown_image}=      Set Variable                \n\n![Screenshot](data:image/png;base64,${base64_image})
    END

    ${surgeon_prompt}=          Catenate
    ...                         You are an expert QA Automation AI Surgeon specializing in Salesforce testing using Robot Framework and QWeb.
    ...                         Your objective is to analyze a single failed test step, evaluate the error, and provide a corrected version of THAT SPECIFIC STEP so the test execution can successfully heal and continue.
    ...                         
    ...                         --- FAILURE CONTEXT ---
    ...                         • Failed Step: ${failed_step}
    ...                         • Error Encountered: ${error_message}
    ...                         • Prior Execution History: ${executed_history_json}
    ...                         
    ...                         --- CRITICAL HEALING RULES FOR PICKLISTS ---
    ...                         1. If the failure involves selecting a picklist value (e.g., 'Open - Not Contacted' is not found), you MUST consult the attached 'org_context_*.json' metadata file.
    ...                         2. Treat this JSON file as your absolute source of truth. Locate the specific object (e.g., Lead) and field (e.g., Status) to view the actual allowed 'picklistValues' array.
    ...                         3. Identify a valid option string directly from the metadata list. Update the failed step arguments to use this valid option instead. Do NOT guess or invent values.
    ...                         
    ...                         --- SYSTEM CONSTRAINTS & OUTPUT FORMAT ---
    ...                         • You must respond ONLY with a single, valid JSON object representing the single corrected step.
    ...                         • Do NOT wrap your response in markdown code blocks like \`\`\`json ... \`\`\`.
    ...                         • The JSON must strictly follow this dictionary structure:
    ...                         {
    ...                             "intent": "Select a valid alternative Status value derived from metadata context",
    ...                             "keyword": "PickList",
    ...                             "arguments": ["Status", "Working - Contacted"]
    ...                         }
    
    Send Message To Agent       ${assistant_id}             ${DIALOGUE_ID}              ${surgeon_prompt}
    ${ai_reply}=                Retrieve Agent Reply
    
    # ── SELF-CORRECTION RETRY LOOP ──────────────────────────────────────────
    FOR    ${attempt}    IN RANGE    1    4
        ${status}    ${parsed}=  Run Keyword And Ignore Error                            Extract Agent JSON Reply    ${ai_reply}
        ${is_dict}=              Evaluate                    isinstance($parsed, dict) if '${status}' == 'PASS' else False
        
        IF    ${is_dict}
            Log To Console      ✅ AI Surgeon payload validated successfully as Dictionary structure on attempt ${attempt}.
            BREAK
        END
        
        Log To Console          ⚠️ AI Surgeon returned invalid schema structure (Attempt ${attempt}/3). Issuing error correction...
        ${correction_prompt}=    Catenate
        ...                     CRITICAL ERROR: Your previous response violated the structural constraints.\n
        ...                     The response must be a single root JSON object/dictionary enclosed in curly braces {}.\n
        ...                     You returned a raw list/array or text format which caused a system type parsing failure.\n
        ...                     Please re-read the required keys ("escalate", "escalation_reason", "recovery_steps", "corrected_steps") and resubmit your response wrapped strictly inside a single JSON dictionary object.
        
        Send Message To Agent   ${assistant_id}             ${DIALOGUE_ID}              ${correction_prompt}
        ${ai_reply}=            Retrieve Agent Reply
    END
    # ─────────────────────────────────────────────────────────────────────────

    Set Suite Variable          ${DIALOGUE_ID}              ${ORIGINAL_DIALOGUE_ID}
    RETURN                      ${ai_reply}

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
    [Arguments]                 ${ai_final_reply}
    ${raw_text}=                Set Variable                ${ai_final_reply}

    ${is_dict}=                 Evaluate                    isinstance($ai_final_reply, dict)
    IF                          ${is_dict}
        ${messages}=            Get From Dictionary         ${ai_final_reply}           messages                    default=${NONE}
        IF                      $messages == $NONE or len($messages) == 0
            Fail                Parser Error: dialogue_data contains no messages.
        END
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
            ${starts_with_bracket}=                         Run Keyword And Return Status                           Should Contain              ${stripped}        [
            ${starts_with_brace}=                           Run Keyword And Return Status                           Should Contain              ${stripped}        {
            IF                  ${starts_with_bracket} or ${starts_with_brace}
                ${raw_text}=    Set Variable                ${text_val}
                BREAK
            END
        END
    END

    ${is_still_non_string}=     Evaluate                    not isinstance($raw_text, str)
    IF                          ${is_still_non_string}
        Fail                    Parser Error: Input could not be reduced to a JSON string after unwrapping. Value received: ${raw_text}
    END

    ${parsed_json}=             Evaluate                    JsonSanitizer.parse_ai_json_reply($raw_text)
    Log To Console              Stack Parser: Contract extraction completed successfully.
    RETURN                      ${parsed_json}