*** Settings ***
Library                         RequestsLibrary
Library                         Collections
Library                         String
Library                         DateTime
Library                         OperatingSystem
Library                         QWeb
Library                         QForce
Library                         String
Library                         DateTime
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
    Create Session              alias=CopadoSession         url=https://copadogpt-api.robotic.copado.com          headers=${headers}
    Log To Console              Persistent request session initialized.

    # Send Message To Agent
    #                           [Documentation]             Sends a prompt message while ensuring Content-Type is pristine.
    #                           [Arguments]                 ${target_assistant_id}      ${prompt}

    #                           ${msg_uuid}=                Evaluate                    str(uuid.uuid4())         modules=uuid
    #                           Log To Console              Sending message with request ID: ${msg_uuid}

    #                           ${msg_headers}=             Create Dictionary           Content-Type=application/json

    #                           ${message_payload}=         Create Dictionary
    #                           ...                         request_id=${msg_uuid}
    #                           ...                         prompt=${prompt}
    #                           ...                         assistantId=${target_assistant_id}

    #                           # Post using the identical session pool to preserve validation state
    #                           ${send_msg_res}=            POST On Session
    #                           ...                         alias=CopadoSession
    #                           ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/messages
    #                           ...                         headers=${msg_headers}
    #                           ...                         json=${message_payload}
    #                           ...                         expected_status=200
Send Message To Agent
    [Documentation]             Posts a prompt message to the specified assistant dialogue thread.
    ...
    ...                         403 RETRY STRATEGY:
    ...                         The Copado AI API returns 403 on a dialogue thread that is still
    ...                         warming up after creation or document upload, even when a GET on
    ...                         the dialogue returns 200 with no active-processing signals.
    ...                         This keyword retries the POST up to ${max_retries} times using
    ...                         exponential backoff (base ${backoff_base}s, doubling each attempt)
    ...                         before raising a hard failure.
    ...
    ...                         Retry schedule (defaults):
    ...                         Attempt 1 - immediate
    ...                         Attempt 2 - wait 10s
    ...                         Attempt 3 - wait 20s
    ...                         Attempt 4 - wait 40s
    ...                         Attempt 5 - wait 80s        (total budget ~150s)
    [Arguments]                 ${target_assistant_id}
    ...                         ${prompt}
    ...                         ${max_retries}=5
    ...                         ${backoff_base}=10

    ${msg_uuid}=                Evaluate                    str(uuid.uuid4())           modules=uuid
    Log To Console              Sending message with request ID: ${msg_uuid}

    ${message_payload}=         Create Dictionary
    ...                         request_id=${msg_uuid}
    ...                         prompt=${prompt}
    ...                         assistantId=${target_assistant_id}

    # ── RETRY LOOP ──────────────────────────────────────────────────────────
    FOR                         ${attempt}                  IN RANGE                    1                         ${max_retries} + 1

        Log To Console          📤 [Attempt ${attempt}/${max_retries}] POSTing message to dialogue ${DIALOGUE_ID}...

        ${response}=            POST On Session
        ...                     alias=CopadoSession
        ...                     url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/messages
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
            # Exhausted all retries. Fail with a clear diagnostic.
                Fail
                ...             SEND MESSAGE FAILED: Received 403 on all ${max_retries} attempts.
                ...             Dialogue ID: ${DIALOGUE_ID}
                ...             The API session context may not have finished initialising.
                ...             Consider increasing max_retries or backoff_base in the caller.
            END

            # Calculate exponential backoff: base * 2^(attempt-1)
            # Attempt 1 -> 10s, Attempt 2 -> 20s, Attempt 3 -> 40s, Attempt 4 -> 80s
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


Get Agent ID By Name
    [Documentation]             Resolves a Copado AI assistant ID by its visible name within
    ...                         a given workspace utilizing our active persistent session.
    [Arguments]                 ${target_name}              ${workspace_id}
    ${WSPACE}=                  String.Strip String         ${workspace_id}

    Log To Console              Discovering assistants in workspace: ${WSPACE}

    # FIX: Route through the persistent session alias; headers are handled automatically
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
Read Dialogue With Messages
    [Documentation]             Reads the details of an existing AI dialogue, including all its messages,
    ...                         using the persistent session alias. The dialogue data is stored as a
    ...                         suite variable for use in subsequent keywords or test cases.
    ...
    ...                         Only the dialogue creator and current workspace member can call this endpoint.
    ...
    ...                         Arguments:
    ...                         ${target_dialogue_id} - UUID of the dialogue to retrieve.
    [Arguments]                 ${target_dialogue_id}

    Log To Console              Reading dialogue with ID: ${target_dialogue_id}

    ${read_dial_res}=           GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${target_dialogue_id}
    ...                         expected_status=200
    ...                         timeout=90

    ${dialogue_data}=           Set Variable                ${read_dial_res.json()}

    # Store top-level fields as suite variables for downstream use
    ${DIALOGUE_ID}=             Set Variable                ${dialogue_data['id']}
    ${DIALOGUE_NAME}=           Set Variable                ${dialogue_data['name']}
    ${DIALOGUE_MESSAGES}=       Set Variable                ${dialogue_data['messages']}
    ${DIALOGUE_MSG_COUNT}=      Set Variable                ${dialogue_data['message_count']}

    Set Suite Variable          ${DIALOGUE_ID}              ${DIALOGUE_ID}
    Set Suite Variable          ${DIALOGUE_NAME}            ${DIALOGUE_NAME}
    Set Suite Variable          ${DIALOGUE_MESSAGES}        ${DIALOGUE_MESSAGES}
    Set Suite Variable          ${DIALOGUE_MSG_COUNT}       ${DIALOGUE_MSG_COUNT}

    Log To Console              Dialogue '${DIALOGUE_NAME}' retrieved with ${DIALOGUE_MSG_COUNT} message(s).

    [Return]                    ${dialogue_data}
