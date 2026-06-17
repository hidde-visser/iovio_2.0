*** Settings ***
Documentation                   Example resource file with custom keywords. NOTE: Some keywords below may need
...                             minor changes to work in different instances.
Library                         QForce
Library                         String
Library                         DateTime
Library                         OperatingSystem
Library                         ../resources/ObjectSanitizer.py
Resource                        ../resources/MetadataRetrieval.robot
Library                         ../resources/DomParserLibrary.py
Library                         ../resources/ExplorationSessionLibrary.py
Resource                        ../resources/CopadoAI.robot


*** Variables ***
# IMPORTANT: Please read the readme.txt to understand needed variables and how to handle them!!
${BROWSER}                      chrome
${home_url}                     ${login_url}/lightning/page/home
${SANDBOX}                      False


*** Keywords ***
Setup Browser
    # Setting search order is not really needed here, but given as an example
    # if you need to use multiple libraries containing keywords with duplicate names
    Set Library Search Order    QForce                      QWeb
    Open Browser                about:blank                 ${BROWSER}
    SetConfig                   LineBreak                   ${EMPTY}                    #\ue000
    Evaluate                    random.seed()               random                      # initialize random generator
    SetConfig                   DefaultTimeout              45s                         #sometimes salesforce is slow
    # adds a delay of 0.3 between keywords. This is helpful in cloud with limited resources.
    SetConfig                   Delay                       0.3

End suite
    Close All Browsers

UI Login Via JWT
    [Documentation]             Opens browser and logs in via JWT frontdoor.jsp — no password screen.
    ...                         Uses CLIENT_ID, USERNAME, SERVER_KEY and SANDBOX from Project Settings.
    OpenBrowser                 about:blank                 ${BROWSER}
    SetConfig                   DefaultTimeout              45s
    SetConfig                   LineBreak                   ${EMPTY}
    JwtAuthenticate             ${CLIENT_ID}                ${USERNAME}                 ${SERVER_KEY}               sandbox=${SANDBOX}
    JwtLogin                    /lightning/page/home

Login
    [Documentation]             Login to Salesforce instance. Takes instance_url, username and password as
    ...                         arguments. Uses values given in Copado Robotic Testing's variables section by default.
    [Arguments]                 ${sf_instance_url}=${login_url}                         ${sf_username}=${username}                             ${sf_password}=${password}
    GoTo                        ${sf_instance_url}
    TypeText                    Username                    ${sf_username}              delay=1
    TypeSecret                  Password                    ${sf_password}
    ClickText                   Log In
    # We'll check if variable ${secret} is given. If yes, fill the MFA dialog.
    # If not, MFA is not expected.
    # ${secret} is ${None} unless specifically given.
    ${MFA_needed}=              Run Keyword And Return Status                           Should Not Be Equal         ${None}                    ${secret}
    Run Keyword If              ${MFA_needed}               Fill MFA                    ${sf_username}              ${secret}                  ${sf_instance_url}


Login As
    [Documentation]             Login As different persona. User needs to be logged into Salesforce with Admin rights
    ...                         before calling this keyword to change persona.
    ...                         Example:
    ...                         LoginAs                     Chatter Expert
    [Arguments]                 ${persona}
    ClickText                   Setup
    ClickItem                   Setup                       delay=1
    SwitchWindow                NEW
    TypeText                    Search Setup                ${persona}                  delay=2
    ClickElement                //*[@title\="${persona}"]                               delay=2                     # wait for list to populate, then click
    VerifyText                  Freeze                      timeout=45                  # this is slow, needs longer timeout
    ClickText                   Login                       anchor=Freeze               partial_match=False         delay=1


Fill MFA
    [Documentation]             Gets the MFA OTP code and fills the verification dialog (if needed)
    [Arguments]                 ${sf_username}=${username}                              ${mfa_secret}=${secret}     ${sf_instance_url}=${login_url}
    ${mfa_code}=                GetOTP                      ${sf_username}              ${mfa_secret}               ${login_url}
    TypeSecret                  Verification Code           ${mfa_code}
    ClickText                   Verify