Create Dialogue Thread
    [Documentation]             Creates a new AI dialogue thread with a dynamically generated name
    ...                         utilizing our active persistent session.
    ...
    ...                         FIX: Timestamp now uses second-level precision (%S suffix) to guarantee
    ...                         a unique dialogue name even when called multiple times within the same
    ...                         minute. Previously, minute-only precision caused the API to return the
    ...                         existing dialogue instead of creating a new one, resulting in the surgeon
    ...                         thread sharing the same UUID as the original thread and triggering a 403.
    [Arguments]                 ${target_assistant_id}

    # FIX: Added %S (seconds) to guarantee uniqueness within the same minute.
    ${timestamp}=               DateTime.Get Current Date
    ...                         result_format=%m/%d/%Y %I:%M:%S%p
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


Wait Until Dialogue Is Idle
    [Documentation]             Polls the dialogue state endpoint until the thread reports it is no
    ...                         longer actively processing a message. This prevents 403 deadlocks
    ...                         caused by POSTing a new message to a thread that is still streaming
    ...                         a prior AI response.
    ...
    ...                         Polls every ${poll_interval} seconds up to ${max_attempts} times.
    ...                         Raises a clear error if the thread does not become idle in time.
    [Arguments]                 ${max_attempts}=12          ${poll_interval}=5s

    Log To Console              ⏳ Waiting for dialogue ${DIALOGUE_ID} to become idle...

    FOR                         ${attempt}                  IN RANGE                    1                         ${max_attempts} + 1
        ${dial_res}=            GET On Session
        ...                     alias=CopadoSession
        ...                     url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
        ...                     expected_status=any
        ...                     timeout=30

        ${dial_data}=           Set Variable                ${dial_res.json()}

        # The API exposes a 'status' or 'is_processing' field on the dialogue object.
        # We check both known field shapes defensively.
        ${status}=              Get From Dictionary         ${dial_data}                status                    default=unknown
        ${is_processing}=       Get From Dictionary         ${dial_data}                is_processing             default=${False}

        Log To Console          [Attempt ${attempt}/${max_attempts}] Dialogue status: '${status}' | is_processing: ${is_processing}

        # Treat the thread as idle if status is not an active/processing value
        # AND is_processing is not True.
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

    # If we exhausted all attempts, fail with a clear diagnostic message.
    Fail
    ...                         TIMEOUT: Dialogue ${DIALOGUE_ID} did not become idle after ${max_attempts} attempts.
    ...                         Last known status: '${status}' | is_processing: ${is_processing}.
    ...                         The prior AI response may still be streaming. Increase max_attempts or poll_interval.

Attach Document To Dialogue
    [Documentation]             Uploads a local file using the persistent session pool.
    [Arguments]                 ${file_path}

    ${absolute_path}=           Normalize Path              ${file_path}
    Should Exist                ${absolute_path}

    ${file_name}=               Fetch From Right            ${absolute_path}            /
    ${file_handle}=             Evaluate                    open($absolute_path, 'rb')
    ${file_tuple}=              Create List                 ${file_name}                ${file_handle}            application/octet-stream
    ${file_obj}=                Create Dictionary           file=${file_tuple}

    ${upload_headers}=          Create Dictionary           accept=application/json

    # POST using session alias to seamlessly intercept the secure RAG cookies
    ${upload_res}=              POST On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/documents
    ...                         headers=${upload_headers}
    ...                         files=${file_obj}
    ...                         expected_status=201
    ...                         timeout=90

    Log To Console              Document successfully attached: ${file_name}
    RETURN                      ${file_name}                # 🌟 Simply return the file name string

Verify Document Is Ready
    [Arguments]                 ${file_name}

    # 1. Inspect the main dialogue thread state
    ${dialogue_res}=            GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
    ...                         expected_status=any
    ...                         timeout=90

    # 2. Inspect the agent session state
    ${session_res}=             GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}/agent-session
    ...                         expected_status=any
    ...                         timeout=90

    # 🔍 Dump both payloads to the console so we can see the lock keys
    Log To Console              \n--- [DIAGNOSTIC: DIALOGUE THREAD STATE] ---
    Log To Console              Dialogue HTTP Status: ${dialogue_res.status_code}
    Log To Console              Dialogue Payload: ${dialogue_res.json()}
    Log To Console              ------------------------------------------
    Log To Console              \n--- [DIAGNOSTIC: AGENT SESSION STATE] ---
    Log To Console              Session HTTP Status: ${session_res.status_code}
    Log To Console              Session Payload: ${session_res.json()}
    Log To Console              ----------------------------------------

    RETURN                      ${dialogue_res.json()}
Retrieve Agent Reply
    [Documentation]             Waits for the streaming agent to finish, then fetches the full
    ...                         dialogue thread and extracts the last message content using our session pool.
    # Give the RAG engine ample time to process larger file structures
    Sleep                       5s

    # FIX: Route through the persistent session alias and drop the old headers variable reference
    ${history_res}=             GET On Session
    ...                         alias=CopadoSession
    ...                         url=/organizations/${CLEAN_ORG}/dialogues/${DIALOGUE_ID}
    ...                         expected_status=200
    ...                         timeout=90

    ${history_json}=            Set Variable                ${history_res.json()}
    ${all_messages}=            Set Variable                ${history_json['messages']}
    ${last_message}=            Set Variable                ${all_messages[-1]}
    ${ai_final_reply}=          Set Variable                ${last_message['content']}

    Log To Console              Compiled AI Agent Answer Received:
    Log To Console              ${ai_final_reply}

    RETURN                      ${ai_final_reply}

Extract And Sanitize Robot Script
    [Documentation]             Extracts a clean, executable Robot Framework script from the AI reply.
    [Arguments]                 ${ai_final_reply}

    # ── Prong 1: Structured artifact path ────────────────────────────────────
    ${final_robot_script}=      Set Variable                ${NONE}

    ${is_list}=                 Evaluate                    isinstance($ai_final_reply, list)
    IF                          ${is_list}
        FOR                     ${item}                     IN                          @{ai_final_reply}
            ${has_artifact}=    Run Keyword And Return Status
            ...                 Dictionary Should Contain Key                           ${item}                   artifact
            IF                  ${has_artifact}
                ${artifact}=    Get From Dictionary         ${item}                     artifact
                IF              $artifact != $NONE and $artifact.get('language') == 'robot'
                    ${final_robot_script}=                  Get From Dictionary         ${item}                   text
                    Log To Console                          Prong 1 matched: structured artifact block found.
                    BREAK
                END
            END
        END

        # Prong 1 secondary: look for raw *** Settings *** marker in text values
        IF                      $final_robot_script == $NONE
            FOR                 ${item}                     IN                          @{ai_final_reply}
                ${text_val}=    Get From Dictionary         ${item}                     text
                IF              '*** Settings ***' in $text_val
                    ${final_robot_script}=                  Set Variable                ${text_val}
                    Log To Console                          Prong 1 secondary matched: Settings block found in text.
                    BREAK
                END
            END
        END
    END

    # ── Prong 2: Plain string markdown fence extraction ───────────────────────
    IF                          $final_robot_script == $NONE
        Log To Console          Prong 2 activated: attempting markdown fence extraction.
        ${cropped_left}=        Fetch From Right            ${ai_final_reply}           \`\`\`robot
        ${final_robot_script}=                              Fetch From Left             ${cropped_left}           \`\`\`
        ${final_robot_script}=                              Strip String                ${final_robot_script}
        Log To Console          Prong 2 extracted script block.
    END

    Log To Console              Raw extracted script:
    Log To Console              ${final_robot_script}

    # ── State machine sanitization loop ──────────────────────────────────────
    @{script_lines}=            Split To Lines              ${final_robot_script}
    ${cleaned_steps_list}=      Create List
    ${inside_test_cases}=       Set Variable                ${FALSE}
    ${passed_title_line}=       Set Variable                ${FALSE}

    FOR                         ${raw_line}                 IN                          @{script_lines}
        ${line}=                Strip String                ${raw_line}
        ${line}=                Replace String              ${line}                     \r                        ${EMPTY}

        # Skip empty lines and pure comments
        IF                      $line == "" or $line.startswith('#')
            CONTINUE
        END

        # Detect the Test Cases section boundary
        IF                      '*** Test Cases ***' in $line
            ${inside_test_cases}=                           Set Variable                ${TRUE}
            CONTINUE
        END

        IF                      ${inside_test_cases}
        # Skip any other structural section headers encountered inside
            IF                  $line.startswith('*')
                CONTINUE
            END

            # Skip the test case title line (first non-bracket, non-empty line)
            IF                  ${passed_title_line} == ${FALSE}
                IF              $line.startswith('[')
                    CONTINUE
                END
                ${passed_title_line}=                       Set Variable                ${TRUE}
                CONTINUE
            END

            # Skip inline test case settings (e.g. [Documentation], [Tags])
            IF                  $line.startswith('[')
                CONTINUE
            END

            # Skip suite/library/resource configuration lines
            IF                  $line.startswith('Library') or $line.startswith('Resource') or $line.startswith('Suite')
                CONTINUE
            END

            # Everything that falls through is a clean, executable step
            Append To List      ${cleaned_steps_list}       ${line}
        END
    END

    Log To Console              Sanitized steps to be executed:
    FOR                         ${step}                     IN                          @{cleaned_steps_list}
        Log To Console          -> ${step}
    END

    RETURN                      ${cleaned_steps_list}

DiscoverCopadoAIWorkspaces
    ${API_KEY}=                 String.Strip String         ${CopadoAIApi}
    ${ORG}=                     String.Strip String         ${ORG_ID}
    ${WSPACE}=                  String.Strip String         ${WORKSPACE_ID}
    Log To Console              ${API_KEY}
    ${headers}=                 Create Dictionary
    ...                         accept=application/json
    ...                         Content-Type=application/json
    ...                         X-Authorization=${API_KEY}

    ${list_res}=                RequestsLibrary.GET
    ...                         url=https://copadogpt-api.robotic.copado.com/organizations/${ORG}/workspaces
    ...                         headers=${headers}
    ...                         expected_status=200
    ...                         timeout=90

    Log To Console              workspaces available: ${list_res}







    ################### NEW KEYWORDS 6/9 #######################

Compile Golden Path Script
    [Documentation]             Translates the JSON Golden Path into a pure Robot Framework script.
    ...                         Logs to console for Live Testing and writes to a .robot file.

    ${script_content}=          Set Variable                *** Test Cases ***\nAgentic Generated Test\n

    FOR                         ${action}                   IN                          @{GOLDEN_PATH_SCRIPT}
        ${keyword}=             Get From Dictionary         ${action}                   keyword
        ${args}=                Get From Dictionary         ${action}                   args                      default=@{EMPTY}
        ${kwargs}=              Get From Dictionary         ${action}                   kwargs                    default=&{EMPTY}

        # Add 4 spaces for Robot Framework indentation
        ${step_string}=         Set Variable                \ \ \ \ ${keyword}

        FOR                     ${arg}                      IN                          @{args}
            ${step_string}=     Catenate                    SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}            ${step_string}              ${arg}
        END

        FOR                     ${key}                      ${val}                      IN                        &{kwargs}
            ${step_string}=     Catenate                    SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}            ${step_string}              ${key}=${val}
        END

        ${script_content}=      Catenate                    SEPARATOR=\n                ${script_content}         ${step_string}
    END

    Log To Console              🌟 COMPILED GOLDEN PATH SCRIPT 🌟
    Log To Console              Script: ${script_content}

    ${ts}=                      Get Time                    format=%Y%m%d_%H%M%S
    ${file_path}=               Set Variable                ${OUTPUT_DIR}/Agentic_Golden_Path_${ts}.robot
    Create File                 ${file_path}                ${script_content}
    Log To Console              💾 Backup saved to: ${file_path}

    RETURN                      ${script_content}

Create The successful Test Script

Execute Agentic JSON Steps
    [Documentation]             Iterates over AI-proposed JSON steps, executes each action sequence,
    ...                         and routes failures to the AI Surgeon.
    ...
    ...                         v3 changes:
    ...                         - Accepts ${user_intent} and passes it straight through to
    ...                         Resolve Step Failure so the surgeon always knows the original goal.
    ...                         - No other logic changes from v2.
    ...
    ...                         FALSE POSITIVE DETECTION (carried from v2):
    ...                         After any action whose args contain a destructive trigger word
    ...                         (Save, Next, Done, Submit, Confirm, Create, Finish), a Post-Action
    ...                         Snag Check fires at page scope:
    ...
    ...                         1. UseModal Off is called FIRST so IsText/IsElement search the full
    ...                         page. The Salesforce snag banner renders outside the modal container
    ...                         so modal scope would miss it entirely.
    ...
    ...                         2. Four signals are probed:
    ...                         a. IsText                   We hit a snag               (timeout=3s)
    ...                         b. IsText                   Review the following fields                           (timeout=2s)
    ...                         c. IsElement slds-has-error class                       (timeout=2s)
    ...                         d. IsElement slds-theme_error toast (timeout=2s)
    ...
    ...                         3. If any signal fires:
    ...                         - UseModal On is restored (form is still open, modal is still live)
    ...                         - error is prefixed SILENT_APP_ERROR: and routed to the surgeon
    ...                         - the strategy loop breaks immediately
    ...
    ...                         4. If no signal fires:
    ...                         - UseModal Off remains in effect
    ...                         - the next step manages its own modal scope as normal
    [Arguments]                 ${json_steps}
    ...                         ${user_intent}

    # Destructive trigger words. If any action arg matches one of these (case-insensitive),
    # the Post-Action Snag Check fires after that action completes with PASS.
    @{DESTRUCTIVE_TRIGGERS}=    Create List
    ...                         save                        next                        done                      submit                      confirm            create    finish

    FOR                         ${index}                    ${step}                     IN ENUMERATE              @{json_steps}
        ${step_intent}=         Get From Dictionary         ${step}                     intent
        ${strategies}=          Get From Dictionary         ${step}                     strategies
        ${is_risky}=            Get From Dictionary         ${step}                     is_risky
        ...                     default=${False}

        Log To Console          \n🤖 Attempting Intent: ${step_intent}

        ${step_passed}=         Set Variable                ${False}
        ${last_error}=          Set Variable                ${EMPTY}
        ${failure_mode}=        Set Variable                HARD_KEYWORD_ERROR

        # ── THE FALLBACK LOOP ────────────────────────────────────────────────
        FOR                     ${strategy_actions}         IN                          @{strategies}
            ${strategy_passed}=                             Set Variable                ${True}
            ${temp_passed_actions}=                         Create List

            # ── THE ACTION SEQUENCE LOOP ─────────────────────────────────────
            FOR                 ${action}                   IN                          @{strategy_actions}
                ${keyword}=     Get From Dictionary         ${action}                   keyword
                ${args}=        Get From Dictionary         ${action}                   args                      default=@{EMPTY}
                ${raw_kwargs}=                              Get From Dictionary         ${action}                 kwargs                      default=&{EMPTY}

                # ── KWARGS SANITIZATION ──────────────────────────────────────
                ${is_dict}=     Evaluate                    isinstance($raw_kwargs, dict)
                IF              not ${is_dict}
                    ${raw_kwargs}=                          Create Dictionary
                END

                ${clean_kwargs}=                            Create Dictionary
                FOR             ${key}                      ${val}                      IN                        &{raw_kwargs}
                    ${is_bool}=                             Evaluate                    isinstance($val, bool)
                    IF          ${is_bool}
                        ${str_val}=                         Evaluate                    str($val)
                        Set To Dictionary                   ${clean_kwargs}             ${key}                    ${str_val}
                    ELSE
                        Set To Dictionary                   ${clean_kwargs}             ${key}                    ${val}
                    END
                END

                # ── XPATH ESCAPE: re-inject \= at dispatch time ──────────────
                ${escaped_args}=                            Create List
                FOR             ${arg}                      IN                          @{args}
                    ${is_str}=                              Evaluate                    isinstance($arg, str)
                    IF          ${is_str}
                        ${arg}=                             Evaluate                    JsonSanitizer.escape_xpath_arg($arg)
                    END
                    Append To List                          ${escaped_args}             ${arg}
                END

                # ── CAPTURE STATE BEFORE ACTION ──────────────────────────────
                ${url_before}=                              GetUrl
                Set To Dictionary                           ${action}                   url_before                ${url_before}

                Log To Console                              ↳ Executing: ${keyword}
                ${status}       ${message}=                 Run Keyword And Ignore Error
                ...             ${keyword}                  @{escaped_args}             &{clean_kwargs}

                # ── CAPTURE STATE AFTER ACTION ───────────────────────────────
                ${url_after}=                               GetUrl
                Set To Dictionary                           ${action}                   url_after                 ${url_after}

                IF              '${status}' == 'PASS'

                # ── POST-ACTION SNAG CHECK ───────────────────────────────
                # Determine if this action is a destructive trigger by checking
                # whether any arg (lowercased) matches a word in the trigger list.
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

                        # MANDATORY: drop modal scope so probes search the full page.
                        # The Salesforce snag banner renders outside the modal container.
                        UseModal                            Off

                        # Signal A: Primary snag banner
                        ${snag_found}=                      IsText                      We hit a snag             timeout=3s
                        # Signal B: Field-level validation summary
                        ${review_found}=                    IsText                      Review the following fields                           timeout=2s
                        # Signal C: Inline field error class
                        ${field_error}=                     IsElement
                        ...     xpath=//div[contains(@class,'slds-has-error')]
                        ...     timeout=2s
                        # Signal D: Error toast
                        ${toast_error}=                     IsElement
                        ...     xpath=//*[contains(@class,'slds-theme_error')]
                        ...     timeout=2s

                        ${snag_detected}=                   Evaluate
                        ...     $snag_found or $review_found or $field_error or $toast_error

                        IF      ${snag_detected}
                        # The form is still open. Restore modal scope so the surgeon
                        # can interact with the live form on its next attempt.
                            UseModal                        On

                            # Build a descriptive error message for the surgeon.
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
                            # UseModal Off remains in effect. Next step manages its own scope.
                        END
                    END

                    # Only append to passed list if the snag check also passed.
                    IF          ${strategy_passed}
                        Append To List                      ${temp_passed_actions}      ${action}
                    END

                ELSE
                    ${strategy_passed}=                     Set Variable                ${False}
                    ${failure_mode}=                        Set Variable                HARD_KEYWORD_ERROR
                    ${last_error}=                          Catenate                    SEPARATOR=\n              ${last_error}               [Strategy failed] ${keyword} → ${message}
                    Log To Console                          ↳ Strategy failed at ${keyword}: ${message}.
                    BREAK
                END
            END

            # ── DID THE ENTIRE STRATEGY COMPLETE SUCCESSFULLY? ───────────────
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

        # ── ALL STRATEGIES FAILED: ROUTE TO SURGEON ──────────────────────────
        IF                      not ${step_passed}
            Append To Failed History                        ${step}
            Log To Console      ❌ All strategies failed for: ${step_intent}. Mode: ${failure_mode}. Pausing for Agentic Re-Prompt.

            # Return 5 values: status, failed_step, error_msg, failed_index, failure_mode
            RETURN              FAIL                        ${step}                     ${last_error}             ${index}                    ${failure_mode}
        END
    END

    # PASS path: 5 concrete values to match the FAIL path signature.
    RETURN                      PASS                        ${NONE}                     ${EMPTY}                  -1                          NONE



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
    [Documentation]             Recovers from a failed agentic step by opening a FRESH dialogue thread
    ...                         for the AI Surgeon, uploading a live DOM snapshot, and dispatching a
    ...                         failure-mode-aware, intent-aware surgeon prompt.
    ...
    ...                         v7 fixes:
    ...                         - Fixed ModuleNotFoundError: No module named '{$rem_args_str}{$rem_kwa_suffix}"'
    ...                         - Root cause: Evaluate f"..." lines containing literal spaces inside the
    ...                         string caused Robot Framework's argument parser to split the expression
    ...                         at those spaces, treating the second half as a Python module name.
    ...                         - Fix: replaced all f-string line-building Evaluate calls with Catenate,
    ...                         which accepts each component as a discrete argument and is immune to
    ...                         the space-splitting problem. The SEPARATOR is set to four spaces to
    ...                         produce the same "keyword                               args                      kwargs" output format.
    ...                         - The safe Evaluate calls (join expressions with no spaces) are unchanged.
    [Arguments]                 ${assistant_id}
    ...                         ${failed_step}
    ...                         ${error_message}
    ...                         ${remaining_steps}
    ...                         ${dom_json_path}
    ...                         ${executed_history_json}
    ...                         ${user_intent}
    ...                         ${failure_mode}=HARD_KEYWORD_ERROR

    # ── STEP 1: Preserve original thread ID for audit purposes ─────────────
    ${ORIGINAL_DIALOGUE_ID}=    Set Variable                ${DIALOGUE_ID}
    Log To Console              🔒 Original dialogue preserved: ${ORIGINAL_DIALOGUE_ID}

    # ── STEP 2: Spin up a fresh surgeon dialogue thread ─────────────────────
    Log To Console              🆕 Opening fresh surgeon dialogue...
    Create Dialogue Thread      ${assistant_id}
    Log To Console              ✅ Surgeon dialogue created: ${DIALOGUE_ID}

    # ── STEP 3: Upload the live DOM snapshot ────────────────────────────────
    Log To Console              🏥 Uploading live DOM snapshot to surgeon thread...
    ${attached_file_name}=      Attach Document To Dialogue                             ${dom_json_path}

    # ── STEP 4: Wait for the thread to confirm idle ──────────────────────────
    Log To Console              ⏳ Polling surgeon thread until idle (max 60s)...
    Wait Until Dialogue Is Idle                             max_attempts=12             poll_interval=5s

    # ── STEP 5: Build a clean human-readable summary of the failed step ─────
    #
    # CRITICAL: ${failed_step} is a STEP-level dict with this shape:
    #                           { "intent": "...", "is_risky": ..., "strategies": [ [ {action}, ... ], ... ] }
    #
    # keyword/args/kwargs live inside strategies[0][0] (the representative action).
    # Reading them directly from ${failed_step} always returns "unknown"/empty because
    # those keys do not exist at the step level.

    ${failed_intent}=           Get From Dictionary         ${failed_step}              intent                    default=unknown

    ${failed_strategies}=       Get From Dictionary         ${failed_step}              strategies                default=@{EMPTY}
    ${rep_keyword}=             Set Variable                unknown
    ${rep_args_str}=            Set Variable                (none)
    ${rep_kwargs_str}=          Set Variable                (none)

    ${has_strategies}=          Evaluate                    len($failed_strategies) > 0
    IF                          ${has_strategies}
        ${first_strategy}=      Get From List               ${failed_strategies}        0
        ${has_actions}=         Evaluate                    len($first_strategy) > 0
        IF                      ${has_actions}
            ${rep_action}=      Get From List               ${first_strategy}           0
            ${rep_keyword}=     Get From Dictionary         ${rep_action}               keyword                   default=unknown
            ${rep_args}=        Get From Dictionary         ${rep_action}               args                      default=@{EMPTY}
            ${rep_kwargs}=      Get From Dictionary         ${rep_action}               kwargs                    default=&{EMPTY}
            # Safe Evaluate: join expression contains no spaces, no RF splitting risk.
            ${rep_args_str}=    Evaluate                    ', '.join(str(a) for a in $rep_args)
            # Pre-compute kwargs string, then assign via IF to avoid inline conditional in Evaluate.
            ${rep_kwargs_raw}=                              Evaluate                    ', '.join(f"{k}={v}" for k, v in $rep_kwargs.items())
            IF                  '${rep_kwargs_raw}' != ''
                ${rep_kwargs_str}=                          Set Variable                ${rep_kwargs_raw}
            ELSE
                ${rep_kwargs_str}=                          Set Variable                (none)
            END
        END
    END

    # ── STEP 6: Build a clean numbered list of remaining steps ──────────────
    #
    # FIX v7: line-building now uses Catenate instead of Evaluate f"...".
    # Catenate accepts each component as a discrete argument so RF's parser
    # never sees spaces inside the expression. SEPARATOR is four spaces to
    # produce the "N. Keyword                               args                        kwargs" format.
    #
    # Pattern for each line:
    #                           Catenate                    SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}
    #                           ...                         ${step_num}.                ${rem_kw}                 ${rem_args_str}             ${rem_kwa_suffix}
    # When rem_kwa_suffix is ${EMPTY} the trailing separator is harmless.

    @{remaining_lines}=         Create List
    ${step_num}=                Set Variable                ${1}

    FOR                         ${rem_step}                 IN                          @{remaining_steps}
        ${rem_strategies}=      Get From Dictionary         ${rem_step}                 strategies                default=@{EMPTY}
        ${rem_has_strats}=      Evaluate                    len($rem_strategies) > 0
        IF                      ${rem_has_strats}
            ${rem_first}=       Get From List               ${rem_strategies}           0
            ${rem_has_acts}=    Evaluate                    len($rem_first) > 0
            IF                  ${rem_has_acts}
                ${rem_action}=                              Get From List               ${rem_first}              0
                ${rem_kw}=      Get From Dictionary         ${rem_action}               keyword                   default=unknown
                ${rem_args}=    Get From Dictionary         ${rem_action}               args                      default=@{EMPTY}
                ${rem_kwargs}=                              Get From Dictionary         ${rem_action}             kwargs                      default=&{EMPTY}
                # Safe Evaluate: join expressions contain no spaces, no RF splitting risk.
                ${rem_args_str}=                            Evaluate                    ', '.join(str(a) for a in $rem_args)
                ${rem_kwa_raw}=                             Evaluate                    ', '.join(f"{k}={v}" for k, v in $rem_kwargs.items())
                # Pre-compute the kwarg suffix via IF. No inline conditional in Evaluate.
                IF              '${rem_kwa_raw}' != ''
                    ${rem_kwa_suffix}=                      Set Variable                ${rem_kwa_raw}
                ELSE
                    ${rem_kwa_suffix}=                      Set Variable                ${EMPTY}
                END
                # FIX v7: Catenate builds the line. Each component is a discrete argument.
                # Trailing empty suffix produces no extra separator because Catenate
                # only inserts the separator BETWEEN non-empty components.
                ${step_prefix}=                             Catenate                    SEPARATOR=.${SPACE}       ${step_num}                 ${rem_kw}
                IF              '${rem_kwa_suffix}' != '${EMPTY}'
                    ${rem_line}=                            Catenate
                    ...         SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}
                    ...         ${step_prefix}              ${rem_args_str}             ${rem_kwa_suffix}
                ELSE
                    ${rem_line}=                            Catenate
                    ...         SEPARATOR=${SPACE}${SPACE}${SPACE}${SPACE}
                    ...         ${step_prefix}              ${rem_args_str}
                END
                Append To List                              ${remaining_lines}          ${rem_line}
            END
        END
        ${step_num}=            Evaluate                    ${step_num} + 1
    END

    ${remaining_readable}=      Catenate                    SEPARATOR=\n                @{remaining_lines}
    # ── STEP 7: Build the failure-mode context block (RULE 0) ───────────────
    ${failure_context}=         Set Variable                ${EMPTY}

    IF                          '${failure_mode}' == 'SILENT_APP_ERROR'
        ${failure_context}=     Catenate                    SEPARATOR=\n
        ...                     FAILURE MODE: SILENT_APP_ERROR
        ...                     The QWord executed without error, but a post-action snag check detected
        ...                     a Salesforce validation signal after the destructive action completed.
        ...                     - The browser is still on the SAME FORM. The record was NOT saved.
        ...                     - UseModal is ON. The form is still open and active.
        ...                     - Do NOT propose navigation or re-opening the form.
        ...                     - Read the DOM to find fields flagged slds-has-error or missing required values.
        ...                     - Your corrected_steps MUST fix those fields BEFORE re-attempting Save/Next/Done.
        ...                     - recovery_steps should be empty unless a blocking overlay appeared.
        ...                     DETECTED SIGNAL: ${error_message}
    ELSE
        ${failure_context}=     Catenate                    SEPARATOR=\n
        ...                     FAILURE MODE: HARD_KEYWORD_ERROR
        ...                     A QWord threw an exception. The action did not complete. BEFORE DOING ANYTHING REVIEW THE ATTACHED FILE: ${attached_file_name}. This contains the dom for the active state of the application which will tell you exactly what you need. 
        ...                     - The most likely cause is that a step was missing, hallucinated, or an incorrect value assigned to the step (For example, a picklist value that doesn't exist or a typo to match)
        ...                     - Inspect the DOM and the audit trail URL to determine actual browser state.
        ...                     - recovery_steps may be needed if the browser is in a stuck state.
        ...                     ERROR THROWN: ${error_message}
    END

    # ── STEP 8: Build and send the surgeon prompt ────────────────────────────
    ${surgeon_prompt}=          Catenate                    SEPARATOR=\n
    ...                         ════════════════════════════════════════════
    ...                         ORIGINAL TEST INTENT (why this test exists):
    ...                         ════════════════════════════════════════════
    ...                         ${user_intent}
    ...
    ...                         This surgeon session was triggered during an AI-generated test case
    ...                         built from the intent above. Every recovery decision you make must
    ...                         serve that intent. If a proposed step does not move toward completing
    ...                         that intent, it is wrong.
    ...                         You should understand, this test was AI generated. A lot of guess work has been applied. 
    ...                         Buttons, text, picklist we are trying to interact with can entirely be made up. Your sole 
    ...                         goal should be to use what is available in to you from the JSON dom extraction to complete 
    ...                         the intent successfully.
    ...
    ...                         ════════════════════════════════════════════
    ...                         RULE 0: FAILURE CLASSIFICATION — READ THIS FIRST
    ...                         ════════════════════════════════════════════
    ...                         ${failure_context}
    ...
    ...                         ════════════════════════════════════════════
    ...                         FAILED STEP SUMMARY:
    ...                         ════════════════════════════════════════════
    ...                         Step Intent : ${failed_intent}
    ...                         Keyword                     : ${rep_keyword}
    ...                         Args                        : ${rep_args_str}
    ...                         Kwargs                      : ${rep_kwargs_str}
    ...
    ...                         NOTE: The above shows the PRIMARY strategy action that was attempted.
    ...                         All strategies for this step were exhausted before the surgeon was called.
    ...
    ...                         ════════════════════════════════════════════
    ...                         LIVE DOM FILE:
    ...                         ════════════════════════════════════════════
    ...                         File name: ${attached_file_name}
    ...                         You MUST open and read this file before proposing any corrected steps.
    ...                         Do not fabricate element locators. Every locator must be confirmed in the DOM.
    ...                         Pay special attention to any fields with class slds-has-error or marked
    ...                         as required (*) that appear empty. These are the most likely root cause
    ...                         of Save failures even when the Save button locator itself is correct.
    ...
    ...                         ════════════════════════════════════════════
    ...                         HISTORICAL EXECUTION AUDIT TRAIL (PASSED STEPS):
    ...                         ════════════════════════════════════════════
    ...                         Each entry shows the exact keyword executed and its real before/after URLs.
    ...                         The url_after of the last entry is the ground truth for current browser location.
    ...                         ${executed_history_json}
    ...
    ...                         ════════════════════════════════════════════
    ...                         REMAINING PLANNED STEPS (what still needs to happen):
    ...                         ════════════════════════════════════════════
    ...                         ${remaining_readable}
    ...
    ...                         ════════════════════════════════════════════
    ...                         YOUR MISSION:
    ...                         ════════════════════════════════════════════
    ...
    ...                         RULE 1: CROSS-STATE VERIFICATION (do this FIRST)
    ...                         Reconcile the audit trail and the DOM as a single combined state signal.
    ...                         a. The url_after of the last passed step is ground truth for browser location.
    ...                         b. Confirm the DOM elements match what you expect at that URL.
    ...                         c. If the DOM reveals a different screen than the failed step assumed,
    ...                         treat the entire remaining plan as potentially invalid and reconstruct.
    ...
    ...                         RULE 2: URL PARAMETER DIAGNOSTIC PARSING
    ...                         Parse ALL URL parameters as diagnostic signals. Known Salesforce signals:
    ...                         - useRecordTypeCheck=1: record type gate is open, form fields not yet rendered.
    ...                         - navigationLocation=LIST_VIEW: launched from list view context.
    ...                         - nooverride=1: standard override suppressed.
    ...                         Account for any gate or flow state in your corrected steps.
    ...
    ...                         RULE 3: MISSING STEP DETECTION
    ...                         Ask: "Are there steps never planned but required to reach the assumed state?"
    ...                         If yes, insert them into corrected_steps BEFORE the originally failed step.
    ...                         Common patterns: record type selection, modal confirmation dialogs,
    ...                         permission overlays, missing required field values (for SILENT_APP_ERROR).
    ...                         IMPORTANT: If the DOM shows any required field (*) that is empty or flagged
    ...                         with slds-has-error, you MUST insert a TypeText or PickList step to populate
    ...                         it BEFORE re-attempting Save. Do not skip unknown required fields.
    ...
    ...                         RULE 4: recovery_steps vs corrected_steps
    ...                         recovery_steps: one-time actions to exit a stuck/broken browser state RIGHT NOW.
    ...                         Empty if the browser is already in a recoverable position.
    ...                         For SILENT_APP_ERROR: almost always empty (form is still open).
    ...                         corrected_steps: the FULL plan from recovered state onward, including
    ...                         inserted missing steps, the corrected failed step, and all remaining steps.
    ...
    ...                         RULE 5: DOM SCOPE LIMITATION FLAGGING
    ...                         If a remaining step targets elements NOT in the attached DOM (because that
    ...                         screen is not yet rendered), flag it with "dom_verified": false and note
    ...                         that a second snapshot is required. Do NOT assign confidence above 70 for
    ...                         any step you cannot confirm in the DOM.
    ...
    ...                         RULE 6: FIX THE FAILED STEP WITH BACKUP STRATEGIES
    ...                         Provide at least two strategy arrays for the corrected failed step:
    ...                         - Strategy 1 (Primary): best corrected action using DOM-confirmed attributes.
    ...                         - Strategy 2 (Backup): XPath fallback using ClickElement. Escape equals signs:
    ...                         ClickElement                xpath=//button[@title\='Save']
    ...                         -NOTE backup should only be an xpath IF you have the dom available for the given step. For elements not present at this stage, you should never guess an xpath or recommend a backup you are not absolutely confident in.
    ...
    ...                         ════════════════════════════════════════════
    ...                         OUTPUT FORMAT — STRICT JSON ONLY:
    ...                         ════════════════════════════════════════════
    ...                         Output ONLY the raw JSON object below. No markdown, no prose, no explanation.
    ...
    ...                         {
    ...                         "escalate": false,
    ...                         "escalation_reason": "",
    ...                         "recovery_steps": [],
    ...                         "corrected_steps": [
    ...                         {
    ...                         "intent": "Description of the action",
    ...                         "is_risky": false,
    ...                         "dom_verified": true,
    ...                         "confidence_score": 95,
    ...                         "strategies": [
    ...                         [ { "keyword": "ClickText", "args": ["Next"], "kwargs": {} } ],
    ...                         [ { "keyword": "ClickElement", "args": ["xpath=//button[normalize-space()\='Next']"], "kwargs": {} } ]
    ...                         ]
    ...                         }
    ...                         ]
    ...                         }
    ...
    ...                         SCHEMA RULES:
    ...                         - dom_verified: true only if element confirmed in the attached DOM file.
    ...                         - confidence_score must reflect actual DOM evidence. Max 70 if dom_verified is false.
    ...                         - corrected_steps must include ALL steps from this point forward.
    ...                         - escalate: true with a clear escalation_reason if no safe recovery path exists.

    Send Message To Agent       ${assistant_id}             ${surgeon_prompt}
    Sleep                       10s
    ${ai_reply}=                Retrieve Agent Reply

    # ── STEP 9: Record surgeon-proposed corrections ──────────────────────────
    ${surgeon_steps}=           Extract Agent JSON Reply    ${ai_reply}
    FOR                         ${step}                     IN                          @{surgeon_steps}
        Append To Proposed Steps                            ${step}
    END

    Log To Console              🏁 Surgeon reply received from thread: ${DIALOGUE_ID}

    RETURN                      ${ai_reply}





Generate Initial Test Steps
    [Documentation]             Compiles the system rules, schema instructions, and
    ...                         user intent into a unified prompt payload for the AI.
    ...                         Utilizes native retries to guard against cloud API flakiness.
    [Arguments]                 ${assistant_id}             ${user_intent}

    ${system_rules}=            Generate Agentic System Prompt

    ${final_architect_prompt}=                              Catenate                    SEPARATOR=\n
    ...                         ${system_rules}
    ...
    ...                         USER INTENT FOR THIS SCENARIO:
    ...                         ${user_intent}
    ...
    ...                         Generate the JSON steps according to the rules and schema format above now.
    ...                         Consider this scenario as already signed into Salesforce with JwtAuthenticate and JWTLogin waiting idly at the home page.

    # Guard the API message injection and reply extraction layer with explicit retries
    Send Message To Agent       ${assistant_id}             ${final_architect_prompt}
    Sleep                       10
    ${ai_reply}=                Retrieve Agent Reply
    ${parsed_steps}=            Extract Agent JSON Reply    ${ai_reply}
    Set All Proposed Steps      @{parsed_steps}
    RETURN                      ${ai_reply}


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
        ${messages}=            Get From Dictionary         ${ai_final_reply}           messages                  default=${NONE}
        IF                      $messages == $NONE or len($messages) == 0
            Fail                Parser Error: dialogue_data contains no messages.
        END
        # Walk messages to find the last AI (assistant) turn
        ${ai_content}=          Set Variable                ${NONE}
        FOR                     ${msg}                      IN                          @{messages}
            ${role}=            Get From Dictionary         ${msg}                      role                      default=${EMPTY}
            IF                  '${role}' == 'ai'
                ${ai_content}=                              Get From Dictionary         ${msg}                    content                     default=${NONE}
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
            ${artifact}=        Get From Dictionary         ${item}                     artifact                  default=${NONE}
            IF                  $artifact != $NONE
                ${raw_text}=    Get From Dictionary         ${item}                     text
                BREAK
            END
            ${text_val}=        Get From Dictionary         ${item}                     text                      default=${EMPTY}
            ${stripped}=        Evaluate                    str($text_val).strip()

            # Safe native string probing
            ${starts_with_bracket}=                         Run Keyword And Return Status                         Should Start With           ${stripped}        [
            ${starts_with_brace}=                           Run Keyword And Return Status                         Should Start With           ${stripped}        {
            IF                  ${starts_with_bracket} or ${starts_with_brace}
                ${raw_text}=    Set Variable                ${text_val}
                BREAK
            END
        END
    END

    # Guard: after unwrapping, raw_text must now be a string
    ${is_still_non_string}=     Evaluate                    not isinstance($raw_text, str)
    IF                          ${is_still_non_string}
        Log To Console          🚨 FATAL: raw_text type=${raw_text.__class__.__name__} | value=${raw_text}
        Fail                    Parser Error: Input could not be reduced to a JSON string after unwrapping.
    END

    # ── STEP 2: SANITIZE + PARSE (delegated to Python library) ─────────────
    # parse_ai_json_reply() handles fence stripping, escape flattening,
    # invalid escape removal, and XPath \= re-injection in pure Python,
    # with no Robot Framework escaping-layer interference.
    ${parsed_json}=             Evaluate                    JsonSanitizer.parse_ai_json_reply($raw_text)
    # ${parsed_json}=             Evaluate                    JsonSanitizer.parse_ai_json_reply($raw_text)    modules=JsonSanitizer
    Log To Console              Stack Parser: Contract extraction completed successfully.

    RETURN                      ${parsed_json}






    #######Step Returns#####

    # ════════════════════════════════════════════════════════════════════
    # AGENTIC STEP TRACKING - Getters, Setters, and Appenders
    # ════════════════════════════════════════════════════════════════════

Get All Proposed Steps
    [Documentation]             Returns the full list of every step the AI has suggested so far.
    RETURN                      @{ALL_PROPOSED_STEPS}

Get Execution History Passed
    [Documentation]             Returns the list of steps that executed without throwing a CRT error.
    RETURN                      @{EXECUTION_HISTORY_PASSED}

Get Execution History Failed
    [Documentation]             Returns the list of steps that threw a CRT error during execution.
    RETURN                      @{EXECUTION_HISTORY_FAILED}

Get Golden Path Script
    [Documentation]             Returns the final optimized sequence to be saved as the real test asset.
    RETURN                      @{GOLDEN_PATH_SCRIPT}

    # ── Appenders (used internally by the execution engine) ─────────────

Append To Proposed Steps
    [Documentation]             Adds a single step entry to ALL_PROPOSED_STEPS at suite scope.
    [Arguments]                 ${step}
    Append To List              ${ALL_PROPOSED_STEPS}       ${step}
    Set Suite Variable          @{ALL_PROPOSED_STEPS}       @{ALL_PROPOSED_STEPS}

Append To Passed History
    [Documentation]             Records a step that passed execution into EXECUTION_HISTORY_PASSED.
    [Arguments]                 ${step}
    Append To List              ${EXECUTION_HISTORY_PASSED}                             ${step}
    Set Suite Variable          @{EXECUTION_HISTORY_PASSED}                             @{EXECUTION_HISTORY_PASSED}

Append To Failed History
    [Documentation]             Records a step that failed execution into EXECUTION_HISTORY_FAILED.
    [Arguments]                 ${step}
    Append To List              ${EXECUTION_HISTORY_FAILED}                             ${step}
    Set Suite Variable          @{EXECUTION_HISTORY_FAILED}                             @{EXECUTION_HISTORY_FAILED}

Append To Golden Path
    [Documentation]             Adds a confirmed optimized step to the GOLDEN_PATH_SCRIPT.
    [Arguments]                 ${step}
    Append To List              ${GOLDEN_PATH_SCRIPT}       ${step}
    Set Suite Variable          @{GOLDEN_PATH_SCRIPT}       @{GOLDEN_PATH_SCRIPT}

    # ── Full list setters (for bulk replacement, e.g. after AI reply parsing) ──

Set All Proposed Steps
    [Documentation]             Replaces ALL_PROPOSED_STEPS entirely with a new list.
    [Arguments]                 @{steps}
    Set Suite Variable          @{ALL_PROPOSED_STEPS}       @{steps}

Set Golden Path Script
    [Documentation]             Replaces GOLDEN_PATH_SCRIPT entirely with a new list.
    [Arguments]                 @{steps}
    Set Suite Variable          @{GOLDEN_PATH_SCRIPT}       @{steps}