Home
    [Documentation]             Example appstarte: Navigate to homepage, login if needed
    GoTo                        ${home_url}
    ${login_status} =           IsText                      To access this page, you have to log in to Salesforce.                             2
    Run Keyword If              ${login_status}             Login
    ClickText                   Home
    VerifyTitle                 Home | Salesforce


    # Example of custom keyword with robot fw syntax. NOTE: These keywords may need to be adjusted
    # to work in your environment
VerifyStage
    [Documentation]             Verifies that stage given in ${text} is at ${selected} state; either selected (true) or not selected (false)
    [Arguments]                 ${text}                     ${selected}=true
    VerifyElement               //a[@title\="${text}" and (@aria-checked\="${selected}" or @aria-selected\="${selected}")]


VerifyStageColor
    [Documentation]             Example keyword on how to verify background color of element.
    ...                         Note that this keyword might need adjusting in your instance (colors and locators can be different)
    [Arguments]                 ${stage_text}               ${color}=navy
    &{COLORS}=                  Create Dictionary           navy=rgba(1, 68, 134, 1)    green=rgba(59, 167, 85, 1)

    ${elem}=                    GetWebElement               ${stage_text}               element_type=item
    ${background_color}=        Evaluate                    $elem.value_of_css_property("background-color")
    Should Be Equal             ${COLORS.${color}}          ${background_color}         msg=Error: Background color ( ${background_color}) differs from ${color} (${COLORS.${color}})


NoData
    VerifyNoItem                ${data}                     tag=a                       timeout=3                   delay=2


DeleteAccounts
    [Documentation]             RunBlock to remove all data until it doesn't exist anymore
    ClickText                   ${data}
    ClickText                   Delete
    VerifyText                  Are you sure you want to delete this account?
    ClickText                   Delete                      2
    VerifyText                  Undo
    VerifyNoText                Undo
    ClickText                   Accounts                    partial_match=False


DeleteLeads
    [Documentation]             RunBlock to remove all data until it doesn't exist anymore
    ClickText                   ${data}
    ClickText                   Delete
    VerifyText                  Are you sure you want to delete this lead?
    ClickText                   Delete                      2
    VerifyText                  Undo
    VerifyNoText                Undo
    ClickText                   Leads                       partial_match=False

    # In common.robot
Capture Page Elements
    [Documentation]             Captures the live page DOM, cleanses it, names it contextually,
    ...                         saves it to a JSON file on disk, and returns the absolute file path.
    ${body_html}=               Get Attribute               //body                      outerHTML
    ${json_output}=             Parse Elements From HTML    ${body_html}
    ${file_name}=               Extract Page Name           ${json_output}
    ${ts}=                      Get Current Date            result_format=%Y%m%d_%H%M%S

    ${target_path}=             Set Variable                ${OUTPUT_DIR}/${file_name}_${ts}.json
    Create File                 ${target_path}              ${json_output}

    RETURN                      ${target_path}

Run Agentic Test Scenario
    [Documentation]             Top-level orchestrator for the agentic test execution loop.
    ...                         Unified with:
    ...                         - Fix 1 (Type Guard Intercept)
    ...                         - Fix 2 (Index-based Circuit Breaker)
    ...                         - Fix 4 (Data Isolation Suite Reset)
    ...                         - V0.12: Dynamic Test Naming & Screenshot Integration
    [Arguments]                 ${assistant_id}             ${user_intent}              ${metadata_json_path}=${NONE}

    Log To Console              🚀 Starting Agentic Scenario for Intent: ${user_intent}

    # ── FIX 4: DATA ISOLATION SUITE RESET ────────────────────────────────────
    # Reset tracking arrays so previous scenarios do not bleed into this execution thread
    @{ALL_PROPOSED_STEPS}=      Create List
    Set Suite Variable          @{ALL_PROPOSED_STEPS}
    @{EXECUTION_HISTORY_PASSED}=                            Create List
    Set Suite Variable          @{EXECUTION_HISTORY_PASSED}
    @{EXECUTION_HISTORY_FAILED}=                            Create List
    Set Suite Variable          @{EXECUTION_HISTORY_FAILED}
    @{GOLDEN_PATH_SCRIPT}=      Create List
    Set Suite Variable          @{GOLDEN_PATH_SCRIPT}
    # ─────────────────────────────────────────────────────────────────────────

    # Only attach the metadata file if a path was actually provided and exists.
    IF                          $metadata_json_path != $NONE and $metadata_json_path != '${EMPTY}'
        Log To Console          📦 Attaching Salesforce Org Metadata Contract...
        Wait Until Keyword Succeeds                         10x
        ...                     2s                          Attach Document To Dialogue                             ${DIALOGUE_ID}             ${metadata_json_path}
    END

    ${ai_reply}=                Generate Initial Test Steps
    ...                         ${assistant_id}             ${user_intent}
    ${active_steps}=            Extract Agent JSON Reply    ${ai_reply}

    # ── V0.12: DYNAMIC TEST NAMING ───────────────────────────────────────────
    ${test_name}=               Generate Agentic Test Name                              ${assistant_id}             ${DIALOGUE_ID}             ${user_intent}
    Log To Console              🏷️ Test named as: ${test_name}
    # ─────────────────────────────────────────────────────────────────────────

    ${global_retries}=          Set Variable                0
    ${MAX_GLOBAL_RETRIES}=      Set Variable                50
    ${step_retries}=            Set Variable                0
    ${MAX_STEP_RETRIES}=        Set Variable                10

    # ── FIX 2: CIRCUIT BREAKER INITIALIZATION ────────────────────────────────
    # Initialize tracker as an index integer instead of a volatile intent string
    ${last_failed_index}=       Set Variable                -2
    # ─────────────────────────────────────────────────────────────────────────

    TRY
        WHILE                   ${global_retries} < ${MAX_GLOBAL_RETRIES}

            Log To Console      ▶️ Executing Active Step Queue...

            # Execute Agentic JSON Steps returns 5 values
            ${status}           ${failed_step}              ${error_msg}                ${failed_index}
            ...                 ${failure_mode}=            Execute Agentic JSON Steps
            ...                 ${active_steps}
            ...                 ${user_intent}

            IF                  '${status}' == 'PASS'
                Log To Console                              ✅ Scenario completed successfully!
                BREAK
            END

            # ── FIX 2: INDEX-BASED CIRCUIT BREAKER RETRY EVALUATION ──────────
            IF                  $failed_index == $last_failed_index
                ${step_retries}=                            Evaluate                    ${step_retries} + 1
            ELSE
                ${step_retries}=                            Set Variable                1
                ${last_failed_index}=                       Set Variable                ${failed_index}
            END

            IF                  ${step_retries} >= ${MAX_STEP_RETRIES}
                Log To Console                              🛑 FATAL: Stuck looping on step index [${failed_index}] 3 consecutive times.
                Log To Console                              Mode: ${failure_mode}.
                Log To Console                              Error: ${error_msg}

                # Pure Robot Framework replacement to verify negative testing intent
                ${user_intent_lower}=                       Convert To Lower Case       ${user_intent}
                ${is_negative_test}=                        Set Variable                ${False}
                @{boundary_words}=                          Create List                 exceed                      limit                      error                 validation             invalid    boundary

                FOR             ${word}                     IN                          @{boundary_words}
                    ${contains}=                            Run Keyword And Return Status                           Should Contain             ${user_intent_lower}             ${word}
                    IF          ${contains}
                        ${is_negative_test}=                Set Variable                ${True}
                        BREAK
                    END
                END

                IF              ${is_negative_test}
                    Fail        Potential Defect Found: AI stuck looping on verification step. Expected application to enforce validation limits/error banners, but the operation proceeded and application state shifted. Intent: ${user_intent}
                ELSE
                    Fail        Agentic Loop Aborted: AI is looping or blocked by Business Logic.
                END
            END
            # ─────────────────────────────────────────────────────────────────

            Log To Console      ⚠️ AI Intervention Required. Mode: ${failure_mode}. Capturing DOM and Screenshot...
            ${dom_json_path}=                               Capture Page Elements

            # --- Capture Screenshot ---
            ${ts}=              Get Current Date            result_format=%Y%m%d_%H%M%S
            ${screenshot_name}=                             Set Variable                ${test_name}_failure_${ts}.png
            ${screenshot_path}=                             Set Variable                ${OUTPUT_DIR}/${screenshot_name}

            # QWeb's LogScreenshot forces its own naming convention (screenshot-<test>-<uuid>.png).
            # We capture its returned path and copy it to our custom test-named path.
            ${qweb_screenshot}=                             LogScreenshot
            Copy File           ${qweb_screenshot}          ${screenshot_path}
            Sleep               1s
            # -------------------------------

            ${remaining_steps}=                             Get Slice From List         ${active_steps}             ${failed_index + 1}
            ${remaining_json}=                              Evaluate                    json.dumps($remaining_steps)                           json

            # Serialize the successful step history to pass to the surgeon.
            ${executed_history_json}=                       Evaluate                    json.dumps($EXECUTION_HISTORY_PASSED)                  json

            Log To Console      🏥 Calling AI Surgeon for recovery. Failure mode: ${failure_mode}
            ${ai_reply}=        Resolve Step Failure
            ...                 ${assistant_id}
            ...                 ${failed_step}
            ...                 ${error_msg}
            ...                 ${remaining_steps}
            ...                 ${dom_json_path}
            ...                 ${screenshot_path}
            ...                 ${executed_history_json}
            ...                 ${user_intent}
            ...                 ${failure_mode}

            ${surgeon_payload}=                             Extract Agent JSON Reply    ${ai_reply}

            # ── FIX 1: NON-DICTIONARY TYPE GUARD ─────────────────────────────
            ${is_dict}=         Evaluate                    isinstance($surgeon_payload, dict)
            IF                  not ${is_dict}
                Log To Console                              🛑 CRITICAL: AI Surgeon returned a non-dictionary payload type.
                Fail            Agentic Loop Aborted: AI Surgeon layout breakdown. Value received: ${surgeon_payload}
            END
            # ─────────────────────────────────────────────────────────────────

            ${escalate}=        Get From Dictionary         ${surgeon_payload}          escalate                    default=${False}
            IF                  ${escalate}
                ${reason}=      Get From Dictionary         ${surgeon_payload}          escalation_reason
                Log To Console                              🛑 BUSINESS LOGIC BLOCKER: ${reason}
                Fail            AI Escalated the test. Reason: ${reason}
            END

            ${recovery_steps}=                              Get From Dictionary         ${surgeon_payload}          recovery_steps             default=@{EMPTY}
            IF                  ${recovery_steps}
                Log To Console                              🩹 Executing Silent Recovery Steps...
                FOR             ${rec_action}               IN                          @{recovery_steps}
                    ${rec_kw}=                              Get From Dictionary         ${rec_action}               keyword                    default=UNKNOWN_KEYWORD

                    IF          '${rec_kw}' == 'UNKNOWN_KEYWORD'
                        Log To Console                      ⚠️ Skipping recovery step: AI returned malformed JSON missing 'keyword'.
                        CONTINUE
                    END

                    ${rec_args}=                            Get From Dictionary         ${rec_action}               args                       default=@{EMPTY}
                    ${rec_kwa}=                             Get From Dictionary         ${rec_action}               kwargs                     default=&{EMPTY}
                    Log To Console                          \ \ \ \ ${rec_kw}
                    Run Keyword And Ignore Error            ${rec_kw}                   @{rec_args}                 &{rec_kwa}
                END
            END

            ${active_steps}=    Get From Dictionary         ${surgeon_payload}          corrected_steps             default=@{EMPTY}
            ${global_retries}=                              Evaluate                    ${global_retries} + 1
        END

        IF                      ${global_retries} >= ${MAX_GLOBAL_RETRIES}
            Fail                ❌ Global retry limit (${MAX_GLOBAL_RETRIES}) exceeded. Scenario aborted.
        END

    FINALLY
    # Pass the active assistant_id and the dynamically generated test name to the compiler
        Compile Golden Path Script                          ${DIALOGUE_ID}              ${assistant_id}             ${test_name}
    END